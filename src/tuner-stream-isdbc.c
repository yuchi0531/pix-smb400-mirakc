/*
 * tuner-stream-isdbc: ISDB-C (ITU-T J.83 Annex C) TS streamer for PIX-SMB400.
 *
 * The SMB400's front-end is a Sony CXD2857 demodulator (+ CXD2868 tuner).
 * The OEM tuner SDK (tunertest_oem) only exposes ISDB-T / ISDB-S / ISDB-S3.
 * This binary therefore:
 *
 *   1. lets tunertest_oem initialise the board and tune the RF to the
 *      requested cable channel in ISDB-T 6 MHz mode (AGC/filter settle),
 *   2. kills tunertest_oem (the demod/I2C state is preserved in hardware),
 *   3. reconfigures the CXD2857 to DVB-C 6 MHz (ISDB-C / J.83C, 5.274 Mbaud)
 *      over I2C, and enables the TS output,
 *   4. streams the raw (C-CAS scrambled) TS from the HiSilicon DMX.
 *
 * C-CAS descrambling is intentionally NOT implemented: the output is the
 * raw MPEG-TS as transmitted on the cable.
 *
 * I2C addressing (confirmed on hardware):
 *   bus 2, SLV-T 0xD8 (8-bit) / SLV-X 0xDC (8-bit), chip ID 0x091 (CXD2857).
 *
 * Usage: tuner-stream-isdbc <tunerId> <freqKHz> <bwMHz>
 *        tunerId: 0 (SMB400 has a single full-NIM front-end)
 *        bwMHz:   6 (ISDB-C) or 8 (DVB-C 8 MHz; diagnostic)
 *
 * Build: see Makefile target build-bins
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <dlfcn.h>
#include <sys/types.h>
#include <sys/wait.h>

extern int *__errno(void);
#undef  errno
#define errno (*__errno())
extern char *strerror(int errnum);

typedef int          HI_S32;
typedef unsigned int HI_U32;
typedef unsigned char HI_U8;
typedef void        *HI_HANDLE;

#define HI_SUCCESS      0
#define HI_FALSE        0

#define DMX_ID          0
#define TS_PORT_ID      32
#define REC_BUF_SIZE    (1024 * 1024)

/* The OEM tuner needs ~12 s for AGC/settling before the QAM demod can lock. */
#define SETTLE_MS       12000
#define POST_KILL_MS    500
#define LOCK_WAIT_MS    8000

#define I2C_BUS         2
#define SLVT            0xD8u   /* 8-bit I2C address of SLV-T */
#define SLVX            0xDCu   /* 8-bit I2C address of SLV-X */

/*===== Globals =====*/
static volatile int g_running = 1;
static pid_t g_tuner_pid = -1;

static void on_signal(int sig)
{
    (void)sig;
    g_running = 0;
    if (g_tuner_pid > 0) {
        kill(g_tuner_pid, SIGKILL);
        g_tuner_pid = -1;
    }
}

/*===== libhi_msp: DMX + I2C =====*/
static void *g_lib_msp = NULL;

typedef HI_S32 (*PFN_DMX_Init)(void);
typedef HI_S32 (*PFN_DMX_DeInit)(void);
typedef HI_S32 (*PFN_DMX_AttachTSPort)(HI_U32, HI_U32);
typedef HI_S32 (*PFN_DMX_DetachTSPort)(HI_U32);
typedef HI_S32 (*PFN_DMX_CreateRecChn)(void *, HI_HANDLE *);
typedef HI_S32 (*PFN_DMX_DestroyRecChn)(HI_HANDLE);
typedef HI_S32 (*PFN_DMX_StartRecChn)(HI_HANDLE);
typedef HI_S32 (*PFN_DMX_StopRecChn)(HI_HANDLE);
typedef HI_S32 (*PFN_DMX_AcquireRecData)(HI_HANDLE, void *, HI_U32);
typedef HI_S32 (*PFN_DMX_ReleaseRecData)(HI_HANDLE, const void *);
typedef HI_S32 (*PFN_I2C_Init)(HI_U32);
typedef HI_S32 (*PFN_I2C_SetRateEx)(HI_U32, HI_U32);
typedef HI_S32 (*PFN_I2C_Write)(HI_U32, HI_U32, HI_U32, HI_U32, HI_U8 *, HI_U32);
typedef HI_S32 (*PFN_I2C_Read)(HI_U32, HI_U32, HI_U32, HI_U32, HI_U8 *, HI_U32);

