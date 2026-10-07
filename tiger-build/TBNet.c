#include "TBNet.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>
#include <signal.h>
#include <stdarg.h>
#include "psa/crypto.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/error.h"

static mbedtls_x509_crt roots;
static int rootsLoaded = 0;
static pthread_mutex_t setupLock = PTHREAD_MUTEX_INITIALIZER;
static int psaReady = 0;
static pthread_key_t versionKey;
static pthread_once_t versionOnce = PTHREAD_ONCE_INIT;

static void makeVersionKey(void)
{
    pthread_key_create(&versionKey, free);
}

typedef struct {
    int fd;
    volatile int *cancel;
    int idle;           /* seconds */
    int failure;        /* a TBNET_ERR_ code when the I/O callbacks gave up */
} Link;

static double now(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1000000.0;
}

static void say(char *text, size_t size, const char *format, ...)
{
    va_list args;
    if (!text || size == 0)
        return;
    va_start(args, format);
    vsnprintf(text, size, format, args);
    va_end(args);
}

int tbnet_set_roots(const unsigned char *pem, size_t length)
{
    unsigned char *copy;
    int result;
    signal(SIGPIPE, SIG_IGN);
    pthread_mutex_lock(&setupLock);
    if (rootsLoaded) {
        pthread_mutex_unlock(&setupLock);
        return 0;
    }
    mbedtls_x509_crt_init(&roots);
    copy = malloc(length + 1);
    if (!copy) {
        pthread_mutex_unlock(&setupLock);
        return -1;
    }
    memcpy(copy, pem, length);
    copy[length] = 0;
    result = mbedtls_x509_crt_parse(&roots, copy, length + 1);
    free(copy);
    if (result < 0 && roots.version == 0) {
        pthread_mutex_unlock(&setupLock);
        return -1;
    }
    rootsLoaded = 1;
    pthread_mutex_unlock(&setupLock);
    return result > 0 ? result : 0;
}

/* ---- sockets ---- */

static int waitFor(int fd, int writing, double deadline, volatile int *cancel)
{
    for (;;) {
        fd_set set;
        struct timeval slice;
        double left = deadline - now();
        int r;
        if (cancel && *cancel)
            return TBNET_ERR_CANCELLED;
        if (left <= 0)
            return TBNET_ERR_TIMEOUT;
        slice.tv_sec = 0;
        slice.tv_usec = left > 0.2 ? 200000 : (int)(left * 1000000) + 1000;
        FD_ZERO(&set);
        FD_SET(fd, &set);
        r = select(fd + 1, writing ? NULL : &set, writing ? &set : NULL, NULL, &slice);
        if (r > 0)
            return 0;
        if (r < 0 && errno != EINTR)
            return TBNET_ERR_IO;
    }
}

/* Whether a socket address is on the public internet: not loopback, private, link-local, carrier-grade NAT, multicast or unspecified. */
static int publicAddress(const struct sockaddr *address)
{
    if (address->sa_family == AF_INET) {
        const unsigned char *b = (const unsigned char *)&((const struct sockaddr_in *)address)->sin_addr;
        return !(b[0] == 10 || b[0] == 127 || b[0] == 0 || b[0] >= 224 || (b[0] == 169 && b[1] == 254) || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127));
    }
    if (address->sa_family == AF_INET6) {
        const unsigned char *b = ((const struct sockaddr_in6 *)address)->sin6_addr.s6_addr;
        int zeros = 1, i;
        for (i = 0; i < 15; i++)
            if (b[i])
                zeros = 0;
        if ((zeros && (b[15] == 0 || b[15] == 1)) || (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || b[0] == 0xff)
            return 0;
        if (b[10] == 0xff && b[11] == 0xff && !b[0] && !b[1] && !b[2] && !b[3] && !b[4] && !b[5] && !b[6] && !b[7] && !b[8] && !b[9])
            return !(b[12] == 10 || b[12] == 127 || b[12] == 0 || b[12] >= 224 || (b[12] == 192 && b[13] == 168) || (b[12] == 172 && b[13] >= 16 && b[13] <= 31) || (b[12] == 169 && b[13] == 254) || (b[12] == 100 && b[13] >= 64 && b[13] <= 127));
        return 1;
    }
    return 0;
}

