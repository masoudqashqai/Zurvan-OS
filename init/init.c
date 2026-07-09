/*
 * Zurvan PID 1 — a minimal init.
 *
 * This is the program the kernel runs as /init after unpacking the initramfs.
 * It is deliberately small and meant to be read top to bottom.
 *
 * THE TWO RULES OF PID 1 (get these wrong and the kernel panics with no clue):
 *
 *   1. PID 1 must NEVER exit. If it returns or _exit()s, the kernel panics with
 *      "Attempted to kill init!". This program is therefore an infinite
 *      supervising loop, not a script that falls off the end.
 *
 *   2. PID 1 must REAP zombies. Orphaned processes get re-parented to PID 1;
 *      if it never wait()s for them they pile up as zombies forever. We reap
 *      every dead child in the supervise loop.
 *
 * Responsibilities for v1 (milestone 3):
 *   - mount /proc, /sys, and devtmpfs on /dev
 *   - set up the console (stdin/stdout/stderr on /dev/console)
 *   - run an optional rc script (/etc/rc.init) — where networking goes later
 *   - supervise a shell: spawn it, respawn it if it dies, and reap everything
 *
 * Networking (milestone 5) and the YAML provisioner (milestone 6) hang off the
 * rc script / a spawned service rather than bloating this file.
 *
 * Build: see init/Makefile (static, freestanding-ish, no surprises).
 */

#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

/* The shell we hand control to once the system is up. Bash if present,
 * otherwise fall back to busybox sh. */
static const char *SHELL_CANDIDATES[] = {
	"/bin/bash",
	"/bin/sh",
	NULL,
};

/* Best-effort write; we genuinely don't care about short writes here. */
static void wr(const char *s, size_t n)
{
	ssize_t r = write(STDOUT_FILENO, s, n);
	(void)r;
}

static void msg(const char *s)
{
	wr("[init] ", 7);
	wr(s, strlen(s));
	wr("\n", 1);
}

/* mkdir + mount, tolerating "already exists" / "already mounted". */
static void do_mount(const char *src, const char *tgt, const char *fs,
                     unsigned long flags)
{
	mkdir(tgt, 0755);
	if (mount(src, tgt, fs, flags, NULL) != 0 && errno != EBUSY) {
		msg("mount failed:");
		msg(tgt);
	}
}

static void early_mounts(void)
{
	do_mount("proc",     "/proc", "proc",     0);
	do_mount("sysfs",    "/sys",  "sysfs",    0);
	/* devtmpfs: the kernel populates /dev for us (CONFIG_DEVTMPFS_MOUNT can
	 * also do this automatically, but mounting here keeps init self-contained). */
	do_mount("devtmpfs", "/dev",  "devtmpfs", 0);
	/* devpts: pseudo-terminals — sshd (dropbear) can't open a session
	 * without it. Must come after /dev so the mount point can be created. */
	do_mount("devpts",   "/dev/pts", "devpts", 0);
}

/* Point stdin/stdout/stderr at the console so the shell has a terminal. */
static void setup_console(void)
{
	int fd = open("/dev/console", O_RDWR);
	if (fd < 0)
		return; /* nothing we can do; carry on */
	dup2(fd, STDIN_FILENO);
	dup2(fd, STDOUT_FILENO);
	dup2(fd, STDERR_FILENO);
	if (fd > STDERR_FILENO)
		close(fd);
}

/* Run /etc/rc.init once, if it exists and is executable, and wait for it.
 * This is the hook where networking (udhcpc) and, later, the provisioner run. */
static void run_rc(void)
{
	const char *rc = "/etc/rc.init";
	if (access(rc, X_OK) != 0)
		return;

	pid_t pid = fork();
	if (pid == 0) {
		setsid();
		execl(rc, rc, (char *)NULL);
		_exit(127);
	} else if (pid > 0) {
		int status;
		while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
			;
	}
}

