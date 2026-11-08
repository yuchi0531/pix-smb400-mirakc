#ifndef ACAS_REMOTE_H
#define ACAS_REMOTE_H

/*
 * acas_remote.h — client for the SMB400 ACAS APDU proxy.
 *
 * The proxy (src/acas_proxy.c) owns the on-device ACAS chip and exposes the
 * SCI APDU interface over TCP.  b61dec / b25dec can run on another host and
 * use this client instead of dlopen()ing libstationtv_lt_px_stream.so.
 *
 * Wire protocol (big-endian u16 lengths):
 *   handshake: "ACAS" | u8 token_len | token
 *              <- u8 status (0 = OK)
 *   APDU:      u8 0x01 | u16 len | data
 *              <- u8 status | u16 len | data
 *   GET_CKC:   u8 0x02
 *              <- u8 status | u16 clen | a0_cmd | u16 rlen | a0_resp
 *   GET_ATR:   u8 0x03
 *              <- u8 status | u16 len | atr
 *   PING:      u8 0x04
 *              <- u8 status
 */

#include <stdint.h>

#define ACAS_REMOTE_MAGIC     "ACAS"
#define ACAS_REMOTE_DEFAULT_PORT 40773

#define ACAS_REMOTE_CMD_APDU     0x01
#define ACAS_REMOTE_CMD_GET_CKC  0x02
#define ACAS_REMOTE_CMD_GET_ATR  0x03
#define ACAS_REMOTE_CMD_PING     0x04

/* Connect to "host[:port]" (port defaults to 40773).  token may be NULL/"".
 * Returns 0 on success, -1 on failure. */
int acas_remote_connect(const char *spec, const char *token);

/* Send one APDU and receive the chip response.  Returns 0 on success. */
int acas_remote_exchange(const uint8_t *cmd, int cmd_len,
                         uint8_t *resp, int resp_max, int *resp_len);

/* Fetch the A0 command/response pair produced by the proxy's GetCkc().
 * Buffers must be at least 64 bytes.  Returns 0 on success. */
int acas_remote_get_ckc(uint8_t *a0_cmd, int *a0_cmd_len,
                        uint8_t *a0_resp, int *a0_resp_len);

int acas_remote_get_atr(uint8_t *atr, int *atr_len);
int acas_remote_is_connected(void);
void acas_remote_close(void);

#endif
