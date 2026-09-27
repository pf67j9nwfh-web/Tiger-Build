# Tiger Build

Tiger Build is a Cocoa chat window for Mac OS X 10.4 Tiger.  Chats are listed down the side. Drag the divider to resize that list. Each chat can turn ppc-commander on or off, and each chat keeps its own model. 

PPC-Commander is an included MCP server application that provides the models similar functionality to modern contempary programs like Desktop Commander. 

Tiger cannot open a modern HTTPS connection, so a small relay on a current Mac calls the model APIs and forwards tool calls to the Power Mac over SSH. The relay also talks to a local OpenAI-compatible server, such as LM Studio, on that same Mac.

USE THIS AT YOUR OWN RISK.  MAC OS X TIGER IS A 20+ YEAR OLD OPERATING SYSTEM AND IS VERY INSECURE.  I AM NOT LIABLE FOR ANY SECURITY VULERNABILITIES ABLE TO BE EXPLOITED FROM USING THIS APPLICATION ON TIGER.  YOU HAVE BEEN WARNED.

Tiger Build is licensed under the MIT License and comes with no warranty. See `LICENSE`.

## What you need

- A PowerPC Mac on Mac OS X 10.4 with the system Python 2.3, which Tiger already includes, and Xcode 2.5 to build Tiger Build.
- Install the develop tools disc that's apart of the Mac OS X Tiger OS installation set as well.
- A current Mac on the same network, with Python 3.
- An API for Grok. ChatGPT, Claude, Mistral, Muse, and/or Gemini if you plan on using them instead of locally hosted models.
- An SSH key the Mac accepts. Tiger's OpenSSH only understands `ssh-rsa`.

## Install the bridge server on the current Mac

Due to Mac OS X Tiger's old age, a bridge server is required to make this function properly.  This was tested on a modern Mac running Golden Gate, but older ones may also work well.  This should be portable to Windows or Linux as well.

Python 3 is required. The relay is `relay/chat_proxy.py`. It listens on `0.0.0.0:8765` unless `config.sh` sets another `LISTEN_PORT`.

```bash
git clone <this repository>
cd tiger-desk
mkdir -p ~/Library/Application\ Support/TigerDesk
cp config.example.sh ~/Library/Application\ Support/TigerDesk/config.sh
```

Edit that `config.sh`. Set `TIGER_HOST` to the Power Mac, `TIGER_USER` to the account there, and `TIGER_KEY` / `TIGER_KNOWN` to an `ssh-rsa` key and known-hosts file the Power Mac accepts. `REMOTE_COMMANDER` stays `$HOME/ppc-commander/ppc_commander.py`.

```bash
cp .env.example .env
```

Put provider keys in `.env`: `XAI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_WORKSPACE_ID`, `MISTRAL_API_KEY`, `MUSE_API_KEY`, and `GEMINI_API_KEY`. Leave a line blank when you do not have that key. For LM Studio or another OpenAI-compatible server on this Mac, set `LOCAL_MODEL_URL` (the default is `http://127.0.0.1:1234/v1`) and, only if that server requires one, `LOCAL_API_KEY`.

```bash
chmod 600 .env
./scripts/setup.sh
```

`setup.sh` starts the relay and reloads it at login. The log is `~/Library/Application Support/TigerDesk/relay.log`. Check it with `curl http://127.0.0.1:8765/health`, which answers `ok grok-4.7`.

If `.env` contains keys, setup writes `~/Library/Application Support/TigerDesk/providers.json` and the relay does the same the first time it starts. That file is the one Preferences edits. A blank field in Preferences keeps the saved key. The address in Local server is reached from this Mac, so `127.0.0.1` is LM Studio on the relay machine. Do not commit `.env` or `providers.json`.

To build an installer package instead:

```bash
./scripts/build-pkg.sh
```

That writes `dist/TigerDesk-1.1.pkg`, which installs the relay on this Mac at `/usr/local/tiger-desk`. The package does not contain an API key. The installer’s last screen, and `/usr/local/tiger-desk/ENV-SETUP.txt`, explain how to create `.env` from `.env.example`, fill in the keys you have, edit `config.sh` for the Power Mac, and run `scripts/setup.sh`.

`./scripts/build-tiger-pkg.sh` compiles on the Power Mac and writes `dist/TigerBuild-1.1.pkg`. On Mac OS X 10.4 that package installs Tiger Build.app and copies ppc-commander to `~/ppc-commander/ppc_commander.py` for each user. It does not contain an API key.

## Build Tiger Build

The Cocoa app is built on the PowerPC Mac, not on the current Mac. `scripts/install-tiger.sh` copies `tiger-build/` to `~/TigerBuild-build/native` on the PowerPC Mac and runs `make` there. You need Xcode 2.5, so `/Developer/SDKs/MacOSX10.4u.sdk` exists. The Makefile compiles with:

