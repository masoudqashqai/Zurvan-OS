/*
 * zurvan-face — the web admin panel (v2 milestone 6, "the face").
 *
 * The victory lap: one static binary serving one HTTPS panel, so routine
 * administration never needs an SSH session. It is a thin FACE over the CLIs
 * the earlier milestones already built and tested — it runs no logic of its
 * own that a shell couldn't. Every action shells out (via fork/execvp with an
 * argv array, never a shell string — so a snapshot name or file path can
 * never become a command) to:
 *
 *   zurvan-svc state   -> services + supervisor status  (reads /run/svc)
 *   zurvan-lion        -> list / restore /data snapshots (M4)
 *   zurvan-snake       -> run a job in a sandbox, browse history (M5)
 *   zurvan-pkg         -> list / install / remove packages (M1)
 *   zurvan-upgrade     -> apply a signed A/B image bundle (M3)
 *   /data              -> the only writable, worth-browsing tree (file editor)
 *
 * TLS: BearSSL, static, no dynamic loader. The per-box key+cert are made at
 * first boot by zurvan-certgen into /data/face and loaded here as DER.
 *
 * Auth: one token, generated at first boot into /data/face/token and printed
 * to the console. The login form sets it as a cookie; every request compares
 * the cookie to the token in constant time. No users, no sessions DB — one
 * shared admin secret, like the box itself has one root.
 *
 * Concurrency: one client at a time (accept, serve, close). A panel is not a
 * web server under load; simplicity beats throughput here.
 *
 * Usage: zurvan-face [--port N] [--dir /data/face]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include "bearssl.h"

#define DEF_PORT   8443
#define DEF_DIR    "/data/face"
#define TOKEN_LEN  32                  /* hex chars */
#define REQ_MAX    (256 * 1024)        /* cap a text form field (the editor) */
#define OUT_MAX    (512 * 1024)
#define HDR_MAX    (16 * 1024)         /* request headers must fit here */
#define UPLOAD_MAX (32 * 1024 * 1024)  /* cap an uploaded body (packages/bundles) */

static const char *g_dir = DEF_DIR;
static char g_token[TOKEN_LEN + 1];

/* --- logging ---------------------------------------------------------------- */
static void face_log(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt);
	fputs("[face] ", stdout); vfprintf(stdout, fmt, ap); fputc('\n', stdout);
	fflush(stdout); va_end(ap);
}

/* --- constant-time compare -------------------------------------------------- */
static int ct_eq(const char *a, const char *b)
{
	size_t la = strlen(a), lb = strlen(b);
	unsigned d = (unsigned)(la ^ lb);
	for (size_t i = 0; i < la && i < lb; i++)
		d |= (unsigned)(a[i] ^ b[i]);
	return d == 0;
}

/* --- run a CLI, capture stdout+stderr into buf (argv NULL-terminated) ------- */
/* Returns the child's exit code, or -1. No shell: argv is exec'd directly, so
 * user-supplied names/paths are arguments, never syntax. */
static int run(char *const argv[], char *buf, size_t bufsz, const char *stdin_data)
{
	int outp[2], inp[2];
	if (pipe(outp) != 0) return -1;
	if (pipe(inp) != 0) { close(outp[0]); close(outp[1]); return -1; }

	pid_t pid = fork();
	if (pid < 0) { close(outp[0]); close(outp[1]); close(inp[0]); close(inp[1]); return -1; }
	if (pid == 0) {
		dup2(inp[0], 0); dup2(outp[1], 1); dup2(outp[1], 2);
		close(inp[0]); close(inp[1]); close(outp[0]); close(outp[1]);
		execvp(argv[0], argv);
		_exit(127);
	}
	close(outp[1]); close(inp[0]);
	if (stdin_data) { ssize_t w = write(inp[1], stdin_data, strlen(stdin_data)); (void)w; }
	close(inp[1]);

	size_t n = 0;
	if (buf && bufsz) {
		ssize_t r;
		while (n + 1 < bufsz && (r = read(outp[0], buf + n, bufsz - 1 - n)) > 0)
			n += (size_t)r;
		buf[n] = '\0';
	}
	close(outp[0]);
	int status;
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR) ;
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/* --- HTML escaping into a growable buffer ----------------------------------- */
struct buf { char *p; size_t n, cap; };
static void bput(struct buf *b, const char *s, size_t len)
{
	if (b->n + len + 1 > b->cap) {
		b->cap = (b->n + len + 1) * 2 + 256;
		b->p = realloc(b->p, b->cap);
	}
	memcpy(b->p + b->n, s, len); b->n += len; b->p[b->n] = '\0';
}
static void bputs(struct buf *b, const char *s) { bput(b, s, strlen(s)); }
static void bprintf(struct buf *b, const char *fmt, ...)
{
	/* Measure first, then format — never truncate. The old fixed-buffer
	 * version cut the ~1.1KB CSS mid-<style>, which broke rendering in real
	 * browsers (curl didn't care). */
	va_list ap, ap2;
	va_start(ap, fmt);
	va_copy(ap2, ap);
	int n = vsnprintf(NULL, 0, fmt, ap);
	va_end(ap);
	if (n > 0) {
		if (b->n + (size_t)n + 1 > b->cap) {
			b->cap = (b->n + (size_t)n + 1) * 2 + 256;
			b->p = realloc(b->p, b->cap);
		}
		vsnprintf(b->p + b->n, (size_t)n + 1, fmt, ap2);
		b->n += (size_t)n;
	}
	va_end(ap2);
}
static void besc(struct buf *b, const char *s)   /* HTML-escape */
{
	for (; *s; s++) switch (*s) {
		case '&': bputs(b, "&amp;");  break;
		case '<': bputs(b, "&lt;");   break;
		case '>': bputs(b, "&gt;");   break;
		case '"': bputs(b, "&quot;"); break;
		default:  bput(b, s, 1);
	}
}

/* --- URL decoding (in place) ------------------------------------------------ */
static void url_decode(char *s)
{
	char *o = s;
	for (; *s; s++) {
		if (*s == '%' && s[1] && s[2]) {
			int hi = s[1], lo = s[2];
			#define HEX(c) ((c)<='9'?(c)-'0':((c)|0x20)-'a'+10)
			*o++ = (char)((HEX(hi) << 4) | HEX(lo)); s += 2;
			#undef HEX
		} else if (*s == '+') *o++ = ' ';
		else *o++ = *s;
	}
	*o = '\0';
}
/* find KEY=VALUE in a urlencoded body; copies decoded value, returns 1 if found */
static int form_get(const char *body, const char *key, char *out, size_t outsz)
{
	size_t klen = strlen(key);
	const char *p = body;
	while (p && *p) {
		if (strncmp(p, key, klen) == 0 && p[klen] == '=') {
			const char *v = p + klen + 1;
			const char *e = strchr(v, '&');
			size_t len = e ? (size_t)(e - v) : strlen(v);
			if (len >= outsz) len = outsz - 1;
			memcpy(out, v, len); out[len] = '\0';
			url_decode(out);
			return 1;
		}
		p = strchr(p, '&'); if (p) p++;
	}
	return 0;
}

/* --- path safety: only /data, no traversal ---------------------------------- */
static int data_path_ok(const char *rel, char *abs, size_t abssz)
{
	if (strstr(rel, "..")) return 0;
	snprintf(abs, abssz, "/data/%s", rel[0] == '/' ? rel + 1 : rel);
	return 1;
}

/* ==========================================================================
 * HTTP request + response
 * ========================================================================== */

struct req {
	char method[8];
	char path[1024];
	char query[1024];
	char cookie[256];
	char ctype[256];        /* Content-Type (for multipart uploads) */
	size_t clen;
	const char *body;
	int body_owned;         /* body was malloc'd and must be freed */
};

/* --- shared page chrome ----------------------------------------------------- */
static const char *CSS =
"*{box-sizing:border-box}body{margin:0;font:15px/1.5 system-ui,sans-serif;"
"background:#0f1115;color:#d7dbe0}a{color:#6fb3ff;text-decoration:none}"
"a:hover{text-decoration:underline}header{background:#161a21;border-bottom:1px solid #262c36;"
"padding:0 20px;display:flex;align-items:center;gap:18px;height:52px}"
"header .brand{font-weight:700;color:#fff;letter-spacing:.5px}header nav{display:flex;gap:14px}"
"header .sp{flex:1}main{max-width:960px;margin:24px auto;padding:0 20px}"
"h1{font-size:20px;margin:0 0 16px}h2{font-size:16px;margin:24px 0 10px;color:#aeb6c2}"
".card{background:#161a21;border:1px solid #262c36;border-radius:10px;padding:16px;margin:0 0 16px}"
"table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:8px 10px;border-bottom:1px solid #232833}"
"th{color:#8b93a1;font-weight:600;font-size:13px}"
".ok{color:#5ad18b}.bad{color:#ff6b6b}.dim{color:#8b93a1}"
"button,input[type=submit]{background:#2a6df4;color:#fff;border:0;border-radius:7px;"
"padding:8px 14px;font:inherit;cursor:pointer}button.g{background:#333b49}button.r{background:#a13030}"
"input[type=text],input[type=password],textarea{width:100%;background:#0f1115;color:#e8ebf0;"
"border:1px solid #2a3140;border-radius:7px;padding:9px;font:inherit}"
"textarea{min-height:340px;font-family:ui-monospace,monospace;font-size:13px}"
"pre{background:#0b0d11;border:1px solid #232833;border-radius:8px;padding:12px;overflow:auto;font-size:13px}"
"form.inline{display:inline}.mono{font-family:ui-monospace,monospace}.pill{font-size:12px;"
"padding:2px 8px;border-radius:20px;background:#232833}"
"details.info{background:#12202b;border:1px solid #1d3547;border-radius:10px;padding:12px 16px;margin:0 0 16px}"
"details.info summary{cursor:pointer;color:#7fc4ff;font-weight:600;list-style:none}"
"details.info summary::-webkit-details-marker{display:none}"
"details.info[open] summary{margin-bottom:8px}details.info p{margin:6px 0;color:#b9c2cf}"
"label{display:block;margin:0 0 6px;color:#aeb6c2;font-size:13px}"
"input[type=file]{color:#aeb6c2;font:inherit}.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}"
".row input[type=file]{flex:1;min-width:0}"
/* both package tables share this layout so their columns line up across cards */
"table.pkg{table-layout:fixed}"
"table.pkg td:nth-child(2),table.pkg th:nth-child(2){width:28%}"
"table.pkg td:nth-child(3),table.pkg th:nth-child(3){width:160px;text-align:right}"
"td.row{gap:6px;justify-content:flex-end}";

