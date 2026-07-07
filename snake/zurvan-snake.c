/*
 * zurvan-snake — work that leaves no trace (v2 milestone 5).
 *
 * The lion's mirror twin: where the lion makes things permanent, the snake
 * makes work perfectly disposable. Give it a job (a script, a build, a
 * cron-shaped task) and it runs it in a FRESH TMPFS SANDBOX IN ITS OWN MOUNT
 * NAMESPACE, returns the result, and the sandbox evaporates with the
 * namespace. The host filesystem is never touched.
 *
 * This is only *safe* because of Zurvan's architecture: the OS is already
 * disposable and the root is sealed read-only, so a messy or misbehaving job
 * costs nothing. It is a minimal CI-runner / scratch-executor primitive —
 * NOT a container runtime: mount namespace + tmpfs + timeout is the whole
 * isolation story. No images, no network/pid namespaces, no OCI.
 *
 * How the sandbox is built (in the child, before the job runs):
 *
 *   1. unshare(CLONE_NEWNS) + make every mount recursively private — mount
 *      changes in here propagate nowhere.
 *   2. bind-remount / read-only (a no-op under the seal, a guarantee under
 *      zurvan.rw).
 *   3. fresh private tmpfs over every writable surface: /tmp (the job's
 *      64 MB workspace) and — crucially — /data, /run, /var/run, /var/log.
 *      The permanent world isn't protected from the job; it simply IS NOT
 *      THERE. The lion's den, the YAML, service state: an empty tmpfs.
 *   4. the job runs as /tmp/job/job, cwd /tmp/job, no_new_privs, in its own
 *      session (one kill(-pgid) reaps everything it spawned).
 *
 * What crosses back — and nothing else does:
 *   - exit status         (run mode: our exit code; queue mode: results/status)
 *   - captured output     (run mode: live on stdout; queue mode: results/log)
 *   - declared artifacts  (regular files the job left in $ARTIFACTS —
 *                          copied out through directory fds opened BEFORE the
 *                          namespace hid /data; top-level files only)
 *
 * Jobs arrive two ways:
 *   zurvan-snake run [--timeout N] <script|->     one job now, over SSH/console
 *   zurvan-snake daemon                            watch /data/snake/queue/
 *
 * The daemon (an ordinary supervised service, see /etc/svc/snake.def) picks
 * queue files oldest-first, runs each with the default timeout, and leaves
 * /data/snake/results/<name>-<stamp>/ = { job, log, status, artifacts/ }.
 * The queue file is consumed at pickup: at-most-once — a crash mid-job must
 * not re-run a possibly-destructive job, and the results dir keeps the copy.
 */

#define _GNU_SOURCE
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define QUEUE_DIR    "/data/snake/queue"
#define RESULTS_DIR  "/data/snake/results"
#define JOB_DIR      "/tmp/job"                /* inside the sandbox */
#define ART_DIR      "/tmp/job/artifacts"

#define DEF_TIMEOUT  300                       /* seconds */
#define POLL_SECS    5
#define NAME_LEN     64
#define PATH_LEN     512

