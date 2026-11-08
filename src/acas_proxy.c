/*
 * acas_proxy.c — SMB400 ACAS APDU proxy.
 *
 * Owns the on-device ACAS chip through libstationtv_lt_px_stream.so and
 * exposes the SCI APDU interface over TCP so b61dec / b25dec can run on
 * another host (the "remote decoder").
 *
 * The chip is shared with other processes through the library's
 * PIXELA_DeviceSharing locks (SCI_WRAPPER_InitForAllProcess).  This proxy
 * serialises its own clients with a mutex and performs the A0 (GetCkc)
 * handshake once, so every client can derive the same KCL from the
 * returned a0_cmd/a0_resp.
 *
 * Usage: acas_proxy [-p port] [-v]
 *   default port: 40773
 *
 * No authentication: any host that can reach the port can use the ACAS
 * chip.  Run only on a trusted LAN.
 *
 * Protocol: see src/acas_remote.h.
 *
 * Notes:
 *   - Run as root (ADB shell on SMB400 is root).
 *   - Stop pix_airtuner first (start_mirakc.sh / stop_android_tv.sh does).
 *   - Only one A0 session is kept.  Do not run local b61dec/b25dec A0
 *     initiators at the same time; after the tuner-script split the proxy is
 *     the only ACAS A0 user.
 */

#include "acas_remote.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#if defined(ACAS_ANDROID)
extern int *__errno(void);
#undef errno
#define errno (*__errno())
extern char *strerror(int errnum);
#endif
#include <signal.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

typedef int (*fn0)(void);
typedef int (*fn3p)(uint8_t *, uint8_t *, uint8_t *);
typedef int (*set_fn)(uint8_t *, int, uint8_t *, int *);
typedef int (*get_fn)(uint8_t *, int *);

static fn0     sw_InitAll;
static fn0     sw_ResetF;
static fn0     sw_WaitAct;
static fn3p    sw_GetCkc;
static set_fn  sw_SetData;
static get_fn  sw_GetData;
static get_fn  sw_GetAtr;

static void   *g_lib;
static int     g_verbose;
static int     g_port = ACAS_REMOTE_DEFAULT_PORT;
static int     g_listen = -1;
static volatile int g_stop;

static pthread_mutex_t g_chip_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t g_a0_cmd[64];
static uint8_t g_a0_resp[64];
static int     g_have_ckc;

static uint16_t get_u16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static void put_u16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)(v & 0xff);
}

