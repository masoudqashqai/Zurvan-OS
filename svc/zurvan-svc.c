/*
 * zurvan-svc — the babysitter (v2 milestone 2).
 *
 * A declarative service supervisor, meant to be read top to bottom like the
 * PID 1. It starts the enabled services in dependency order, restarts the
 * ones that die (with backoff), and logs what it did. That is the whole
 * feature: no socket activation, no cgroups, no parallel-start optimizer.
 *
 * PID 1 does not grow for this — it supervises zurvan-svc exactly the way it
 * supervises the console shell, and zurvan-svc supervises everything else.
 *
 * There is deliberately NO YAML in this file. The system has one YAML parser
 * (the provisioner); by the time we run, the shell layer has digested
 * everything into trivial files:
 *
 *   /run/svc/enabled      one enabled service name per line
 *                         (written by the provisioner from the services: list)
 *   /etc/svc/NAME.def     definitions baked into the image (e.g. ssh)
 *   /run/svc/NAME.def     definitions exported from package manifests by
 *                         zurvan-pkg (these win over /etc/svc)
 *
 * A .def is flat key=value:
 *
 *   exec=/bin/dropbear -F -R     command line, split on spaces (no quoting)
 *   after=networking             space-separated names to wait for
 *   restart=yes                  restart on death (anything else: leave dead)
 *
 * A dependency with no .def of its own (e.g. "networking", which rc.init
 * already brought up) is assumed satisfied — the supervisor babysits daemons,
 * it does not model the world.
 *
 * The main loop is a one-second heartbeat: reap whatever died, start whatever
 * is due. Restarts back off 1s -> 2s -> ... -> 30s and reset after a service
 * stays up a minute. This process never exits (PID 1 would just respawn it).
 */

#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAX_SVCS   32
#define MAX_DEPS    8
#define MAX_ARGS   16
#define NAME_LEN   64
#define LINE_LEN  256

#define BACKOFF_MIN     1   /* seconds */
#define BACKOFF_MAX    30
#define STABLE_SECS    60   /* up this long => backoff resets */

struct svc {
	char   name[NAME_LEN];
	char   exec[LINE_LEN];              /* command line, split at spawn */
	char   deps[MAX_DEPS][NAME_LEN];
	int    ndeps;
	int    restart;
	pid_t  pid;                         /* 0 = not running */
	time_t started_at;
	time_t due_at;                      /* next (re)start time; 0 = not due */
	int    backoff;
	int    gave_up;                     /* restart=no and it died */
};

static struct svc svcs[MAX_SVCS];
static int nsvcs;

/* --- tiny helpers ---------------------------------------------------------- */