static void page_head(struct buf *b, const char *title, const char *active)
{
	bputs(b, "<!doctype html><html><head><meta charset=utf-8>"
	         "<meta name=viewport content=\"width=device-width,initial-scale=1\"><title>");
	besc(b, title);
	bprintf(b, " — Zurvan</title><style>%s</style></head><body><header>"
	           "<span class=brand>&#128367; ZURVAN</span><nav>", CSS);
	struct { const char *href, *name; } nav[] = {
		{"/", "Overview"}, {"/services", "Services"}, {"/snapshots", "Snapshots"},
		{"/jobs", "Jobs"}, {"/files", "Files"}, {"/packages", "Packages"},
		{"/system", "System"},
	};
	for (unsigned i = 0; i < sizeof nav / sizeof nav[0]; i++)
		bprintf(b, "<a href=\"%s\"%s>%s</a>", nav[i].href,
		        strcmp(nav[i].name, active) == 0 ? " style=color:#fff" : "", nav[i].name);
	bputs(b, "</nav><span class=sp></span><a href=/logout class=dim>Log out</a></header><main>");
}
static void page_foot(struct buf *b) { bputs(b, "</main></body></html>"); }

/* A collapsible "what is this?" box — native <details>, no JavaScript. `html`
 * is trusted markup (paragraphs), not user input. */
static void info_box(struct buf *b, const char *summary, const char *html)
{
	bputs(b, "<details class=info><summary>\xE2\x84\xB9 ");   /* ℹ */
	besc(b, summary);
	bputs(b, "</summary>");
	bputs(b, html);
	bputs(b, "</details>");
}

/* Write a whole buffer to <dir>/<name> (name already validated). */
static int save_file(const char *dir, const char *name, const void *data, size_t len)
{
	char path[1200];
	snprintf(path, sizeof path, "%s/%s", dir, name);
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) return -1;
	const char *p = data; size_t off = 0; int ok = 1;
	while (off < len) {
		ssize_t w = write(fd, p + off, len - off);
		if (w <= 0) { ok = 0; break; }
		off += (size_t)w;
	}
	close(fd);
	return ok ? 0 : -1;
}

/* A filename is safe if it has no path separators or "..". */
static int name_safe(const char *s)
{
	return s[0] && !strchr(s, '/') && !strchr(s, '\\') && !strstr(s, "..");
}

/* Human-readable size, 1024-based like `ls -h`: "743 B", "1.4 KB", "3.0 MB". */
static void human_size(long long b, char *out, size_t n)
{
	static const char *u[] = { "B", "KB", "MB", "GB", "TB" };
	int i = 0;
	double v = (double)b;
	while (v >= 1024.0 && i < 4) { v /= 1024.0; i++; }
	if (i == 0) snprintf(out, n, "%lld B", b);
	else        snprintf(out, n, "%.1f %s", v, u[i]);
}

static int path_exists(const char *p) { struct stat st; return stat(p, &st) == 0; }

/* Is `name` a whole line of a small line-per-entry file (e.g. /run/svc/enabled)? */
static int line_in_file(const char *path, const char *name)
{
	FILE *f = fopen(path, "r");
	if (!f) return 0;
	char l[256]; int found = 0;
	while (fgets(l, sizeof l, f)) {
		char *nl = strchr(l, '\n'); if (nl) *nl = 0;
		if (strcmp(l, name) == 0) { found = 1; break; }
	}
	fclose(f);
	return found;
}

/* --- one-shot flash message ------------------------------------------------
 * A POST action does its work, stashes a result line here, and redirects; the
 * next GET reads-and-deletes it and shows it once. This keeps Post/Redirect/Get
 * (a browser refresh is a clean GET, never a re-run of the action) AND surfaces
 * the output — which the actions used to throw away, so a failed install just
 * silently reloaded. One file, since the panel serves one client at a time. */
static void set_flash(const char *msg)
{
	if (!msg || !msg[0]) return;
	save_file(g_dir, "flash", msg, strlen(msg));
}
static void take_flash(char *buf, size_t n)
{
	buf[0] = 0;
	char p[512]; snprintf(p, sizeof p, "%s/flash", g_dir);
	int fd = open(p, O_RDONLY);
	if (fd < 0) return;
	ssize_t r = read(fd, buf, n - 1);
	close(fd); unlink(p);
	if (r > 0) buf[r] = 0;
}

/* ==========================================================================
 * Views  (each returns HTML in *out)
 * ========================================================================== */

/* service introspection from /proc — defined further down */
static struct { long inode; int port; } g_listens[128];
static int g_nlisten;
static void scan_listens(const char *path);
static void ports_for_pid(int pid, char *out, size_t n);
static void uptime_for_pid(int pid, char *out, size_t n);

/* Render the enabled services as a table. `full` adds PID + a Restart button
 * (the Services page); the Overview passes 0 for a compact summary. */
static void services_table(struct buf *out, int full)
{
	char st[8192] = "";
	char *sv[] = { "zurvan-svc", "state", NULL };
	run(sv, st, sizeof st, NULL);

	g_nlisten = 0;
	scan_listens("/proc/net/tcp");
	scan_listens("/proc/net/tcp6");

	bputs(out, "<div class=card><table><tr><th>Service</th><th>State</th>"
	           "<th>Listening</th><th>Uptime</th>");
	if (full) bputs(out, "<th>PID</th><th></th>");
	bputs(out, "</tr>");

	/* strtok_r, not strtok: uptime_for_pid()/scan_listens() also tokenize, and a
	 * shared strtok cursor would corrupt this line loop after the first row. */
	char *lsave = NULL;
	for (char *line = strtok_r(st, "\n", &lsave); line; line = strtok_r(NULL, "\n", &lsave)) {
		char name[64] = ""; int pid = 0; char state[32] = "";
		if (sscanf(line, "%63s %d %31s", name, &pid, state) >= 1 && name[0] && name[0] != '[') {
			char ports[128], upt[32];
			ports_for_pid(pid, ports, sizeof ports);
			uptime_for_pid(pid, upt, sizeof upt);
			bprintf(out, "<tr><td class=mono>%s</td><td class=%s>%s</td>",
			        name, strstr(state, "up") ? "ok" : "dim", state[0] ? state : "?");
			bprintf(out, "<td class=mono>%s</td>", ports[0] ? ports : "<span class=dim>&mdash;</span>");
			bprintf(out, "<td class=dim>%s</td>", upt[0] ? upt : "&mdash;");
			if (full) {
				if (pid > 0) bprintf(out, "<td class=dim>%d</td>", pid);
				else         bputs(out, "<td class=dim>&mdash;</td>");
				bputs(out, "<td class=row>");
				if (strcmp(state, "disabled") == 0 || strcmp(state, "stopping") == 0) {
					bprintf(out, "<form class=inline method=post action=/services/enable>"
					             "<input type=hidden name=name value=\"%s\">"
					             "<button>Enable</button></form>", name);
				} else {
					bprintf(out, "<form class=inline method=post action=/services/restart>"
					             "<input type=hidden name=name value=\"%s\">"
					             "<button class=g>Restart</button></form>", name);
					/* Disabling face kills THIS panel — say so before doing it. */
					if (strcmp(name, "face") == 0)
						bputs(out, "<form class=inline method=post action=/services/disable "
						           "onsubmit=\"return confirm('Disable face? This panel STOPS "
						           "immediately and only comes back via SSH or the console: "
						           "zurvan-svc enable face')\">"
						           "<input type=hidden name=name value=\"face\">"
						           "<button class=g>Disable</button></form>");
					else
						bprintf(out, "<form class=inline method=post action=/services/disable "
						             "onsubmit=\"return confirm('Disable %s? It stops now and "
						             "stays off, across reboots, until re-enabled.')\">"
						             "<input type=hidden name=name value=\"%s\">"
						             "<button class=g>Disable</button></form>", name, name);
				}
				bputs(out, "</td>");
			}
			bputs(out, "</tr>");
		}
	}
	bputs(out, "</table></div>");
}

