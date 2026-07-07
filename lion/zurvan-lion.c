/*
 * zurvan-lion — guardian of /data (v2 milestone 4).
 *
 * A small snapshot daemon, meant to be read top to bottom like the PID 1 and
 * zurvan-svc. Its only job is protecting the memory box: periodically pack
 * all of /data (except its own snapshot directory — no snowballing) into one
 * compressed archive plus a manifest, keep the last N in a ring, and put a
 * chosen snapshot back on request.
 *
 * It runs as an ordinary supervised service (see /etc/svc/lion.def) and, like
 * zurvan-svc, parses NO YAML: the provisioner digests the YAML lion: block
 * into a flat /run/lion.conf (every=24h, keep=7 — both optional, those are
 * the defaults). The heavy lifting is delegated to busybox tar and sha256sum;
 * this program is the policy, not the plumbing.
 *
 * Layout under /data/lion/:
 *
 *   lion-YYYYMMDD-HHMMSS.tar.gz     one snapshot (UTC stamp; names sort by age)
 *   lion-YYYYMMDD-HHMMSS.manifest   created=<epoch> size=<bytes> sha256=<hex>
 *   .new-*                          in-flight temp files; never trusted, swept
 *
 * THE TWO GUARDRAILS (non-negotiable, from the roadmap):
 *
 *   1. Atomicity: a snapshot is written under a temp name, fsynced, and
 *      renamed into place — archive first, manifest last. A power cut leaves
 *      the previous good snapshot untouched, never a corrupt new one. An
 *      archive without a manifest is garbage by definition and gets swept.
 *
 *   2. The guardian must never become the threat: if /data runs low the lion
 *      deletes its OWN oldest snapshots first — but never the single newest
 *      good one (deleting your only backup to make room for a hopeful new
 *      one is how backups die). If space still doesn't suffice, it logs and
 *      skips the cycle rather than filling the disk.
 *
 * Restores verify the manifest checksum BEFORE unpacking; a corrupt archive
 * is refused, not "tried". Restoring overlays /data (files deleted since the
 * snapshot come back; files created since remain) — services holding state
 * open should be restarted after, or restore before enabling them.
 *
 * Usage:
 *   zurvan-lion daemon           supervised mode: snapshot on schedule
 *   zurvan-lion snap             take one snapshot now
 *   zurvan-lion list             list snapshots
 *   zurvan-lion restore <name>            unpack <name> OVER /data (overlay):
 *                                         files in the snapshot come back;
 *                                         files added since are kept.
 *   zurvan-lion restore --mirror <name>   make /data EXACTLY the snapshot:
 *                                         files added since are DELETED. Its
 *                                         own snapshot dir is always preserved.
 */

#define _XOPEN_SOURCE 700         /* nftw; also popen, gmtime_r, fileno, statvfs */
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <dirent.h>
#include <fcntl.h>
#include <ftw.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define DATA_DIR   "/data"
#define LION_DIR   "/data/lion"
#define CONF_PATH  "/run/lion.conf"

#define DEF_EVERY  (24 * 3600)   /* one snapshot a day */
#define DEF_KEEP   7             /* keep a week */

#define MAX_SNAPS  128
#define NAME_LEN   64
#define PATH_LEN   512          /* LION_DIR + a full d_name always fits */
#define LINE_LEN   256

#define RETRY_SECS   600         /* after a failed cycle, try again in 10 min */
#define MARGIN_BYTES (4LL << 20) /* keep at least this much free after a snap */

static long every = DEF_EVERY;
static int  keep  = DEF_KEEP;

/* --- tiny helpers ---------------------------------------------------------- */

static void lion_log(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("[lion] ", stdout);
	vfprintf(stdout, fmt, ap);
	fputc('\n', stdout);
	fflush(stdout);
	va_end(ap);
}

static void chomp(char *s)
{
	size_t n = strlen(s);
	while (n && (s[n-1] == '\n' || s[n-1] == '\r' || s[n-1] == ' '))
		s[--n] = '\0';
}

/* fork/exec/wait; returns the child's exit status, or -1. No shell involved,
 * so snapshot paths never meet quoting. */
static int run(char *const argv[])
{
	pid_t pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		execvp(argv[0], argv);
		_exit(127);
	}
	int status;
	while (waitpid(pid, &status, 0) < 0)
		;
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/* /data is only worth snapshotting if something is mounted there: compare
 * device ids with the root. RAM-only boxes just make the lion idle. */
static int data_mounted(void)
{
	struct stat a, b;
	if (stat(DATA_DIR, &a) != 0 || stat("/", &b) != 0)
		return 0;
	return a.st_dev != b.st_dev;
}

