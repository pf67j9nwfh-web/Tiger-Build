/* P-256 key exchange and signatures, and bulk ciphers: the work in one TLS 1.2 handshake and its traffic. */
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include "mbedtls/ecp.h"
#include "mbedtls/ecdh.h"
#include "mbedtls/ecdsa.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/gcm.h"
#include "mbedtls/chachapoly.h"

static double now(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

int main(void)
{
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_ecp_group grp;
    mbedtls_mpi d, z;
    mbedtls_ecp_point Q;
    mbedtls_ecdsa_context ctx;
    unsigned char hash[32], sig[MBEDTLS_ECDSA_MAX_LEN], key[32], iv[12], tag[16];
    static unsigned char data[16384], out[16384];
    size_t siglen = 0;
    double t;
    int i, n = 20;
    memset(hash, 7, 32); memset(key, 1, 32); memset(iv, 2, 12);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&drbg);
    mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy, (const unsigned char *)"b", 1);
    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d); mbedtls_mpi_init(&z);
    mbedtls_ecp_point_init(&Q);
    mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    t = now();
    for (i = 0; i < n; i++)
        mbedtls_ecdh_gen_public(&grp, &d, &Q, mbedtls_ctr_drbg_random, &drbg);
    printf("P-256 ECDH key generation:   %6.1f ms each\n", (now() - t) / n);
    t = now();
    for (i = 0; i < n; i++)
        mbedtls_ecdh_compute_shared(&grp, &z, &Q, &d, mbedtls_ctr_drbg_random, &drbg);
    printf("P-256 ECDH shared secret:    %6.1f ms each\n", (now() - t) / n);
    mbedtls_ecdsa_init(&ctx);
    mbedtls_ecdsa_genkey(&ctx, MBEDTLS_ECP_DP_SECP256R1, mbedtls_ctr_drbg_random, &drbg);
    t = now();
    for (i = 0; i < n; i++)
        mbedtls_ecdsa_write_signature(&ctx, MBEDTLS_MD_SHA256, hash, 32, sig, &siglen, mbedtls_ctr_drbg_random, &drbg);
    printf("P-256 ECDSA sign:            %6.1f ms each\n", (now() - t) / n);
    t = now();
    for (i = 0; i < n; i++)
        mbedtls_ecdsa_read_signature(&ctx, hash, 32, sig, siglen);
    printf("P-256 ECDSA verify:          %6.1f ms each\n", (now() - t) / n);
    {
        mbedtls_gcm_context gcm;
        mbedtls_chachapoly_context cp;
        mbedtls_gcm_init(&gcm);
        mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, 128);
        t = now();
        for (i = 0; i < 200; i++)
            mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_DECRYPT, sizeof(data), iv, 12, NULL, 0, data, out, 16, tag);
        printf("AES-128-GCM decrypt:         %6.1f MB/s\n", 200.0 * sizeof(data) / 1048576.0 / ((now() - t) / 1000.0));
        mbedtls_chachapoly_init(&cp);
        mbedtls_chachapoly_setkey(&cp, key);
        t = now();
        for (i = 0; i < 200; i++)
            mbedtls_chachapoly_encrypt_and_tag(&cp, sizeof(data), iv, NULL, 0, data, out, tag);
        printf("ChaCha20-Poly1305:           %6.1f MB/s\n", 200.0 * sizeof(data) / 1048576.0 / ((now() - t) / 1000.0));
    }
    return 0;
}