static int write_full(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static int read_full(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static void logmsg(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[acas_proxy] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

static int load_lib(void) {
    g_lib = dlopen("/vendor/lib/libstationtv_lt_px_stream.so", RTLD_NOW);
    if (!g_lib) {
        logmsg("dlopen: %s", dlerror());
        return -1;
    }
#define LD(var, sym) \
    var = (__typeof__(var))dlsym(g_lib, sym); \
    if (!var) { logmsg("dlsym %s: %s", sym, dlerror()); return -1; }
    LD(sw_InitAll,  "SCI_WRAPPER_InitForAllProcess")
    LD(sw_ResetF,   "SCI_WRAPPER_ResetForced")
    LD(sw_WaitAct,  "SCI_WRAPPER_WaitForActivation")
    LD(sw_GetCkc,   "SCI_WRAPPER_GetCkc")
    LD(sw_SetData,  "SCI_WRAPPER_SetData")
    LD(sw_GetData,  "SCI_WRAPPER_GetData")
    LD(sw_GetAtr,   "SCI_WRAPPER_GetAtr")
#undef LD
    return 0;
}

static int do_get_ckc_locked(void) {
    int r = sw_GetCkc(g_a0_cmd, g_a0_resp, NULL);
    if (r == 0) g_have_ckc = 1;
    return r;
}

static int do_get_ckc(void) {
    pthread_mutex_lock(&g_chip_lock);
    int r = do_get_ckc_locked();
    pthread_mutex_unlock(&g_chip_lock);
    return r;
}

static int init_chip(void) {
    int r;

    /* Multi-process mode: enables the library's PIXELA_DeviceSharing
     * CAS/CKC locks so this proxy can coexist with other ACAS users. */
    r = sw_InitAll();
    if (r != 0) { logmsg("InitForAllProcess failed: %d", r); return -1; }

    r = sw_ResetF();
    if (r != 0) { logmsg("ResetForced failed: %d", r); return -1; }

    r = sw_WaitAct();
    if (r != 0) { logmsg("WaitForActivation failed: %d", r); return -1; }

    /* A0 once.  Clients get a0_cmd/a0_resp and derive KCL themselves. */
    for (int i = 0; i < 5; i++) {
        if (do_get_ckc() == 0) {
            logmsg("A0 auth OK (a0_cmd/a0_resp cached)");
            return 0;
        }
        logmsg("A0 auth failed (attempt %d/5)", i + 1);
        sleep(1);
    }
    logmsg("A0 auth failed; GET_CKC will keep failing");
    return 0; /* keep serving so clients see a clear status */
}

static void handle_apdu(int fd, const uint8_t *cmd, int cmd_len) {
    uint8_t resp[512];
    uint8_t dummy[4];
    int dummy_len = 0;
    int rlen = (int)sizeof(resp);
    int ok = 1;

    pthread_mutex_lock(&g_chip_lock);
    if (sw_SetData((uint8_t *)cmd, cmd_len, dummy, &dummy_len) != 0) ok = 0;
    if (ok && sw_GetData(resp, &rlen) != 0) ok = 0;
    if (!ok) rlen = 0;
    pthread_mutex_unlock(&g_chip_lock);

    uint8_t hdr[3];
    hdr[0] = ok ? 0 : 1;
    put_u16(hdr + 1, (uint16_t)rlen);
    if (write_full(fd, hdr, 3) < 0) return;
    if (rlen > 0) write_full(fd, resp, (size_t)rlen);
}

static void handle_ckc(int fd) {
    if (!g_have_ckc) {
        do_get_ckc();
    }
    if (!g_have_ckc) {
        uint8_t st = 1;
        write_full(fd, &st, 1);
        return;
    }
    uint8_t st = 0;
    uint8_t lenc[2], lenr[2];
    put_u16(lenc, (uint16_t)sizeof(g_a0_cmd));
    put_u16(lenr, (uint16_t)sizeof(g_a0_resp));
    write_full(fd, &st, 1);
    write_full(fd, lenc, 2);
    write_full(fd, g_a0_cmd, sizeof(g_a0_cmd));
    write_full(fd, lenr, 2);
    write_full(fd, g_a0_resp, sizeof(g_a0_resp));
}

static void handle_atr(int fd) {
    uint8_t atr[256];
    int len = (int)sizeof(atr);

    pthread_mutex_lock(&g_chip_lock);
    int ok = (sw_GetAtr(atr, &len) == 0);
    pthread_mutex_unlock(&g_chip_lock);

    uint8_t st = ok ? 0 : 1;
    uint8_t lb[2];
    if (!ok) len = 0;
    put_u16(lb, (uint16_t)len);
    write_full(fd, &st, 1);
    write_full(fd, lb, 2);
    if (len > 0) write_full(fd, atr, (size_t)len);
}

static void *client_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    uint8_t magic[4];

    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &(int){1}, sizeof(int));

    if (read_full(fd, magic, 4) < 0 || memcmp(magic, ACAS_REMOTE_MAGIC, 4) != 0) {
        close(fd);
        return NULL;
    }
    {
        uint8_t st = 0;
        if (write_full(fd, &st, 1) < 0) { close(fd); return NULL; }
    }
    logmsg("client connected");

    while (!g_stop) {
        uint8_t cmd;
        if (read_full(fd, &cmd, 1) < 0) break;

        if (cmd == ACAS_REMOTE_CMD_APDU) {
            uint8_t lb[2];
            if (read_full(fd, lb, 2) < 0) break;
            int len = (int)get_u16(lb);
            if (len < 0 || len > 512) break;
            uint8_t apdu[512];
            if (len > 0 && read_full(fd, apdu, (size_t)len) < 0) break;
            handle_apdu(fd, apdu, len);
        } else if (cmd == ACAS_REMOTE_CMD_GET_CKC) {
            handle_ckc(fd);
        } else if (cmd == ACAS_REMOTE_CMD_GET_ATR) {
            handle_atr(fd);
        } else if (cmd == ACAS_REMOTE_CMD_PING) {
            uint8_t st = 0;
            write_full(fd, &st, 1);
        } else {
            uint8_t st = 2;
            write_full(fd, &st, 1);
            break;
        }
    }

    logmsg("client disconnected");
    close(fd);
    return NULL;
}

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
    if (g_listen >= 0) close(g_listen);
}

static void usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s [-p port] [-v]\n\n"
        "  -p port   listen port (default %d)\n"
        "  -v        verbose\n\n"
        "Exposes the on-device ACAS chip (SCI APDU) over TCP for remote\n"
        "b61dec / b25dec.  Run as root; stop pix_airtuner first.\n",
        prog, ACAS_REMOTE_DEFAULT_PORT);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) {
            g_port = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-v") == 0) {
            g_verbose = 1;
        } else {
            usage(argv[0]);
            return 1;
        }
    }
    if (g_port <= 0 || g_port > 65535) {
        fprintf(stderr, "invalid port\n");
        return 1;
    }

    if (load_lib() < 0) return 1;
    if (init_chip() < 0) return 1;

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGPIPE, SIG_IGN);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { logmsg("socket: %s", strerror(errno)); return 1; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    sa.sin_port = htons((uint16_t)g_port);

    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        logmsg("bind(%d): %s", g_port, strerror(errno));
        close(fd);
        return 1;
    }
    if (listen(fd, 16) < 0) {
        logmsg("listen: %s", strerror(errno));
        close(fd);
        return 1;
    }
    g_listen = fd;

    logmsg("listening on 0.0.0.0:%d", g_port);

    while (!g_stop) {
        int cfd = accept(fd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            if (g_stop) break;
            logmsg("accept: %s", strerror(errno));
            continue;
        }
        pthread_t th;
        if (pthread_create(&th, NULL, client_thread, (void *)(intptr_t)cfd) != 0) {
            logmsg("pthread_create failed");
            close(cfd);
            continue;
        }
        pthread_detach(th);
    }

    logmsg("shutting down");
    if (g_lib) dlclose(g_lib);
    return 0;
}