/* Spawn the service supervisor (v2 milestone 2), if the image ships one.
 * It is supervised exactly like the shell: just another child to respawn.
 * PID 1 stays a babysitter of two; zurvan-svc babysits everything else. */
static pid_t spawn_svc(void)
{
	const char *svc = "/sbin/zurvan-svc";
	if (access(svc, X_OK) != 0)
		return -1;

	pid_t pid = fork();
	if (pid == 0) {
		setsid();
		execl(svc, svc, (char *)NULL);
		_exit(127);
	}
	return pid;
}

/* Spawn the best available shell as a session leader. Returns its pid, or -1. */
static pid_t spawn_shell(void)
{
	const char *shell = NULL;
	for (int i = 0; SHELL_CANDIDATES[i]; i++) {
		if (access(SHELL_CANDIDATES[i], X_OK) == 0) {
			shell = SHELL_CANDIDATES[i];
			break;
		}
	}
	if (!shell) {
		msg("no shell found (need /bin/bash or /bin/sh)");
		return -1;
	}

	pid_t pid = fork();
	if (pid == 0) {
		/* New session so the shell owns the controlling terminal. */
		setsid();
		setup_console();
		ioctl(STDIN_FILENO, TIOCSCTTY, 1);
		/* Start it as an interactive LOGIN shell: argv[0] with a leading '-'
		 * is the portable "login" signal (works for bash and busybox sh), so
		 * it sources /etc/profile — where the Zurvan prompt lives, shared with
		 * SSH sessions. Without this the console got bash's bare "bash-5.2#". */
		const char *base = strrchr(shell, '/');
		base = base ? base + 1 : shell;
		char dashname[64];
		snprintf(dashname, sizeof dashname, "-%s", base);   /* "-bash" / "-sh" */
		char *const argv[] = { dashname, "-i", NULL };
		char *const envp[] = {
			"HOME=/root",
			"TERM=linux",
			"PATH=/bin:/sbin:/usr/bin:/usr/sbin",
			NULL,
		};
		execve(shell, argv, envp);
		_exit(127);
	}
	return pid;
}

int main(void)
{
	/* Ignore signals that could otherwise kill PID 1; we drive everything
	 * from the reaping loop instead. */
	signal(SIGINT,  SIG_IGN);
	signal(SIGTERM, SIG_IGN);

	early_mounts();
	setup_console();
	msg("Zurvan init — boundless time begins.");

	run_rc();

	pid_t svc   = spawn_svc();
	/* Let the supervisor print its first service-start lines before the
	 * interactive prompt appears, so boot logs don't land on top of the
	 * shell prompt. Only the initial spawn waits; respawns stay immediate. */
	if (svc > 0)
		sleep(1);
	pid_t shell = spawn_shell();

	/*
	 * The supervising loop. This NEVER returns.
	 *
	 * waitpid(-1, ...) reaps any dead child (Rule 2). If the one that died is
	 * our supervised shell, we respawn it so the box always has a console
	 * (Rule 1 stays satisfied because we never leave this loop).
	 */
	for (;;) {
		int status;
		pid_t dead = waitpid(-1, &status, 0);

		if (dead < 0) {
			if (errno == EINTR)
				continue;
			/* ECHILD: no children at all (e.g. shell failed to spawn).
			 * Pause briefly and try to bring a shell back rather than spin. */
			sleep(1);
			if (shell <= 0)
				shell = spawn_shell();
			continue;
		}

		if (dead == shell) {
			msg("shell exited; respawning.");
			shell = spawn_shell();
		} else if (svc > 0 && dead == svc) {
			/* zurvan-svc never exits by design, so this is a crash.
			 * Breathe for a second so a broken binary can't spin us. */
			msg("service supervisor exited; respawning.");
			sleep(1);
			svc = spawn_svc();
		}
		/* Any other reaped pid was an orphan we adopted — nothing else to do. */
	}

	/* Unreachable. */
	return 0;
}
