# ppc-commander for Mac OS X 10.4 through 10.6 (ppc, i386, and 64-bit where the 10.5 SDK exists), or any Mac with `make host`.
SDK32 ?= /Developer/SDKs/MacOSX10.4u.sdk
SDK64 ?= /Developer/SDKs/MacOSX10.5.sdk
SDKX86 ?= $(if $(wildcard /Developer/SDKs/MacOSX10.6.sdk),/Developer/SDKs/MacOSX10.6.sdk,$(SDK64))
CC32 ?= $(if $(wildcard /usr/bin/gcc-4.0),gcc-4.0,gcc)
CC64 ?= $(if $(wildcard /usr/bin/gcc-4.2),gcc-4.2,gcc)
ARCHS64 ?= $(if $(wildcard $(SDK64)),ppc64 x86_64,)
SRC := CMCore.m CMFiles.m CMProcess.m CMVcs.m CMServer.m ../tiger-build/TBJSON.m
HDR := CMCore.h ../tiger-build/TBJSON.h ../tiger-build/TBCompat.h
FLAGS := -Wall -Wno-deprecated-declarations -O2 -fobjc-exceptions -I. -I../tiger-build -framework Foundation

ppc-commander: $(SRC) $(HDR)
	mkdir -p build
	$(CC32) -arch ppc -arch i386 -isysroot $(SDK32) -mmacosx-version-min=10.4 $(FLAGS) -o build/c32 $(SRC)
	$(if $(findstring ppc64,$(ARCHS64)),$(CC64) -arch ppc64 -isysroot $(SDK64) -mmacosx-version-min=10.5 $(FLAGS) -o build/cp64 $(SRC))
	$(if $(findstring x86_64,$(ARCHS64)),$(CC64) -arch x86_64 -isysroot $(SDKX86) -mmacosx-version-min=10.5 $(FLAGS) -o build/cx64 $(SRC))
	lipo -create build/c32 $$(ls build/cp64 build/cx64 2>/dev/null) -output ppc-commander
	rm -rf build

host: $(SRC) $(HDR)
	clang -Wno-deprecated-declarations -O1 -g -fobjc-exceptions -I. -I../tiger-build -framework Foundation -o ppc-commander-host $(SRC)

clean:
	rm -rf build ppc-commander ppc-commander-host
