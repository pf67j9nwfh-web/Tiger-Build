/* Spike: TLS 1.3 (falling back to 1.2) to the AI providers with mbedTLS 3.6, timing each step,
   then a second connection that resumes the first one's session. */
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include "psa/crypto.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/error.h"

static double now(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

static int dial(const char *host)
{
    struct addrinfo hints, *res = NULL;
    int fd;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, "443", &hints, &res) != 0 || !res)
        return -1;
    fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0 || connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);
    return fd;
}

int main(int argc, char **argv)
{
    static const char *hosts[] = {"api.anthropic.com", "api.openai.com", "generativelanguage.googleapis.com", "api.x.ai", "api.mistral.ai", NULL};
    const char *cafile = argc > 1 ? argv[1] : "cacert.pem";
    int force12 = argc > 2 && strcmp(argv[2], "tls12") == 0;
    mbedtls_x509_crt cacert;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_ssl_session saved[8];
    int have_session[8];
    double t0;
    int ret, h, pass;
    psa_status_t status = psa_crypto_init();
    printf("psa_crypto_init: %d\n", (int)status);
    mbedtls_x509_crt_init(&cacert);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&drbg);
    mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy, (const unsigned char *)"tlstest", 7);
    t0 = now();
    ret = mbedtls_x509_crt_parse_file(&cacert, cafile);
    printf("parse CA bundle: %d, %.0f ms\n", ret, now() - t0);
    memset(have_session, 0, sizeof(have_session));
    for (h = 0; hosts[h]; h++)
        mbedtls_ssl_session_init(&saved[h]);
    for (pass = 0; pass < 2; pass++) {
        printf("--- connection %s\n", pass ? "2 (resuming)" : "1 (full handshake)");
        for (h = 0; hosts[h]; h++) {
            mbedtls_net_context net;
            mbedtls_ssl_context ssl;
            mbedtls_ssl_config conf;
            char line[256];
            unsigned char buf[2048];
            double tc, th, tf, te;
            unsigned total = 0;
            uint32_t flags;
            int fd;
            mbedtls_net_init(&net);
            mbedtls_ssl_init(&ssl);
            mbedtls_ssl_config_init(&conf);
            tc = now();
            fd = dial(hosts[h]);
            if (fd < 0) {
                printf("%-36s connect failed\n", hosts[h]);
                goto done;
            }
            net.fd = fd;
            mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
            if (force12)
                mbedtls_ssl_conf_max_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_2);
            mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_REQUIRED);
            mbedtls_ssl_conf_ca_chain(&conf, &cacert, NULL);
            mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);
            mbedtls_ssl_setup(&ssl, &conf);
            mbedtls_ssl_set_hostname(&ssl, hosts[h]);
            mbedtls_ssl_set_bio(&ssl, &net, mbedtls_net_send, mbedtls_net_recv, NULL);
            if (pass && have_session[h])
                mbedtls_ssl_set_session(&ssl, &saved[h]);
            th = now();
            while ((ret = mbedtls_ssl_handshake(&ssl)) != 0) {
                if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
                    mbedtls_strerror(ret, line, sizeof(line));
                    printf("%-36s handshake failed: -0x%04x %s\n", hosts[h], -ret, line);
                    goto done;
                }
            }
            tf = now();
            flags = mbedtls_ssl_get_verify_result(&ssl);
            snprintf(line, sizeof(line), "GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\nUser-Agent: tlstest\r\n\r\n", hosts[h]);
            mbedtls_ssl_write(&ssl, (const unsigned char *)line, strlen(line));
            memset(buf, 0, sizeof(buf));
            while ((ret = mbedtls_ssl_read(&ssl, buf + total, sizeof(buf) - 1 - total)) > 0 && total < sizeof(buf) - 1)
                total += ret;
            te = now();
            if (!pass && mbedtls_ssl_get_session(&ssl, &saved[h]) == 0)
                have_session[h] = 1;
            if (strchr((char *)buf, '\r'))
                *strchr((char *)buf, '\r') = 0;
            printf("%-34s %s %-38s connect %3.0f ms, handshake %4.0f ms, answer %3.0f ms, cert flags %u%s [%s]\n", hosts[h],
                mbedtls_ssl_get_version(&ssl), mbedtls_ssl_get_ciphersuite(&ssl), th - tc, tf - th, te - tf, (unsigned)flags,
                (pass && have_session[h]) ? "" : "", (char *)buf);
done:
            mbedtls_ssl_free(&ssl);
            mbedtls_ssl_config_free(&conf);
            mbedtls_net_free(&net);
        }
    }
    return 0;
}
