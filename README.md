# Tiger Build

**A native AI chat app for Mac OS X 10.4 Tiger, 10.5 Leopard and 10.6 Snow Leopard, on PowerPC and Intel, that can also work on the Mac it runs on.**

Tiger Build is a Cocoa chat window for old Macs. Each chat picks its own service and model: Grok, ChatGPT, Claude, Mistral, Muse, Gemini, or a model on your own local server such as LM Studio. Turn on **Commander** (ppc-commander) for a chat and the model can list folders, read and edit files, run shell commands, and take screenshots on that Mac, much like Desktop Commander does on modern systems. Tiger Build reads the Mac's model and OS version from the system, so it works on any Mac it supports. It keeps its brushed-metal look on Tiger and uses the same layout on Leopard and Snow Leopard, and everything fits a 1024x768 screen (iMac G3 and up).

> [!WARNING]
> USE THIS AT YOUR OWN RISK. MAC OS X TIGER IS A 20+ YEAR OLD OPERATING SYSTEM AND IS VERY INSECURE. I AM NOT LIABLE FOR ANY SECURITY VULNERABILITIES ABLE TO BE EXPLOITED FROM USING THIS APPLICATION ON TIGER. YOU HAVE BEEN WARNED.

Tiger Build is licensed under the MIT License and comes with no warranty. See [`LICENSE`](LICENSE).

## Screenshots

**The client**, on Mac OS X 10.4 Tiger (PowerPC, brushed metal), 10.5 Leopard (Intel) and 10.6 Snow Leopard (Intel):

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

## How it fits together

Tiger cannot open modern HTTPS connections, so Tiger Build never calls an AI service itself. **Tiger Build Relay** runs on a current Mac on the same network. It receives each chat over plain HTTP (protected by a token), calls the AI service, and, when the model wants a tool, runs ppc-commander on the Tiger Mac over SSH.

```
 Tiger Mac (10.4, PowerPC)                  Relay (Mac, Windows, or Linux)
 ┌──────────────────────┐   HTTP + token    ┌───────────────────────────┐   HTTPS   ┌──────────────────┐
 │ Tiger Build.app      │ ────────────────▶ │ Tiger Build Relay         │ ────────▶ │ AI services      │
 │ chats, workspaces    │                   │ keys, model checks, tools │           └──────────────────┘
 └──────────────────────┘                   │                           │   HTTP    ┌──────────────────┐
 ┌──────────────────────┐   SSH (ssh-rsa)   │                           │ ────────▶ │ local server     │
 │ ~/ppc-commander/     │ ◀──────────────── │ runs tools when asked     │           │ (optional)       │
 └──────────────────────┘                   └───────────────────────────┘           └──────────────────┘
```

Chats stay on the Tiger Mac. API keys stay on the relay computer; Tiger Build is only told whether each key is saved.

## What you need