static int dial(const char *host, const char *port, int timeout, volatile int *cancel, int publicOnly, char *errorText, size_t errorSize)
{
    struct addrinfo hints, *list = NULL, *a;
    int pass, fd = -1, rc;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    rc = getaddrinfo(host, port, &hints, &list);
    if (rc != 0 || !list) {
        say(errorText, errorSize, "Cannot find %s (%s).", host, gai_strerror(rc));
        return TBNET_ERR_DNS;
    }
    /* IPv4 first: a network with no IPv6 route leaves the first IPv6 attempt hanging. */
    for (pass = 0; pass < 2 && fd < 0; pass++) {
        for (a = list; a && fd < 0; a = a->ai_next) {
            int s, flags, wait;
            if ((pass == 0) != (a->ai_family == AF_INET))
                continue;
            if (publicOnly && !publicAddress(a->ai_addr))
                continue;
            s = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
            if (s < 0)
                continue;
            flags = fcntl(s, F_GETFL, 0);
            fcntl(s, F_SETFL, flags | O_NONBLOCK);
            {
                int on = 1;
                setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
#ifdef SO_NOSIGPIPE
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
            }
            if (connect(s, a->ai_addr, a->ai_addrlen) != 0 && errno != EINPROGRESS) {
                close(s);
                continue;
            }
            wait = waitFor(s, 1, now() + (pass == 0 ? timeout : timeout) / 2.0 + 1, cancel);
            if (wait == TBNET_ERR_CANCELLED) {
                close(s);
                freeaddrinfo(list);
                return TBNET_ERR_CANCELLED;
            }
            if (wait == 0) {
                int soerr = 0;
                socklen_t len = sizeof(soerr);
                getsockopt(s, SOL_SOCKET, SO_ERROR, &soerr, &len);
                if (soerr == 0) {
                    fd = s;
                    break;
                }
            }
            close(s);
        }
    }
    freeaddrinfo(list);
    if (fd < 0) {
        say(errorText, errorSize, publicOnly ? "Cannot connect to %s (only public web addresses are allowed here)." : "Cannot connect to %s.", host);
        return TBNET_ERR_CONNECT;
    }
    return fd;
}

/* ---- the connection: plain, or TLS over the same socket ---- */

typedef struct {
    Link link;
    int tls;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
} Conn;

static int ioSend(void *ctx, const unsigned char *buf, size_t len)
{
    Link *link = (Link *)ctx;
    for (;;) {
        ssize_t n = send(link->fd, buf, len, 0);
        int w;
        if (n >= 0)
            return (int)n;
        if (errno == EINTR)
            continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            link->failure = TBNET_ERR_IO;
            return MBEDTLS_ERR_NET_SEND_FAILED;
        }
        w = waitFor(link->fd, 1, now() + link->idle, link->cancel);
        if (w) {
            link->failure = w;
            return MBEDTLS_ERR_NET_SEND_FAILED;
        }
    }
}

static int ioRecv(void *ctx, unsigned char *buf, size_t len)
{
    Link *link = (Link *)ctx;
    for (;;) {
        ssize_t n = recv(link->fd, buf, len, 0);
        int w;
        if (n >= 0)
            return (int)n;
        if (errno == EINTR)
            continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            link->failure = TBNET_ERR_IO;
            return MBEDTLS_ERR_NET_RECV_FAILED;
        }
        w = waitFor(link->fd, 0, now() + link->idle, link->cancel);
        if (w) {
            link->failure = w;
            return MBEDTLS_ERR_NET_RECV_FAILED;
        }
    }
}

