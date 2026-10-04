# mbedTLS for Tiger Build 2.0

TLS 1.3 (and 1.2) for Mac OS X 10.4 to 10.6, which only have TLS 1.0 of their own. mbedTLS 3.6.7 (Apache-2.0).

    ./fetch.sh        # on a current Mac: download, check the SHA-256, apply old-macs.patch
    ./build-mac.sh    # on Snow Leopard with Xcode 3.2: build/libmbedtls32.a, 64x86.a, 64ppc.a

`old-macs.patch` makes three changes:
- `mbedtls_ms_time()` uses `mach_absolute_time()` before 10.12, which has no `clock_gettime()`.
- 32-bit Intel uses the C constant-time code; gcc 4.0 and 4.2 cannot allocate registers for the assembly in position-independent code.
- 64-bit Intel's empty asm clobber lists get `"cc"`, which gcc 4.2 requires.

`tb_config.h` turns off AES-NI (no compiler support, and no Intel Mac of this era has it) and, for `ppc64`, uses 32-bit limbs
without assembly because Darwin's libgcc has no `__udivti3`.

Read the CA bundle into memory and parse it with `mbedtls_x509_crt_parse`: it takes about 20 ms, while `mbedtls_x509_crt_parse_file`
took 0.6 to 25 seconds on the old Macs. Resolve IPv4 first and set a connect timeout. See `spikes/tls/tlstest13.c`.