typedef struct {
    HI_U8  *pDataAddr;
    HI_U32  u32DataPhyAddr;
    HI_U32  u32Len;
} HI_UNF_DMX_REC_DATA_S;

typedef struct {
    HI_U32 u32DmxId;
    HI_U32 u32RecBufSize;
    HI_U32 enRecType;
    HI_U32 bDescramed;
    HI_U32 enIndexType;
    HI_U32 u32IndexSrcPid;
    HI_U32 enTsPacketType;
} HI_UNF_DMX_REC_ATTR_S;

static PFN_DMX_Init          g_DMX_Init;
static PFN_DMX_DeInit        g_DMX_DeInit;
static PFN_DMX_AttachTSPort  g_DMX_AttachTSPort;
static PFN_DMX_DetachTSPort  g_DMX_DetachTSPort;
static PFN_DMX_CreateRecChn  g_DMX_CreateRecChn;
static PFN_DMX_DestroyRecChn g_DMX_DestroyRecChn;
static PFN_DMX_StartRecChn   g_DMX_StartRecChn;
static PFN_DMX_StopRecChn    g_DMX_StopRecChn;
static PFN_DMX_AcquireRecData g_DMX_AcquireRecData;
static PFN_DMX_ReleaseRecData g_DMX_ReleaseRecData;
static PFN_I2C_Init          g_I2C_Init;
static PFN_I2C_SetRateEx     g_I2C_SetRateEx;
static PFN_I2C_Write         g_I2C_Write;
static PFN_I2C_Read          g_I2C_Read;

static int load_libraries(void)
{
    g_lib_msp = dlopen("libhi_msp.so", RTLD_NOW);
    if (!g_lib_msp) {
        fprintf(stderr, "dlopen(libhi_msp.so): %s\n", dlerror());
        return -1;
    }
    g_DMX_Init           = dlsym(g_lib_msp, "HI_UNF_DMX_Init");
    g_DMX_DeInit         = dlsym(g_lib_msp, "HI_UNF_DMX_DeInit");
    g_DMX_AttachTSPort   = dlsym(g_lib_msp, "HI_UNF_DMX_AttachTSPort");
    g_DMX_DetachTSPort   = dlsym(g_lib_msp, "HI_UNF_DMX_DetachTSPort");
    g_DMX_CreateRecChn   = dlsym(g_lib_msp, "HI_UNF_DMX_CreateRecChn");
    g_DMX_DestroyRecChn  = dlsym(g_lib_msp, "HI_UNF_DMX_DestroyRecChn");
    g_DMX_StartRecChn    = dlsym(g_lib_msp, "HI_UNF_DMX_StartRecChn");
    g_DMX_StopRecChn     = dlsym(g_lib_msp, "HI_UNF_DMX_StopRecChn");
    g_DMX_AcquireRecData = dlsym(g_lib_msp, "HI_UNF_DMX_AcquireRecData");
    g_DMX_ReleaseRecData = dlsym(g_lib_msp, "HI_UNF_DMX_ReleaseRecData");
    g_I2C_Init           = dlsym(g_lib_msp, "HI_UNF_I2C_Init");
    g_I2C_SetRateEx      = dlsym(g_lib_msp, "HI_UNF_I2C_SetRateEx");
    g_I2C_Write          = dlsym(g_lib_msp, "HI_UNF_I2C_Write");
    g_I2C_Read           = dlsym(g_lib_msp, "HI_UNF_I2C_Read");

    if (!g_DMX_Init || !g_DMX_AttachTSPort || !g_DMX_CreateRecChn ||
        !g_DMX_StartRecChn || !g_DMX_AcquireRecData || !g_DMX_ReleaseRecData ||
        !g_I2C_Init || !g_I2C_Write || !g_I2C_Read) {
        fprintf(stderr, "Failed to resolve libhi_msp functions\n");
        return -1;
    }
    return 0;
}

/*===== I2C helpers (CXD2857) =====*/
static int iwr(HI_U32 addr, HI_U32 reg, HI_U8 data)
{
    HI_U8 b = data;
    return g_I2C_Write(I2C_BUS, addr, reg, 1, &b, 1) == 0 ? 0 : -1;
}

static int iwrm(HI_U32 addr, HI_U32 reg, const HI_U8 *buf, int n)
{
    return g_I2C_Write(I2C_BUS, addr, reg, 1, (HI_U8 *)buf, (HI_U32)n) == 0 ? 0 : -1;
}

static int ird(HI_U32 addr, HI_U32 reg, HI_U8 *out, int n)
{
    return g_I2C_Read(I2C_BUS, addr, reg, 1, out, (HI_U32)n) == 0 ? 0 : -1;
}