static void view_overview(struct buf *out)
{
	page_head(out, "Overview", "Overview");
	bputs(out, "<h1>Overview</h1>");

	char hn[128] = "", up[256] = "";
	int fd = open("/etc/hostname", O_RDONLY);
	if (fd >= 0) { ssize_t n = read(fd, hn, sizeof hn - 1); if (n > 0) hn[n] = 0; close(fd); }
	char *nl = strchr(hn, '\n'); if (nl) *nl = 0;
	char *upv[] = { "uptime", NULL }; run(upv, up, sizeof up, NULL);
	char *nlq = strchr(up, '\n'); if (nlq) *nlq = 0;

	bputs(out, "<div class=card><table>");
	bprintf(out, "<tr><th>Hostname</th><td class=mono>%s</td></tr>", hn[0] ? hn : "(unset)");
	bprintf(out, "<tr><th>Uptime</th><td class=dim>%s</td></tr>", up);
	bputs(out, "</table></div>");

	bputs(out, "<h2>Services</h2>");
	services_table(out, 0);   /* compact: Service / State / Listening / Uptime */
	bputs(out, "<p class=dim><a href=/services>Manage services &rarr;</a></p>");
	bputs(out, "<p class=dim>Zurvan v2 — the snake sheds, the lion remembers.</p>");
	page_foot(out);
}

/* --- listening ports, mapped to the process that owns them ------------------ */
/* Built from /proc/net/tcp{,6} (kernel's socket table) + /proc/<pid>/fd. Lets
 * the Services page show what each service listens on — which the supervisor
 * itself doesn't know (a port is private to each program's config).
 * (g_listens/g_nlisten declared up by services_table.) */
static void scan_listens(const char *path)
{
	FILE *f = fopen(path, "r");
	if (!f) return;
	char line[512];
	int first = 1;
	while (fgets(line, sizeof line, f)) {
		if (first) { first = 0; continue; }      /* header row */
		char *local = NULL, *st = NULL, *inode = NULL, *sv = NULL;
		int col = 0;
		for (char *t = strtok_r(line, " ", &sv); t; t = strtok_r(NULL, " ", &sv), col++) {
			if (col == 1) local = t; else if (col == 3) st = t; else if (col == 9) inode = t;
		}
		if (!local || !st || !inode || strcmp(st, "0A") != 0) continue;  /* 0A = LISTEN */
		char *c = strrchr(local, ':');
		if (!c) continue;
		if (g_nlisten < 128) {
			g_listens[g_nlisten].port  = (int)strtol(c + 1, NULL, 16);
			g_listens[g_nlisten].inode = strtol(inode, NULL, 10);
			g_nlisten++;
		}
	}
	fclose(f);
}

static void ports_for_pid(int pid, char *out, size_t n)
{
	out[0] = 0;
	if (pid <= 0) return;
	char dir[64];
	snprintf(dir, sizeof dir, "/proc/%d/fd", pid);
	DIR *d = opendir(dir);
	if (!d) return;
	int found[32], nf = 0;
	struct dirent *e;
	while ((e = readdir(d))) {
		char lp[400], tgt[128];
		snprintf(lp, sizeof lp, "%s/%s", dir, e->d_name);
		ssize_t r = readlink(lp, tgt, sizeof tgt - 1);
		if (r <= 0) continue;
		tgt[r] = 0;
		long ino;
		if (sscanf(tgt, "socket:[%ld]", &ino) != 1) continue;
		for (int i = 0; i < g_nlisten; i++) {
			if (g_listens[i].inode != ino) continue;
			int p = g_listens[i].port, dup = 0;
			for (int j = 0; j < nf; j++) if (found[j] == p) dup = 1;
			if (!dup && nf < 32) found[nf++] = p;
		}
	}
	closedir(d);
	for (int i = 1; i < nf; i++)
		for (int j = i; j > 0 && found[j-1] > found[j]; j--) {
			int t = found[j-1]; found[j-1] = found[j]; found[j] = t;
		}
	char *o = out; size_t rem = n;
	for (int i = 0; i < nf && rem > 8; i++) {
		int w = snprintf(o, rem, "%s%d", i ? ", " : "", found[i]);
		o += w; rem -= (size_t)w;
	}
}

/* How long the process has been alive, from /proc/<pid>/stat field 22
 * (starttime, in clock ticks since boot) vs /proc/uptime. */
static void uptime_for_pid(int pid, char *out, size_t n)
{
	out[0] = 0;
	if (pid <= 0) return;
	double sys_up = 0;
	FILE *f = fopen("/proc/uptime", "r");
	if (f) { if (fscanf(f, "%lf", &sys_up) != 1) sys_up = 0; fclose(f); }

	char path[64];
	snprintf(path, sizeof path, "/proc/%d/stat", pid);
	f = fopen(path, "r");
	if (!f) return;
	char buf[1024];
	size_t r = fread(buf, 1, sizeof buf - 1, f);
	fclose(f);
	buf[r] = 0;
	/* comm (field 2) may contain spaces/parens; the last ')' ends it, and
	 * field 22 (starttime) is the 20th token after that. */
	char *p = strrchr(buf, ')');
	if (!p) return;
	long start = 0; int idx = 0; char *sv = NULL;
	for (char *t = strtok_r(p + 1, " ", &sv); t; t = strtok_r(NULL, " ", &sv), idx++)
		if (idx == 19) { start = strtol(t, NULL, 10); break; }

	long hz = sysconf(_SC_CLK_TCK); if (hz <= 0) hz = 100;
	long s = (long)(sys_up - (double)start / (double)hz);
	if (s < 0) s = 0;
	/* Adaptive units, like the file-size column: the largest unit that fits,
	 * plus the next one down for context. */
	if      (s < 60)    snprintf(out, n, "%lds", s);
	else if (s < 3600)  snprintf(out, n, "%ldm %lds", s / 60, s % 60);
	else if (s < 86400) snprintf(out, n, "%ldh %ldm", s / 3600, (s % 3600) / 60);
	else                snprintf(out, n, "%ldd %ldh", s / 86400, (s % 86400) / 3600);
}

static void view_services(struct buf *out, const char *flash)
{
	page_head(out, "Services", "Services");
	bputs(out, "<h1>Services</h1>");
	if (flash && flash[0]) { bputs(out, "<div class=card>"); besc(out, flash); bputs(out, "</div>"); }

	services_table(out, 1);   /* full: PID column + Restart buttons */

	bputs(out, "<p class=dim><b>Listening</b> is the TCP port(s) the service accepts "
	           "connections on; <b>Uptime</b> is how long it has been running (a value that "
	           "keeps resetting means it is crash-looping); <b>PID</b> is its process id. "
	           "<b>Restart</b> signals the supervisor to respawn the service. <b>Disable</b> "
	           "stops it and keeps it off — across reboots — until <b>Enable</b> removes "
	           "the off-switch (a marker on /data, so it outlives the ephemeral OS).</p>");
	page_foot(out);
}

static void view_snapshots(struct buf *out, const char *flash)
{
	page_head(out, "Snapshots", "Snapshots");
	bputs(out, "<h1>Snapshots <span class=dim>— the lion</span></h1>");
	if (flash && flash[0]) { bputs(out, "<div class=card>"); besc(out, flash); bputs(out, "</div>"); }

	info_box(out, "What is this page?",
	    "<p>The <b>lion</b> guards <span class=mono>/data</span>: each snapshot is one "
	    "checksummed, compressed archive of everything you would cry about losing. "
	    "<b>Snapshot now</b> takes one immediately; enable the <span class=mono>lion</span> "
	    "service in the YAML to take them on a schedule and keep the last N.</p>"
	    "<p><b>Restore</b> unpacks a snapshot back over <span class=mono>/data</span> "
	    "(the checksum is verified first). Two flavours:</p>"
	    "<p><b>Restore</b> = overlay — brings back what was in the snapshot but keeps "
	    "files you created since (safe default). <b>Mirror</b> = make /data <i>exactly</i> "
	    "the snapshot, which <b>deletes</b> anything added after it. Restart affected "
	    "services afterward, or reboot.</p>");

	char snaps[16384] = "";
	char *lv[] = { "zurvan-lion", "list", NULL };
	run(lv, snaps, sizeof snaps, NULL);

	bputs(out, "<div class=card>");
	if (!snaps[0] || strstr(snaps, "no snapshots")) {
		bputs(out, "<p class=dim>No snapshots yet.</p>");
	} else {
		bputs(out, "<table><tr><th>Snapshot</th><th>When (UTC)</th><th>Size</th><th></th></tr>");
		char *line = strtok(snaps, "\n");
		while (line) {
			char name[80] = ""; sscanf(line, "%79s", name);
			if (strncmp(name, "lion-", 5) == 0) {
				bprintf(out, "<tr><td class=mono>%s</td>", name);
				/* rest of the line after the name = "date time UTC bytes ..." */
				char *rest = line + strlen(name);
				while (*rest == ' ') rest++;
				bprintf(out, "<td class=dim colspan=2>"); besc(out, rest); bputs(out, "</td>");
				bprintf(out, "<td class=row><form class=inline method=post action=/snapshots/restore "
				             "onsubmit=\"return confirm('Restore %s over /data? (keeps files added since)')\">"
				             "<input type=hidden name=name value=\"%s\">"
				             "<button class=g>Restore</button></form>"
				             "<form class=inline method=post action=/snapshots/restore "
				             "onsubmit=\"return confirm('MIRROR-restore %s?\\n\\nThis DELETES every file created "
				             "after the snapshot and makes /data exactly match it. This cannot be undone.')\">"
				             "<input type=hidden name=name value=\"%s\">"
				             "<input type=hidden name=mode value=mirror>"
				             "<button class=r>Mirror</button></form></td></tr>",
				        name, name, name, name);
			}
			line = strtok(NULL, "\n");
		}
		bputs(out, "</table>");
	}
	bputs(out, "</div><form method=post action=/snapshots/snap>"
	           "<button>Snapshot now</button></form>");
	page_foot(out);
}

