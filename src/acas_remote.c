/*
 * acas_remote.c — TCP client for the SMB400 ACAS APDU proxy.
 *
 * See acas_remote.h for the wire protocol.  No Android-specific code here:
 * the same object is linked into the device binaries (local mode) and into
 * the remote decoder binaries (Linux/Windows).
 */

#define _GNU_SOURCE
#include "acas_remote.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#if defined(ACAS_ANDROID)
extern int *__errno(void);
#undef errno
#define errno (*__errno())
extern char *strerror(int errnum);
#endif
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>

static int g_sock = -1;
static char g_last_error[160];

static const char *last_error(void) {
    return g_last_error[0] ? g_last_error : "unknown error";
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
        if (n == 0) return -1; /* EOF */
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static uint16_t get_u16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static void put_u16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)(v & 0xff);
}

int acas_remote_connect(const char *spec) {
    char host[128];
    int port = ACAS_REMOTE_DEFAULT_PORT;
    const char *colon;

    acas_remote_close();
    g_last_error[0] = '\0';

    if (!spec || !*spec) {
        snprintf(g_last_error, sizeof(g_last_error), "empty host spec");
        return -1;
    }

    colon = strrchr(spec, ':');
    if (colon && colon[1]) {
        size_t hlen = (size_t)(colon - spec);
        if (hlen >= sizeof(host)) hlen = sizeof(host) - 1;
        memcpy(host, spec, hlen);
        host[hlen] = '\0';
        port = atoi(colon + 1);
    } else {
        snprintf(host, sizeof(host), "%s", spec);
    }
    if (port <= 0 || port > 65535) {
        snprintf(g_last_error, sizeof(g_last_error), "invalid port");
        return -1;
    }

#if defined(ACAS_ANDROID)
    /* The Android binaries are compiled with glibc headers but linked against
     * bionic libc.  bionic's getaddrinfo() does not return a compatible
     * struct addrinfo (ai_addr comes back NULL), so connect() fails with
     * EFAULT.  Build the sockaddr directly from the numeric IPv4 address
     * instead.  Remote decoders on Linux/Windows still use getaddrinfo()
     * below, so host names keep working there. */
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &sin.sin_addr) != 1) {
        snprintf(g_last_error, sizeof(g_last_error),
                 "invalid IPv4 address '%s'", host);
        return -1;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        snprintf(g_last_error, sizeof(g_last_error), "socket: %s", strerror(errno));
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&sin, sizeof(sin)) < 0) {
        snprintf(g_last_error, sizeof(g_last_error), "connect(%s:%d): %s",
                 host, port, strerror(errno));
        close(fd);
        return -1;
    }
#else
    struct addrinfo hints;
    struct addrinfo *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);

    int rc = getaddrinfo(host, portstr, &hints, &res);
    if (rc != 0 || !res) {
        snprintf(g_last_error, sizeof(g_last_error), "getaddrinfo(%s): %s",
                 host, gai_strerror(rc));
        return -1;
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        snprintf(g_last_error, sizeof(g_last_error), "socket: %s", strerror(errno));
        freeaddrinfo(res);
        return -1;
    }

    if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
        snprintf(g_last_error, sizeof(g_last_error), "connect(%s:%d): %s",
                 host, port, strerror(errno));
        close(fd);
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);
#endif

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    if (write_full(fd, ACAS_REMOTE_MAGIC, 4) < 0) {
        snprintf(g_last_error, sizeof(g_last_error), "handshake write failed");
        close(fd);
        return -1;
    }

    uint8_t status = 0xff;
    if (read_full(fd, &status, 1) < 0) {
        snprintf(g_last_error, sizeof(g_last_error), "handshake read failed");
        close(fd);
        return -1;
    }
    if (status != 0) {
        snprintf(g_last_error, sizeof(g_last_error), "auth rejected (status=%u)", status);
        close(fd);
        return -1;
    }

    g_sock = fd;
    return 0;
}

int acas_remote_is_connected(void) {
    return g_sock >= 0;
}