static void logf(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("[svc] ", stdout);
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

static struct svc *find(const char *name)
{
	for (int i = 0; i < nsvcs; i++)
		if (strcmp(svcs[i].name, name) == 0)
			return &svcs[i];
	return NULL;
}

/* --- loading ---------------------------------------------------------------- */

/* Fill in exec/after/restart for s from the first existing .def:
 * /run/svc (package exports) wins over /etc/svc (image built-ins). */
static int load_def(struct svc *s)
{
	char path[LINE_LEN];
	FILE *f = NULL;
	const char *dirs[] = { "/run/svc", "/etc/svc", NULL };

	for (int i = 0; dirs[i] && !f; i++) {
		snprintf(path, sizeof path, "%s/%s.def", dirs[i], s->name);
		f = fopen(path, "r");
	}
	if (!f)
		return -1;

	char line[LINE_LEN];
	while (fgets(line, sizeof line, f)) {
		chomp(line);
		if (strncmp(line, "exec=", 5) == 0) {
			snprintf(s->exec, sizeof s->exec, "%s", line + 5);
		} else if (strncmp(line, "restart=", 8) == 0) {
			s->restart = strcmp(line + 8, "yes") == 0;
		} else if (strncmp(line, "after=", 6) == 0) {
			char *tok = strtok(line + 6, " ");
			while (tok && s->ndeps < MAX_DEPS) {
				snprintf(s->deps[s->ndeps++], NAME_LEN, "%s", tok);
				tok = strtok(NULL, " ");
			}
		}
	}
	fclose(f);
	return s->exec[0] ? 0 : -1;
}

static void load_enabled(void)
{
	FILE *f = fopen("/run/svc/enabled", "r");
	if (!f) {
		logf("nothing enabled (/run/svc/enabled missing) — idling.");
		return;
	}

	char line[LINE_LEN];
	while (fgets(line, sizeof line, f) && nsvcs < MAX_SVCS) {
		chomp(line);
		if (!line[0] || line[0] == '#' || find(line))
			continue;

		struct svc *s = &svcs[nsvcs];
		memset(s, 0, sizeof *s);
		snprintf(s->name, sizeof s->name, "%s", line);
		if (load_def(s) != 0) {
			logf("WARNING: no definition for '%s' — skipping "
			     "(want %s.def in /etc/svc or a package service: block)",
			     s->name, s->name);
			continue;
		}
		s->backoff = BACKOFF_MIN;
		s->due_at  = time(NULL);        /* due immediately, deps permitting */
		nsvcs++;
	}
	fclose(f);
	logf("%d service(s) enabled.", nsvcs);
}

/* --- running ----------------------------------------------------------------- */

/* A dependency is satisfied if it's running, or if we don't manage it at all
 * (rc.init targets like "networking"). A managed-but-dead dep blocks. */
static int deps_ready(const struct svc *s)
{
	for (int i = 0; i < s->ndeps; i++) {
		const struct svc *d = find(s->deps[i]);
		if (d && d->pid == 0)
			return 0;
	}
	return 1;
}

static void spawn(struct svc *s)
{
	char cmd[LINE_LEN];
	char *argv[MAX_ARGS];
	int argc = 0;

	snprintf(cmd, sizeof cmd, "%s", s->exec);
	char *tok = strtok(cmd, " ");
	while (tok && argc < MAX_ARGS - 1) {
		argv[argc++] = tok;
		tok = strtok(NULL, " ");
	}
	argv[argc] = NULL;
	if (argc == 0)
		return;

	pid_t pid = fork();
	if (pid < 0) {
		logf("fork failed for %s; retrying in %ds", s->name, s->backoff);
		s->due_at = time(NULL) + s->backoff;
		return;
	}
	if (pid == 0) {
		/* Own session: a dying service can't take siblings with it. */
		setsid();
		char *const envp[] = {
			"PATH=/bin:/sbin:/usr/bin:/usr/sbin",
			"HOME=/root",
			NULL,
		};
		execve(argv[0], argv, envp);
		_exit(127);
	}

	s->pid = pid;
	s->started_at = time(NULL);
	s->due_at = 0;
	logf("started %s (pid %d)", s->name, (int)pid);

	char path[LINE_LEN];
	snprintf(path, sizeof path, "/run/svc/%s.pid", s->name);
	FILE *f = fopen(path, "w");
	if (f) { fprintf(f, "%d\n", (int)pid); fclose(f); }
}

static void reap(void)
{
	int status;
	pid_t dead;

	while ((dead = waitpid(-1, &status, WNOHANG)) > 0) {
		for (int i = 0; i < nsvcs; i++) {
			struct svc *s = &svcs[i];
			if (s->pid != dead)
				continue;

			time_t up = time(NULL) - s->started_at;
			s->pid = 0;

			if (!s->restart) {
				s->gave_up = 1;
				logf("%s exited (status %d) after %lds — restart=no, leaving it.",
				     s->name, status, (long)up);
				break;
			}

			/* Stable run resets the backoff; a quick death doubles it. */
			if (up >= STABLE_SECS)
				s->backoff = BACKOFF_MIN;
			s->due_at = time(NULL) + s->backoff;
			logf("%s died (status %d) after %lds — restarting in %ds",
			     s->name, status, (long)up, s->backoff);
			if (s->backoff < BACKOFF_MAX) {
				s->backoff *= 2;
				if (s->backoff > BACKOFF_MAX)
					s->backoff = BACKOFF_MAX;
			}
			break;
		}
		/* Unknown pids are orphans that got re-parented our way; reaping
		 * them (which the waitpid above just did) is all they needed. */
	}
}

static void start_due(void)
{
	time_t now = time(NULL);
	for (int i = 0; i < nsvcs; i++) {
		struct svc *s = &svcs[i];
		if (s->pid || s->gave_up || !s->due_at || s->due_at > now)
			continue;
		if (!deps_ready(s))
			continue;       /* stays due; picked up on a later tick */
		spawn(s);
	}
}

/* --- main ---------------------------------------------------------------------- */

int main(void)
{
	/* PID 1 respawns us if we die; don't die for trivia. */
	signal(SIGINT,  SIG_IGN);
	signal(SIGHUP,  SIG_IGN);
	signal(SIGPIPE, SIG_IGN);

	mkdir("/run/svc", 0755);
	load_enabled();

	/* The heartbeat. Never returns, even with nothing to supervise —
	 * exiting would just make PID 1 spin respawning us. */
	for (;;) {
		reap();
		start_due();
		sleep(1);
	}
	return 0;
}