static int connWrite(Conn *c, const unsigned char *data, size_t length)
{
    size_t done = 0;
    while (done < length) {
        int n = c->tls ? mbedtls_ssl_write(&c->ssl, data + done, length - done) : ioSend(&c->link, data + done, length - done);
        if (n <= 0) {
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE)
                continue;
            return c->link.failure ? c->link.failure : TBNET_ERR_IO;
        }
        done += n;
    }
    return 0;
}

/* Returns the byte count, 0 at the end of the stream, or a negative TBNET_ERR_ code. */
static int connRead(Conn *c, unsigned char *buf, size_t size)
{
    for (;;) {
        int n = c->tls ? mbedtls_ssl_read(&c->ssl, buf, size) : ioRecv(&c->link, buf, size);
        if (n > 0)
            return n;
        if (n == 0 || n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)
            return 0;
        if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE || n == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET)
            continue;
        if (c->link.failure)
            return c->link.failure;
        return TBNET_ERR_IO;
    }
}

static void connClose(Conn *c)
{
    if (c->tls) {
        mbedtls_ssl_free(&c->ssl);
        mbedtls_ssl_config_free(&c->conf);
        mbedtls_ctr_drbg_free(&c->drbg);
        mbedtls_entropy_free(&c->entropy);
    }
    if (c->link.fd >= 0)
        close(c->link.fd);
}

/* ---- URL ---- */

typedef struct {
    int https;
    char host[256];
    char port[8];
    char path[2048];
} Url;

static int parseUrl(const char *url, Url *out)
{
    const char *p = url, *hostStart, *hostEnd, *slash;
    if (strncasecmp(p, "https://", 8) == 0) {
        out->https = 1;
        p += 8;
    } else if (strncasecmp(p, "http://", 7) == 0) {
        out->https = 0;
        p += 7;
    } else {
        return -1;
    }
    hostStart = p;
    slash = strpbrk(p, "/?");
    hostEnd = slash ? slash : p + strlen(p);
    if (hostStart < hostEnd && *hostStart == '[') {
        const char *close = memchr(hostStart, ']', hostEnd - hostStart);
        if (!close)
            return -1;
        snprintf(out->host, sizeof(out->host), "%.*s", (int)(close - hostStart - 1), hostStart + 1);
        p = close + 1;
        snprintf(out->port, sizeof(out->port), "%s", (p < hostEnd && *p == ':') ? p + 1 : out->https ? "443" : "80");
        if (p < hostEnd && *p == ':')
            snprintf(out->port, sizeof(out->port), "%.*s", (int)(hostEnd - p - 1), p + 1);
    } else {
        const char *colon = memchr(hostStart, ':', hostEnd - hostStart);
        snprintf(out->host, sizeof(out->host), "%.*s", (int)((colon ? colon : hostEnd) - hostStart), hostStart);
        if (colon)
            snprintf(out->port, sizeof(out->port), "%.*s", (int)(hostEnd - colon - 1), colon + 1);
        else
            snprintf(out->port, sizeof(out->port), "%s", out->https ? "443" : "80");
    }
    if (slash && *slash == '?')
        snprintf(out->path, sizeof(out->path), "/%s", slash);
    else
        snprintf(out->path, sizeof(out->path), "%s", slash ? slash : "/");
    return out->host[0] ? 0 : -1;
}

/* ---- the request ---- */

static const char *tlsVersionName(Conn *c)
{
    return c->tls ? mbedtls_ssl_get_version(&c->ssl) : "none";
}

const char *tbnet_last_tls_version(void)
{
    const char *value;
    pthread_once(&versionOnce, makeVersionKey);
    value = pthread_getspecific(versionKey);
    return value ? value : "";
}

static void rememberVersion(const char *name)
{
    char *copy = strdup(name);
    char *old;
    pthread_once(&versionOnce, makeVersionKey);
    old = pthread_getspecific(versionKey);
    free(old);
    pthread_setspecific(versionKey, copy);
}