static long long free_bytes(void)
{
	struct statvfs vfs;
	if (statvfs(DATA_DIR, &vfs) != 0)
		return -1;
	return (long long)vfs.f_bavail * (long long)vfs.f_frsize;
}

/* sha256 of a file via busybox sha256sum; hex (64 chars) into out. */
static int sha256_of(const char *path, char *out, size_t outsz)
{
	char cmd[PATH_LEN + 16];
	snprintf(cmd, sizeof cmd, "sha256sum %s", path);
	FILE *p = popen(cmd, "r");
	if (!p)
		return -1;
	int ok = fscanf(p, "%64s", out) == 1 && strlen(out) == 64;
	(void)outsz;
	pclose(p);
	return ok ? 0 : -1;
}

/* --- the snapshot ring ------------------------------------------------------ */

/* A snapshot exists iff its .manifest does (the manifest is renamed into
 * place LAST, so its presence certifies a complete archive). Names sort
 * chronologically because the stamp is fixed-width UTC. */
static int snap_names(char names[][NAME_LEN])
{
	DIR *d = opendir(LION_DIR);
	if (!d)
		return 0;

	int n = 0;
	struct dirent *e;
	while ((e = readdir(d)) && n < MAX_SNAPS) {
		const char *dot = strstr(e->d_name, ".manifest");
		if (strncmp(e->d_name, "lion-", 5) != 0 || !dot || dot[9] != '\0')
			continue;
		size_t len = (size_t)(dot - e->d_name);
		if (len >= NAME_LEN)
			continue;
		memcpy(names[n], e->d_name, len);
		names[n][len] = '\0';
		n++;
	}
	closedir(d);

	/* insertion sort; MAX_SNAPS is small */
	for (int i = 1; i < n; i++)
		for (int j = i; j > 0 && strcmp(names[j-1], names[j]) > 0; j--) {
			char tmp[NAME_LEN];
			memcpy(tmp, names[j-1], NAME_LEN);
			memcpy(names[j-1], names[j], NAME_LEN);
			memcpy(names[j], tmp, NAME_LEN);
		}
	return n;
}

/* manifest_get NAME KEY -> malloc-free static value, or "" */
static const char *manifest_get(const char *name, const char *key)
{
	static char val[LINE_LEN];
	val[0] = '\0';

	char path[PATH_LEN];
	snprintf(path, sizeof path, LION_DIR "/%s.manifest", name);
	FILE *f = fopen(path, "r");
	if (!f)
		return val;

	size_t klen = strlen(key);
	char line[LINE_LEN];
	while (fgets(line, sizeof line, f)) {
		chomp(line);
		if (strncmp(line, key, klen) == 0 && line[klen] == '=') {
			snprintf(val, sizeof val, "%s", line + klen + 1);
			break;
		}
	}
	fclose(f);
	return val;
}

static void delete_snap(const char *name, const char *why)
{
	char path[PATH_LEN];
	snprintf(path, sizeof path, LION_DIR "/%s.tar.gz", name);
	unlink(path);
	snprintf(path, sizeof path, LION_DIR "/%s.manifest", name);
	unlink(path);
	lion_log("deleted %s (%s)", name, why);
}

/* Sweep in-flight temp files and orphaned archives (no manifest): both are
 * the debris of an interrupted snapshot and were never trusted. */
static void sweep(void)
{
	DIR *d = opendir(LION_DIR);
	if (!d)
		return;
	struct dirent *e;
	while ((e = readdir(d))) {
		char path[PATH_LEN];
		if (strncmp(e->d_name, ".new-", 5) == 0) {
			snprintf(path, sizeof path, LION_DIR "/%s", e->d_name);
			unlink(path);
			continue;
		}
		const char *ext = strstr(e->d_name, ".tar.gz");
		if (strncmp(e->d_name, "lion-", 5) == 0 && ext && ext[7] == '\0') {
			char man[PATH_LEN];
			snprintf(man, sizeof man, LION_DIR "/%.*s.manifest",
			         (int)(ext - e->d_name), e->d_name);
			if (access(man, F_OK) != 0) {
				snprintf(path, sizeof path, LION_DIR "/%s", e->d_name);
				unlink(path);
				lion_log("swept orphaned %s (no manifest)", e->d_name);
			}
		}
	}
	closedir(d);
}

/* Delete oldest snapshots until at most max_left remain (but see guardrail 2:
 * callers pass max_left >= 1 when pruning for space). */
static void prune_to(int max_left, const char *why)
{
	char names[MAX_SNAPS][NAME_LEN];
	int n = snap_names(names);
	for (int i = 0; n - i > max_left; i++)
		delete_snap(names[i], why);
}