static void snake_log(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("[snake] ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	fflush(stderr);
	va_end(ap);
}

/* --- small plumbing ---------------------------------------------------------- */

static int copy_fd(int in, int out)
{
	char buf[65536];
	ssize_t n;
	while ((n = read(in, buf, sizeof buf)) > 0) {
		char *p = buf;
		while (n > 0) {
			ssize_t w = write(out, p, (size_t)n);
			if (w < 0)
				return -1;
			p += w;
			n -= w;
		}
	}
	return n < 0 ? -1 : 0;
}

static int data_mounted(void)
{
	struct stat a, b;
	if (stat("/data", &a) != 0 || stat("/", &b) != 0)
		return 0;
	return a.st_dev != b.st_dev;
}

static void stamp_now(char *out, size_t sz)
{
	time_t now = time(NULL);
	struct tm tm;
	gmtime_r(&now, &tm);
	strftime(out, sz, "%Y%m%d-%H%M%S", &tm);
}

/* --- the sandbox (runs in the forked child) ----------------------------------- */

static void mount_tmpfs(const char *path, const char *opts)
{
	/* Best effort: a path that doesn't exist in this image just isn't a
	 * writable surface to hide. Everything vital is checked by the caller. */
	mount("tmpfs", path, "tmpfs", MS_NOSUID | MS_NODEV, opts);
}

/* Build the sandbox and exec the job. job_fd is the script (opened before
 * the namespace hid its origin), art_fd the real results/artifacts dir or
 * -1, log_fd the capture file or -1 (inherit = run mode's live output).
 * Exits with the job's status; 125 means the sandbox itself failed. */
static void sandbox_child(int job_fd, int art_fd, int log_fd)
{
	if (log_fd >= 0) {
		dup2(log_fd, STDOUT_FILENO);
		dup2(log_fd, STDERR_FILENO);
		close(log_fd);
	}

	/* Own session: the timeout kill(-pgid) reaps the whole job tree. */
	setsid();

	if (unshare(CLONE_NEWNS) != 0) {
		snake_log("ERROR: unshare(CLONE_NEWNS): %s", strerror(errno));
		_exit(125);
	}
	/* Nothing we mount from here on is visible outside this namespace. */
	if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
		snake_log("ERROR: cannot make mounts private: %s", strerror(errno));
		_exit(125);
	}
	/* Under the seal / is already ro; under zurvan.rw this makes the
	 * sandbox's view ro anyway. Best effort by design. */
	mount(NULL, "/", NULL, MS_REMOUNT | MS_BIND | MS_RDONLY, NULL);

	/* The job's whole writable world, fresh and private. /data first: the
	 * permanent world is not protected from the job — it is NOT THERE. */
	mount_tmpfs("/data",    "size=16m,mode=0755");
	mount_tmpfs("/run",     "size=16m,mode=0755");
	mount_tmpfs("/var/run", "size=16m,mode=0755");
	mount_tmpfs("/var/log", "size=16m,mode=0755");
	if (mount("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV,
	          "size=64m,mode=1777") != 0) {
		snake_log("ERROR: cannot mount the job tmpfs: %s", strerror(errno));
		_exit(125);
	}

	if (mkdir(JOB_DIR, 0700) != 0 || mkdir(ART_DIR, 0700) != 0) {
		snake_log("ERROR: cannot lay out %s", JOB_DIR);
		_exit(125);
	}

	/* Materialize the script inside the sandbox (its origin — queue file,
	 * host path, stdin spool — may not exist in here). */
	int jf = open(JOB_DIR "/job", O_WRONLY | O_CREAT | O_EXCL, 0700);
	if (jf < 0 || lseek(job_fd, 0, SEEK_SET) < 0 || copy_fd(job_fd, jf) != 0) {
		snake_log("ERROR: cannot materialize the job script");
		_exit(125);
	}
	close(jf);
	close(job_fd);
	if (chdir(JOB_DIR) != 0)
		_exit(125);

	/* The job (and everything it forks) can never gain privileges. */
	prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);

	char *const envp[] = {
		(char *)"PATH=/bin:/sbin:/usr/bin:/usr/sbin",
		(char *)"HOME=" JOB_DIR,
		(char *)"TMPDIR=/tmp",
		(char *)"ARTIFACTS=" ART_DIR,
		NULL,
	};
	char *const argv[] = { (char *)JOB_DIR "/job", NULL };

	pid_t job = fork();
	if (job < 0)
		_exit(125);
	if (job == 0) {
		execve(argv[0], argv, envp);
		if (errno == ENOEXEC) {         /* plain script, no shebang */
			char *const shargv[] =
				{ (char *)"/bin/sh", (char *)JOB_DIR "/job", NULL };
			execve("/bin/sh", shargv, envp);
		}
		snake_log("ERROR: cannot exec the job: %s", strerror(errno));
		_exit(126);
	}

	int status;
	while (waitpid(job, &status, 0) < 0 && errno == EINTR)
		;

	/* Declared artifacts cross back through art_fd — a handle into the REAL
	 * /data grabbed before this namespace replaced it. Top-level regular
	 * files only; an artifact "tree" is a job that should make a tarball. */
	if (art_fd >= 0) {
		DIR *d = opendir(ART_DIR);
		struct dirent *e;
		int n = 0;
		while (d && (e = readdir(d))) {
			char p[PATH_LEN];
			struct stat st;
			snprintf(p, sizeof p, ART_DIR "/%s", e->d_name);
			if (stat(p, &st) != 0 || !S_ISREG(st.st_mode))
				continue;
			int in = open(p, O_RDONLY);
			int out = openat(art_fd, e->d_name,
			                 O_WRONLY | O_CREAT | O_TRUNC, 0644);
			if (in >= 0 && out >= 0 && copy_fd(in, out) == 0)
				n++;
			if (in >= 0)  close(in);
			if (out >= 0) close(out);
		}
		if (d)
			closedir(d);
		if (n)
			snake_log("%d artifact(s) delivered", n);
	}

	if (WIFEXITED(status))
		_exit(WEXITSTATUS(status));
	_exit(WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 125);
}