static void view_jobs(struct buf *out, const char *flash)
{
	page_head(out, "Jobs", "Jobs");
	bputs(out, "<h1>Jobs <span class=dim>— the snake</span></h1>");
	if (flash && flash[0]) { bputs(out, "<div class=card>"); besc(out, flash); bputs(out, "</div>"); }

	info_box(out, "What is this page?",
	    "<p>The <b>snake</b> runs a throwaway script in a <b>disposable sandbox</b> — its "
	    "own private tmpfs in a fresh mount namespace. The script gets an empty, writable "
	    "system: it can create, delete, and scribble anywhere and <b>none of it touches "
	    "this machine</b>. When it finishes, the sandbox evaporates.</p>"
	    "<p>Only three things come back: the <b>exit status</b>, the <b>captured output</b> "
	    "(the log below), and any files the script copies into the <span class=mono>"
	    "$ARTIFACTS</span> directory. Use it for a quick build, a one-off script, or trying "
	    "a risky command safely.</p>");

	bputs(out, "<div class=card><h2 style=margin-top:0>Run a script</h2>"
	           "<form method=post action=/jobs/run>"
	           "<label>Shell script (runs with /bin/sh; save results with "
	           "<span class=mono>echo ... &gt; \"$ARTIFACTS/name\"</span>)</label>"
	           "<textarea name=script placeholder=\"#!/bin/sh&#10;echo hello from the sandbox&#10;"
	           "date &gt; \\&quot;$ARTIFACTS/when.txt\\&quot;\"></textarea>"
	           "<p><button>&#9654; Run in sandbox</button></p></form></div>");

	bputs(out, "<h2>History</h2><div class=card>");
	DIR *d = opendir("/data/snake/results");
	if (d) {
		char names[256][80]; int n = 0;
		struct dirent *e;
		while ((e = readdir(d)) && n < 256)
			if (e->d_name[0] != '.' && strlen(e->d_name) < 80)
				memcpy(names[n++], e->d_name, strlen(e->d_name) + 1);
		closedir(d);
		/* newest first (names are name-YYYYMMDD-HHMMSS) */
		for (int i = 1; i < n; i++) for (int j = i; j > 0 && strcmp(names[j-1], names[j]) < 0; j--) {
			char t[80]; memcpy(t, names[j-1], 80); memcpy(names[j-1], names[j], 80); memcpy(names[j], t, 80);
		}
		if (n == 0) bputs(out, "<p class=dim>No jobs run yet.</p>");
		else {
			bputs(out, "<table><tr><th>Job</th><th></th></tr>");
			for (int i = 0; i < n; i++)
				bprintf(out, "<tr><td class=mono>%s</td><td><a href=\"/job?id=%s\">view</a></td></tr>",
				        names[i], names[i]);
			bputs(out, "</table>");
		}
	} else bputs(out, "<p class=dim>No job history (queue daemon not enabled, or none run).</p>");
	bputs(out, "</div>");
	page_foot(out);
}

static void view_job(struct buf *out, const char *id)
{
	page_head(out, "Job", "Jobs");
	char safe[128]; snprintf(safe, sizeof safe, "%s", id);
	if (strstr(safe, "..") || strchr(safe, '/')) { bputs(out, "<p class=bad>bad id</p>"); page_foot(out); return; }
	bprintf(out, "<h1>Job <span class=mono>%s</span></h1><p><a href=/jobs>&larr; all jobs</a></p>", safe);

	char path[256], data[OUT_MAX];
	const char *files[] = { "status", "log" };
	for (unsigned i = 0; i < 2; i++) {
		snprintf(path, sizeof path, "/data/snake/results/%s/%s", safe, files[i]);
		int fd = open(path, O_RDONLY);
		bprintf(out, "<h2>%s</h2><div class=card><pre>", files[i]);
		if (fd >= 0) { ssize_t r = read(fd, data, sizeof data - 1); if (r > 0) { data[r] = 0; besc(out, data); } close(fd); }
		else bputs(out, "(none)");
		bputs(out, "</pre></div>");
	}
	page_foot(out);
}

static void view_files(struct buf *out, const char *rel)
{
	page_head(out, "Files", "Files");
	char abs[1024];
	if (!rel[0]) rel = "";
	if (!data_path_ok(rel, abs, sizeof abs)) { bputs(out, "<p class=bad>bad path</p>"); page_foot(out); return; }

	bprintf(out, "<h1>Files <span class=dim>/data/%s</span></h1>", rel);
	bputs(out, "<p class=dim>The root filesystem is read-only and reborn each boot; /data is the only durable tree.</p>");
	DIR *d = opendir(abs);
	if (!d) { bputs(out, "<p class=bad>cannot open directory</p>"); page_foot(out); return; }

	/* The New buttons live inside the upload form's row (for the layout) but
	 * are type=button so they never submit it. */
	bprintf(out, "<div class=card><form method=post action=\"/files/upload?path=%s\" "
	             "enctype=multipart/form-data><div class=row>"
	             "<input type=file name=file><button>Upload here</button>"
	             "<button type=button class=g onclick=\"nd('%s')\">New folder</button>"
	             "<button type=button class=g onclick=\"nf('%s')\">New file</button>"
	             "</div></form></div>", rel, rel, rel);

	bputs(out, "<div class=card><table><tr><th>Name</th><th>Size</th><th></th></tr>");
	if (rel[0]) {
		char up[1024]; snprintf(up, sizeof up, "%s", rel);
		char *s = strrchr(up, '/'); if (s) *s = 0; else up[0] = 0;
		bprintf(out, "<tr><td><a href=\"/files?path=%s\">../</a></td><td></td><td></td></tr>", up);
	}
	struct dirent *e;
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.') continue;
		char full[1536]; snprintf(full, sizeof full, "%s/%s", abs, e->d_name);
		struct stat st; if (stat(full, &st) != 0) continue;
		char child[1536];
		snprintf(child, sizeof child, "%s%s%s", rel, rel[0] ? "/" : "", e->d_name);
		int isdir = S_ISDIR(st.st_mode);
		bputs(out, "<tr><td>");
		if (isdir)
			bprintf(out, "&#128193; <a href=\"/files?path=%s\">%s/</a></td><td></td>", child, e->d_name);
		else {
			char sz[32]; human_size((long long)st.st_size, sz, sizeof sz);
			bprintf(out, "&#128196; <a href=\"/file?path=%s\">%s</a></td><td class=dim>%s</td>",
			        child, e->d_name, sz);
		}
		/* per-row actions: rename, copy (files only), delete */
		bputs(out, "<td class=row>");
		bprintf(out, "<button class=g onclick=\"ren('%s')\">Rename</button>", child);
		if (!isdir)
			bprintf(out, "<button class=g onclick=\"cp('%s')\">Copy</button>", child);
		bprintf(out, "<form class=inline method=post action=/files/delete "
		             "onsubmit=\"return confirm('Delete %s?')\">"
		             "<input type=hidden name=path value=\"%s\">"
		             "<button class=r>Delete</button></form>", e->d_name, child);
		bputs(out, "</td></tr>");
	}
	closedir(d);
	bputs(out, "</table></div>");
	/* rename/copy prompt helpers — post a tiny generated form (no inline inputs
	 * cluttering every row). Kept minimal; matches the confirm() dialogs. */
	bputs(out,
	    "<script>"
	    "function post(u,d){var f=document.createElement('form');f.method='post';f.action=u;"
	    "for(var k in d){var i=document.createElement('input');i.type='hidden';i.name=k;i.value=d[k];"
	    "f.appendChild(i);}document.body.appendChild(f);f.submit();}"
	    "function base(p){return p.split('/').pop();}"
	    "function ren(p){var n=prompt('Rename to:',base(p));if(n)post('/files/rename',{path:p,name:n});}"
	    "function cp(p){var n=prompt('Copy to (new name):',base(p));if(n)post('/files/copy',{path:p,name:n});}"
	    "function nd(d){var n=prompt('New folder name:');if(n)post('/files/mkdir',{path:d,name:n});}"
	    /* a new file is just the editor pointed at a path that doesn't exist
	     * yet — Save creates it */
	    "function nf(d){var n=prompt('New file name:');"
	    "if(n)location.href='/file?path='+(d?d+'/':'')+encodeURIComponent(n);}"
	    "</script>");
	page_foot(out);
}

