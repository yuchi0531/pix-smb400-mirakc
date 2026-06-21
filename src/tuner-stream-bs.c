/*
 * tuner-stream-bs: Tune to a BS or BS4K channel and stream to stdout.
 *
 * Usage: tuner-stream-bs <tunerId> <mode> <freqKHz> <streamId>
 *
 *   tunerId:  0 or 1  (physical tuner)
 *   mode:     1 = ISDB-S  (regular BS, outputs MPEG-TS)
 *             2 = ISDB-S3 (BS 4K,      outputs TLV/MMTP)
 *   freqKHz:  IF centre frequency in kHz
 *             = satellite_GHz * 1e6 - 10678000  (LNB LO = 10.678 GHz)
 *             e.g. BS7  (11.84256 GHz) → 1164560
 *                  BS17 (12.03436 GHz) → 1356360
 *   streamId: 0 = auto-select first available TS/Stream ID
 *
 * Writes binary stream (MPEG-TS for mode=1, TLV for mode=2) to stdout.
 * Writes "LOCKED\n" to stderr when first data arrives from the tuner.
 * Exits on SIGTERM/SIGINT or when stdout is closed (broken pipe).
 * Restarts /system/bin/tunertest automatically at its ~2 GB internal limit.
 *
 * tunertest argument order (satellite):
 *   mode   file       limitSize   freqKHz   param    DeviceID  TunerNum  Lock
 *   <m>    <fifo>     2147483647  <freq>    <sid>    1         <t>       1
 *
 *   DeviceID 1 = PIX-SMB400
 *   Lock 1    = exclusive (prevents pix_airtuner conflicts)
 *
 * Build (Android ARM32): see Makefile target build-tuner-stream-bs
 */

#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>

extern int *__errno(void);
#undef  errno
#define errno (*__errno())
extern char *strerror(int errnum);

#define TS_SYNC 0x47u   /* MPEG-TS sync byte (ISDB-S mode=1) */

static volatile int g_running   = 1;
static pid_t        g_child_pid = -1;
static char         g_fifo_path[64];