/* --- taking a snapshot -------------------------------------------------------- */

static time_t newest_created(void)
{
	char names[MAX_SNAPS][NAME_LEN];
	int n = snap_names(names);
	if (n == 0)
		return 0;
	return (time_t)atoll(manifest_get(names[n-1], "created"));
}

static long long newest_size(void)
{
	char names[MAX_SNAPS][NAME_LEN];
	int n = snap_names(names);
	if (n == 0)
		return 0;
	return atoll(manifest_get(names[n-1], "size"));
}

static int snapshot(void)
{
	if (!data_mounted()) {
		lion_log("no /data disk mounted — nothing to guard.");
		return -1;
	}
	mkdir(LION_DIR, 0700);
	sweep();

	/* Guardrail 2, part 1: make room BEFORE writing. Estimate the new
	 * snapshot at the newest one's size (they're siblings) plus 25% and a
	 * fixed margin; eat oldest snapshots — never the newest — until it fits. */
	long long need = newest_size();
	need = need + need / 4 + MARGIN_BYTES;
	while (free_bytes() >= 0 && free_bytes() < need) {
		char names[MAX_SNAPS][NAME_LEN];
		int n = snap_names(names);
		if (n <= 1)
			break;                     /* the last good snapshot is sacred */
		delete_snap(names[0], "making room");
	}

	/* Names have one-second resolution and a manual `snap` can race the
	 * daemon: temp names carry our pid so two writers never share a file,
	 * and a stamp that already exists is waited out, never reused. */
	char stamp[32], name[NAME_LEN];
	char tmp_arch[PATH_LEN], arch[PATH_LEN], tmp_man[PATH_LEN], man[PATH_LEN];
	time_t now;
	for (;;) {
		now = time(NULL);
		struct tm tm;
		gmtime_r(&now, &tm);
		strftime(stamp, sizeof stamp, "%Y%m%d-%H%M%S", &tm);
		snprintf(name, sizeof name, "lion-%s", stamp);
		snprintf(arch, sizeof arch, LION_DIR "/%s.tar.gz",   name);
		snprintf(man,  sizeof man,  LION_DIR "/%s.manifest", name);
		if (access(arch, F_OK) != 0 && access(man, F_OK) != 0)
			break;
		sleep(1);
	}
	snprintf(tmp_arch, sizeof tmp_arch, LION_DIR "/.new-%s.%d.tar.gz",
	         name, (int)getpid());
	snprintf(tmp_man,  sizeof tmp_man,  LION_DIR "/.new-%s.%d.manifest",
	         name, (int)getpid());

	/* Everything except our own directory — no snowballing. Both exclude
	 * spellings so the subtree is skipped regardless of tar's matching. */
	char *tar_argv[] = {
		"tar", "-czf", tmp_arch, "-C", DATA_DIR,
		"--exclude", "./lion", "--exclude", "./lion/*", ".", NULL,
	};
	lion_log("snapshotting " DATA_DIR " -> %s.tar.gz", name);
	int rc = run(tar_argv);
	if (rc != 0) {
		/* Guardrail 2, part 2: an ENOSPC mid-write is the likely cause;
		 * eat one more old snapshot (again sparing the newest) and retry
		 * once. Anything else: give up loudly, leave nothing behind. */
		unlink(tmp_arch);
		char names[MAX_SNAPS][NAME_LEN];
		int n = snap_names(names);
		if (n > 1) {
			delete_snap(names[0], "retry after failed write");
			rc = run(tar_argv);
		}
		if (rc != 0) {
			unlink(tmp_arch);
			lion_log("ERROR: tar failed (rc %d) — snapshot skipped", rc);
			return -1;
		}
	}

	struct stat st;
	char sha[80];
	if (stat(tmp_arch, &st) != 0 || sha256_of(tmp_arch, sha, sizeof sha) != 0) {
		unlink(tmp_arch);
		lion_log("ERROR: cannot stat/checksum the new archive — skipped");
		return -1;
	}

	/* Guardrail 1: fsync the archive, rename it, THEN the manifest — its
	 * appearance is the commit point — and fsync the directory so the
	 * renames themselves survive a power cut. */
	int fd = open(tmp_arch, O_RDONLY);
	if (fd >= 0) { fsync(fd); close(fd); }

	FILE *f = fopen(tmp_man, "w");
	if (!f) {
		unlink(tmp_arch);
		lion_log("ERROR: cannot write manifest — skipped");
		return -1;
	}
	fprintf(f, "created=%lld\nsize=%lld\nsha256=%s\n",
	        (long long)now, (long long)st.st_size, sha);
	fflush(f);
	fsync(fileno(f));
	fclose(f);

	if (rename(tmp_arch, arch) != 0 || rename(tmp_man, man) != 0) {
		unlink(tmp_arch); unlink(tmp_man); unlink(arch);
		lion_log("ERROR: rename failed — skipped");
		return -1;
	}
	int dfd = open(LION_DIR, O_RDONLY);
	if (dfd >= 0) { fsync(dfd); close(dfd); }

	lion_log("snapshot %s done (%lld bytes, sha256 %.12s...)",
	         name, (long long)st.st_size, sha);

	prune_to(keep, "ring buffer");
	return 0;
}