static int setbits(HI_U32 addr, HI_U32 reg, HI_U8 data, HI_U8 mask)
{
    HI_U8 v = 0;
    if (mask == 0) return 0;
    if (mask != 0xff) {
        if (ird(addr, reg, &v, 1) != 0) return -1;
        data = (HI_U8)((data & mask) | (v & (mask ^ 0xff)));
    }
    return iwr(addr, reg, data);
}

#define B(addr, bank) iwr((addr), 0x00, (bank))
#define W(addr, reg, data) iwr((addr), (reg), (data))
#define WM(addr, reg, buf, n) iwrm((addr), (reg), (buf), (n))

/* Cancel the ISDB-T demod parameters (Sony SDK "sleep" for ISDB-T). */
static void isdbt_cancel(void)
{
    static const HI_U8 d38[2] = { 0x01, 0x02 };
    B(SLVT, 0x00); setbits(SLVT, 0x80, 0x1F, 0x1F);
    B(SLVT, 0x10);
    W(SLVT, 0x69, 0x05); W(SLVT, 0x6B, 0x07); W(SLVT, 0x9D, 0x14);
    W(SLVT, 0xD3, 0x00); W(SLVT, 0xED, 0x01); W(SLVT, 0xE2, 0x4E);
    W(SLVT, 0xF2, 0x03); W(SLVT, 0xDE, 0x32);
    B(SLVT, 0x15); W(SLVT, 0xDE, 0x03);
    B(SLVT, 0x17); WM(SLVT, 0x38, d38, 2);
    B(SLVT, 0x1E); W(SLVT, 0x73, 0x00);
    B(SLVT, 0x63); W(SLVT, 0x81, 0x01);
}

/* DVB-C band setting (6 MHz = ISDB-C, 8 MHz = diagnostic). */
static void dvbc_band(int bw)
{
    static const HI_U8 itb6[14] = { 0x31,0xA8,0x29,0x9B,0x27,0x9C,0x28,0x9E,0x29,0xA4,0x29,0xA2,0x29,0xA8 };
    static const HI_U8 itb8[14] = { 0x29,0x9A,0x28,0x9E,0x2F,0xB9,0x27,0xA5,0x28,0xA9,0x2B,0xB0,0x08,0xD6 };
    static const HI_U8 sym6[4]  = { 0x07,0x33,0x00,0xEE };
    static const HI_U8 sym8[4]  = { 0x09,0x9A,0x00,0xEE };
    double iff = (bw == 8) ? 4.9 : 3.7;
    HI_U32 v = (HI_U32)((iff / 48.0) * 16777216.0 + 0.5);
    HI_U8 d[3];

    d[0] = (HI_U8)((v >> 16) & 0xff);
    d[1] = (HI_U8)((v >>  8) & 0xff);
    d[2] = (HI_U8)( v        & 0xff);

    B(SLVT, 0x10); WM(SLVT, 0xA6, (bw == 8) ? itb8 : itb6, 14); WM(SLVT, 0xB6, d, 3);
    B(SLVT, 0x11); W(SLVT, 0xA3, (bw == 8) ? 0x00 : 0x14);
    B(SLVT, 0x40); WM(SLVT, 0x26, (bw == 8) ? sym8 : sym6, 4);
}

/* Sony SDK "SLtoAC": switch the shared demod core to DVB-C (ISDB-C/J.83C). */
static void dvbc_init(int bw)
{
    static const HI_U8 d33[3] = { 0x00, 0x03, 0x3B };
    static const HI_U8 dce[2] = { 0x01, 0x01 };

    W(SLVX, 0x00, 0x00);
    W(SLVX, 0x17, 0x04);
    B(SLVT, 0x00);
    W(SLVT, 0xA9, 0x00);
    W(SLVT, 0x2C, 0x01);
    W(SLVT, 0x4B, 0x74);
    W(SLVT, 0x49, 0x00);
    W(SLVX, 0x18, 0x00);
    B(SLVT, 0x11); W(SLVT, 0x6A, 0x48);
    B(SLVT, 0x10); W(SLVT, 0xA5, 0x01);
    B(SLVT, 0x11); WM(SLVT, 0x33, d33, 3);
    B(SLVT, 0x48); W(SLVT, 0x2C, 0x03);
    B(SLVT, 0x00); WM(SLVT, 0xCE, dce, 2);
    dvbc_band(bw);
    B(SLVT, 0x00);
    setbits(SLVT, 0x80, 0x08, 0x1F);
}