static int startTls(Conn *c, const char *host, char *errorText, size_t errorSize)
{
    int ret;
    pthread_mutex_lock(&setupLock);
    if (!psaReady) {
        psaReady = psa_crypto_init() == PSA_SUCCESS ? 1 : -1;
    }
    pthread_mutex_unlock(&setupLock);
    if (psaReady != 1 || !rootsLoaded) {
        say(errorText, errorSize, "The secure connection library is not ready.");
        return TBNET_ERR_TLS;
    }
    mbedtls_ssl_init(&c->ssl);
    mbedtls_ssl_config_init(&c->conf);
    mbedtls_entropy_init(&c->entropy);
    mbedtls_ctr_drbg_init(&c->drbg);
    c->tls = 1;
    ret = mbedtls_ctr_drbg_seed(&c->drbg, mbedtls_entropy_func, &c->entropy, (const unsigned char *)"TigerBuild", 10);
    if (ret == 0)
        ret = mbedtls_ssl_config_defaults(&c->conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) {
        say(errorText, errorSize, "The secure connection could not be set up (-0x%04x).", -ret);
        return TBNET_ERR_TLS;
    }
    mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
    mbedtls_ssl_conf_ca_chain(&c->conf, &roots, NULL);
    mbedtls_ssl_conf_rng(&c->conf, mbedtls_ctr_drbg_random, &c->drbg);
    if (mbedtls_ssl_setup(&c->ssl, &c->conf) != 0 || mbedtls_ssl_set_hostname(&c->ssl, host) != 0) {
        say(errorText, errorSize, "The secure connection could not be set up.");
        return TBNET_ERR_TLS;
    }
    mbedtls_ssl_set_bio(&c->ssl, &c->link, ioSend, ioRecv, NULL);
    while ((ret = mbedtls_ssl_handshake(&c->ssl)) != 0) {
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE)
            continue;
        if (c->link.failure == TBNET_ERR_CANCELLED)
            return TBNET_ERR_CANCELLED;
        if (c->link.failure == TBNET_ERR_TIMEOUT) {
            say(errorText, errorSize, "The secure handshake with %s timed out.", host);
            return TBNET_ERR_TIMEOUT;
        }
        if (ret == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED) {
            char why[200];
            mbedtls_x509_crt_verify_info(why, sizeof(why), "", mbedtls_ssl_get_verify_result(&c->ssl));
            while (strlen(why) > 0 && (why[strlen(why) - 1] == '\n' || why[strlen(why) - 1] == ' '))
                why[strlen(why) - 1] = 0;
            say(errorText, errorSize, "The certificate of %s was not accepted: %s. Check this Mac's date and time.", host, why);
            return TBNET_ERR_CERT;
        }
        {
            char why[160];
            mbedtls_strerror(ret, why, sizeof(why));
            say(errorText, errorSize, "The secure handshake with %s failed: %s.", host, why);
        }
        return TBNET_ERR_TLS;
    }
    rememberVersion(tlsVersionName(c));
    return 0;
}

/* memmem() arrived in Mac OS X 10.7. */
static unsigned char *findBlankLine(unsigned char *buf, size_t length)
{
    size_t i;
    for (i = 0; i + 4 <= length; i++) {
        if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n')
            return buf + i;
    }
    return NULL;
}

/* Reads until "\r\n\r\n". Anything past it stays in buf. */
static int readHeaders(Conn *c, unsigned char *buf, size_t size, size_t *used, size_t *headerEnd)
{
    *used = 0;
    for (;;) {
        unsigned char *found;
        int n;
        if (*used >= 4 && (found = findBlankLine(buf, *used))) {
            *headerEnd = (size_t)(found - buf) + 4;
            return 0;
        }
        if (*used >= size - 1)
            return TBNET_ERR_PROTOCOL;
        n = connRead(c, buf + *used, size - 1 - *used);
        if (n < 0)
            return n;
        if (n == 0)
            return TBNET_ERR_PROTOCOL;
        *used += n;
    }
}