/* --- restore ------------------------------------------------------------------ */

/* recursive remove (depth-first, don't follow symlinks) */
static int rm_cb(const char *p, const struct stat *s, int t, struct FTW *f)
{
	(void)s; (void)t; (void)f;
	remove(p);
	return 0;
}
static void rm_rf(const char *path) { nftw(path, rm_cb, 16, FTW_DEPTH | FTW_PHYS); }

static int restore(const char *arg, int mirror)
{
	/* Accept "lion-STAMP", bare "STAMP", or a full filename; then validate
	 * hard — this string ends up in paths. */
	char name[NAME_LEN];
	if (strncmp(arg, "lion-", 5) == 0)
		snprintf(name, sizeof name, "%s", arg);
	else
		snprintf(name, sizeof name, "lion-%s", arg);
	char *ext = strstr(name, ".tar.gz");
	if (ext)
		*ext = '\0';
	for (const char *p = name + 5; *p; p++)
		if (!((*p >= '0' && *p <= '9') || *p == '-')) {
			lion_log("ERROR: '%s' is not a snapshot name", arg);
			return -1;
		}

	char arch[PATH_LEN];
	snprintf(arch, sizeof arch, LION_DIR "/%s.tar.gz", name);
	const char *want = manifest_get(name, "sha256");
	if (!want[0] || access(arch, R_OK) != 0) {
		lion_log("ERROR: no snapshot %s (see: zurvan-lion list)", name);
		return -1;
	}

	/* The checksum is verified BEFORE any restore is trusted. */
	char have[80];
	if (sha256_of(arch, have, sizeof have) != 0 || strcmp(have, want) != 0) {
		lion_log("ERROR: %s fails its checksum — corrupt, refusing to restore", name);
		return -1;
	}
	if (!mirror) {
		/* Overlay: unpack over /data. Files in the snapshot come back;
		 * anything created since is left untouched. The safe default. */
		lion_log("checksum verified; restoring %s over " DATA_DIR " (overlay)", name);
		char *tar_argv[] = { "tar", "-xzf", arch, "-C", DATA_DIR, NULL };
		if (run(tar_argv) != 0) {
			lion_log("ERROR: unpack failed — /data may be partially restored");
			return -1;
		}
		lion_log("restore done. Restart affected services (or reboot) to pick it up.");
		return 0;
	}

	/* Mirror: make /data EXACTLY the snapshot. Extract to a scratch dir first,
	 * then delete everything in /data (except our own snapshot dir) and move
	 * the extracted tree into place. Extract-first means a tar failure never
	 * deletes anything. This DISCARDS files created after the snapshot. */
	lion_log("checksum verified; MIRROR-restoring %s (extra files will be removed)", name);
	char tmp[PATH_LEN];
	snprintf(tmp, sizeof tmp, DATA_DIR "/.lion-restore.%d", (int)getpid());
	rm_rf(tmp);
	if (mkdir(tmp, 0700) != 0) {
		lion_log("ERROR: cannot make scratch dir — aborted, nothing changed");
		return -1;
	}
	char *ex_argv[] = { "tar", "-xzf", arch, "-C", tmp, NULL };
	if (run(ex_argv) != 0) {
		rm_rf(tmp);
		lion_log("ERROR: unpack failed — aborted, /data untouched");
		return -1;
	}

	/* wipe /data except the snapshot dir (lion) and our scratch dir */
	DIR *d = opendir(DATA_DIR);
	if (d) {
		struct dirent *e;
		while ((e = readdir(d))) {
			if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..") ||
			    !strcmp(e->d_name, "lion"))
				continue;
			char p[PATH_LEN];
			snprintf(p, sizeof p, DATA_DIR "/%s", e->d_name);
			if (strcmp(p, tmp) == 0)
				continue;
			rm_rf(p);
		}
		closedir(d);
	}
	/* move the snapshot's contents into /data (same filesystem: atomic renames) */
	d = opendir(tmp);
	if (d) {
		struct dirent *e;
		while ((e = readdir(d))) {
			if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
				continue;
			char src[PATH_LEN + 288], dst[PATH_LEN + 288];
			snprintf(src, sizeof src, "%s/%s", tmp, e->d_name);
			snprintf(dst, sizeof dst, DATA_DIR "/%s", e->d_name);
			rename(src, dst);
		}
		closedir(d);
	}
	rm_rf(tmp);
	lion_log("mirror restore done: " DATA_DIR " now matches %s. Restart services or reboot.", name);
	return 0;
}