void acas_remote_close(void) {
    if (g_sock >= 0) {
        close(g_sock);
        g_sock = -1;
    }
}

int acas_remote_exchange(const uint8_t *cmd, int cmd_len,
                         uint8_t *resp, int resp_max, int *resp_len) {
    if (g_sock < 0) return -1;
    if (cmd_len < 0 || cmd_len > 65535) return -1;

    uint8_t hdr[3];
    hdr[0] = ACAS_REMOTE_CMD_APDU;
    put_u16(hdr + 1, (uint16_t)cmd_len);
    if (write_full(g_sock, hdr, 3) < 0 ||
        (cmd_len && write_full(g_sock, cmd, (size_t)cmd_len) < 0)) {
        snprintf(g_last_error, sizeof(g_last_error), "APDU write: %s", strerror(errno));
        return -1;
    }

    uint8_t status = 0xff;
    uint8_t lenbuf[2];
    if (read_full(g_sock, &status, 1) < 0) return -1;
    if (status != 0) {
        snprintf(g_last_error, sizeof(g_last_error), "proxy APDU status=%u", status);
        return -1;
    }
    if (read_full(g_sock, lenbuf, 2) < 0) return -1;
    uint16_t len = get_u16(lenbuf);
    if ((int)len > resp_max) {
        /* Drain the payload so the connection stays in sync. */
        uint8_t tmp[256];
        uint16_t left = len;
        while (left > 0) {
            size_t take = left > sizeof(tmp) ? sizeof(tmp) : left;
            if (read_full(g_sock, tmp, take) < 0) return -1;
            left = (uint16_t)(left - take);
        }
        snprintf(g_last_error, sizeof(g_last_error), "response too large (%u)", len);
        return -1;
    }
    if (len && read_full(g_sock, resp, len) < 0) return -1;
    if (resp_len) *resp_len = (int)len;
    return 0;
}

int acas_remote_get_ckc(uint8_t *a0_cmd, int *a0_cmd_len,
                        uint8_t *a0_resp, int *a0_resp_len) {
    if (g_sock < 0) return -1;
    uint8_t cmd = ACAS_REMOTE_CMD_GET_CKC;
    if (write_full(g_sock, &cmd, 1) < 0) return -1;

    uint8_t status = 0xff;
    if (read_full(g_sock, &status, 1) < 0) return -1;
    if (status != 0) {
        snprintf(g_last_error, sizeof(g_last_error), "proxy GET_CKC status=%u", status);
        return -1;
    }

    uint8_t lenbuf[2];
    if (read_full(g_sock, lenbuf, 2) < 0) return -1;
    uint16_t clen = get_u16(lenbuf);
    if (clen > 64) return -1;
    if (clen && read_full(g_sock, a0_cmd, clen) < 0) return -1;

    if (read_full(g_sock, lenbuf, 2) < 0) return -1;
    uint16_t rlen = get_u16(lenbuf);
    if (rlen > 64) return -1;
    if (rlen && read_full(g_sock, a0_resp, rlen) < 0) return -1;

    if (a0_cmd_len) *a0_cmd_len = (int)clen;
    if (a0_resp_len) *a0_resp_len = (int)rlen;
    return 0;
}

int acas_remote_get_atr(uint8_t *atr, int *atr_len) {
    if (g_sock < 0) return -1;
    uint8_t cmd = ACAS_REMOTE_CMD_GET_ATR;
    if (write_full(g_sock, &cmd, 1) < 0) return -1;

    uint8_t status = 0xff;
    if (read_full(g_sock, &status, 1) < 0) return -1;
    if (status != 0) return -1;

    uint8_t lenbuf[2];
    if (read_full(g_sock, lenbuf, 2) < 0) return -1;
    uint16_t len = get_u16(lenbuf);
    if (len > 256) return -1;
    if (len && read_full(g_sock, atr, len) < 0) return -1;
    if (atr_len) *atr_len = (int)len;
    return 0;
}
