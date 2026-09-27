# Build Tiger Build on Mac OS X 10.4 with Xcode 2.5.
SDK := /Developer/SDKs/MacOSX10.4u.sdk
CC := gcc
CFLAGS := -arch ppc -isysroot $(SDK) -mmacosx-version-min=10.4 -Wall -O2
LIBS := -framework Cocoa -framework CoreServices -framework QTKit
SOURCES := main.m ChatController.m TranscriptView.m
APP := TigerBuild.app

.PHONY: all clean

all: $(APP)/Contents/MacOS/TigerBuild

$(APP)/Contents/MacOS/TigerBuild: $(SOURCES) Info.plist TigerBuild.icns
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	$(CC) $(CFLAGS) -o $(APP)/Contents/MacOS/TigerBuild $(SOURCES) $(LIBS)
	cp Info.plist $(APP)/Contents/Info.plist
	cp TigerBuild.icns $(APP)/Contents/Resources/TigerBuild.icns
	printf 'APPL????' > $(APP)/Contents/PkgInfo

clean:
	rm -rf $(APP) "Tiger Build.app"
