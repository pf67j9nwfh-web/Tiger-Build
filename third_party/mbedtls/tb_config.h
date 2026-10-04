/* Tiger Build's changes to mbedTLS's default configuration, for gcc 4.0/4.2 on Mac OS X 10.4 to 10.6. */
#undef MBEDTLS_AESNI_C        /* needs compiler intrinsics gcc 4.x lacks; no Intel Mac of this era has AES-NI */
#undef MBEDTLS_PADLOCK_C
#if defined(__ppc64__)
#undef MBEDTLS_HAVE_ASM
#define MBEDTLS_HAVE_INT32    /* 64-bit limbs need __udivti3, which Darwin's libgcc does not have */
#endif
