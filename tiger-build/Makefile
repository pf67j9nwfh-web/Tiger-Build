# Build Tiger Build for Mac OS X 10.4 through 10.6, PowerPC and Intel,
# 32-bit and 64-bit, with Xcode 2.5 (Tiger), 3.1 (Leopard) or 3.2 (Snow Leopard).
#   make        build TigerBuild.app
#   make test   build and run the unit checks (no window needed)
#
# The 32-bit program (ppc, i386) is built against the 10.4 SDK and runs on every
# system from Tiger on. Where the 10.5 SDK is installed (Leopard or later with
# Xcode 3.x), a 64-bit program (ppc64, x86_64) is built against it and joined to
# the first with lipo, so one app runs 64-bit on G5 and Intel Macs that can and
# 32-bit everywhere else. A G5 on Tiger has no 64-bit Cocoa, so it runs the
# 32-bit slice. Set ARCHS32 / ARCHS64 to change the choice (ARCHS64= for none).
SDK32 ?= /Developer/SDKs/MacOSX10.4u.sdk
SDK64 ?= /Developer/SDKs/MacOSX10.5.sdk
# 64-bit Intel QuickTime (QTKit) exists from 10.6, so x86_64 uses the 10.6 SDK when it is installed.
SDKX86 ?= $(if $(wildcard /Developer/SDKs/MacOSX10.6.sdk),/Developer/SDKs/MacOSX10.6.sdk,$(SDK64))
ARCHS32 ?= ppc i386
ifeq ($(wildcard $(SDK64)),)
ARCHS64 ?=
else
ARCHS64 ?= ppc64 x86_64
endif
# The 10.4 SDK needs gcc 4.0; on Xcode 3.2 that is installed next to gcc 4.2.
CC32 ?= $(if $(wildcard /usr/bin/gcc-4.0),gcc-4.0,gcc)
CC64 ?= $(if $(wildcard /usr/bin/gcc-4.2),gcc-4.2,gcc)
# TLS 1.3 and 1.2 from mbedTLS (third_party/mbedtls), which the old systems lack.
TLS := ../third_party/mbedtls
TLSFLAGS := -std=gnu99 -I$(TLS)/include -DMBEDTLS_USER_CONFIG_FILE=\"$(shell cd $(TLS) && pwd)/tb_config.h\"
CFLAGS32 := $(addprefix -arch ,$(ARCHS32)) -isysroot $(SDK32) -mmacosx-version-min=10.4 -Wall -Wno-deprecated-declarations -O2 $(TLSFLAGS)
CFLAGSPPC64 := -arch ppc64 -isysroot $(SDK64) -mmacosx-version-min=10.5 -Wall -Wno-deprecated-declarations -O2 $(TLSFLAGS)
CFLAGSX86 := -arch x86_64 -isysroot $(SDKX86) -mmacosx-version-min=10.5 -Wall -Wno-deprecated-declarations -O2 $(TLSFLAGS) $(if $(findstring 10.6,$(SDKX86)),-DTB_QTKIT64=1)
LIBS32 := $(TLS)/lib/libmbedtls32.a -framework Security -framework Cocoa -framework ApplicationServices -lz -framework CoreServices -framework CoreAudio -framework QTKit
LIBS64 := $(TLS)/lib/libmbedtls64ppc.a -framework Security -framework Cocoa -framework ApplicationServices -lz -framework CoreServices -framework CoreAudio
comma := ,
LIBSX86 := $(TLS)/lib/libmbedtls64x86.a -framework Security -framework Cocoa -framework ApplicationServices -lz -framework CoreServices -framework CoreAudio $(if $(findstring 10.6,$(SDKX86)),-Wl$(comma)-weak_framework$(comma)QTKit)
SOURCES := main.m ChatController.m ChatController+Run.m ChatController+Preferences.m ChatController+History.m ChatController+Commander.m ChatController+Integrations.m ChatController+Workspaces.m ChatController+Attachments.m ChatController+ChatFile.m ChatController+Extras.m ChatController+Appearance.m ChatController+Sudo.m ChatController+Voice.m ChatController+Dictation.m EngineRequest.m TBSupport.m TBMachine.m TBMarkup.m TBEmoji.m TBJSON.m TBHTTP.m TBRun.m TBEngine.m TBMCP.m TBProviders.m TBPricing.m TBLocal.m TBSession.m TBSessionGrok.m TBService.m TBExtract.m TBSpeech.m TBOutputs.m TBMedia.m TBBuiltin.m TBIntegrations.m TBExtras.m TBSSH.m TBTheme.m TBProviderIcons.m TranscriptView.m
HEADERS := TBCompat.h ChatController.h ChatController_Private.h EngineRequest.h TBSupport.h TBMarkup.h TBEmoji.h TBHTTP.h TBRun.h TBEngine.h TBMCP.h TBProviders.h TBPricing.h TBLocal.h TBSession.h TBService.h TBExtract.h TBSpeech.h TBOutputs.h TBMedia.h TBBuiltin.h TBIntegrations.h TBExtras.h TBSSH.h TBTheme.h TBProviderIcons.h TranscriptView.h
APP := TigerBuild.app
BIN := $(APP)/Contents/MacOS/TigerBuild