/* Enable the TS output (Sony SDK "tuneEnd" + setstreamoutput). */
static void dvbc_tune_end(void)
{
    HI_U8 a9 = 0;
    B(SLVT, 0x00);
    W(SLVT, 0xFE, 0x01);
    if (ird(SLVT, 0xA9, &a9, 1) == 0 && (a9 & 0x03) == 0x00) {
        B(SLVT, 0x00);
        W(SLVT, 0xC3, 0x00);   /* TS output: 0 = enable */
    }
}

static int dvbc_status(int *sync, int *unlock, int *tslock)
{
    HI_U8 d = 0;
    B(SLVT, 0x40);
    if (ird(SLVT, 0x88, &d, 1) != 0) return -1;
    *sync   = (d & 0x01) ? 1 : 0;
    *unlock = (d & 0x02) ? 1 : 0;
    if (ird(SLVT, 0x10, &d, 1) != 0) return -1;
    *tslock = (d & 0x20) ? 1 : 0;
    return 0;
}

/*===== DMX =====*/
static HI_S32 dmx_setup(HI_U32 dmx_id, HI_U32 port_id, HI_HANDLE *phRecChn)
{
    HI_S32 ret;
    HI_UNF_DMX_REC_ATTR_S attr;

    ret = g_DMX_Init();
    fprintf(stderr, "DMX_Init: ret=0x%x\n", ret);

    ret = g_DMX_AttachTSPort(dmx_id, port_id);
    fprintf(stderr, "DMX_AttachTSPort(dmx=%u, port=%u): ret=0x%x\n",
            dmx_id, port_id, ret);
    if (ret != HI_SUCCESS) return ret;

    memset(&attr, 0, sizeof(attr));
    attr.u32DmxId       = dmx_id;
    attr.u32RecBufSize  = REC_BUF_SIZE;
    attr.enRecType      = 1;
    attr.bDescramed     = HI_FALSE;
    attr.enTsPacketType = 0;

    ret = g_DMX_CreateRecChn(&attr, phRecChn);
    fprintf(stderr, "DMX_CreateRecChn: ret=0x%x handle=%p\n", ret, (void *)*phRecChn);
    if (ret != HI_SUCCESS) return ret;

    ret = g_DMX_StartRecChn(*phRecChn);
    fprintf(stderr, "DMX_StartRecChn: ret=0x%x\n", ret);
    return ret;
}

static void dmx_deinit(HI_HANDLE hRecChn, HI_U32 dmx_id)
{
    if (g_DMX_StopRecChn)    g_DMX_StopRecChn(hRecChn);
    if (g_DMX_DestroyRecChn) g_DMX_DestroyRecChn(hRecChn);
    if (g_DMX_DetachTSPort)  g_DMX_DetachTSPort(dmx_id);
    if (g_DMX_DeInit)        g_DMX_DeInit();
}

static void dmx_stream(HI_HANDLE hRecChn, int ts_fd)
{
    HI_UNF_DMX_REC_DATA_S data;
    int locked = 0;
    int nloops = 0, nerrors = 0;

    fprintf(stderr, "TS capture started\n");
    while (g_running) {
        nloops++;
        memset(&data, 0, sizeof(data));
        if (g_DMX_AcquireRecData(hRecChn, &data, 1000) != HI_SUCCESS) {
            nerrors++;
            if (g_running) usleep(10000);
            continue;
        }
        if (data.u32Len == 0 || !data.pDataAddr) {
            g_DMX_ReleaseRecData(hRecChn, &data);
            continue;
        }
        if (!locked) {
            fprintf(stderr, "TS data flowing (%u bytes)\n", data.u32Len);
            locked = 1;
        }
        const HI_U8 *p = data.pDataAddr;
        HI_U32 rem = data.u32Len;
        while (rem > 0 && g_running) {
            ssize_t w = write(ts_fd, p, (size_t)rem);
            if (w < 0) {
                fprintf(stderr, "write(ts_fd): errno=%d\n", errno);
                g_running = 0;
                break;
            }
            p += w; rem -= (HI_U32)w;
        }
        g_DMX_ReleaseRecData(hRecChn, &data);
    }
    fprintf(stderr, "TS capture stopped: %d loops, %d errors\n", nloops, nerrors);
}