| Where | What |
| --- | --- |
| Client Mac | Any Mac running Mac OS X 10.4 Tiger, 10.5 Leopard or 10.6 Snow Leopard, PowerPC or Intel, with its built-in Python (2.3, 2.5 or 2.6), and Remote Login on (System Preferences → Sharing). To build the app yourself: Xcode 2.5 on Tiger (32-bit `ppc` and `i386` from the 10.4 SDK), or Xcode 3.1/3.2 on Leopard and Snow Leopard, which also build 64-bit `ppc64` and `x86_64` from the 10.5 SDK. The app is one universal binary; a G5 on Tiger, which has no 64-bit Cocoa, uses its 32-bit part |
| Relay computer | A Mac, Windows PC, or Linux computer that meets the minimums in [Relay system requirements](#relay-system-requirements) |
| Network | The Tiger Mac and the relay computer on the same network, and the Tiger Mac able to reach the relay directly |
| Optional | API keys for any of xAI, OpenAI, Anthropic, Mistral, Muse and Google, optionally a Brave or Tavily key for better web search (search works without one), and/or a local OpenAI-compatible server. One key is enough; none is fine with only a local server |

### Relay system requirements

The relay's SSH settings need an OpenSSH client of 9.1 or later, because it enforces `RequiredRSASize=2048`. That sets the operating-system minimums below. Intel/x64 and Apple Silicon/ARM64 are both supported.

| Relay computer | Minimum | Also needed |
| --- | --- | --- |
| macOS | macOS 14 Sonoma | Python 3.8 or later (Apple's command line tools provide `/usr/bin/python3`: `xcode-select --install`) |
| Windows | Windows 11 version 24H2 | Python 3.8 or later from python.org, with Tk (the default install includes it). ARM64 PCs can use native ARM64 Python (3.11 or later) or x64 Python |
| Linux | Ubuntu 24.04 or Debian 12 for the `.deb`; other systemd distributions with the same parts can run `scripts/setup.py` | Python 3.8 or later, `python3-tk`, OpenSSH client 9.1 or later |

Older systems ship an older OpenSSH client, and the relay cannot reach the Tiger Mac with it. Tested: macOS with OpenSSH 10.3, Windows 11 25H2 (ARM64) with OpenSSH 9.5, Ubuntu 26.04 (ARM64) with OpenSSH 10.2.

You need two pieces of information: the **Tiger Mac's IP address** (System Preferences → Network on that Mac) and the **short user name** of the account on it that will run ppc-commander.

## Setup

All commands run on the **relay Mac**, from a checkout of this repository. Replace `TIGERUSER` and `TIGER.MAC.ADDRESS` with your own values.

> [!TIP]
> In 1.3 you can skip steps 1–3. Run `./scripts/setup.sh` (step 4) and then, on the Tiger Mac, open Tiger Build and choose **Configuration → Connect Commander over SSH**. It adds the relay's key to that Mac and tells the relay its address and user name; no password is typed. The steps below remain the manual way, and `setup.sh` run from a terminal can also install the key for you if you set `TIGER_HOST` and `TIGER_USER` first.

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

This copies ppc-commander to `~/ppc-commander`, builds Tiger Build there with `make test` and `make`, puts it on that account's desktop, and fills in the relay address and token. Add `TIGER_SUDO_POLICY=1` to also install the optional root-owned `/etc/ppc-commander.json` policy.

Without the script, open **Tiger Build → Preferences**, enter the relay address, port and token from step 4, and click **Test Connection**. For setup from the installer packages, see [`RELEASE.txt`](RELEASE.txt).

## Where settings are kept

### Relay computer

The settings folder is **`~/Library/Application Support/Tiger Build Relay/`** on macOS, **`%APPDATA%\Tiger Build Relay`** on Windows, and **`~/.local/share/tiger-build-relay`** on Linux. Set `TIGERBUILD_RELAY_HOME` to use another folder. After the Mac package, open **Tiger Build Relay** in `/Applications`. On Windows, open it from the Start menu. On Linux, open it from the application menu. **Show Folder** opens the settings folder. A checkout's `setup.sh` uses `~/Applications` until the package is installed.

| File | Contents |
| --- | --- |
| `config.sh` | Tiger Mac address and user (also editable in the relay app's Tiger Mac settings or in Tiger Build's Preferences, Commander), SSH key paths, relay port, optional `LISTEN_ADDR`, `ALLOWED_CLIENTS`, `RELAY_TOKEN`, `TIGER_HOME` (override path: `TIGERBUILD_RELAY_CONFIG`) |
| `pricing-cache.json` | Model prices used for the cost estimate, fetched when the relay starts and then daily; the last copy is kept so costs work offline |
| `providers.json` | API keys, Anthropic workspace ID, local LLM server address and key (mode 600) |
| `integrations.json` | Tool switches, Brave/Tavily keys and choice, Claude thinking, custom MCP servers (mode 600) |
| `relay-token` | The shared token Tiger Build must send (mode 600) |
| `models-cache.json` | Results of the model tests |
| `ssh-clients.json` | Which account the relay signs in as for each Tiger Build computer that has connected |
| `last-client.json` | The last Tiger Mac seen: address, model, OS, user |
| `relay.log` | Relay log |
| `history/TigerBuild-history.plist` | History snapshot copied from Tiger Build |
| `agent-notes.txt` | Agent toolbox scratch notes |
| `media/` | Generated images and videos |
| `service.plist` | The relay's launchd job while start-at-login is off |
| `app/` | The installed relay code; `app/.env` optionally seeds API keys |

Start at login is a launchd agent on macOS (`~/Library/LaunchAgents/local.tigerbuild.relay.plist`), a scheduled task named Tiger Build Relay on Windows (or, when Windows will not create that task without elevation, a `Tiger Build Relay` shortcut in the Startup folder), and a systemd user service (`local.tigerbuild.relay.service`) on Linux. Stop stops the running relay. Turning start-at-login off does not stop it. SSH files are `~/.ssh/ppc_tiger_rsa` and `~/.ssh/ppc_tiger_known_hosts` (on Windows, under `%USERPROFILE%\.ssh`). The Mac package installs the app in `/Applications`. Windows adds a Start menu shortcut. Linux adds an application-menu entry. Program files go to `/usr/local/tiger-build-relay`, `/opt/tiger-build-relay`, or `%LOCALAPPDATA%\Tiger Build Relay\package`. Settings stay in the folders above.

### Tiger Mac

The settings folder is **`~/Library/Application Support/Tiger Build/`**.

| File | Contents |
| --- | --- |
| `server.txt` | Relay address and port |
| `token.txt` | Relay token (mode 600) |
| `chats.plist` | Chats in the Default workspace, with that workspace's settings (directory restriction, last-used model and tools) |
| `workspaces/<name>.plist` | The same for each other workspace |
| `models.txt` | The model list last received from the relay |
| `media/` | Downloaded images and videos |
| `history-before-import-*.plist` | Backups made before a history import |
| `commander/` | ppc-commander on/off state |

Elsewhere on the Tiger Mac: `~/Library/Preferences/local.tigerbuild.TigerBuild.plist` (window, sidebar width, current workspace), `~/Library/LaunchAgents/local.tigerbuild.commander.plist` (Commander at login), `~/ppc-commander/` (`ppc_commander.py`, `service.py`, `config.json`, `tool-history.jsonl`, `usage.json`), `/etc/ppc-commander.json` (optional policy), `~/.ssh/authorized_keys` (the relay's public key), `~/TigerBuild-build/native/` (build folder used by `install-tiger.sh`), and the app itself on the desktop or in `/Applications`.

## Using Tiger Build

- **Chats and workspaces.** The popup at the top of the sidebar picks a workspace (project); each has its own chats. Workspace → New Workspace (⌘⇧N) makes one, Delete Workspace removes one (deleting the last one starts a new empty Default), and Workspace Directory Restriction can restrict Commander to one directory. API keys and tools are shared. Clear All History in the History menu deletes every chat and every workspace.
- **Models.** The popups under the chat list pick the service and model. A new chat starts with the model, tool switches and approval choices of the chat used last in that workspace, or with one fixed model if you choose that in Preferences, New Chats. Services with no key or no working models are dimmed with the reason.
- **Tools.** The **Tools** button under the chat list switches each tool on or off for the chat: Commander, the agent toolbox, web search, other models (see below) and every custom MCP server. **Ask Before Running** makes the model wait for your answer before it runs a tool, for all tools or for chosen ones, and "Always Allow" in the question turns it off for that tool in that chat. The choices are remembered per chat. Each tool call shows as a card; click it to see the command and its output.
- **Stop and guidance.** **Stop** (⌘.) ends a running reply at once, even in the middle of a long command. While a model works with tools, **Send** becomes **Guide** (its dot blinks while the model runs): a note typed then is delivered to the model between steps, never in the middle of a command. If the reply ends first, the note goes back into the message box. Guidance is offered for Grok, ChatGPT, Claude, Gemini and Mistral.
- **Attach files.** **Attach...** (next to Edit Last and Retry, or Chat → Attach File, ⇧⌘A) adds files to the chat; you can also drop them on the chat window or on the Dock icon. Text and code files, PDFs, RTF and HTML are read on the Mac itself (text up to about 300 KB each). **Word, Excel and PowerPoint (.docx .xlsx .pptx), Pages, Numbers and Keynote files, OpenDocument files, and HEIC, WebP and AVIF pictures** cannot be read on these Macs, so Tiger Build sends them to the relay, which returns their text (slide by slide, sheet by sheet) and JPEG pictures (the preview of a Pages, Numbers or Keynote file, the first slide of a PowerPoint). Pictures are shrunk to 1600 pixels and sent to models that can see them; phone photos stored sideways are turned upright. The relay needs no extra software for documents; for HEIC and WebP it uses `sips` on a Mac, or Pillow (with pillow-heif), `heif-convert` (Ubuntu package `libheif-examples`) or ImageMagick elsewhere. Old .xls, .ppt and .pages from before 2013 are only partly readable; save them as .xlsx or .pptx. Each file appears in the chat as "Attached: name", and the model can use it for the rest of the conversation. Files are read one at a time with a "Reading..." note, so the window stays usable. You can also paste a picture from the clipboard (a screenshot) or files copied in the Finder into the message box. The first time you attach for a service, Tiger Build says the files will be sent to that service. If a file would not fit the model's context (a local model with a small window, say), Tiger Build says so and offers to attach a shortened copy. A copy of each file is kept in Application Support, and the model is told where (with `~` for your home folder, and nothing when the workspace is restricted to another folder), so with Commander it can also run or edit the file. A PDF that is mostly drawings or a scan (little text for its pages) is also sent as pictures of its first three pages; **Chat → Attach PDF Pages** (⇧⌘P) adds any pages you name (for example `7, 10-12`). Files kept for chats you delete are cleaned up. Pictures are re-sent with each message only for the last six attached, and the oldest are dropped first if the total would be too big for the relay.
- **Files from the model.** When you ask for a file (a script, a document, a changed version of an attachment), the model hands it over with the `agent_save_file` tool and it appears in the chat with a **Save As...** button. Every code block also has **Save** and **Copy** in its header. A name ending in `.docx`, `.xlsx` or `.pdf` makes a real Word, Excel or PDF file from the model's plain text (headings, bullets, **bold** and tables for Word and PDF; rows of tab or comma separated cells for Excel), and the model can also give any file as base64 (up to 8 MB). A picture a tool looks at, such as `view_image` or a screenshot, is shown in the chat too.
- **Code blocks.** Code in a reply is shown in a dark panel that names the language and colours keywords, strings, comments and numbers (Python, JavaScript, TypeScript, C, C++, Objective-C, Java, Kotlin, Swift, Go, Rust, Ruby, PHP, shell, SQL, JSON, YAML, HTML, XML, CSS and more). Replies also show **bold**, *italics*, `inline code`, headings, bullets, links (click to open) and tables, which are laid out in a fixed-width panel with Save (tab separated) and Copy. Long code lines wrap rather than scroll.
- **One chat to a file.** Chat → Export This Chat (⌥⌘E) saves the selected chat as a Tiger Build file that carries its attachments and pictures (import it again with Chat → Import Chat, ⌥⌘I, into any workspace on any Mac), or as Markdown or plain text to read. This is a manual copy and does not use the relay. History → Export All History also carries every attachment inside the file; the copy kept on the relay and the backup made before an import hold references only.
- **Edit and retry.** **Retry** sends your last message again and replaces the reply. **Edit Last** takes the last message back into the message box to change; Cancel Edit (or Escape) puts everything back. Files attached after that message stay. Right-click any message for **Edit From Here** (your own messages) and **Branch Chat From Here**, which copies the chat up to that point into a new chat.
- **Voice (optional, off until you switch it on).** Chat → Voice has **Speak Last Reply** (⌥⌘S), **Stop Speaking** (⌥⌘.), **Speak Replies Automatically** (⇧⌥⌘J), **Voice Commands** (⌥⌘G) and **Choose Voice...** (⌥⌘V). Replies are read with the Mac's own speech voices (Tiger and later; the better "Alex" voice needs 10.5). Code and tables are not read out (the voice says there is one), links are spoken as their words, and a very long reply is read in the first part only. Sending a message or pressing Stop stops the speech. Voice Commands listens, only while Tiger Build is in front, for five phrases: "Send message", "Stop", "New chat", "Read that again" and "Stop talking". Mac OS X before 10.8 has no dictation, only recognition of a fixed list of phrases, so you still type what you say to the model. Nothing here is active unless you turn it on, and the settings are remembered.
- **Find in Chats** (⌘F) searches every chat in the workspace and jumps to the message. **Custom Instructions** (⌥⌘T) tells the model how to answer in this chat, and optionally in every new chat in the workspace. **View → Bigger Text, Smaller Text, Normal Text Size** (⌥⌘=, ⌥⌘-, ⌥⌘0) change the size of the text in chats, the chat list and the message box (the popups and buttons keep the system size). Controls and messages are labelled for VoiceOver (a message says who spoke and whether it holds code or a file), and **Chat → Copy Last Code Block** (⇧⌘C) copies code without clicking the panel's Copy label; VoiceOver has not been run on these Macs, only the labels checked with `TigerBuild --list-accessibility`. A long reply is saved every few seconds as it arrives.
- **Thinking.** "Show model thinking" is on by default (Tools settings). Returned reasoning appears in its own card, and the latest of it stays visible just above the message box while the model runs, so it does not scroll away. It is shown for Claude, ChatGPT reasoning models (o-series, GPT-5 and 6; asked through the Responses API, which returns summaries), Grok, Gemini, Mistral Magistral and local reasoning models. A model shows nothing when it chose not to reason about that question, and non-reasoning models (for example GPT-4.1) have nothing to show.
- **Cost and context.** The line above the chat shows the context in use and a running **estimated cost** of the chat, summed over every model it used (hover it for the breakdown). Rates come from a public price list the relay fetches, including the higher rates some services charge for very large prompts. Local models show N/A. It is an estimate, not an invoice. When a chat's context fills, it is summarized (also Chat, Compact Chat Now), and long tool runs trim old output to stay inside the window. A reply that hits the model's output limit ends with a note instead of an error.
- **Source control.** Commander has `repo_info`, `git_read`, `git_write`, `svn_read` and `svn_write`, so a model can check a folder's repository, read status, diffs and logs, and make commits the way Claude Code does. The programs are the ones on that Mac: Subversion comes with Mac OS X 10.5 and later (1.4 on Leopard, 1.6 on Snow Leopard), and git is not part of Mac OS X before Lion, so on these Macs install it yourself (for example from MacPorts) and the tools find it; if it is missing, the model is told how. Nothing goes through a shell. Only listed sub-commands run; read and write are separate tools, and the read tools (and `repo_info`) never ask for approval, while the write tools follow your Ask Before Running setting, which is on by default in chats with attached files. Refused outright: force pushes, deleting remote branches, skipping hooks, `git config` outside a short safe list, passwords on the command line, options that run another program, interactive rebase and commits without `-m`. Paths must stay inside the workspace's allowed directories. A diff or commit shows its totals on the tool card, for example `svn_read - Completed  2 files  +3  −0`; expand the card for the full diff. A repository you did not make can contain hooks or filters that run code, as with any source control tool, so use it on repositories you trust. Tested for real with Subversion 1.4 and 1.6; git was tested with a stand-in program (the exact arguments and environment it receives), because none of the test Macs has git.
- **Screenshots.** Commander has a `take_screenshot` tool; a model that can see pictures uses it to look at the Mac's screen (someone must be logged in at its console). It also has `view_image`, which shrinks a picture file on that Mac (JPEG, PNG, GIF, TIFF, BMP, PDF first page, icns) to a JPEG so a model that can see pictures can answer questions about it; models without vision are not offered either tool.
- **Ask other models.** When switched on for a chat, the model can ask any other working model for a second opinion with `consult_model`. The other model's usage is counted in the chat's cost.
- **Commander runs on the Mac you chat from.** The relay keeps one SSH link per Tiger Build computer (`ssh-clients.json`), so a MacBook and a Power Mac using the same relay each get their own files, shell and screenshots. A computer that has not chosen Configuration, Connect Commander over SSH gets no Commander, and says so, rather than silently using another Mac. Tiger Build offers to connect when it sees this. Several windows, and several computers, can work at once: windows share one copy of each workspace's chats (a chat that is working in one window cannot be sent to from another), each window has its own workspace, and the relay handles each request separately, limiting simultaneous SSH logins to one Mac so an old sshd is not overwhelmed. A burst of 24 simultaneous chats was tested; the only failures were a local LLM server refusing that many parallel generations.
- **Tool steps.** A reply may use up to 40 tool steps (set 1 to 200 under Tools settings, Most tool steps in one reply). At the limit the relay stops it and says so; say "continue" to go on.
- **Relay and Commander status.** A red line at the top of the chat says when the relay cannot be reached, rejects the token, or does not accept this Mac's address. An orange one says why Commander cannot run, for example that SSH cannot sign in, Remote Login is off, or the host key changed, with the fix. During a long run the relay sends heartbeats, so a slow command never looks like a lost connection.
- **Commander menu.** Start, Stop and Start at Login for ppc-commander as a standalone service, and this Mac's model, OS and IP addresses. The status line shows On or Off.
- **History menu.** Export, import and clear the history of **all workspaces at once**, or copy it to and from the relay Mac. Files from 1.2 (one workspace) still import, into the current workspace.
- **Configuration menu.** MCP servers and agent tools, Connect Commander over SSH, and export/import of all settings.

Every menu command has a keyboard shortcut, shown in the menu.

## Tiger Build Relay app

The Mac app and the Windows and Linux settings windows show the same things: whether the relay is running, its address, port and token, the Tiger Mac, start and stop, start at login, API keys, and the local server. Closing the window leaves the relay running. They also list the **Connected Macs**: each Mac that chats through the relay with its account, home folder and where its tools run, with Add, Save and Test, Test and Remove. Everything needed to connect a Mac can be done from these windows, from Tiger Build's own Preferences (Commander tab: Connect, Test, Forget Host Key, Disconnect), or by choosing Configuration, Connect Commander over SSH in Tiger Build.

From Terminal, without opening a window:

```bash
"/Applications/Tiger Build Relay.app/Contents/MacOS/TigerBuildRelay" --start
"/Applications/Tiger Build Relay.app/Contents/MacOS/TigerBuildRelay" --stop
```

`python3 "$HOME/Library/Application Support/Tiger Build Relay/app/relay/control.py" status|start|stop` does the same without the app.

## Models, tools and search

- **Live model list.** At start and every six hours the relay asks each service that has a key for its models, drops non-chat models, and sends each a tiny test request with a tool. Only models that pass are offered. Changing a key retests that service.
- **Local LLM server.** None is assumed. The address is as seen from the relay computer, and it is not the relay's own address. LM Studio on the relay computer is usually `http://127.0.0.1:1234/v1`. LM Studio on another computer is that computer's address, for example `http://10.0.1.105:1234/v1`.
- **Custom MCP servers.** Add stdio servers (absolute program path, arguments, environment) in the MCP Servers tab of the tools panel of either app; double-click a server to edit it. Each can be switched on, and set to ask first. They run on the relay Mac and start disabled; enable only programs you trust. `relay/http_mcp.py` bridges Streamable HTTP servers.
- **Example MCP servers.** `mcp-examples/` has three small servers to try the custom-server feature, in Python 3 with no dependencies: `mcp_calc.py` (exact arithmetic and unit conversion), `mcp_notes.py` (a notebook the model can write to; add it with "Ask first" on to see approvals) and `mcp_sysinfo.py` (host facts, plus `slow_task` and `always_fails` for testing Stop and errors). In the MCP Servers tab choose Add, set the program to your Python 3 (for example `/usr/local/bin/python3`) and the argument to the full path of the script. The official reference servers also work: for example program `/path/to/npx` with arguments `-y|@modelcontextprotocol/server-filesystem|/some/folder`, and environment `PATH=/path/to/node/bin:/usr/bin:/bin` (or `uvx` with `mcp-server-time`). They run on the relay computer.
- **Agent toolbox.** Optional UTC time and scratch-note tools.
- **Web search and pictures.** Search runs on the relay computer, not on the Mac in front of you. It works with no key (DuckDuckGo, with Wikipedia as a fallback); a Brave or Tavily key gives broader results, and a refused key falls back to the free search. Models can also look for pictures (Brave or Tavily when keyed, otherwise Wikimedia Commons) and show them in the chat: the relay downloads the picture, so the old Macs never need to reach the web. Several pictures appear as separate messages. The relay only fetches public web addresses. Grok uses its own native search while that switch is on.
- **Claude thinking.** Optional. Signed thinking blocks are passed back unchanged during tool use, as Anthropic requires; signatures are never shown.
- **Settings backups.** Export/Import All Settings in either app. Backups contain API keys and the token in plain text, so keep them private. Imported MCP servers stay disabled.

## Security

- File conversion (`/v1/extract`) reads files from your own Macs but refuses entity definitions in XML, parts that unpack to more than 64 MB, and archives over 400 MB, and runs two conversions at a time. The relay deletes the files it hands to clients after three days.
- Every request except `/health` needs the relay token, and only the Tiger Mac and the relay computer may connect. The relay listens on one network address, not all of them.
- SSH uses the strongest settings Tiger's OpenSSH 5.1 supports.
- A model cannot change ppc-commander's blocked commands, allowed folders or shell, or edit ppc-commander's own files.
- With tools on, a model runs shell commands as the Tiger Mac account. The guards stop mistakes and simple tricks, not a determined attacker. Use a separate account for real separation.

## Encrypting the connection to the relay

The relay speaks plain HTTP on your network, so chats, attached files and the token cross it unencrypted (Tiger cannot do modern TLS). On a network you do not fully trust, send it through SSH. Tiger's old SSH cannot sign in to a modern SSH server, so the relay computer opens the tunnel instead, the same way it already reaches Commander:

```bash
scripts/relay-tunnel.sh TIGER-ADDRESS [USER]
```

Leave that running on the relay computer (it reconnects if the link drops), then set the relay address in Tiger Build Preferences on that Mac to `http://127.0.0.1:8765`. It uses the relay's own SSH key, which Commander setup has already put on the Tiger Mac, and Remote Login must be on there. A tunnelled Mac tells the relay which Mac it is with an `X-TigerBuild-Client` header, which the relay believes only for connections from the relay computer itself and only for allowed addresses, so Commander still goes to the right Mac.

## Troubleshooting

| You see | Try |
| --- | --- |
| "Cannot reach the relay" | Check the address and port in Preferences; on the relay Mac run `curl http://ADDRESS:PORT/health`; allow Python in the macOS firewall |
| "The relay rejected the token" | Copy the token from the relay app into Preferences, or run `install-tiger.sh` again |
| "does not accept this Mac's address" | Add the Tiger Mac's address to `ALLOWED_CLIENTS` in `config.sh`, then run `setup.sh` |
| "tiger mac tools: offline" in `/health`, or the orange Commander line | The message says why. Usually: on the Tiger Mac choose Configuration → Connect Commander over SSH in Tiger Build; turn on Remote Login; or check the address and user in the relay app. `ppc-commander/bin/ppc-ssh 'echo ok'` must print `ok` |
| A service is dimmed | Add its key, or wait for its models to finish testing |
| Claude asks for `anthropic-workspace-id` | Enter the Workspace ID |

## Building, testing and packages

```bash
python3 -m unittest discover -s relay -p 'test_*.py'      # relay tests
python3 relay/chat_proxy.py --self-test
ppc-commander/bin/ppc-ssh 'cd ~/TigerBuild-build/native && make test'
ppc-commander/bin/ppc-ssh 'cd ~/ppc-commander && python ppc_commander.py --self-test'
```

`scripts/build-pkg.sh` makes `dist/TigerBuildRelay-1.4.pkg` (macOS, `/usr/local/tiger-build-relay`). `scripts/build-deb.sh` makes `dist/tiger-build-relay_1.4_all.deb` (Linux, `/opt/tiger-build-relay`). `scripts/build-windows.ps1`, or `python3 scripts/build-windows-zip.py` on a Mac, makes `dist/tiger-build-relay-payload.zip` and `Install-TigerBuildRelay.cmd` (Windows; not an exe installer). `scripts/build-tiger-pkg.sh` makes `dist/TigerBuild-1.4.pkg` for Tiger. `scripts/build-relay-gui.sh` rebuilds the Mac relay app. `/health` reports `version: 1.4`.

The macOS package includes a universal Intel/Apple Silicon settings app. The Windows zip and Linux `Architecture: all` package are source-based and work with the platform's own Python (3.8+), Tk, and OpenSSH; they do not bundle a CPU-specific Python. ARM64 has been runtime-tested; x64 support has been checked in the source and package contents, but not yet tested on an x64 machine. Run setup as your own user, not as administrator/root. The Windows `.cmd` unpacks the files; then run the setup command it displays to create the Start menu shortcut.

## Upgrading from Tiger Desk

The relay used to be called Tiger Desk. Running `scripts/setup.sh` stops it, moves `~/Library/Application Support/TigerDesk` to `Tiger Build Relay` (keys, token and history included), rewrites the launchd job, and replaces `Tiger Desk.app` with `Tiger Build Relay.app`. Tiger Build keeps working with the same token. Old settings backups still import, and Tiger Build carries its preferences over from the old `local.jr.tigerbuild` identifier.

## Why Do This?

This is just a project for fun.  I saw people creating similar chat environments for older operating systems like Windows 95 and decided to give this a try myself.  As far as I can tell at the time of writing, this is the only LLM chat app for PowerPC Mac OS X that supports interaction with the system itself and is not just a chat interface only.  This app was made with heavy LLM support from Grok Build for fun so don't expect perfection.  However, I think it's actually a decently cromulent LLM chat build environment.  Don't expect any future updates or support for this.  I might add some but no promises.  Feel free to suggest improvements.  As stated above, Mac OS X Tiger is a very old operating system with security vulnerabilities, use at your own risk.