static void view_file(struct buf *out, const char *rel, const char *flash)
{
	page_head(out, "Edit", "Files");
	char abs[1024];
	if (!data_path_ok(rel, abs, sizeof abs)) { bputs(out, "<p class=bad>bad path</p>"); page_foot(out); return; }
	bprintf(out, "<h1>Edit <span class=dim>/data/%s</span></h1>", rel);

	/* back to the directory this file lives in (also the post-Save way out —
	 * saving re-renders this page, it doesn't navigate) */
	char up[1024]; snprintf(up, sizeof up, "%s", rel);
	char *s = strrchr(up, '/'); if (s) *s = 0; else up[0] = 0;
	bprintf(out, "<p><a href=\"/files?path=%s\">&larr; back to /data/%s</a></p>", up, up);

	if (flash && flash[0]) { bputs(out, "<div class=card>"); besc(out, flash); bputs(out, "</div>"); }

	char data[OUT_MAX]; data[0] = 0;
	ssize_t rlen = 0;
	int fd = open(abs, O_RDONLY);
	if (fd >= 0) { rlen = read(fd, data, sizeof data - 1); if (rlen > 0) data[rlen] = 0; else rlen = 0; close(fd); }

	/* Refuse to edit a binary. The textarea is text-only and besc() stops at
	 * the first NUL, so a binary would show truncated garbage AND — the real
	 * hazard — Save would write that back, corrupting the file (and since
	 * /usr/bin/* are symlinks into /data/apps, the installed program with it).
	 * A NUL byte is the reliable "not text" tell. */
	int binary = 0;
	for (ssize_t i = 0; i < rlen; i++) if (!data[i]) { binary = 1; break; }
	if (binary) {
		bputs(out, "<div class=card><p class=bad>This looks like a binary file.</p>"
		           "<p class=dim>The panel editor is text-only; opening it here would "
		           "show garbage, and saving would corrupt the file. Fetch it over "
		           "<span class=mono>scp</span> if you need it.</p></div>");
		page_foot(out); return;
	}
	/* A text file bigger than the read buffer would load truncated, and saving
	 * would drop the tail — warn instead of silently losing data. */
	int truncated = (rlen == (ssize_t)sizeof data - 1);

	if (truncated)
		bputs(out, "<div class=card><p class=bad>This file is larger than the editor "
		           "can safely hold; only the first part is shown. <b>Do not save</b> — "
		           "it would truncate the file. Edit it over SSH instead.</p></div>");

	bputs(out, "<form method=post action=/file><div class=card>");
	bprintf(out, "<input type=hidden name=path value=\"%s\"><textarea name=content>", rel);
	besc(out, data);
	bputs(out, "</textarea></div><button>Save</button> ");
	bprintf(out, "<a href=\"/files?path=%s\" class=dim>back without saving</a></form>", up);
	page_foot(out);
}

static void view_packages(struct buf *out, const char *flash)
{
	page_head(out, "Packages", "Packages");
	bputs(out, "<h1>Packages</h1>");
	if (flash && flash[0]) { bputs(out, "<div class=card>"); besc(out, flash); bputs(out, "</div>"); }

	info_box(out, "What is this page?",
	    "<p>A Zurvan package is a <span class=mono>.tar.gz</span> of static binaries plus a "
	    "manifest. <b>Upload</b> one below (or drop it in <span class=mono>/data</span>), then "
	    "<b>Install</b> — it unpacks into <span class=mono>/data/apps</span> and its files are "
	    "linked into the standard paths on every boot.</p>");

	bputs(out, "<h2>Upload a package</h2><div class=card>"
	           "<form method=post action=/packages/upload enctype=multipart/form-data>"
	           "<div class=row><input type=file name=file accept=.gz,.tgz,.tar.gz>"
	           "<button>Upload to /data</button></div>"
	           "<p class=dim>Then click Install below.</p></form></div>");

	char installed[8192] = "";
	char *pv[] = { "zurvan-pkg", "list", NULL };
	run(pv, installed, sizeof installed, NULL);

	/* Installed table: name + version, an Enable button for a SERVICE package
	 * not yet declared, and Uninstall. A service is one that exported a .def on
	 * install; "enabled" means it's in the supervisor's set (/run/svc/enabled).
	 * A plain tool (hello, sqlite3, curl) exports no .def, so no Enable button
	 * is ever shown for it — there is nothing to enable. */
	bputs(out, "<h2>Installed</h2><div class=card><table class=pkg>"
	           "<tr><th>Package</th><th>Version</th><th></th></tr>");
	int ninst = 0;
	{
		char buf[8192]; snprintf(buf, sizeof buf, "%s", installed);
		char *line = strtok(buf, "\n");
		while (line) {
			char name[128] = "", ver[64] = "";
			if (sscanf(line, "%127s %63s", name, ver) >= 1 &&
			    name[0] && name[0] != '[' && strcmp(name, "no") != 0) {
				ninst++;
				char defp[256]; snprintf(defp, sizeof defp, "/run/svc/%s.def", name);
				int is_svc = path_exists(defp);
				int is_en  = line_in_file("/run/svc/enabled", name);
				bprintf(out, "<tr><td class=mono>%s</td><td class=dim>%s</td><td class=row>",
				        name, ver);
				if (is_svc && !is_en)
					bprintf(out, "<form class=inline method=post action=/packages/enable "
					             "onsubmit=\"return confirm('Enable %s? It is added to "
					             "services: in zurvan.yaml and started now.')\">"
					             "<input type=hidden name=name value=\"%s\">"
					             "<button>Enable</button></form>", name, name);
				else if (is_svc)
					bputs(out, "<a href=/services class=pill>enabled</a>");
				bprintf(out, "<form class=inline method=post action=/packages/remove "
				             "onsubmit=\"return confirm('Uninstall %s?')\">"
				             "<input type=hidden name=name value=\"%s\">"
				             "<button class=r>Uninstall</button></form></td></tr>",
				        name, name);
			}
			line = strtok(NULL, "\n");
		}
	}
	if (!ninst) bputs(out, "<tr><td class=dim>Nothing installed yet.</td></tr>");
	bputs(out, "</table></div>");

	/* Available tarballs on /data: Install (or "installed" badge) + Delete. */
	bputs(out, "<h2>Package files on /data</h2><div class=card><table class=pkg>"
	           "<tr><th>File</th><th>Status</th><th></th></tr>");
	DIR *d = opendir("/data");
	int any = 0;
	if (d) {
		struct dirent *e;
		while ((e = readdir(d))) {
			size_t l = strlen(e->d_name);
			if (l <= 7 || strcmp(e->d_name + l - 7, ".tar.gz") != 0)
				continue;
			any = 1;
			/* installed if some "name " line is a prefix of "<file>-" */
			int is_inst = 0;
			char ibuf[8192]; snprintf(ibuf, sizeof ibuf, "%s", installed);
			for (char *ln = strtok(ibuf, "\n"); ln; ln = strtok(NULL, "\n")) {
				char nm[128] = ""; sscanf(ln, "%127s", nm);
				size_t nl = strlen(nm);
				if (nl && strncmp(e->d_name, nm, nl) == 0 && e->d_name[nl] == '-') { is_inst = 1; break; }
			}
			bprintf(out, "<tr><td class=mono>%s</td><td>", e->d_name);
			if (is_inst)
				bputs(out, "<span class=ok>&#10003; installed</span>");
			else
				bprintf(out, "<form class=inline method=post action=/packages/install>"
				             "<input type=hidden name=file value=\"%s\">"
				             "<button>Install</button></form>", e->d_name);
			bprintf(out, "</td><td><form class=inline method=post action=/packages/delete "
			             "onsubmit=\"return confirm('Delete the file %s from /data?')\">"
			             "<input type=hidden name=file value=\"%s\">"
			             "<button class=g>Delete file</button></form></td></tr>",
			        e->d_name, e->d_name);
		}
		closedir(d);
	}
	if (!any) bputs(out, "<tr><td class=dim>No package files in /data — upload one above.</td></tr>");
	bputs(out, "</table></div>");
	page_foot(out);
}

static void view_system(struct buf *out, const char *flash)
{
	page_head(out, "System", "System");
	bputs(out, "<h1>System</h1>");
	if (flash && flash[0]) { bputs(out, "<div class=card>"); besc(out, flash); bputs(out, "</div>"); }

	info_box(out, "How upgrades work",
	    "<p>Zurvan keeps <b>two image slots</b>. Upgrading writes the <b>inactive</b> one, boots "
	    "it once, and if that boot fails it <b>rolls back automatically</b> to the slot you are "
	    "on now — so a bad image can never brick the box. The bundle's signature is verified "
	    "<b>before</b> anything is written.</p>");

	bputs(out, "<h2>Upgrade image (A/B, signed)</h2><div class=card>"
	           "<form method=post action=/system/upload enctype=multipart/form-data>"
	           "<div class=row><input type=file name=file accept=.tar>"
	           "<button>Upload bundle to /data</button></div></form>"
	           "<p class=dim>Then stage it below. (Or place a signed "
	           "<span class=mono>*.tar</span> in /data via scp.)</p><table>");
	DIR *dd = opendir("/data");
	int anyb = 0;
	if (dd) {
		struct dirent *e;
		while ((e = readdir(dd))) {
			size_t l = strlen(e->d_name);
			if (l > 4 && strcmp(e->d_name + l - 4, ".tar") == 0) {
				anyb = 1;
				bprintf(out, "<tr><td class=mono>%s</td><td>"
				             "<form class=inline method=post action=/system/upgrade "
				             "onsubmit=\"return confirm('Stage %s into the inactive slot?')\">"
				             "<input type=hidden name=file value=\"%s\">"
				             "<button>Verify &amp; stage</button></form></td></tr>",
				        e->d_name, e->d_name, e->d_name);
			}
		}
		closedir(dd);
	}
	if (!anyb) bputs(out, "<tr><td class=dim>No .tar bundles in /data.</td></tr>");
	bputs(out, "</table></div>");

	bputs(out, "<h2>Power</h2><div class=card>"
	           "<form method=post action=/system/reboot onsubmit=\"return confirm('Reboot now?')\">"
	           "<button class=r>Reboot</button></form>"
	           "<p class=dim>The OS reboots from RAM, identical; /data and the active image persist.</p></div>");
	page_foot(out);
}

