# Tiger Build

**A native AI chat app for Mac OS X 10.4 Tiger, 10.5 Leopard and 10.6 Snow Leopard for PowerPC and Intel.**

Tiger Build is a Cocoa chat window for old Macs. It has support for a broad range of providers including: Grok, ChatGPT, Claude, Mistral, Muse, Gemini, and local LLM servers. With **Commander** (ppc-commander) on, the model can list folders, read and edit files, run shell commands, use git and Subversion, and take screenshots on that Mac. Tiger Build is also designed to look right at home on these older Macs
and uses a UI that is mostly period accurate for the OSes it's operating on. It's almost like a glance into an alternate reality where the
LLM revolution occured around 2009 instead of the 2020s.

> [!WARNING]
> USE THIS AT YOUR OWN RISK. MAC OS X TIGER, LEOPARD, AND SNOW LEOPARD ARE A 15+ YEAR OLD OPERATING SYSTEMS AND ARE VERY INSECURE. I AM NOT LIABLE FOR ANY SECURITY VULNERABILITIES ABLE TO BE EXPLOITED FROM USING THIS APPLICATION ON THESE MACHINES. YOU HAVE BEEN WARNED. SAFEGUARDS HAVE BEEN INCLUDED THOUGH AS MUCH AS IS FEASIBLE WITHIN THE CONFINES OF THE LIMITATIONS OF ITS OPERATING ENVIRONMENT.