.PHONY: all clean test

all: $(BIN)

# models.txt is the model list built into the app for when the relay cannot
# be reached. install-tiger.sh writes it from relay/providers.py.
# ppc-commander/ (copied in by the install script) is the Commander the app
# installs into ~/ppc-commander when that is missing or older.
$(BIN): $(SOURCES) TBNet.c TBNet.h $(HEADERS) Info.plist TigerBuild.icns models.txt Emoji.pack cacert.pem prices-seed.json
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	rm -rf build && mkdir build
	$(CC32) $(CFLAGS32) -c -o build/TBNet32.o TBNet.c
	$(CC32) $(CFLAGS32) -fobjc-exceptions -Wl,-w -o build/TigerBuild32 $(SOURCES) build/TBNet32.o $(LIBS32)
ifneq ($(strip $(ARCHS64)),)
	$(if $(findstring ppc64,$(ARCHS64)),$(CC64) $(CFLAGSPPC64) -c -o build/TBNetP64.o TBNet.c && $(CC64) $(CFLAGSPPC64) -o build/TigerBuildP64 $(SOURCES) build/TBNetP64.o $(LIBS64))
	$(if $(findstring x86_64,$(ARCHS64)),$(CC64) $(CFLAGSX86) -c -o build/TBNetX64.o TBNet.c && $(CC64) $(CFLAGSX86) -o build/TigerBuildX64 $(SOURCES) build/TBNetX64.o $(LIBSX86))
	lipo -create build/TigerBuild32 $$(ls build/TigerBuildP64 build/TigerBuildX64 2>/dev/null) -output $(BIN)
else
	cp build/TigerBuild32 $(BIN)
endif
	rm -rf build
	cp Info.plist $(APP)/Contents/Info.plist
	cp TigerBuild.icns $(APP)/Contents/Resources/TigerBuild.icns
	cp models.txt Emoji.pack Emoji-LICENSE.txt cacert.pem prices-seed.json $(APP)/Contents/Resources/
	if [ -d ppc-commander ]; then mkdir -p $(APP)/Contents/Resources/ppc-commander && cp ppc-commander/ppc_commander.py ppc-commander/service.py $(APP)/Contents/Resources/ppc-commander/; fi
	printf 'APPL????' > $(APP)/Contents/PkgInfo

tbtests: tests.m TBSupport.m TBMachine.m TBMarkup.m TBEmoji.m TBJSON.m TBSupport.h TBMarkup.h TBEmoji.h TBCompat.h
	$(CC32) $(CFLAGS32) -o tbtests tests.m TBSupport.m TBMachine.m TBMarkup.m TBEmoji.m TBJSON.m -framework Foundation

test: tbtests
	./tbtests

clean:
	rm -rf $(APP) "Tiger Build.app" tbtests build