static void view_login(struct buf *out, int failed)
{
	bprintf(out, "<!doctype html><html><head><meta charset=utf-8><title>Zurvan — sign in</title>"
	             "<meta name=viewport content=\"width=device-width,initial-scale=1\"><style>%s"
	             ".box{max-width:340px;margin:12vh auto;padding:0 20px}</style></head><body>"
	             "<div class=box><h1>&#128367; Zurvan</h1>", CSS);
	if (failed) bputs(out, "<div class=card><span class=bad>Wrong token.</span></div>");
	bputs(out, "<div class=card><form method=post action=/login>"
	           "<p class=dim>Enter the admin token (printed on the console at first boot).</p>"
	           "<p><input type=password name=token autofocus placeholder=\"admin token\"></p>"
	           "<button>Sign in</button></form></div></div></body></html>");
}

/* ==========================================================================
 * request dispatch
 * ========================================================================== */

static int authed(const struct req *r)
{
	/* cookie: "ztok=<token>" */
	const char *c = strstr(r->cookie, "ztok=");
	if (!c) return 0;
	c += 5;
	char val[128]; size_t i = 0;
	while (c[i] && c[i] != ';' && i < sizeof val - 1) { val[i] = c[i]; i++; }
	val[i] = 0;
	return ct_eq(val, g_token);
}

/* Build an HTTP response into resp. `extra` may add headers (e.g. Set-Cookie). */
static void respond(struct buf *resp, const char *status, const char *ctype,
                    const char *extra, const char *body, size_t blen)
{
	bprintf(resp, "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
	              "Connection: close\r\nX-Content-Type-Options: nosniff\r\n%s\r\n",
	        status, ctype, blen, extra ? extra : "");
	bput(resp, body, blen);
}
static void redirect(struct buf *resp, const char *to, const char *setcookie)
{
	char hdr[256];
	snprintf(hdr, sizeof hdr, "Location: %s\r\n%s", to, setcookie ? setcookie : "");
	respond(resp, "303 See Other", "text/plain", hdr, "", 0);
}

/* defined below, in the TLS/HTTP plumbing section */
static int multipart_file(const struct req *r, char *fname, size_t fnsz,
                          const char **data, size_t *dlen);