static void on_signal(int sig)
{
    (void)sig;
    g_running = 0;
    if (g_child_pid > 0)
        kill(g_child_pid, SIGTERM);
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr,
            "usage: %s <tunerId> <mode> <freqKHz> <streamId>\n"
            "  tunerId:  0 or 1\n"
            "  mode:     1=ISDB-S (BS), 2=ISDB-S3 (BS4K)\n"
            "  freqKHz:  IF frequency in kHz (sat_GHz*1e6 - 10678000)\n"
            "  streamId: 0=auto\n",
            argv[0]);
        return 1;
    }

    int tunerId  = atoi(argv[1]);
    int mode     = atoi(argv[2]);
    int freqKHz  = atoi(argv[3]);
    int streamId = atoi(argv[4]);

    if (mode != 1 && mode != 2) {
        fprintf(stderr, "error: mode must be 1 (ISDB-S) or 2 (ISDB-S3), got %d\n", mode);
        return 1;
    }

    fprintf(stderr, "args: tunerId=%d mode=%d freq=%d streamId=%d\n",
            tunerId, mode, freqKHz, streamId);

    snprintf(g_fifo_path, sizeof(g_fifo_path),
             "/data/local/tmp/tuner_bs_%d.ts", tunerId);

    signal(SIGTERM, on_signal);
    signal(SIGINT,  on_signal);
    signal(SIGPIPE, on_signal);

    /*
     * Redirect our process stdout to /dev/null so tunertest's text output
     * (which it writes to stdout) does not pollute the TS/TLV stream we
     * forward on ts_fd.
     */
    int ts_fd = dup(STDOUT_FILENO);
    if (ts_fd < 0) {
        fprintf(stderr, "dup(stdout): %s\n", strerror(errno));
        return 1;
    }
    {
        int dn = open("/dev/null", O_WRONLY);
        if (dn < 0) {
            fprintf(stderr, "open /dev/null: %s\n", strerror(errno));
            return 1;
        }
        dup2(dn, STDOUT_FILENO);
        close(dn);
    }

    char mode_str[4], freq_str[16], stream_str[16], tuner_str[4], limit_str[16];
    snprintf(mode_str,   sizeof(mode_str),   "%d", mode);
    snprintf(freq_str,   sizeof(freq_str),   "%d", freqKHz);
    snprintf(stream_str, sizeof(stream_str), "%d", streamId);
    snprintf(tuner_str,  sizeof(tuner_str),  "%d", tunerId);
    /* INT32_MAX: tunertest runs ~18 min per invocation at BS bitrate before
     * hitting this limit; we restart it transparently. */
    snprintf(limit_str,  sizeof(limit_str),  "%d", 2147483647);

    char *tunertest_argv[] = {
        "/system/bin/tunertest",
        mode_str,      /* 1=ISDB-S(LNB=OFF), 2=ISDB-S3(LNB=OFF) */
        g_fifo_path,   /* output FIFO */
        limit_str,     /* ~2 GB limit before automatic exit */
        freq_str,      /* IF frequency in kHz */
        stream_str,    /* param: TS ID (ISDB-S) or Stream ID (ISDB-S3), 0=auto */
        "1",           /* DeviceID = PIX-SMB400 */
        tuner_str,     /* TunerNum */
        "1",           /* Lock = exclusive */
        NULL
    };

    int locked_reported = 0;

    while (g_running) {
        unlink(g_fifo_path);
        if (mkfifo(g_fifo_path, S_IRWXU) < 0) {
            fprintf(stderr, "mkfifo(%s): %s\n", g_fifo_path, strerror(errno));
            break;
        }

        g_child_pid = fork();
        if (g_child_pid == 0) {
            /*
             * Child: close the TS pipe fd and silence stderr so exec'd
             * tunertest leaves no live fds pointing at our output pipes.
             */
            close(ts_fd);
            {
                int dn = open("/dev/null", O_WRONLY);
                if (dn >= 0) {
                    dup2(dn, STDERR_FILENO);
                    close(dn);
                }
            }
            execv("/system/bin/tunertest", tunertest_argv);
            _exit(1);
        }
        if (g_child_pid < 0) {
            fprintf(stderr, "fork: %s\n", strerror(errno));
            break;
        }
        fprintf(stderr, "tunertest pid=%d mode=%d freq=%d\n",
                (int)g_child_pid, mode, freqKHz);

        /*
         * Open a dummy write-end first so that open(O_RDONLY) returns
         * immediately instead of blocking until tunertest opens the write end.
         * If tunertest exits without ever opening the FIFO, closing this dummy
         * fd causes subsequent read()s to return 0 (EOF) so we don't hang.
         */
        int dummy_wfd = open(g_fifo_path, O_WRONLY | O_NONBLOCK);
        int fifo_fd = open(g_fifo_path, O_RDONLY);
        if (dummy_wfd >= 0) close(dummy_wfd); /* hand off write-end to tunertest */
        if (fifo_fd < 0) {
            fprintf(stderr, "open fifo: %s\n", strerror(errno));
            kill(g_child_pid, SIGTERM);
            waitpid(g_child_pid, NULL, 0);
            g_child_pid = -1;
            break;
        }

        /* Buffer: 256 packets × 188 bytes, aligned for MPEG-TS and fine for TLV. */
        uint8_t buf[188 * 256];
        while (g_running) {
            ssize_t n = read(fifo_fd, buf, sizeof(buf));
            if (n <= 0)
                break;

            if (!locked_reported) {
                /*
                 * ISDB-S  (mode=1): MPEG-TS — scan for the 0x47 sync byte
                 *   anywhere in the first read (tunertest may not align to a
                 *   packet boundary when it opens the FIFO).
                 * ISDB-S3 (mode=2): TLV     — any data means lock is achieved.
                 */
                int locked = 0;
                if (mode == 2) {
                    locked = 1;
                } else {
                    ssize_t j;
                    for (j = 0; j < n; j++) {
                        if (buf[j] == TS_SYNC) { locked = 1; break; }
                    }
                }
                if (locked) {
                    fprintf(stderr, "LOCKED\n");
                    locked_reported = 1;
                }
            }

            const uint8_t *p = buf;
            ssize_t rem = n;
            while (rem > 0 && g_running) {
                ssize_t w = write(ts_fd, p, (size_t)rem);
                if (w < 0) {
                    g_running = 0;
                    break;
                }
                p   += w;
                rem -= w;
            }
        }
        close(fifo_fd);

        int status = 0;
        waitpid(g_child_pid, &status, 0);
        g_child_pid = -1;

        if (!g_running)
            break;

        if (WIFEXITED(status))
            fprintf(stderr, "tunertest exited (code=%d), restarting...\n",
                    WEXITSTATUS(status));
        else if (WIFSIGNALED(status))
            fprintf(stderr, "tunertest killed signal=%d, restarting...\n",
                    WTERMSIG(status));
        else
            fprintf(stderr, "tunertest exited (status=%d), restarting...\n", status);

        usleep(300000); /* 300 ms re-lock wait */
    }

    unlink(g_fifo_path);
    close(ts_fd);
    return 0;
}
