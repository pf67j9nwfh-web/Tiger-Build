#ifndef TBNET_H
#define TBNET_H

#include <stddef.h>

/* A small blocking HTTP and HTTPS client for the old Macs, whose own TLS stops at 1.0. TLS 1.3 and 1.2 come from mbedTLS.
   Call it on a worker thread. The response is handed over as it arrives, so a model's reply can be shown while it is written. */

#define TBNET_OK 0
#define TBNET_ERR_URL -1
#define TBNET_ERR_DNS -2
#define TBNET_ERR_CONNECT -3
#define TBNET_ERR_TLS -4
#define TBNET_ERR_CERT -5
#define TBNET_ERR_TIMEOUT -6
#define TBNET_ERR_CANCELLED -7
#define TBNET_ERR_PROTOCOL -8
#define TBNET_ERR_IO -9

typedef struct {
    const char *method;                 /* "GET", "POST" ... */
    const char *url;                    /* http:// or https:// */
    const char *const *headers;         /* NULL-terminated "Name: value" lines; Host, Content-Length and Connection are added */
    const unsigned char *body;
    size_t bodyLength;
    int connectTimeout;                 /* seconds, 0 for 15 */
    int idleTimeout;                    /* seconds without a byte either way, 0 for 120 */
    volatile int *cancel;               /* set to non-zero from another thread to stop */
    void *context;
    /* Called once, with the status code and the raw header lines. */
    void (*onHeaders)(void *context, int status, const char *headerText);
    /* Called for each piece of the body, already unchunked. Return non-zero to stop. */
    int (*onBody)(void *context, const unsigned char *data, size_t length);
    int publicOnly;                     /* non-zero: connect only to public internet addresses (checked on the address actually used) */
} TBNetRequest;

/* The trusted root certificates, as the PEM text of the bundle. Call once, before the first request. Returns the number of
   certificates that could not be read (0 is good), or -1 if nothing could be loaded. */
int tbnet_set_roots(const unsigned char *pem, size_t length);

/* Runs the request. Returns TBNET_OK when the whole response arrived (any HTTP status), or a negative TBNET_ERR_ code,
   with a sentence in errorText. */
int tbnet_perform(const TBNetRequest *request, char *errorText, size_t errorSize);

/* The TLS version of the last handshake on this thread's last request, such as "TLSv1.3", for tests and the About box. */
const char *tbnet_last_tls_version(void);

#endif