/* Read one service's state word ("up"/"down"/"disabled"/"stopping"). */
static void svc_state_of(const char *name, char *buf, size_t bufsz)
{
	buf[0] = 0;
	char st[8192];
	char *v[] = { "zurvan-svc", "state", NULL };
	run(v, st, sizeof st, NULL);
	char *save = NULL;
	for (char *line = strtok_r(st, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
		char n[64] = "", state[32] = ""; int pid;
		if (sscanf(line, "%63s %d %31s", n, &pid, state) == 3 && strcmp(n, name) == 0) {
			snprintf(buf, bufsz, "%s", state);
			return;
		}
	}
}

/* enable/disable are asynchronous: the supervisor acts on its 1-second
 * heartbeat, so redirecting the instant the CLI returns re-renders a
 * transient "stopping"/"down" that the user then has to reload past. Briefly
 * poll until the service reaches the settled state (or we give up — a service
 * that crash-loops may never reach "up", which is fine, the page shows that). */
static void svc_settle(const char *name, const char *want, int max_ms)
{
	char s[32];
	for (int t = 0; ; t += 150) {
		svc_state_of(name, s, sizeof s);
		if (strcmp(s, want) == 0 || t >= max_ms)
			return;
		usleep(150000);
	}
}

static void handle(const struct req *r, struct buf *resp)
{
	struct buf page = {0};

	/* --- unauthenticated routes --- */
	if (strcmp(r->path, "/login") == 0 && strcmp(r->method, "POST") == 0) {
		char tok[128] = "";
		form_get(r->body ? r->body : "", "token", tok, sizeof tok);
		if (ct_eq(tok, g_token)) {
			char sc[256];
			snprintf(sc, sizeof sc, "Set-Cookie: ztok=%s; Path=/; HttpOnly; Secure; SameSite=Strict\r\n", g_token);
			redirect(resp, "/", sc);
		} else { view_login(&page, 1); respond(resp, "200 OK", "text/html", NULL, page.p, page.n); }
		free(page.p); return;
	}
	if (!authed(r)) {
		if (strcmp(r->path, "/login") == 0) view_login(&page, 0);
		else { redirect(resp, "/login", NULL); return; }
		respond(resp, "200 OK", "text/html", NULL, page.p, page.n);
		free(page.p); return;
	}
	if (strcmp(r->path, "/logout") == 0) {
		redirect(resp, "/login", "Set-Cookie: ztok=; Path=/; Max-Age=0\r\n");
		return;
	}

	/* --- POST actions (each does one thing, then redirects) --- */
	if (strcmp(r->method, "POST") == 0) {
		const char *body = r->body ? r->body : "";
		char arg[1200] = "", out[OUT_MAX];
		/* Actions capture the CLI's output and stash it as a one-shot flash,
		 * then redirect (PRG) — so the result, success or failure, shows on the
		 * next page load instead of being silently discarded. */
		if (strcmp(r->path, "/services/restart") == 0 && form_get(body, "name", arg, sizeof arg)) {
			char *v[] = { "zurvan-svc", "restart", arg, NULL };
			run(v, out, sizeof out, NULL);
			set_flash(out[0] ? out : "restart signalled.");
			redirect(resp, "/services", NULL); return;
		}
		if (strcmp(r->path, "/services/disable") == 0 && form_get(body, "name", arg, sizeof arg)) {
			char *v[] = { "zurvan-svc", "disable", arg, NULL };
			run(v, out, sizeof out, NULL);
			set_flash(out[0] ? out : "disabled.");
			svc_settle(arg, "disabled", 2500);   /* SIGTERM lands fast */
			redirect(resp, "/services", NULL); return;
		}
		if (strcmp(r->path, "/services/enable") == 0 && form_get(body, "name", arg, sizeof arg)) {
			char *v[] = { "zurvan-svc", "enable", arg, NULL };
			run(v, out, sizeof out, NULL);
			set_flash(out[0] ? out : "enabled.");
			svc_settle(arg, "up", 3000);          /* waits out the heartbeat + deps */
			redirect(resp, "/services", NULL); return;
		}
		if (strcmp(r->path, "/snapshots/snap") == 0) {
			char *v[] = { "zurvan-lion", "snap", NULL }; run(v, out, sizeof out, NULL);
			set_flash(out[0] ? out : "snapshot taken.");
			redirect(resp, "/snapshots", NULL); return;
		}
		if (strcmp(r->path, "/snapshots/restore") == 0 && form_get(body, "name", arg, sizeof arg)) {
			char mode[16] = ""; form_get(body, "mode", mode, sizeof mode);
			if (strcmp(mode, "mirror") == 0) {
				char *v[] = { "zurvan-lion", "restore", "--mirror", arg, NULL };
				run(v, out, sizeof out, NULL);
			} else {
				char *v[] = { "zurvan-lion", "restore", arg, NULL };
				run(v, out, sizeof out, NULL);
			}
			set_flash(out[0] ? out : "restore done.");
			redirect(resp, "/snapshots", NULL); return;
		}
		if (strcmp(r->path, "/jobs/run") == 0 && form_get(body, "script", arg, sizeof arg)) {
			char *v[] = { "zurvan-snake", "run", "-", NULL };
			run(v, out, sizeof out, arg);
			set_flash(out[0] ? out : "job submitted.");
			redirect(resp, "/jobs", NULL); return;
		}
		if (strcmp(r->path, "/packages/install") == 0 && form_get(body, "file", arg, sizeof arg)) {
			out[0] = 0;
			if (name_safe(arg)) {
				char full[1300]; snprintf(full, sizeof full, "/data/%s", arg);
				char *v[] = { "zurvan-pkg", "install", full, NULL };
				run(v, out, sizeof out, NULL);
			} else snprintf(out, sizeof out, "refused unsafe package name");
			set_flash(out[0] ? out : "installed.");
			redirect(resp, "/packages", NULL); return;
		}
		if (strcmp(r->path, "/packages/enable") == 0 && form_get(body, "name", arg, sizeof arg)) {
			out[0] = 0;
			if (name_safe(arg)) {
				char *v[] = { "zurvan-pkg", "enable", arg, NULL };
				run(v, out, sizeof out, NULL);
				svc_settle(arg, "up", 3000);   /* supervisor rescan + start */
			} else snprintf(out, sizeof out, "refused unsafe package name");
			set_flash(out[0] ? out : "enabled.");
			redirect(resp, "/packages", NULL); return;
		}
		/* --- uploads (multipart): save the file onto /data, then redirect --- */
		if (strcmp(r->path, "/packages/remove") == 0 && form_get(body, "name", arg, sizeof arg)) {
			out[0] = 0;
			if (name_safe(arg)) {
				char *v[] = { "zurvan-pkg", "remove", arg, NULL };
				run(v, out, sizeof out, NULL);
			} else snprintf(out, sizeof out, "refused unsafe package name");
			set_flash(out[0] ? out : "removed.");
			redirect(resp, "/packages", NULL); return;
		}
		if (strcmp(r->path, "/packages/delete") == 0 && form_get(body, "file", arg, sizeof arg)) {
			size_t al = strlen(arg);
			if (name_safe(arg) && al > 7 && strcmp(arg + al - 7, ".tar.gz") == 0) {
				char full[1300]; snprintf(full, sizeof full, "/data/%s", arg);
				if (unlink(full) == 0) snprintf(out, sizeof out, "deleted %s from /data", arg);
				else                   snprintf(out, sizeof out, "could not delete %s: %s", arg, strerror(errno));
			} else snprintf(out, sizeof out, "refused: %s is not a .tar.gz on /data", arg);
			set_flash(out);
			redirect(resp, "/packages", NULL); return;
		}
		if (strcmp(r->path, "/packages/upload") == 0) {
			char fn[256]; const char *fdata; size_t fdlen;
			if (multipart_file(r, fn, sizeof fn, &fdata, &fdlen) && name_safe(fn))
				save_file("/data", fn, fdata, fdlen);
			redirect(resp, "/packages", NULL); return;
		}
		if (strcmp(r->path, "/system/upload") == 0) {
			char fn[256]; const char *fdata; size_t fdlen;
			if (multipart_file(r, fn, sizeof fn, &fdata, &fdlen) && name_safe(fn))
				save_file("/data", fn, fdata, fdlen);
			redirect(resp, "/system", NULL); return;
		}
		if (strcmp(r->path, "/files/upload") == 0) {
			/* target dir comes from the query (?path=REL); the body is the file */
			char dir[1024] = ""; form_get(r->query, "path", dir, sizeof dir);
			char fn[256]; const char *fdata; size_t fdlen; char abs[1200];
			if (multipart_file(r, fn, sizeof fn, &fdata, &fdlen) &&
			    name_safe(fn) && !strstr(dir, "..")) {
				snprintf(abs, sizeof abs, "/data%s%s", dir[0] ? "/" : "", dir);
				save_file(abs, fn, fdata, fdlen);
			}
			char to[1100]; snprintf(to, sizeof to, "/files?path=%s", dir);
			redirect(resp, to, NULL); return;
		}
		if (strcmp(r->path, "/file") == 0) {
			char rel[1024] = "", *content = malloc(REQ_MAX);
			form_get(body, "path", rel, sizeof rel);
			content[0] = 0;
			form_get(body, "content", content, REQ_MAX);
			char abs[1024];
			if (rel[0] && data_path_ok(rel, abs, sizeof abs)) {
				int fd = open(abs, O_WRONLY | O_CREAT | O_TRUNC, 0644);
				if (fd >= 0) { ssize_t w = write(fd, content, strlen(content)); (void)w; close(fd); }
			}
			free(content);
			view_file(&page, rel, "Saved.");
			respond(resp, "200 OK", "text/html", NULL, page.p, page.n);
			free(page.p); return;
		}
		/* --- file management on /data: mkdir / delete / rename / copy --- */
		if (strcmp(r->path, "/files/mkdir") == 0 && form_get(body, "name", arg, sizeof arg)) {
			char dir[1024] = ""; form_get(body, "path", dir, sizeof dir);
			if (name_safe(arg) && !strstr(dir, "..")) {
				char abs[1400];
				snprintf(abs, sizeof abs, "/data/%s%s%s", dir, dir[0] ? "/" : "", arg);
				mkdir(abs, 0755);
			}
			char to[1300]; snprintf(to, sizeof to, "/files?path=%s", dir);
			redirect(resp, to, NULL); return;
		}
		if (strcmp(r->path, "/files/delete") == 0 && form_get(body, "path", arg, sizeof arg)) {
			char abs[1400];
			if (arg[0] && !strstr(arg, "..")) {
				snprintf(abs, sizeof abs, "/data/%s", arg);
				remove(abs);                    /* unlink file or rmdir empty dir */
			}
			char dir[1200]; snprintf(dir, sizeof dir, "%s", arg);
			char *s = strrchr(dir, '/'); if (s) *s = 0; else dir[0] = 0;
			char to[1300]; snprintf(to, sizeof to, "/files?path=%s", dir);
			redirect(resp, to, NULL); return;
		}
		if ((strcmp(r->path, "/files/rename") == 0 || strcmp(r->path, "/files/copy") == 0) &&
		    form_get(body, "path", arg, sizeof arg)) {
			char nm[256] = ""; form_get(body, "name", nm, sizeof nm);
			char dir[1200]; snprintf(dir, sizeof dir, "%s", arg);
			char *s = strrchr(dir, '/'); if (s) *s = 0; else dir[0] = 0;
			if (arg[0] && !strstr(arg, "..") && name_safe(nm)) {
				char src[1400], dst[1700];
				snprintf(src, sizeof src, "/data/%s", arg);
				snprintf(dst, sizeof dst, "/data/%s%s%s", dir, dir[0] ? "/" : "", nm);
				if (strcmp(r->path, "/files/rename") == 0) {
					rename(src, dst);
				} else {
					int in = open(src, O_RDONLY);
					int o = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
					if (in >= 0 && o >= 0) { char b[65536]; ssize_t k;
						while ((k = read(in, b, sizeof b)) > 0) { ssize_t w=write(o,b,k); (void)w; } }
					if (in >= 0) close(in);
					if (o >= 0) close(o);
				}
			}
			char to[1300]; snprintf(to, sizeof to, "/files?path=%s", dir);
			redirect(resp, to, NULL); return;
		}
		if (strcmp(r->path, "/system/upgrade") == 0 && form_get(body, "file", arg, sizeof arg)) {
			out[0] = 0;
			if (!strstr(arg, "..") && !strchr(arg, '/')) {
				char full[1300]; snprintf(full, sizeof full, "/data/%s", arg);
				char *v[] = { "zurvan-upgrade", full, NULL };
				run(v, out, sizeof out, NULL);
			} else snprintf(out, sizeof out, "bad bundle name");
			set_flash(out[0] ? out : "staged.");
			redirect(resp, "/system", NULL); return;
		}
		if (strcmp(r->path, "/system/reboot") == 0) {
			/* Full page with the RIGHT length (the old hardcoded 20 truncated
			 * it to a broken fragment -> blank page). Refresh after ~25s, by
			 * which time the box is usually back. */
			const char *msg =
			    "<!doctype html><meta charset=utf-8>"
			    "<meta http-equiv=refresh content='25;url=/'>"
			    "<title>Rebooting Zurvan</title>"
			    "<body style=\"margin:0;min-height:100vh;display:grid;place-items:center;"
			    "background:#0f1115;color:#d7dbe0;font:16px system-ui,sans-serif;text-align:center\">"
			    "<div><h1>&#128367; Rebooting Zurvan\xE2\x80\xA6</h1>"
			    "<p style=color:#8b93a1>This page returns automatically in a few seconds, "
			    "or <a href=/ style=color:#6fb3ff>reload now</a>.</p></div></body>";
			respond(resp, "200 OK", "text/html", NULL, msg, strlen(msg));
			/* reboot -f: PID 1 ignores SIGTERM, so a polite `reboot` does
			 * nothing here — force the syscall (after sync + a beat so this
			 * response reaches the browser first). */
			if (fork() == 0) {
				sleep(1);
				sync();
				char *v[] = { "reboot", "-f", NULL };
				run(v, NULL, 0, NULL);
				_exit(0);
			}
			return;
		}
		/* upgrade upload handled minimally below (multipart) */
	}

	/* --- GET pages --- */
	/* A one-shot flash left by the last action (see set_flash) shows once on
	 * the page it redirected to, then is consumed. */
	char fl[OUT_MAX]; take_flash(fl, sizeof fl);
	char *flash = fl[0] ? fl : NULL;
	if      (strcmp(r->path, "/") == 0)          view_overview(&page);
	else if (strcmp(r->path, "/services") == 0)  view_services(&page, flash);
	else if (strcmp(r->path, "/snapshots") == 0) view_snapshots(&page, flash);
	else if (strcmp(r->path, "/jobs") == 0)      view_jobs(&page, flash);
	else if (strcmp(r->path, "/job") == 0) {
		char id[128] = ""; form_get(r->query, "id", id, sizeof id); view_job(&page, id);
	}
	else if (strcmp(r->path, "/files") == 0) {
		char p[1024] = ""; form_get(r->query, "path", p, sizeof p); view_files(&page, p);
	}
	else if (strcmp(r->path, "/file") == 0) {
		char p[1024] = ""; form_get(r->query, "path", p, sizeof p); view_file(&page, p, NULL);
	}
	else if (strcmp(r->path, "/packages") == 0)  view_packages(&page, flash);
	else if (strcmp(r->path, "/system") == 0)    view_system(&page, flash);
	else { respond(resp, "404 Not Found", "text/html", NULL, "not found", 9); return; }

	respond(resp, "200 OK", "text/html", NULL, page.p, page.n);
	free(page.p);
}

/* ==========================================================================
 * TLS plumbing (from the M6 spike)
 * ========================================================================== */

static unsigned char *slurp(const char *path, size_t *len)
{
	int fd = open(path, O_RDONLY); if (fd < 0) return NULL;
	unsigned char *b = NULL; size_t cap = 0, n = 0;
	for (;;) {
		if (n == cap) { cap = cap ? cap * 2 : 4096; b = realloc(b, cap); }
		ssize_t r = read(fd, b + n, cap - n);
		if (r < 0) { free(b); close(fd); return NULL; }
		if (r == 0) break;
		n += (size_t)r;
	}
	close(fd); *len = n; return b;
}
static int sock_read(void *ctx, unsigned char *b, size_t l)
{ for (;;) { ssize_t r = read(*(int *)ctx, b, l); if (r <= 0) { if (r<0&&errno==EINTR) continue; return -1; } return (int)r; } }
static int sock_write(void *ctx, const unsigned char *b, size_t l)
{ for (;;) { ssize_t r = write(*(int *)ctx, b, l); if (r <= 0) { if (r<0&&errno==EINTR) continue; return -1; } return (int)r; } }

static br_ec_private_key g_eckey;
static unsigned char g_eckey_buf[BR_EC_KBUF_PRIV_MAX_SIZE];
static br_x509_certificate g_chain[1];

static int load_identity(void)
{
	char kp[512], cp[512];
	snprintf(kp, sizeof kp, "%s/key.der", g_dir);
	snprintf(cp, sizeof cp, "%s/cert.der", g_dir);
	size_t klen, clen;
	unsigned char *k = slurp(kp, &klen), *c = slurp(cp, &clen);
	if (!k || !c) return -1;
	br_skey_decoder_context kc; br_skey_decoder_init(&kc);
	br_skey_decoder_push(&kc, k, klen);
	if (br_skey_decoder_last_error(&kc) != 0 || br_skey_decoder_key_type(&kc) != BR_KEYTYPE_EC)
		return -1;
	const br_ec_private_key *ek = br_skey_decoder_get_ec(&kc);
	memcpy(g_eckey_buf, ek->x, ek->xlen);
	g_eckey.curve = ek->curve; g_eckey.x = g_eckey_buf; g_eckey.xlen = ek->xlen;
	g_chain[0].data = c; g_chain[0].data_len = clen;
	return 0;
}

/* One header value into out (case-insensitive header name incl. "\r\n"). */
static void hdr_val(const char *hdr, const char *name, char *out, size_t outsz)
{
	out[0] = 0;
	const char *h = strcasestr(hdr, name);
	if (!h) return;
	h += strlen(name);
	while (*h == ' ') h++;
	const char *e = strstr(h, "\r\n");
	size_t l = e ? (size_t)(e - h) : strlen(h);
	if (l >= outsz) l = outsz - 1;
	memcpy(out, h, l); out[l] = 0;
}

/* Read one HTTP request: headers into a fixed buffer, body malloc'd by
 * Content-Length (so uploads up to UPLOAD_MAX work without a giant buffer on
 * every request). Headers are small; the body is bulk-read, not byte-by-byte. */
static int read_request(br_sslio_context *ioc, struct req *r)
{
	memset(r, 0, sizeof *r);
	char hdr[HDR_MAX];
	size_t n = 0;
	while (n < sizeof hdr - 1) {
		unsigned char x;
		if (br_sslio_read(ioc, &x, 1) < 0) return -1;
		hdr[n++] = (char)x;
		if (n >= 4 && memcmp(hdr + n - 4, "\r\n\r\n", 4) == 0) break;
	}
	if (n < 4) return -1;
	hdr[n] = 0;

	sscanf(hdr, "%7s %1023s", r->method, r->path);
	char *q = strchr(r->path, '?');
	if (q) { *q = 0; snprintf(r->query, sizeof r->query, "%s", q + 1); }

	hdr_val(hdr, "\r\nCookie:",       r->cookie, sizeof r->cookie);
	hdr_val(hdr, "\r\nContent-Type:", r->ctype,  sizeof r->ctype);
	char cl[32]; hdr_val(hdr, "\r\nContent-Length:", cl, sizeof cl);
	r->clen = (size_t)strtoul(cl, NULL, 10);

	if (r->clen > 0 && r->clen <= UPLOAD_MAX) {
		char *body = malloc(r->clen + 1);
		if (!body) return -1;
		size_t got = 0;
		while (got < r->clen) {
			int k = br_sslio_read(ioc, (unsigned char *)body + got, r->clen - got);
			if (k < 0) { free(body); return -1; }
			got += (size_t)k;
		}
		body[r->clen] = 0;
		r->body = body;
		r->body_owned = 1;
	}
	return 0;
}

/* Find the first file part of a multipart/form-data body. On success returns 1
 * and sets fname (basename, into caller buffer), *data and *dlen (into the
 * request body — not copied). */
static int multipart_file(const struct req *r, char *fname, size_t fnsz,
                          const char **data, size_t *dlen)
{
	if (!r->body || !strcasestr(r->ctype, "multipart/form-data"))
		return 0;
	const char *bp = strcasestr(r->ctype, "boundary=");
	if (!bp) return 0;
	bp += 9;
	char bnd[160];
	int i = 0;
	bnd[i++] = '-'; bnd[i++] = '-';
	while (*bp && *bp != ';' && *bp != ' ' && *bp != '"' && (size_t)i < sizeof bnd - 1)
		bnd[i++] = *bp++;
	bnd[i] = 0;
	size_t blen = strlen(bnd);

	const char *body = r->body, *end = body + r->clen, *p = body;
	while (p < end) {
		const char *bpos = memmem(p, (size_t)(end - p), bnd, blen);
		if (!bpos) break;
		p = bpos + blen;
		if (p + 2 <= end && p[0] == '-' && p[1] == '-') break;   /* closing */
		if (p < end && *p == '\r') p++;
		if (p < end && *p == '\n') p++;
		const char *hend = memmem(p, (size_t)(end - p), "\r\n\r\n", 4);
		if (!hend) break;
		const char *fn = memmem(p, (size_t)(hend - p), "filename=\"", 10);
		const char *content = hend + 4;
		const char *cend = memmem(content, (size_t)(end - content), bnd, blen);
		if (!cend) cend = end;
		const char *ce = cend;
		if (ce - content >= 2 && ce[-2] == '\r' && ce[-1] == '\n') ce -= 2;
		if (fn && fn < hend) {
			fn += 10;
			const char *fe = memchr(fn, '"', (size_t)(hend - fn));
			size_t l = fe ? (size_t)(fe - fn) : 0;
			if (l >= fnsz) l = fnsz - 1;
			memcpy(fname, fn, l); fname[l] = 0;
			char *s = strrchr(fname, '/');  if (s) memmove(fname, s + 1, strlen(s + 1) + 1);
			s = strrchr(fname, '\\');       if (s) memmove(fname, s + 1, strlen(s + 1) + 1);
			*data = content; *dlen = (size_t)(ce - content);
			return 1;
		}
		p = cend;
	}
	return 0;
}

int main(int argc, char **argv)
{
	int port = DEF_PORT;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) port = atoi(argv[++i]);
		else if (strcmp(argv[i], "--dir") == 0 && i + 1 < argc) g_dir = argv[++i];
	}
	signal(SIGPIPE, SIG_IGN);
	/* Children are all spawned by run(), which waitpid()s for each — so we do
	 * NOT ignore SIGCHLD (that would auto-reap them and make waitpid fail with
	 * ECHILD, losing exit codes). */

	/* the admin token */
	char tp[512]; snprintf(tp, sizeof tp, "%s/token", g_dir);
	int fd = open(tp, O_RDONLY);
	if (fd < 0) { face_log("no token at %s — is the panel provisioned?", tp); return 1; }
	ssize_t tn = read(fd, g_token, TOKEN_LEN); close(fd);
	if (tn < 8) { face_log("token too short"); return 1; }
	g_token[tn] = 0;
	char *nl = strchr(g_token, '\n'); if (nl) *nl = 0;

	if (load_identity() != 0) { face_log("cannot load TLS identity from %s", g_dir); return 1; }

	int sfd = socket(AF_INET, SOCK_STREAM, 0);
	int one = 1; setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	struct sockaddr_in sa; memset(&sa, 0, sizeof sa);
	sa.sin_family = AF_INET; sa.sin_addr.s_addr = htonl(INADDR_ANY);
	sa.sin_port = htons((unsigned short)port);
	if (bind(sfd, (struct sockaddr *)&sa, sizeof sa) < 0 || listen(sfd, 16) < 0) {
		face_log("bind/listen on :%d failed", port); return 1;
	}
	face_log("panel up on port %d (https); identity dir %s", port, g_dir);

	for (;;) {
		int cfd = accept(sfd, NULL, NULL);
		if (cfd < 0) continue;

		br_ssl_server_context sc;
		unsigned char iobuf[BR_SSL_BUFSIZE_BIDI];
		br_ssl_server_init_full_ec(&sc, g_chain, 1, BR_KEYTYPE_EC, &g_eckey);
		br_ssl_engine_set_buffer(&sc.eng, iobuf, sizeof iobuf, 1);
		br_ssl_server_reset(&sc);
		br_sslio_context ioc;
		br_sslio_init(&ioc, &sc.eng, sock_read, &cfd, sock_write, &cfd);

		struct req r;
		if (read_request(&ioc, &r) == 0) {
			struct buf resp = {0};
			handle(&r, &resp);
			br_sslio_write_all(&ioc, resp.p, resp.n);
			br_sslio_flush(&ioc);
			free(resp.p);
			if (r.body_owned) free((void *)r.body);
		}
		close(cfd);
	}
}