/* --- running one job (parent side) --------------------------------------------- */

/* Returns the job's exit code; 124 = timeout (the sandbox and everything in
 * it was killed), 125 = sandbox failure. */
static int run_one(int job_fd, int res_fd, int art_fd, int log_fd, int timeout)
{
	time_t started = time(NULL);

	pid_t child = fork();
	if (child < 0)
		return 125;
	if (child == 0)
		sandbox_child(job_fd, art_fd, log_fd);   /* never returns */

	int status = 0, code, timed_out = 0;
	for (;;) {
		pid_t r = waitpid(child, &status, WNOHANG);
		if (r == child)
			break;
		if (time(NULL) - started >= timeout) {
			/* The child setsid()ed: one negative kill takes the runner,
			 * the job, and everything the job spawned. The namespace —
			 * and every byte the job wrote — evaporates with them. */
			kill(-child, SIGKILL);
			while (waitpid(child, &status, 0) < 0 && errno == EINTR)
				;
			timed_out = 1;
			break;
		}
		sleep(1);
	}
	code = timed_out ? 124
	     : WIFEXITED(status) ? WEXITSTATUS(status) : 125;

	if (res_fd >= 0) {
		int sf = openat(res_fd, "status", O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (sf >= 0) {
			dprintf(sf, "exit=%d\ntimeout=%d\nstarted=%lld\nended=%lld\n",
			        code, timed_out,
			        (long long)started, (long long)time(NULL));
			close(sf);
		}
	}
	return code;
}

/* Prepare /data/snake/results/<name>-<stamp>/ (+ artifacts/, + a copy of the
 * job for the record). Fills res_fd/art_fd (-1s when /data is absent). */
static int prep_results(const char *name, int job_fd,
                        int *res_fd, int *art_fd, char *id, size_t idsz)
{
	*res_fd = *art_fd = -1;
	if (!data_mounted())
		return -1;

	char stamp[32], path[PATH_LEN];
	stamp_now(stamp, sizeof stamp);
	snprintf(id, idsz, "%s-%s", name, stamp);

	mkdir("/data/snake", 0755);
	mkdir(RESULTS_DIR, 0755);
	snprintf(path, sizeof path, RESULTS_DIR "/%s", id);
	if (mkdir(path, 0755) != 0 && errno == EEXIST) {
		/* same name in the same second: disambiguate with our pid */
		snprintf(id, idsz, "%s-%s.%d", name, stamp, (int)getpid());
		snprintf(path, sizeof path, RESULTS_DIR "/%s", id);
		if (mkdir(path, 0755) != 0)
			return -1;
	}

	*res_fd = open(path, O_RDONLY | O_DIRECTORY);
	mkdirat(*res_fd, "artifacts", 0755);
	*art_fd = openat(*res_fd, "artifacts", O_RDONLY | O_DIRECTORY);

	int jf = openat(*res_fd, "job", O_WRONLY | O_CREAT | O_TRUNC, 0700);
	if (jf >= 0) {
		lseek(job_fd, 0, SEEK_SET);
		copy_fd(job_fd, jf);
		close(jf);
	}
	return 0;
}

/* --- run mode -------------------------------------------------------------------- */

/* "-" spools stdin to an unlinked temp file so the sandbox (whose /tmp is
 * fresh) can still materialize it from the fd. */
static int open_job(const char *arg)
{
	if (strcmp(arg, "-") != 0)
		return open(arg, O_RDONLY);

	char tmpl[] = "/tmp/snake-stdin.XXXXXX";
	int fd = mkstemp(tmpl);
	if (fd < 0)
		return -1;
	unlink(tmpl);
	if (copy_fd(STDIN_FILENO, fd) != 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static int cmd_run(int argc, char **argv)
{
	int timeout = DEF_TIMEOUT;
	int i = 0;
	if (argc > 1 && strcmp(argv[0], "--timeout") == 0) {
		timeout = atoi(argv[1]);
		if (timeout <= 0) {
			snake_log("ERROR: bad --timeout");
			return 2;
		}
		i = 2;
	}
	if (i >= argc) {
		snake_log("ERROR: no job given");
		return 2;
	}

	int job_fd = open_job(argv[i]);
	if (job_fd < 0) {
		snake_log("ERROR: cannot read job %s", argv[i]);
		return 2;
	}

	/* Results are kept when there's a /data to keep them on; a RAM-only
	 * box still runs the job and streams its output. */
	const char *base = strrchr(argv[i], '/');
	base = base ? base + 1 : argv[i];
	char name[NAME_LEN];
	snprintf(name, sizeof name, "%s", strcmp(argv[i], "-") == 0 ? "stdin" : base);

	char id[NAME_LEN + 40] = "";
	int res_fd, art_fd;
	prep_results(name, job_fd, &res_fd, &art_fd, id, sizeof id);

	int code = run_one(job_fd, res_fd, art_fd, -1 /* live output */, timeout);

	if (code == 124)
		snake_log("job TIMED OUT after %ds — sandbox killed", timeout);
	if (id[0])
		snake_log("job %s: exit=%d, results in " RESULTS_DIR "/%s",
		          name, code, id);
	return code;
}

/* --- queue daemon ------------------------------------------------------------------ */

static int name_ok(const char *s)
{
	if (!s[0] || s[0] == '.')
		return 0;
	for (; *s; s++)
		if (!(( *s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') ||
		      ( *s >= '0' && *s <= '9') || *s == '.' || *s == '_' || *s == '-'))
			return 0;
	return 1;
}

/* Oldest queue entry by mtime, or -1. */
static int pick_job(char *name, size_t sz)
{
	DIR *d = opendir(QUEUE_DIR);
	if (!d)
		return -1;
	struct dirent *e;
	time_t best = 0;
	int found = -1;
	while ((e = readdir(d))) {
		size_t len = strlen(e->d_name);
		/* A name that doesn't fit would truncate into a path that never
		 * unlinks — the daemon would spin on it forever. Skip it loudly. */
		if (len >= sz) {
			snake_log("ignoring over-long queue entry %.20s...", e->d_name);
			continue;
		}
		if (!name_ok(e->d_name))
			continue;
		char p[PATH_LEN];
		struct stat st;
		snprintf(p, sizeof p, QUEUE_DIR "/%s", e->d_name);
		if (stat(p, &st) != 0 || !S_ISREG(st.st_mode))
			continue;
		if (found < 0 || st.st_mtime < best) {
			best = st.st_mtime;
			memcpy(name, e->d_name, len + 1);
			found = 0;
		}
	}
	closedir(d);
	return found;
}

static int cmd_daemon(void)
{
	signal(SIGHUP,  SIG_IGN);
	signal(SIGPIPE, SIG_IGN);
	snake_log("watching " QUEUE_DIR " (timeout %ds per job).", DEF_TIMEOUT);

	for (;;) {
		if (!data_mounted()) {
			sleep(30);              /* RAM-only box: no queue to watch */
			continue;
		}
		mkdir("/data/snake", 0755);
		mkdir(QUEUE_DIR, 0755);
		mkdir(RESULTS_DIR, 0755);

		char name[NAME_LEN];
		if (pick_job(name, sizeof name) != 0) {
			sleep(POLL_SECS);
			continue;
		}

		char qpath[PATH_LEN];
		snprintf(qpath, sizeof qpath, QUEUE_DIR "/%s", name);
		int job_fd = open(qpath, O_RDONLY);
		/* Consume at pickup: at-most-once. A crash mid-job must not re-run
		 * a possibly-destructive job; the results dir keeps the copy. */
		unlink(qpath);
		if (job_fd < 0)
			continue;

		char id[NAME_LEN + 40] = "";
		int res_fd, art_fd;
		prep_results(name, job_fd, &res_fd, &art_fd, id, sizeof id);
		int log_fd = res_fd >= 0
			? openat(res_fd, "log", O_WRONLY | O_CREAT | O_TRUNC, 0644)
			: -1;

		snake_log("job %s -> %s", name, id[0] ? id : "(no /data results)");
		int code = run_one(job_fd, res_fd, art_fd, log_fd, DEF_TIMEOUT);
		snake_log("job %s: exit=%d%s", name, code,
		          code == 124 ? " (TIMED OUT)" : "");

		close(job_fd);
		if (log_fd >= 0) close(log_fd);
		if (art_fd >= 0) close(art_fd);
		if (res_fd >= 0) close(res_fd);
	}
	return 0;
}

/* --- main ---------------------------------------------------------------------------- */

int main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : "";
	if (strcmp(cmd, "run") == 0 && argc > 2)
		return cmd_run(argc - 2, argv + 2);
	if (strcmp(cmd, "daemon") == 0)
		return cmd_daemon();

	fprintf(stderr,
	        "usage: zurvan-snake run [--timeout N] <script|->   run one job now\n"
	        "       zurvan-snake daemon                          watch " QUEUE_DIR "\n");
	return 2;
}