/*===== OEM RF init =====*/
static pid_t start_tunertest_oem(int tuner_id, int freq_khz)
{
    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "fork: %s\n", strerror(errno));
        return -1;
    }
    if (pid == 0) {
        int dn = open("/dev/null", O_RDWR);
        if (dn >= 0) {
            dup2(dn, STDIN_FILENO);
            dup2(dn, STDOUT_FILENO);
            dup2(dn, STDERR_FILENO);
            close(dn);
        }
        { int fd; for (fd = 3; fd < 1024; fd++) close(fd); }

        char tuner_str[8], freq_str[16];
        snprintf(tuner_str, sizeof(tuner_str), "%d", tuner_id);
        snprintf(freq_str,  sizeof(freq_str),  "%d", freq_khz);

        execl("/vendor/bin/tunertest_oem", "tunertest_oem",
              tuner_str,
              "/dev/null",
              "2147483647",
              freq_str,
              "6",
              "1", "0", "1",
              NULL);
        _exit(1);
    }
    return pid;
}

static void wait_ms(int ms)
{
    int i;
    for (i = 0; i < ms && g_running; i += 50) usleep(50 * 1000);
}

/*===== Main =====*/
int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s <tunerId> <freqKHz> <bwMHz>\n", argv[0]);
        return 1;
    }

    int tuner_id = atoi(argv[1]);
    int freq_khz = atoi(argv[2]);
    int bw_mhz   = atoi(argv[3]);
    if (bw_mhz != 6 && bw_mhz != 8) {
        fprintf(stderr, "bwMHz must be 6 or 8\n");
        return 1;
    }

    fprintf(stderr, "tuner-stream-isdbc: tuner=%d freq=%d kHz bw=%d MHz\n",
            tuner_id, freq_khz, bw_mhz);

    signal(SIGTERM, on_signal);
    signal(SIGINT,  on_signal);
    signal(SIGPIPE, on_signal);
    signal(SIGCHLD, SIG_IGN);

    int ts_fd = dup(STDOUT_FILENO);
    if (ts_fd < 0) {
        fprintf(stderr, "dup(stdout): %s\n", strerror(errno));
        return 1;
    }
    {
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, STDOUT_FILENO); close(dn); }
    }

    if (load_libraries() != 0) return 1;

    /* 1. OEM ISDB-T init + RF tune (CXD2868) */
    fprintf(stderr, "OEM init: tunertest_oem freq=%d kHz\n", freq_khz);
    g_tuner_pid = start_tunertest_oem(tuner_id, freq_khz);
    if (g_tuner_pid < 0) return 1;
    wait_ms(SETTLE_MS);
    if (g_tuner_pid > 0) { kill(g_tuner_pid, SIGKILL); g_tuner_pid = -1; }
    usleep(POST_KILL_MS * 1000);
    if (!g_running) { close(ts_fd); return 0; }

    /* 2. DMX capture */
    HI_HANDLE hRecChn = NULL;
    if (dmx_setup(DMX_ID, TS_PORT_ID, &hRecChn) != HI_SUCCESS) {
        fprintf(stderr, "DMX setup failed\n");
        close(ts_fd);
        return 1;
    }

    /* 3. Switch CXD2857 to DVB-C / ISDB-C */
    fprintf(stderr, "I2C: CXD2857 -> ISDB-C (J.83C, %d MHz)\n", bw_mhz);
    if (g_I2C_Init(0) != 0) fprintf(stderr, "I2C_Init failed\n");
    if (g_I2C_SetRateEx) g_I2C_SetRateEx(I2C_BUS, 5);

    isdbt_cancel();
    dvbc_init(bw_mhz);
    dvbc_tune_end();

    {
        int elapsed = 0, sync = 0, unlock = 0, tslock = 0;
        while (elapsed < LOCK_WAIT_MS && g_running) {
            if (dvbc_status(&sync, &unlock, &tslock) == 0) {
                if (elapsed % 1000 == 0)
                    fprintf(stderr, "ISDB-C status: sync=%d unlock=%d tslock=%d\n",
                            sync, unlock, tslock);
                if (sync && !unlock && tslock) {
                    fprintf(stderr, "ISDB-C LOCKED\n");
                    break;
                }
            }
            usleep(200 * 1000);
            elapsed += 200;
        }
        if (elapsed >= LOCK_WAIT_MS)
            fprintf(stderr, "WARNING: ISDB-C lock timeout\n");
    }

    /* 4. Stream raw (C-CAS scrambled) TS */
    dmx_stream(hRecChn, ts_fd);

    fprintf(stderr, "Cleaning up...\n");
    dmx_deinit(hRecChn, DMX_ID);
    close(ts_fd);
    dlclose(g_lib_msp);
    fprintf(stderr, "tuner-stream-isdbc: exit\n");
    return 0;
}