static int headerValue(const char *headers, const char *name, char *out, size_t size)
{
    size_t nameLength = strlen(name);
    const char *p = headers;
    while (*p) {
        const char *eol = strstr(p, "\r\n");
        size_t lineLength = eol ? (size_t)(eol - p) : strlen(p);
        if (lineLength > nameLength && p[nameLength] == ':' && strncasecmp(p, name, nameLength) == 0) {
            const char *v = p + nameLength + 1;
            while (*v == ' ' || *v == '\t')
                v++;
            snprintf(out, size, "%.*s", (int)(lineLength - (v - p)), v);
            return 1;
        }
        if (!eol)
            break;
        p = eol + 2;
    }
    return 0;
}

int tbnet_perform(const TBNetRequest *req, char *errorText, size_t errorSize)
{
    Url url;
    Conn c;
    int fd, rc = 0, status = 0;
    int idle = req->idleTimeout > 0 ? req->idleTimeout : 120;
    int connectTimeout = req->connectTimeout > 0 ? req->connectTimeout : 15;
    char *head;
    size_t headSize, headLength;
    unsigned char buf[16384];
    size_t used = 0, headerEnd = 0;
    char value[256];
    int chunked = 0, haveLength = 0;
    long long remaining = 0;
    const char *const *h;
    rememberVersion("none");
    memset(&c, 0, sizeof(c));
    c.link.fd = -1;
    c.link.cancel = req->cancel;
    c.link.idle = idle;
    if (errorText && errorSize)
        errorText[0] = 0;
    if (parseUrl(req->url, &url) != 0) {
        say(errorText, errorSize, "Not a web address: %s", req->url);
        return TBNET_ERR_URL;
    }
    fd = dial(url.host, url.port, connectTimeout, req->cancel, req->publicOnly, errorText, errorSize);
    if (fd < 0)
        return fd;
    c.link.fd = fd;
    if (url.https && (rc = startTls(&c, url.host, errorText, errorSize)) != 0) {
        connClose(&c);
        return rc;
    }
    headSize = 1024 + strlen(url.path) + strlen(url.host);
    for (h = req->headers; h && *h; h++)
        headSize += strlen(*h) + 2;
    head = malloc(headSize);
    headLength = snprintf(head, headSize, "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\nAccept-Encoding: identity\r\n", req->method ? req->method : "GET", url.path, url.host);
    for (h = req->headers; h && *h; h++)
        headLength += snprintf(head + headLength, headSize - headLength, "%s\r\n", *h);
    if (req->body || (req->method && strcmp(req->method, "POST") == 0))
        headLength += snprintf(head + headLength, headSize - headLength, "Content-Length: %lu\r\n", (unsigned long)req->bodyLength);
    headLength += snprintf(head + headLength, headSize - headLength, "\r\n");
    rc = connWrite(&c, (unsigned char *)head, headLength);
    free(head);
    if (rc == 0 && req->body && req->bodyLength)
        rc = connWrite(&c, req->body, req->bodyLength);
    if (rc != 0) {
        say(errorText, errorSize, rc == TBNET_ERR_CANCELLED ? "Cancelled." : rc == TBNET_ERR_TIMEOUT ? "The server stopped answering." : "The request could not be sent.");
        connClose(&c);
        return rc;
    }
    for (;;) {
        rc = readHeaders(&c, buf, sizeof(buf), &used, &headerEnd);
        if (rc != 0)
            break;
        status = atoi((const char *)buf + 9);
        if (status == 100 && strncmp((const char *)buf, "HTTP/1.1 100", 12) == 0) {
            memmove(buf, buf + headerEnd, used - headerEnd);
            used -= headerEnd;
            continue;
        }
        break;
    }
    if (rc != 0) {
        say(errorText, errorSize, rc == TBNET_ERR_CANCELLED ? "Cancelled." : rc == TBNET_ERR_TIMEOUT ? "The server stopped answering." : "The server's answer was not understood.");
        connClose(&c);
        return rc;
    }
    buf[headerEnd - 2] = 0;
    if (req->onHeaders)
        req->onHeaders(req->context, status, (const char *)buf);
    if (headerValue((const char *)buf, "Transfer-Encoding", value, sizeof(value)) && strcasestr(value, "chunked"))
        chunked = 1;
    else if (headerValue((const char *)buf, "Content-Length", value, sizeof(value))) {
        haveLength = 1;
        remaining = atoll(value);
    }
    if (status == 204 || status == 304 || (req->method && strcmp(req->method, "HEAD") == 0)) {
        haveLength = 1;
        remaining = 0;
        chunked = 0;
    }
    memmove(buf, buf + headerEnd, used - headerEnd);
    used -= headerEnd;
    if (chunked) {
        /* chunk-size line, data, CRLF; a size of 0 ends the body. */
        long long left = 0;
        int state = 0;   /* 0: reading a size line, 1: data, 2: the CRLF after data, 3: trailers */
        char sizeLine[40];
        size_t sizeUsed = 0;
        for (;;) {
            size_t i = 0;
            if (used == 0) {
                int n = connRead(&c, buf, sizeof(buf));
                if (n < 0) {
                    rc = n;
                    break;
                }
                if (n == 0) {
                    rc = state == 3 ? 0 : TBNET_ERR_PROTOCOL;
                    break;
                }
                used = n;
            }
            while (i < used) {
                if (state == 1) {
                    size_t take = used - i < (size_t)left ? used - i : (size_t)left;
                    if (req->onBody && req->onBody(req->context, buf + i, take)) {
                        rc = TBNET_ERR_CANCELLED;
                        goto finished;
                    }
                    i += take;
                    left -= take;
                    if (left == 0)
                        state = 2;
                } else {
                    unsigned char ch = buf[i++];
                    if (state == 2) {
                        if (ch == '\n')
                            state = 0;
                    } else if (state == 3) {
                        if (ch == '\n' && sizeUsed == 0) {
                            rc = 0;
                            goto finished;
                        }
                        if (ch == '\n')
                            sizeUsed = 0;
                        else if (ch != '\r')
                            sizeUsed = 1;
                    } else if (ch == '\n') {
                        sizeLine[sizeUsed] = 0;
                        left = strtoll(sizeLine, NULL, 16);
                        sizeUsed = 0;
                        state = left > 0 ? 1 : 3;
                    } else if (ch != '\r' && sizeUsed < sizeof(sizeLine) - 1) {
                        sizeLine[sizeUsed++] = (char)ch;
                    }
                }
            }
            used = 0;
        }
    } else {
        for (;;) {
            if (used > 0) {
                size_t take = used;
                if (haveLength && (long long)take > remaining)
                    take = (size_t)remaining;
                if (take && req->onBody && req->onBody(req->context, buf, take)) {
                    rc = TBNET_ERR_CANCELLED;
                    break;
                }
                if (haveLength) {
                    remaining -= take;
                    if (remaining <= 0)
                        break;
                }
                used = 0;
            }
            {
                int n = connRead(&c, buf, sizeof(buf));
                if (n < 0) {
                    rc = n;
                    break;
                }
                if (n == 0) {
                    if (haveLength && remaining > 0)
                        rc = TBNET_ERR_PROTOCOL;
                    break;
                }
                used = n;
            }
        }
    }
finished:
    if (rc == TBNET_ERR_CANCELLED)
        say(errorText, errorSize, "Cancelled.");
    else if (rc == TBNET_ERR_TIMEOUT)
        say(errorText, errorSize, "The server stopped answering.");
    else if (rc == TBNET_ERR_PROTOCOL)
        say(errorText, errorSize, "The connection ended before the answer was complete.");
    else if (rc != 0)
        say(errorText, errorSize, "The connection to %s was lost.", url.host);
    connClose(&c);
    return rc;
}
