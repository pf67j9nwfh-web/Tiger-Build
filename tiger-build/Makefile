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
ARCHS32 ?= ppc i386
ifeq ($(wildcard $(SDK64)),)
ARCHS64 ?=
else
ARCHS64 ?= ppc64 x86_64
endif
# The 10.4 SDK needs gcc 4.0; on Xcode 3.2 that is installed next to gcc 4.2.
CC32 ?= $(if $(wildcard /usr/bin/gcc-4.0),gcc-4.0,gcc)
CC64 ?= $(if $(wildcard /usr/bin/gcc-4.2),gcc-4.2,gcc)
CFLAGS32 := $(addprefix -arch ,$(ARCHS32)) -isysroot $(SDK32) -mmacosx-version-min=10.4 -Wall -O2
CFLAGS64 := $(addprefix -arch ,$(ARCHS64)) -isysroot $(SDK64) -mmacosx-version-min=10.5 -Wall -O2
LIBS32 := -framework Cocoa -framework CoreServices -framework QTKit
LIBS64 := -framework Cocoa -framework CoreServices
SOURCES := main.m ChatController.m ChatController+Run.m ChatController+Preferences.m ChatController+History.m ChatController+Commander.m ChatController+Integrations.m ChatController+Workspaces.m RelayClient.m TBSupport.m TBMachine.m TranscriptView.m
HEADERS := TBCompat.h ChatController.h ChatController_Private.h RelayClient.h TBSupport.h TranscriptView.h
APP := TigerBuild.app
BIN := $(APP)/Contents/MacOS/TigerBuild

.PHONY: all clean test

all: $(BIN)

# models.txt is the model list built into the app for when the relay cannot
# be reached. install-tiger.sh writes it from relay/providers.py.
# ppc-commander/ (copied in by the install script) is the Commander the app
# installs into ~/ppc-commander when that is missing or older.
$(BIN): $(SOURCES) $(HEADERS) Info.plist TigerBuild.icns models.txt
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	rm -rf build && mkdir build
	$(CC32) $(CFLAGS32) -o build/TigerBuild32 $(SOURCES) $(LIBS32)
ifneq ($(strip $(ARCHS64)),)
	$(CC64) $(CFLAGS64) -o build/TigerBuild64 $(SOURCES) $(LIBS64)
	lipo -create build/TigerBuild32 build/TigerBuild64 -output $(BIN)
else
	cp build/TigerBuild32 $(BIN)
endif
	rm -rf build
	cp Info.plist $(APP)/Contents/Info.plist
	cp TigerBuild.icns $(APP)/Contents/Resources/TigerBuild.icns
	cp models.txt $(APP)/Contents/Resources/models.txt
	if [ -d ppc-commander ]; then mkdir -p $(APP)/Contents/Resources/ppc-commander && cp ppc-commander/ppc_commander.py ppc-commander/service.py $(APP)/Contents/Resources/ppc-commander/; fi
	printf 'APPL????' > $(APP)/Contents/PkgInfo

tbtests: tests.m TBSupport.m TBMachine.m TBSupport.h TBCompat.h
	$(CC32) $(CFLAGS32) -o tbtests tests.m TBSupport.m TBMachine.m -framework Foundation

test: tbtests
	./tbtests

clean:
	rm -rf $(APP) "Tiger Build.app" tbtests build