```bash
gcc -arch ppc -isysroot /Developer/SDKs/MacOSX10.4u.sdk -mmacosx-version-min=10.4 -Wall -O2 \
  -o TigerBuild.app/Contents/MacOS/TigerBuild \
  main.m ChatController.m TranscriptView.m \
  -framework Cocoa -framework CoreServices -framework QTKit
```

`make` produces `TigerBuild.app`. `install-tiger.sh` copies it to `~/Desktop/Tiger Build.app` and writes the relay address into `~/Library/Application Support/Tiger Build/server.txt`. Open the app from Finder. Launching the Mach-O directly over SSH crashes in CoreDrag.

To rebuild only the app after a source change, from the current Mac:

```bash
COPYFILE_DISABLE=1 tar -C tiger-build -cf - . | ppc-commander/bin/ppc-ssh 'cd "$HOME/TigerBuild-build/native" && tar -xf -'
ppc-commander/bin/ppc-ssh 'cd "$HOME/TigerBuild-build/native" && make clean && make'
```

Then copy `TigerBuild.app` to the Desktop and open it from Finder. `make` with no `clean` can skip the compile when the copied sources are older than the binary.

## Install on the Power Mac

With the SSH key already in `~/.ssh/authorized_keys` on Tiger:

```bash
./scripts/install-tiger.sh
```

This copies ppc-commander and Tiger Build over, builds `Tiger Build.app` on the desktop, and points it at this Mac's relay.

If you still need to install the key, connect once with the legacy algorithms and append `ppc_tiger_rsa.pub`:

```bash
ssh-keygen -t rsa -b 2048 -f ~/.ssh/ppc_tiger_rsa -N "" -C ppc-commander
ssh \
  -o KexAlgorithms=diffie-hellman-group14-sha1,diffie-hellman-group1-sha1 \
  -o HostKeyAlgorithms=ssh-rsa \
  -o PubkeyAcceptedAlgorithms=ssh-rsa \
  -o Ciphers=aes128-cbc,3des-cbc \
  -o MACs=hmac-sha1 \
  -o RequiredRSASize=512 \
  YOURUSER@THE.POWER.MAC \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

Paste the public key, then press Ctrl-D. Put the host key line ssh prints into `~/.ssh/ppc_tiger_known_hosts`.

## Use Tiger Build

Open Tiger Build on the Power Mac. Click the message field and type. The field grows taller as the text wraps, up to a few lines. Return sends. The upper popup under the chat list, and the Model menu, choose Grok, ChatGPT, Claude, Mistral, Muse, Gemini, or Local for the selected chat. The popup under that chooses a version that this app can call, such as Grok 4.7 or 4.3, or Claude Opus 5.5, Fable 5.1, or Sonnet 5. Local versions are read from the model server, and embedding models are left out. Switching chats switches both. The first reply names a new chat. Drag the sidebar divider to resize the chat list. The top right shows the context estimate. A chat that reaches about 85 percent of its window is compacted before the next send. Double-click a chat name to rename it. Delete, or Delete Chat in the Edit menu, removes the selected chat after a confirmation. About Tiger Build and Preferences are in the application menu. Preferences stores API keys and the local server address in the relay config. Quit Tiger Build is in that same menu. When a question is about that computer, and Commander is on, the model can list directories, read and edit files, and run shell commands through ppc-commander. Those steps show up as short notes above the reply. Disk-erase commands stay blocked.

Saved chats and the relay address stay in `~/Library/Application Support/Tiger Build` on the Power Mac (`chats.plist` and `server.txt`). An older `AquaChat` folder in that same place is moved there the first time Tiger Build opens.

## Use the same tools from another MCP client

Point the client at `ppc-commander/bin/ppc-commander-ssh`. For Grok:

```toml
[mcp_servers.ppc-commander]
command = "/absolute/path/to/tiger-desk/ppc-commander/bin/ppc-commander-ssh"
enabled = true
startup_timeout_sec = 45
```

## Layout

| Path | Where it runs |
| --- | --- |
| `tiger-build/` | Tiger Build, the Cocoa app built on the Power Mac |
| `legacy/chat.py` | Earlier Python interface. `install-tiger.sh` does not build it |
| `ppc-commander/ppc_commander.py` | Power Mac, over SSH |
| `relay/chat_proxy.py` | Current Mac |
| `assets/TigerBuild.icns` | Finder icon, in the Tiger icon format |

## Rebuild the icon

`scripts/make_icns.py` turns a PNG into a Tiger-compatible `.icns` (the classic `it32` elements, not a modern PNG-based icon).


## Why Do This?

This is just a project for fun.  I saw people creating similar chat environments for older operating systems like Windows 95 and decided to give this a try myself.  As far as I can tell at the time of writing, this is the only LLM chat app for PowerPC Mac OS X that supports interaction with the system itself and is not just a chat interface only.  This app was made with heavy LLM support from Grok Build for fun so don't expect perfection.  However, I think it's actually a decently cromulent LLM chat build environment.  Don't expect any future updates or support for this.  I might add some but no promises.  Feel free to suggest improvements.  As stated above, Mac OS X Tiger is a very old operating system with security vulnerabilities, use at your own risk.