Tiger Build is licensed under the MIT License and comes with no warranty. See [`LICENSE`](LICENSE). The emoji pictures are [Twemoji](https://github.com/jdecked/twemoji), copyright Twitter, Inc. and other contributors, under [CC-BY 4.0](tiger-build/Emoji-LICENSE.txt).

## Screenshots

**The client**, on Mac OS X 10.4 Tiger, 10.5 Leopard, and 10.6 Snow Leopard:

| Tiger | Leopard | Snow Leopard |
| --- | --- | --- |
| ![Tiger Build on Tiger: an attached file, a diff, Python code and a table, and a file to save](docs/screenshots/client-tiger-chat.png) | ![The same chat on Leopard](docs/screenshots/client-leopard-chat.png) | ![The same chat on Snow Leopard](docs/screenshots/client-snowleopard-chat.png) |

**Asking before a tool runs, with the model's thinking shown above the message box while it works** (Stop and Guide replace Send while a reply runs), and **the Tools menu**, which switches each tool on or off for the chat:

| Approval and live thinking | Tools menu |
| --- | --- |
| ![The approval question for a notebook tool, with the live thinking strip](docs/screenshots/client-approval.png) | ![The Tools menu: Commander and every MCP server, Ask Before Running, and settings](docs/screenshots/client-tools-menu.png) |

**Preferences** are in tabs so they fit a 1024x768 screen, and **MCP servers** are a list with an edit sheet:

| Commander | Local LLM Server | MCP servers |
| --- | --- | --- |
| ![Preferences, Commander tab](docs/screenshots/client-preferences-commander.png) | ![Preferences, Local LLM Server tab](docs/screenshots/client-preferences-llm.png) | ![MCP Servers tab](docs/screenshots/client-mcp-servers.png) |

**The relay app** (macOS shown; Windows and Linux have the same settings in a Tk window):

| Relay | Tools and MCP servers | Connected Macs |
| --- | --- | --- |
| ![Tiger Build Relay main window](docs/screenshots/relay-main.png) | ![MCP servers and agent tools](docs/screenshots/relay-tools.png) | ![Connected Macs window](docs/screenshots/relay-macs.png) |

*Screenshots use example addresses, accounts and servers; the token is hidden.*

## Contents

- [Screenshots](#screenshots)
- [How it fits together](#how-it-fits-together)
- [What you need](#what-you-need)
- [Setup](#setup)
- [Where settings are kept](#where-settings-are-kept)
- [Using Tiger Build](#using-tiger-build)
- [Tiger Build Relay app](#tiger-build-relay-app)
- [Models, tools and search](#models-tools-and-search)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Building, testing and packages](#building-testing-and-packages)
- [Upgrading from Tiger Desk](#upgrading-from-tiger-desk)
- [Why Do This?](#why-do-this)

## How it works

Tiger and the Leopards cannot open modern HTTPS connections, so Tiger Build never calls an AI service itself. **Tiger Build Relay** runs on a current Mac on the same network. It receives each chat over plain HTTP (protected by a token), calls the AI service, and, when the model wants a tool, runs ppc-commander on the Tiger Mac over SSH. The basic operation of this application can be seen in the diagram below:

```
 Tiger Mac (10.4, PowerPC)                  Relay (Mac, Windows, or Linux)
 ┌──────────────────────┐   HTTP + token    ┌───────────────────────────┐   HTTPS   ┌──────────────────────┐
 │ Tiger Build (client) │ ────────────────▶ │ Tiger Build Relay         │ ────────▶ │ External LLM services│
 │                      │                   │                           │           │ (if configured)      │
 │ chats, workspaces    │                   │ keys, model checks, tools │           └──────────────────────┘
 └──────────────────────┘                   │                           │   HTTP    ┌──────────────────────┐
 ┌──────────────────────┐   SSH (ssh-rsa)   │                           │ ────────▶ │ Local LLM server     │
 │ ~/ppc-commander/     │ ◀──────────────── │ runs tools when asked     │           │ (if configured)      │
 └──────────────────────┘                   └───────────────────────────┘           └──────────────────────┘
```

Your chat history stays on the Tiger Build client. API keys stay on the relay computer; The Tiger Build client is only told whether each key is saved and available for use.

## What you need

| Where | What |
| --- | --- |
| Client Mac | Mac OS X 10.4 to 10.6, PowerPC or Intel, with its built-in Python (2.3, 2.5 or 2.6) and Remote Login on (System Preferences → Sharing). To build the app yourself: Xcode 2.5 on Tiger, or Xcode 3.1/3.2 on Leopard and Snow Leopard. It's generated as a universal binary covers that `ppc`, `i386`, `ppc64` and `x86_64`; ppc64 is only supported on Leopard due to OS API limitations.  As a sidenote, there is very little software that ever took advantage of 64 bit on the G5s because of said API limitations.  Newer versions of Mac OS X (or OS X or macOS) are theorically supported on the client since this app does include 64 bit Intel support. It is strongly recommended that you install the Developer Tools disc and/or the appropriate version of Xcode for your client system even if you aren't compiling the Tiger Build client application yourself to let your agents take full advantage of your Mac's capabilities. |
| Relay computer | A Mac, Windows PC, or Linux computer that meets the minimums in [Relay system requirements](#relay-system-requirements) |
| Network | The Tiger Mac and the relay computer on the same network, and the Tiger Mac able to reach the relay directly |
| Optional | API keys for xAI, OpenAI, Anthropic, Mistral, Muse, or Google (as few or as many as you want to configure), a Brave or Tavily key for better web search if desired, and/or a local OpenAI-compatible model server. |

### Relay system requirements

The relay needs an OpenSSH client 9.1 or later (it enforces `RequiredRSASize=2048`), which sets the minimums below. Intel and ARM64 are both supported.

| Relay computer | Minimum | Also needed |
| --- | --- | --- |
| macOS | macOS 14 Sonoma | Python 3.8 or later (Apple's command line tools provide `/usr/bin/python3`: `xcode-select --install`) |
| Windows | Windows 11 version 24H2 | Python 3.8 or later from python.org, with Tk (the default install includes it). ARM64 PCs can use native ARM64 Python (3.11 or later) or x64 Python |
| Linux | Ubuntu 24.04 or Debian 12 for the `.deb`; other systemd distributions with the same parts can run `scripts/setup.py` | Python 3.8 or later, `python3-tk`, OpenSSH client 9.1 or later |

For the client computer, you will need two pieces of information: the **Tiger Build Mac's IP address** (System Preferences → Network on that Mac) and the **short user name** of the account on it that will run ppc-commander.

## Setup

All commands run on the **relay computer** aside from ones that need to execute directly on the client. Replace `TIGERUSER` and `TIGER.MAC.ADDRESS` with your own values.

> [!TIP]
> Steps 1–3 can be skipped: run `./scripts/setup.sh` (step 4), then on the Tiger Mac choose **Configuration → Connect Commander over SSH** in Tiger Build. It installs the relay's key and tells the relay the address and user name; no password is typed.

**1. Make an SSH key Tiger accepts.** Tiger's OpenSSH 5.1 only understands `ssh-rsa`. Leave the passphrase empty so the relay can start at login.

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t rsa -b 2048 -f ~/.ssh/ppc_tiger_rsa -N "" -C tiger-build
```

**2. Install the public key on the Tiger Mac.** This is the only time you type that account's password. Type `yes` to trust its host key.

```bash
ssh -o HostKeyAlgorithms=ssh-rsa -o PubkeyAcceptedAlgorithms=ssh-rsa \
  -o KexAlgorithms=diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha1 \
  -o Ciphers=aes256-ctr,aes128-ctr -o MACs=hmac-sha1 \
  -o UserKnownHostsFile="$HOME/.ssh/ppc_tiger_known_hosts" \
  TIGERUSER@TIGER.MAC.ADDRESS \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' \
  < ~/.ssh/ppc_tiger_rsa.pub
```

**3. Tell the relay which Tiger Mac to use.**

```bash
./scripts/setup.sh      # first run only writes config.sh, then stops
open -e ~/Library/Application\ Support/Tiger\ Build\ Relay/config.sh
```

Set `TIGER_HOST` and `TIGER_USER`. Leave the other lines as they are. Check the key login with `ppc-commander/bin/ppc-ssh 'echo ok'`.

**4. Start the relay.** Optionally put API keys in `.env` first (`cp .env.example .env`); you can also add them later in either app.

```bash
./scripts/setup.sh
```

It installs the relay, starts it (and at login), builds **Tiger Build Relay.app** in `~/Applications`, and prints the relay's **address, port and token**. The first start tests each model once, which takes a few minutes.

**5. Install Tiger Build on the Tiger Mac.**

```bash
./scripts/install-tiger.sh
```

This copies ppc-commander to `~/ppc-commander`, builds Tiger Build there, puts it on the desktop, and fills in the relay address and token. `TIGER_SUDO_POLICY=1` also installs the optional `/etc/ppc-commander.json` policy.

Or open **Tiger Build → Preferences**, enter the address, port and token from step 4, and click **Test Connection**. For the installer packages, see [`RELEASE.txt`](RELEASE.txt).

## Configuration and Setting File Locations and Content

**Relay computer:** `~/Library/Application Support/Tiger Build Relay/` (macOS), `%APPDATA%\Tiger Build Relay` (Windows), `~/.local/share/tiger-build-relay` (Linux). `TIGERBUILD_RELAY_HOME` overrides it, and **Show Folder** in the relay app opens it.

| File | Contents |
| --- | --- |
| `config.sh` | Tiger Mac address and user, SSH key paths, port, `LISTEN_ADDR`, `ALLOWED_CLIENTS`, `RELAY_TOKEN` |
| `providers.json`, `integrations.json` | API keys, local server, tool switches, MCP servers (mode 600) |
| `relay-token` | The token Tiger Build must send (mode 600) |
| `ssh-clients.json` | Which account the relay signs in as for each Tiger Build computer |
| `pricing-cache.json`, `models-cache.json` | Cost prices and model test results |
| `history/`, `media/`, `agent-notes.txt` | History snapshot, generated files, toolbox notes |
| `relay.log`, `app/` | Log and the installed relay code (`app/.env` can seed API keys) |

Start at login is a launchd agent on macOS, a scheduled task (or Startup shortcut) on Windows, and a systemd user service on Linux. Stop stops the relay; turning start-at-login off does not. The SSH key is `~/.ssh/ppc_tiger_rsa`. Program files are in `/usr/local/tiger-build-relay`, `/opt/tiger-build-relay` or `%LOCALAPPDATA%\Tiger Build Relay\package`.

Note: Pricing estimates on model usage are provided as a convience and may not always be accurate. Check the usage directly on the provider's API dashboard for the actual numbers.

**Tiger Mac:** `~/Library/Application Support/Tiger Build/`

| File | Contents |
| --- | --- |
| `server.txt`, `token.txt` | Relay address and token (mode 600) |
| `chats.plist`, `workspaces/<name>.plist` | Chats and settings per workspace, with `backups/` beside them |
| `attachments/`, `media/` | Attached files, downloaded pictures and files |
| `history-before-import-*.plist` | Backups made before a history import |

Preferences are in `~/Library/Preferences/local.tigerbuild.TigerBuild.plist`, ppc-commander in `~/ppc-commander/`, and the relay's public key in `~/.ssh/authorized_keys`.

## Using Tiger Build

Skip this section if you don't want an ultra detailed description of this app's functionality.

**Chats**
- **Workspaces.** The sidebar popup picks a workspace (project); each has its own chats. API keys and tools are shared. Workspace → Directory Restriction limits Commander to one folder.
- **Chat list.** Hover a chat to see its full title. Each service shows its own icon in the provider popup and the Model menu.
- **Models.** The popups under the chat list pick service and model. A new chat starts with the last chat's model, tools and approvals, or a fixed model chosen in Preferences. Services with no key or no working model are dimmed with the reason.
- **Stop and guidance.** Stop (⌘.) ends a reply at once, even mid-command. While a model uses tools, Send becomes **Guide**: a note typed then reaches the model between steps (Grok, ChatGPT, Claude, Gemini, Mistral).
- **Edit and retry.** Retry resends your last message. Edit Last takes it back into the message box (Cancel Edit restores). Right-click any message for **Edit From Here** or **Branch Chat From Here**.
- **Appearance** (View → Appearance, ⌥⌘K). As in iChat, set the bubble colour, text colour and font for your messages and for replies, and put a solid colour, a gradient or a picture behind the chat. Changes show at once; Reset to Default restores the original look. While a reply has not started, a thought cloud with three moving dots shows, like iChat's typing indicator.
- **Find in Chats** (⌘F), **Custom Instructions** (⌥⌘T, per chat or per workspace), and **View → Bigger/Smaller Text** (⌥⌘= and ⌥⌘-).
- **Export and import.** Chat → Export This Chat (⌥⌘E) saves one chat with its files, or as Markdown or text; Import Chat (⌥⌘I) adds it to any workspace. History → Export All History covers every workspace; the relay copy and import backups hold references only. Each workspace file keeps five rolling backups.

**Files and replies**
- **Attach** (button, ⇧⌘A, drag onto the chat or Dock icon, or paste). Text, code, PDF, RTF and HTML are read on the Mac. Word, Excel, PowerPoint, Pages, Numbers, Keynote, OpenDocument, HEIC, WebP and AVIF are converted by the relay (text slide by slide or sheet by sheet, plus a preview picture; Pages/Numbers/Keynote text is recovered, not exact). Pictures are shrunk to 1600 pixels and sent to models that can see them; sideways phone photos are turned upright.
  - A PDF that is mostly drawings or a scan also sends its first three pages as pictures; Chat → Attach PDF Pages (⇧⌘P) adds pages you name, such as `7, 10-12`.
  - The first attach for each service explains the files go to that service. A file too big for the model's context is offered shortened. Stop cancels a read in progress.
  - Copies are kept in Application Support and the model is told where, so Commander can use them. Only the last six pictures are re-sent.
- **Files from the model.** The model can hand over a file with a **Save As...** button. A name ending `.docx`, `.xlsx` or `.pdf` makes a real Word, Excel or PDF file. Pictures a tool looks at are shown in the chat.
- **Emoji.** Macs before Lion have no emoji font, so Tiger Build draws each emoji as a colour picture from the Twemoji set (flags, skin tones and joined emoji too). The chat list shows them too, and copying selected text copies the emoji themselves. Lion and later use the system's own.
- **Code blocks.** Dark panels name the language and colour about 40 languages, with **Save** and **Copy**. Replies also show bold, italics, `inline code`, headings, bullets, links and tables. Chat → Copy Last Code Block (⇧⌘C) copies without clicking.
- **Thinking.** Returned reasoning shows in its own card and stays visible above the message box while the model runs (Claude, ChatGPT reasoning models, Grok, Gemini, Mistral Magistral, local reasoning models). Turn it off in Tools settings.
- **Cost and context.** The line above the chat shows context use and an **estimated cost** (hover for the breakdown), from a public price list the relay fetches; local models show N/A. A full context is summarized (also Chat → Compact Chat Now), and a reply that hits the output limit ends with a note.

**Tools**
- **The Tools button** switches each tool on or off for the chat: Commander, the agent toolbox, web search, other models and every MCP server. **Ask Before Running** waits for your answer, for all tools or chosen ones; "Always Allow" turns it off for that tool in that chat. It is on by default for tools that act on the Mac in chats with attachments. Each call shows as a card; click for the command and output.
- **Screenshots.** `take_screenshot` shows the Mac's screen (someone must be logged in); `view_image` shows a picture file. Models without vision are not offered either.
- **Source control.** `repo_info`, `git_read`, `git_write`, `svn_read` and `svn_write` let a model check status, read diffs and logs, and commit. Read tools never ask first; write tools follow Ask Before Running. A diff or commit shows `2 files +3 −0` on its card.
  - Subversion ships with Mac OS X 10.5 and later. git does not (before Lion): install it yourself, for example from MacPorts, and the tools find it.
  - Nothing runs through a shell. Force pushes, deleting remote branches, skipping hooks, passwords on the command line, interactive rebase and commits without `-m` are refused, and paths must stay in the allowed folders. A repository can contain hooks that run code, so use trusted ones.
- **Ask other models.** `consult_model` asks another working model for a second opinion; its usage counts in the chat's cost.
- **Tool steps.** A reply may use up to 40 tool steps (1 to 200 in Tools settings); then the relay stops it and you can say "continue".

**Voice** (optional, off until switched on, under Chat → Voice)
- **Speaking.** Speak Last Reply (⌥⌘S), Stop Speaking (⌥⌘.), Speak Replies Automatically (⇧⌥⌘J) and Choose Voice (⌥⌘V) use the Mac's own voices ("Alex" needs 10.5). Code and tables are not read out.
- **Voice Commands** (⌥⌘G) listens, while Tiger Build is in front, for "Send message", "Stop", "New chat", "Read that again" and "Stop talking".
- **Dictate** (⌥⌘R) records, press again to stop (⌘. cancels), and puts the words in the message box. The relay turns the clip (16 kHz mono, up to 90 seconds) into text with OpenAI, Mistral or Google, whichever has a key, and does not keep it; Tiger Build says so the first time. Send Dictation Automatically (⌥⌘Y) sends it straight away. It needs a working microphone and a relay 1.4 or later.

**Several Macs and windows**
- Commander runs on the Mac you chat from: the relay keeps one SSH link per Tiger Build computer, and a Mac that has not connected gets no Commander rather than another Mac's. Tiger Build offers to connect.
- Windows share each workspace's chats (a chat working in one window cannot be sent to from another). The relay handles requests separately and limits simultaneous SSH logins to one Mac.

**Status and menus**
- A red line at the top says the relay cannot be reached, rejects the token, or does not accept this Mac's address; an orange one says why Commander cannot run, with the fix; a gray one says the app and relay are different versions. Long runs send heartbeats, so slow commands never look like a lost connection.
- **Commander menu:** Start, Stop and Start at Login for ppc-commander, and this Mac's model, OS and addresses. **Configuration menu:** MCP servers and agent tools, Connect Commander over SSH, and export/import of all settings. VoiceOver labels are set on controls and messages.

## Tiger Build Relay app

The Mac app and the Windows and Linux settings windows show whether the relay is running, its address, port and token, the Tiger Mac, start and stop, start at login, API keys and the local server. Closing the window leaves the relay running in the background. **Connected Macs** lists each Mac that chats through the relay, with its account, home folder and where its tools run, and has Add, Save, Test and Remove. A Mac can also be connected from Tiger Build's Preferences (Commander tab) or Configuration → Connect Commander over SSH.  The
relay client does support having multiple machines connected at once.  Up to four computers has been formally tested in testing.

From Terminal, without a window:

```bash
"/Applications/Tiger Build Relay.app/Contents/MacOS/TigerBuildRelay" --start    # or --stop
python3 "$HOME/Library/Application Support/Tiger Build Relay/app/relay/control.py" status|start|stop
```

## Models, tools and search

- **Live model list.** At start and every six hours the relay asks each keyed service for its models, drops non-chat ones, and test-calls each with a tool. Only models that pass are offered; changing a key retests that service. This means this app will theorically always have
the latest and greatest models available for you to use excluding an API updates that break compatability. The more powerful models tend to do a much better job or working within the confines of the old OS environments than the less powerful ones.
- **Local LLM server.** None is assumed. Give its address as the relay computer sees it: `http://127.0.0.1:1234` for LM Studio or `http://127.0.0.1:11434` for Ollama (`/v1` is added if left off). The relay reads each model's context length from the server. With Ollama, set its context length in Ollama's settings; the default can be small, and Ollama then drops the oldest part of a long chat without saying so.
- **Custom MCP servers.** Add stdio servers (program path, arguments, environment) in the MCP Servers tab of either app; double-click to edit. They run on the relay computer, start disabled, and can be set to ask first. Enable only programs you trust. `relay/http_mcp.py` bridges Streamable HTTP servers.
- **Example servers.** `mcp-examples/` has four dependency-free Python 3 servers: `mcp_calc.py`, `mcp_notes.py`, `mcp_sysinfo.py` (with `slow_task` and `always_fails` for testing Stop) and `mcp_weather.py` (forecasts from wttr.in, fetched with `curl`). Setup adds all four to the server list the first time it runs, switched on (the notebook asks before it runs); remove or switch off any you do not want and it stays that way. To add one by hand, use your Python 3 as the program and the script's full path as the argument. The official servers work too, for example program `/path/to/npx`, arguments `-y|@modelcontextprotocol/server-filesystem|/some/folder`.
- **Web search and pictures.** Search runs on the relay computer. It works with no key (DuckDuckGo, with Wikipedia as a fallback); a Brave or Tavily key broadens it, and a refused key falls back to the free search. Models can find pictures (Brave or Tavily, else Wikimedia Commons) and show them in the chat; the relay downloads them, and only from public addresses. Grok uses its own search while that switch is on.
- **Agent toolbox** adds UTC time and scratch notes. **Claude thinking** passes signed blocks back unchanged, as Anthropic requires in their more recent updates for 5.5 and later models.
- **Settings backups.** Export/Import All Settings in either app. Backups hold API keys and the token in plain text; imported MCP servers stay disabled.

## Security

- Every request except `/health` needs the relay token, and only the Tiger Mac and the relay computer may connect. The relay listens on one address.
- SSH uses the strongest settings Tiger's OpenSSH 5.1 supports.
- A model cannot change ppc-commander's blocked commands, allowed folders or shell, or edit its files.
- File conversion refuses XML entity definitions and oversized archives, and the relay deletes the files it hands out after three days.
- **Administrator (sudo) mode** is off. To let agents run commands as root on a Mac, open Preferences, Commander, tick *Let agents run administrator (sudo) commands*, and type the account password once. Tiger Build checks it and keeps it in that Mac's Keychain, where only Tiger Build can read it. SSH sessions cannot open the Keychain, so when a command contains `sudo`, Commander asks the running Tiger Build for the password over a socket only that account can use (Tiger Build must be open on that Mac), and gives it to sudo through a pipe that is closed before the model's command starts. The model never sees it, but it runs as the same account, so with sudo on it can do anything root can. `ppc_commander.py --sudo on|off|status` does the same from a terminal, and a root-owned `/etc/ppc-commander.json` containing `{"sudoMode": false}` keeps it off. Blocked commands such as `shutdown` stay blocked under sudo, the approval question marks sudo commands, and `sudo` is refused with `detach`. The login keychain must be unlocked, so stay logged in at that Mac.
- With tools on, a model runs shell commands as the Tiger Mac account. The guards stop mistakes and simple tricks, not a determined attacker; use a separate account for real separation.

## Encrypting the connection to the relay

The relay speaks plain HTTP, so chats, attached files and the token cross the network unencrypted (Tiger cannot do modern TLS). To protect them, have the relay computer open an SSH tunnel to the Tiger Mac, as it already does for Commander:

```bash
python3 relay/tunnel.py TIGER-ADDRESS [USER]
```

Leave it running (it reconnects), then set the relay address in Tiger Build's Preferences to `http://127.0.0.1:8765`. It uses the relay's SSH key, so Commander must be set up and Remote Login on. A tunnelled Mac identifies itself with an `X-TigerBuild-Client` header, which the relay believes only from its own computer and only for allowed addresses.

## Troubleshooting

| You see | Try |
| --- | --- |
| "Cannot reach the relay" | Check the address and port in Preferences; on the relay Mac run `curl http://ADDRESS:PORT/health`; allow Python in the macOS firewall |
| "The relay rejected the token" | Copy the token from the relay app into Preferences, or run `install-tiger.sh` again |
| "does not accept this Mac's address" | Add the Tiger Mac's address to `ALLOWED_CLIENTS` in `config.sh`, then run `setup.sh` |
| The orange Commander line, or "tiger mac tools: offline" | The message says why. Usually: choose Configuration → Connect Commander over SSH in Tiger Build, turn on Remote Login, or check the address and user in the relay app. `ppc-commander/bin/ppc-ssh 'echo ok'` must print `ok` |
| A service is dimmed | Add its key, or wait for its models to finish testing |
| Claude asks for `anthropic-workspace-id` | Enter the Workspace ID |

## Building, testing and packages

```bash
python3 -m unittest discover -s relay -p 'test_*.py'      # relay tests
python3 relay/chat_proxy.py --self-test
ppc-commander/bin/ppc-ssh 'cd ~/TigerBuild-build/native && make test'
ppc-commander/bin/ppc-ssh 'cd ~/ppc-commander && python ppc_commander.py --self-test'
```

| Script | Makes |
| --- | --- |
| `scripts/build-pkg.sh` | `dist/TigerBuildRelay-1.5.pkg` (macOS) |
| `scripts/build-deb.sh` | `dist/tiger-build-relay_1.5_all.deb` (Linux) |
| `scripts/build-windows.ps1` or `build-windows-zip.py` | `dist/tiger-build-relay-payload.zip` and `Install-TigerBuildRelay.cmd` (Windows) |
| `scripts/build-tiger-pkg.sh` | `dist/TigerBuild-1.5.pkg` (Tiger Build for the old Macs) |
| `scripts/build-relay-gui.sh` | the Mac relay app |

The macOS package has a universal settings app. The Windows zip and Linux package are source-based and use the platform's Python (3.8+), Tk and OpenSSH. Run setup as your own user, not as administrator. The Windows `.cmd` unpacks the files; then run the setup command it shows. `/health` reports the version.  The macOS relay application uses Swift UI for prettiness, the Linux and Windows versions have their GUI built from Python which is uglyier looking. (Linux and Windows relay support is primarily provided as a courteousy and aren't my primary focus)

## Why Do This?

This is just a project for fun.  I saw people creating similar chat environments for older operating systems like Windows 95 and decided to give this a try myself.  As far as I can tell at the time of writing, this is the only LLM chat app for PowerPC Mac OS X that supports interaction with the system itself and is not just a chat interface only.  This app was made with heavy LLM support from Grok Build and Claude Code (with a little bit of ChatGPT) for fun so don't expect perfection.  However, I think it's actually a decently cromulent LLM chat build environment.  Don't expect any future updates or support for this.  I might add some but no promises.  Feel free to suggest improvements.  As stated above, Mac OS X Tiger is a very old operating system with security vulnerabilities, use at your own risk.