/* --- list ----------------------------------------------------------------------- */

static int list(void)
{
	char names[MAX_SNAPS][NAME_LEN];
	int n = snap_names(names);
	if (n == 0) {
		lion_log("no snapshots in " LION_DIR);
		return 0;
	}
	for (int i = 0; i < n; i++) {
		time_t c = (time_t)atoll(manifest_get(names[i], "created"));
		long long sz = atoll(manifest_get(names[i], "size"));
		char when[32] = "?";
		struct tm tm;
		if (c && gmtime_r(&c, &tm))
			strftime(when, sizeof when, "%Y-%m-%d %H:%M:%S", &tm);
		printf("%s  %s UTC  %lld bytes%s\n",
		       names[i], when, sz, i == n - 1 ? "  (newest)" : "");
	}
	return 0;
}

/* --- config + daemon -------------------------------------------------------------- */

/* every: accepts 3600, 90m, 24h, 7d ... (bare number = seconds). */
static long parse_every(const char *s)
{
	char *end;
	long v = strtol(s, &end, 10);
	if (v <= 0)
		return -1;
	switch (*end) {
	case '\0': case 's': return v;
	case 'm': return v * 60;
	case 'h': return v * 3600;
	case 'd': return v * 86400;
	default:  return -1;
	}
}

static void load_conf(void)
{
	FILE *f = fopen(CONF_PATH, "r");
	if (!f)
		return;
	char line[LINE_LEN];
	while (fgets(line, sizeof line, f)) {
		chomp(line);
		if (strncmp(line, "every=", 6) == 0) {
			long v = parse_every(line + 6);
			if (v > 0)
				every = v;
			else
				lion_log("WARNING: bad every '%s' — using default", line + 6);
		} else if (strncmp(line, "keep=", 5) == 0) {
			int v = atoi(line + 5);
			if (v >= 1)
				keep = v;
			else
				lion_log("WARNING: bad keep '%s' — using default", line + 5);
		}
	}
	fclose(f);
}

static int daemon_loop(void)
{
	load_conf();
	lion_log("guarding " DATA_DIR ": every %lds, keep %d.", every, keep);

	if (data_mounted()) {
		mkdir(LION_DIR, 0700);
		sweep();
	}

	for (;;) {
		if (!data_mounted()) {
			sleep(30);          /* RAM-only box: nothing to guard, stay calm */
			continue;
		}
		time_t last = newest_created();
		time_t now  = time(NULL);
		/* No snapshot yet -> take one immediately: a box is guarded from
		 * its first boot, not from tomorrow. */
		if (last == 0 || now >= last + every) {
			if (snapshot() != 0) {
				sleep(RETRY_SECS);
				continue;
			}
			last = newest_created();
		}
		time_t due = last + every;
		long wait = (long)(due - time(NULL));
		if (wait < 5)
			wait = 5;
		if (wait > 60)
			wait = 60;          /* short ticks: survive clock jumps + config honesty */
		sleep((unsigned)wait);
	}
	return 0;
}

/* --- main ----------------------------------------------------------------------- */

int main(int argc, char **argv)
{
	signal(SIGHUP,  SIG_IGN);
	signal(SIGPIPE, SIG_IGN);

	const char *cmd = argc > 1 ? argv[1] : "";
	if (strcmp(cmd, "daemon") == 0)
		return daemon_loop();
	if (strcmp(cmd, "snap") == 0) {
		load_conf();
		return snapshot() == 0 ? 0 : 1;
	}
	if (strcmp(cmd, "list") == 0)
		return list();
	if (strcmp(cmd, "restore") == 0) {
		/* restore [--mirror] <name> */
		int mirror = 0, i = 2;
		if (argc > 2 && strcmp(argv[2], "--mirror") == 0) { mirror = 1; i = 3; }
		if (i < argc)
			return restore(argv[i], mirror) == 0 ? 0 : 1;
	}

	fprintf(stderr,
	        "usage: zurvan-lion daemon | snap | list | restore [--mirror] <name>\n");
	return 2;
}
