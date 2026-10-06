# TLS 1.2 on Tiger, Leopard and Snow Leopard (spike)

Tests whether a bundled mbedTLS can talk to the AI providers from the old Macs.

    curl -LO https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-2.28.10/mbedtls-2.28.10.tar.bz2
    curl -LO https://curl.se/ca/cacert.pem
    tar xjf mbedtls-2.28.10.tar.bz2
    ./build.sh -std=gnu99        # gcc 4.0 needs -std=gnu99; builds tlstest, benchmark
    ./relink2.sh -std=gnu99      # builds ecbench
    ./tlstest cacert.pem         # TLS 1.2 handshake to five providers, certificates verified
    ./ecbench                    # P-256 and bulk cipher speed

Resolve IPv4 first: on a network without IPv6 the first address from DNS hangs until it times out.
For Leopard, which has no compiler, build on Snow Leopard with `-arch i386 -mmacosx-version-min=10.5 -isysroot /Developer/SDKs/MacOSX10.5.sdk`.
