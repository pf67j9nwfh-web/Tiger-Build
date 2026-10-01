# Build Tiger Build on Mac OS X 10.4 with Xcode 2.5.
#   make        build TigerBuild.app
#   make test   build and run the unit checks (no window needed)
SDK := /Developer/SDKs/MacOSX10.4u.sdk
CC := gcc
CFLAGS := -arch ppc -isysroot $(SDK) -mmacosx-version-min=10.4 -Wall -O2
LIBS := -framework Cocoa -framework CoreServices -framework QTKit
SOURCES := main.m ChatController.m ChatController+Preferences.m ChatController+History.m ChatController+Commander.m ChatController+Integrations.m ChatController+Workspaces.m RelayClient.m TBSupport.m TBMachine.m TranscriptView.m
HEADERS := ChatController.h ChatController_Private.h RelayClient.h TBSupport.h TranscriptView.h
APP := TigerBuild.app

.PHONY: all clean test

all: $(APP)/Contents/MacOS/TigerBuild

# models.txt is the model list built into the app for when the relay cannot
# be reached. install-tiger.sh writes it from relay/providers.py.
$(APP)/Contents/MacOS/TigerBuild: $(SOURCES) $(HEADERS) Info.plist TigerBuild.icns models.txt
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	$(CC) $(CFLAGS) -o $(APP)/Contents/MacOS/TigerBuild $(SOURCES) $(LIBS)
	cp Info.plist $(APP)/Contents/Info.plist
	cp TigerBuild.icns $(APP)/Contents/Resources/TigerBuild.icns
	cp models.txt $(APP)/Contents/Resources/models.txt
	printf 'APPL????' > $(APP)/Contents/PkgInfo

tbtests: tests.m TBSupport.m TBMachine.m TBSupport.h
	$(CC) $(CFLAGS) -o tbtests tests.m TBSupport.m TBMachine.m -framework Foundation

test: tbtests
	./tbtests

clean:
	rm -rf $(APP) "Tiger Build.app" tbtests
