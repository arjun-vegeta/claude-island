// Sits between a Terminal window and `tmux attach`, passing everything through unchanged except
// files dragged in from macOS's screenshot preview.
//
// Dragging the preview drops a path inside $TMPDIR/TemporaryItems, which macOS only lets the app
// you dropped onto (Terminal, and processes it started) read. tmux's server runs on its own, so the
// Claude sessions inside it can't open that file. This relay was started by Terminal, so it can: it
// copies the file to ~/Library/Caches/claude-island-drops and hands Claude that path instead.
//
// Built by build.sh as shell/relay/tmux: Terminal doesn't ask before closing a window that's only
// running tmux, and it names the window after the running command.
//
// Usage: tmux <real tmux> [args...]      (runs the real tmux in a pty and relays to it)
//        tmux --rewrite                   (test: rewrites stdin to stdout)

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

static struct termios original;
static int have_tty = 0;
static volatile sig_atomic_t resized = 0;

static void restore(void) {
    if (have_tty) tcsetattr(STDIN_FILENO, TCSANOW, &original);
}

static void on_winch(int sig) { (void)sig; resized = 1; }

static int write_all(int fd, const char *p, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) {
            if (errno == EINTR || errno == EAGAIN) continue;
            return -1;
        }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static int copy_file(const char *from, const char *to) {
    // The preview may still be writing the file when the path arrives.
    struct stat st;
    for (int i = 0; i < 40 && stat(from, &st) != 0; i++) usleep(50000);
    int in = open(from, O_RDONLY);
    if (in < 0) return -1;
    int out = open(to, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (out < 0) { close(in); return -1; }
    char buf[65536];
    ssize_t n;
    int ok = 0;
    while ((n = read(in, buf, sizeof buf)) > 0) {
        if (write_all(out, buf, (size_t)n) < 0) { ok = -1; break; }
    }
    if (n < 0) ok = -1;
    close(in);
    close(out);
    return ok;
}

static int is_plain(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strchr("._/-+@:,=%", c);
}

// Rewrites dropped TemporaryItems paths in `in` (n bytes) into `out`; returns the new length.
// `out` must hold at least 2 * n + 4096 bytes.
static size_t rewrite(const char *in, size_t n, char *out) {
    static const char marker[] = "/TemporaryItems/";
    size_t o = 0, i = 0;
    while (i < n) {
        const char *hit = memmem(in + i, n - i, marker, sizeof marker - 1);
        if (!hit) break;
        size_t at = (size_t)(hit - in);
        // The path starts after the space, quote or paste marker before it.
        size_t start = at;
        while (start > i && !strchr(" \t\r\n'\"~", in[start - 1])) start--;
        if (in[start] != '/') {   // not an absolute path: leave it alone
            memcpy(out + o, in + i, at + 1 - i);
            o += at + 1 - i;
            i = at + 1;
            continue;
        }
        // It ends at the first unescaped space, quote, control character or the end of the input.
        char path[4096];
        size_t p = 0, end = start;
        char quote = start > 0 && (in[start - 1] == '\'' || in[start - 1] == '"') ? in[start - 1] : 0;
        while (end < n && p < sizeof path - 1) {
            char c = in[end];
            if (c == '\\' && end + 1 < n && !quote) { path[p++] = in[end + 1]; end += 2; continue; }
            if (quote ? c == quote : (c == ' ' || c == '\'' || c == '"')) break;
            if ((unsigned char)c < 0x20) break;
            path[p++] = c;
            end++;
        }
        path[p] = 0;

        const char *home = getenv("HOME");
        const char *name = strrchr(path, '/');
        char dir[1024], dest[4096];
        snprintf(dir, sizeof dir, "%s/Library/Caches/claude-island-drops", home ? home : "/tmp");
        mkdir(dir, 0700);
        snprintf(dest, sizeof dest, "%s/%s", dir, name ? name + 1 : "dropped");

        memcpy(out + o, in + i, start - i);
        o += start - i;
        if (copy_file(path, dest) == 0) {
            for (const char *c = dest; *c && o < 2 * n + 4000; c++) {
                if (!quote && !is_plain(*c)) out[o++] = '\\';
                out[o++] = *c;
            }
        } else {
            memcpy(out + o, in + start, end - start);
            o += end - start;
        }
        i = end;
    }
    memcpy(out + o, in + i, n - i);
    return o + n - i;
}

int main(int argc, char **argv) {
    static char buf[65536], out[2 * 65536 + 4096];

    if (argc == 2 && strcmp(argv[1], "--rewrite") == 0) {
        ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
        if (n > 0) write_all(STDOUT_FILENO, out, rewrite(buf, (size_t)n, out));
        return 0;
    }
    if (argc < 2) {
        fprintf(stderr, "usage: %s <command> [args...]\n", argv[0]);
        return 2;
    }

    struct winsize ws;
    have_tty = isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &original) == 0;
    if (!have_tty || ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) != 0) memset(&ws, 0, sizeof ws);
    // Without a terminal there's nothing to relay.
    if (!have_tty) { execvp(argv[1], argv + 1); return 127; }

    int master;
    pid_t child = forkpty(&master, NULL, &original, &ws);
    if (child < 0) { execvp(argv[1], argv + 1); return 127; }
    if (child == 0) {
        execvp(argv[1], argv + 1);
        _exit(127);
    }

    struct termios raw = original;
    cfmakeraw(&raw);
    tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    atexit(restore);
    signal(SIGWINCH, on_winch);
    signal(SIGPIPE, SIG_IGN);

    struct pollfd fds[2] = {{STDIN_FILENO, POLLIN, 0}, {master, POLLIN, 0}};
    int input_open = 1;
    for (;;) {
        if (resized) {
            resized = 0;
            if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0) ioctl(master, TIOCSWINSZ, &ws);
        }
        fds[0].fd = input_open ? STDIN_FILENO : -1;
        if (poll(fds, 2, -1) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(master, buf, sizeof buf);
            if (n <= 0) {
                if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
                break;   // tmux exited
            }
            if (write_all(STDOUT_FILENO, buf, (size_t)n) < 0) break;
        }
        if (input_open && (fds[0].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
            if (n <= 0) {
                if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
                break;   // the window closed
            }
            const char *data = buf;
            size_t len = (size_t)n;
            if (memmem(buf, len, "/TemporaryItems/", 16)) {
                len = rewrite(buf, len, out);
                data = out;
            }
            if (write_all(master, data, len) < 0) break;
        }
    }

    restore();
    close(master);
    int status = 0;
    if (waitpid(child, &status, WNOHANG) == 0) {
        kill(child, SIGHUP);
        waitpid(child, &status, 0);
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
