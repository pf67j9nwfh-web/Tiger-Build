# Tiger Build

**A native AI chat app for Mac OS X 10.4 Tiger, 10.5 Leopard and 10.6 Snow Leopard for PowerPC and Intel.**

Tiger Build is a Cocoa chat window for old Macs. It talks to the AI services directly, over TLS 1.3 and 1.2 that it brings with it, so **no other computer is needed**. It has support for a broad range of providers including: Grok, ChatGPT, Claude, Mistral, Muse, Gemini, and local LLM servers. With **Commander** on (a small native program inside the app), the model can list folders, read and edit files, run shell commands, use git and Subversion, and take screenshots on that Mac. Commander is a plain MCP server, so modern programs such as Claude Desktop and Claude Code can use an old Mac through it too, with no API key or model setup on the old Mac (see [Using Commander from Claude Desktop, Claude Code and other programs](#using-commander-from-claude-desktop-claude-code-and-other-programs)). Tiger Build is also designed to look right at home on these older Macs
and uses a UI that is mostly period accurate for the OSes it's operating on. It's almost like a glance into an alternate reality where the
LLM revolution occured around 2009 instead of the 2020s.

> [!WARNING]
> USE THIS AT YOUR OWN RISK. MAC OS X TIGER, LEOPARD, AND SNOW LEOPARD ARE A 15+ YEAR OLD OPERATING SYSTEMS AND ARE VERY INSECURE. I AM NOT LIABLE FOR ANY SECURITY VULNERABILITIES ABLE TO BE EXPLOITED FROM USING THIS APPLICATION ON THESE MACHINES. YOU HAVE BEEN WARNED. SAFEGUARDS HAVE BEEN INCLUDED THOUGH AS MUCH AS IS FEASIBLE WITHIN THE CONFINES OF THE LIMITATIONS OF ITS OPERATING ENVIRONMENT.

Tiger Build is licensed under the MIT License and comes with no warranty. See [`LICENSE`](LICENSE). Secure connections use [Mbed TLS](https://github.com/Mbed-TLS/mbedtls) (Apache-2.0) and the Mozilla CA certificate list (MPL-2.0); WebP pictures use [libwebp](https://chromium.googlesource.com/webm/libwebp) (BSD-3-Clause), AVIF pictures use the decoder of [libaom](https://aomedia.googlesource.com/aom/) (BSD-2-Clause with a patent grant), JPEG XL pictures use [jxldec](https://github.com/kjk/jxldec) (MIT, indirectly inferred; see `third_party/jxldec`), SVG pictures are drawn by [NanoSVG](https://github.com/memononen/nanosvg) (zlib licence; see `third_party/nanosvg`), and HEIC pictures use [libde265](https://github.com/strukturag/libde265) (LGPL-3.0, built as a separate library in `Contents/Frameworks` so it can be replaced). The bundled SSH tools are [OpenSSH](https://www.openssh.com/) (BSD-style) with [LibreSSL](https://www.libressl.org/)'s libcrypto (ISC and the OpenSSL/SSLeay licences), SMB file sharing and the SMB tools use [libsmb2](https://github.com/sahlberg/libsmb2) (LGPL-2.1 or later, linked statically with a few changes; its source, patch and rebuild scripts are in `third_party/libsmb2`, so it can be replaced), and `sshfs` is [sshfs 2.2](https://github.com/libfuse/sshfs) with glib (GPL-2.0 and LGPL-2.1; source and patch are in `third_party/sshfs`). The emoji pictures are [Twemoji](https://github.com/jdecked/twemoji), copyright Twitter, Inc. and other contributors, under [CC-BY 4.0](tiger-build/Emoji-LICENSE.txt).

## Screenshots

**The client**, on Mac OS X 10.4 Tiger, 10.5 Leopard, and 10.6 Snow Leopard:

| Tiger | Leopard | Snow Leopard |
| --- | --- | --- |
| ![Tiger Build on Tiger: an attached file, a diff, Python code and a table, and a file to save](docs/screenshots/client-tiger-chat.png) | ![The same chat on Leopard](docs/screenshots/client-leopard-chat.png) | ![The same chat on Snow Leopard](docs/screenshots/client-snowleopard-chat.png) |

**Asking before a tool runs, with the model's thinking shown above the message box while it works** (Stop and Guide replace Send while a reply runs), and **the Tools menu**, which switches each tool on or off for the chat:

| Approval and live thinking | Tools menu |
| --- | --- |
| ![The approval question for a notebook tool, with the live thinking strip](docs/screenshots/client-approval.png) | ![The Tools menu: Commander and every MCP server, Ask Before Running, and settings](docs/screenshots/client-tools-menu.png) |

**Preferences** are in tabs so they fit a 800x600 screen (iBook G3 Clamshell), and **MCP servers** are a list with an edit sheet:

| Commander | Local LLM | Alerts | MCP servers |
| --- | --- | --- | --- |
| ![Preferences, Commander tab](docs/screenshots/client-preferences-commander.png) | ![Preferences, Local LLM tab](docs/screenshots/client-preferences-llm.png) | ![Preferences, Alerts tab](docs/screenshots/client-preferences-alerts.png) | ![MCP Servers tab](docs/screenshots/client-mcp-servers.png) |

**Appearance** (Tiger Build menu) changes the chat, tool-call boxes, status text and interface, and the window look (brushed metal, gray, pinstripes, gradient or a solid colour), with a live sample on top:

![Appearance, Interface tab](docs/screenshots/client-appearance.png)

*Screenshots use example addresses, accounts and servers.*

## Contents

- [Screenshots](#screenshots)
- [How it works](#how-it-works)
- [What you need](#what-you-need)
- [Setup](#setup)
- [Where settings are kept](#configuration-and-setting-file-locations-and-content)
- [Using Tiger Build](#using-tiger-build)
- [Using Commander from Claude Desktop, Claude Code and other programs](#using-commander-from-claude-desktop-claude-code-and-other-programs)
- [Models, tools and search](#models-tools-and-search)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Building, testing and packages](#building-testing-and-packages)
- [Why Do This?](#why-do-this)

## How it works

Tiger Build does everything itself. Tiger and the Leopards cannot open modern HTTPS connections, so it carries its own TLS (Mbed TLS 3.6 with the Mozilla certificate list), tested on PowerPC and Intel from Tiger to Snow Leopard. The app calls each AI service, runs the tool loop, converts attached files, transcribes speech, makes pictures (Grok, ChatGPT, Gemini, Muse) and videos (Grok and Gemini; OpenAI closed its video API in September 2026), and starts Commander (and any MCP servers you add) when a chat needs them. There is no Python and no service to switch on. The basic operation can be seen in the diagram below:

```
 Your Mac (10.4 to 10.6, PowerPC or Intel)
 ┌──────────────────────────────────────────────┐   TLS 1.3 / 1.2   ┌──────────────────────┐
 │ Tiger Build                                  │ ────────────────▶ │ AI services          │
 │  chats, tool loop, keys (Keychain), file     │                   │ (the ones you have   │
 │  conversion, dictation, MCP client           │   HTTP            │  keys for)           │
 │                                              │ ────────────────▶ │ Local LLM server     │
 │                                              │                   │ (if configured)      │
 │  ┌──────────────────────┐                    │                   └──────────────────────┘
 │  │ Commander (in the    │ ◀─ starts with a   │   SSH (optional)  ┌──────────────────────┐
 │  │ app), local only     │    chat that uses  │ ────────────────▶ │ Another Mac running  │
 │  └──────────────────────┘    it              │                   │ Tiger Build, as an   │
 └──────────────────────────────────────────────┘                   │ MCP server           │
                                                                    └──────────────────────┘
```

Your chat history stays on the Mac. API keys are kept in that Mac's Keychain and sent only to the service they belong to.

## What you need

| Where | What |
| --- | --- |
| The Mac | Mac OS X 10.4 to 10.6, PowerPC or Intel. To build the app yourself: Xcode 2.5 on Tiger, or Xcode 3.1/3.2 on Leopard and Snow Leopard. It's generated as a universal binary that covers `ppc`, `i386`, `ppc64` and `x86_64`; ppc64 is only supported on Leopard due to OS API limitations. Newer versions of Mac OS X are theoretically supported since this app does include 64 bit Intel support. It is strongly recommended that you install the Developer Tools disc and/or the appropriate version of Xcode for your system even if you aren't compiling Tiger Build yourself, to let your agents take full advantage of your Mac's capabilities. |
| Network | Internet access to the services you use. The first connection to each service takes a moment on a PowerPC Mac (about 0.2 s for the TLS handshake on a G4). |
| Optional | API keys for SpaceXSI (Grok), OpenAI, Anthropic, Mistral, Muse, or Google (as few or as many as you want to configure), a Brave or Tavily key for better web search, a local OpenAI-compatible model server (LM Studio, Ollama), and another Mac running Tiger Build (with *Allow Other Computers* on) if you want a chat to use that Mac's files and shell too. None of these is needed to use the Mac as a tool server from Claude Desktop, Claude Code or another MCP program: see [Using Commander from Claude Desktop, Claude Code and other programs](#using-commander-from-claude-desktop-claude-code-and-other-programs). |

## Setup

**1. Install.** Open `TigerBuild-2.7.pkg` (or build it yourself, below). It installs Tiger Build in `/Applications` (Commander is inside the app) and, in `/usr/local/tbssh`, the OpenSSH tools, `sshfs` and Tiger Build's own SSH server, which stays off until you allow other computers. On Leopard and Snow Leopard it also adds a Quick Look generator. No sharing service is turned on.

**2. Add keys.** Open **Tiger Build → Preferences**. On the **API Keys** tab paste a key for each service you use, then Save. Keys go to the Keychain; Tiger Build only shows whether one is saved. For LM Studio or Ollama, enter its address on the **Local LLM** tab (it can be another computer on your network).

That's it. **Optional:** to use another Mac's files and shell from a chat, run Tiger Build there, choose Commander → Allow Other Computers, and on this Mac add it under Tool Settings → MCP Servers → Add → *Commander on another computer (SSH)* (Copy Key, Trust Host, Test).

**Building it yourself.** On the Mac, in the checkout:

```bash
cd tiger-build
make            # TigerBuild.app, with the slices your Xcode supports
make test       # unit tests
```

## Configuration and Setting File Locations and Content

Everything is on the Mac. API keys, the search keys and the custom MCP server list (which can hold tokens) and the access tokens from MCP servers you signed in to are in the **login Keychain** under "Tiger Build API keys". The rest:

**`~/Library/Application Support/Tiger Build/`**

| File | Contents |
| --- | --- |
| `chats.plist`, `workspaces/<name>.plist` | Chats and settings per workspace (including its memory notes, if you turned memory on), with `backups/` beside them |
| `attachments/`, `media/` | Attached files, and pictures, videos and files the model made |
| `ssh/` | The key and trusted host list for MCP servers on other computers, and `authorized_keys`, the public keys that may use this Mac's SSH server (only if you set those up) |
| `commander/` | Commander's settings, tool history and the files that say whether Commander is stopped or other computers are allowed |
| `notes-data.json`, `agent-notes.txt` | The example notebook server and the toolbox notes |
| `model-notes.plist`, `skills/` | The short notes about each model that auto mode uses (written by the model you chose, only while auto mode is on), and your skills |
| `history-before-import-*.plist` | Backups made before a history import |

Preferences, including the alert, update-check and spending-limit settings and today's running total, are in `~/Library/Preferences/local.tigerbuild.TigerBuild.plist`.

Note: Pricing estimates on model usage are provided as a convenience and may not always be accurate. Check the usage directly on the provider's API dashboard for the actual numbers.

## Using Tiger Build

Skip this section if you don't want an ultra detailed description of this app's functionality.

**Chats**
- **Chats work at the same time.** Start a reply in one chat, switch to another and start a reply there: both keep going in the one window, a dot in the chat list marks each working chat, and Stop, Guide and the thinking strip belong to the chat on screen. A tool question from a chat that is not on screen appears when it arrives and names its chat. Closing the window stops every running reply. (The workspace selector, History and Configuration menus wait until every reply has finished.)
- **Chat list.** Window → Hide Chat List (Command-backslash) folds the chat list away to give the chat the whole window, and shows it again; the choice is remembered. While it is hidden, the service, model and Tools pickers sit in a band across the top of the chat.
- **Workspaces.** The sidebar popup picks a workspace (project); each has its own chats. API keys and tools are shared. Workspace → Directory Restriction limits Commander's file tools to one folder and checks the paths in shell commands; the shell check is a guard against mistakes, not a sandbox, because a shell can always build a path another way. Only give Commander to models and documents you trust.
- **Chat titles.** Hover a chat to see its full title. Each service shows its own icon in the provider popup and the Model menu.
- **Memory** (optional, off by default; Workspace Settings, ⌥⌘,): while on, after each reply one more small request goes to the chat's model with the last exchange and the current notes, to keep a few lasting facts about you (your name, work, projects, how you like answers). The notes are told to the model in every chat of the workspace, and *View or Edit Memory...* shows, changes or clears them. The update is told to record only what you said, never instructions from files or web pages, and never secrets, but it is a model, so read the notes now and then.
- **Prompts.** Chat → Prompts keeps named prompts: *Save Message as Prompt...* takes what is in the message box, a prompt in the menu is put in the message box, and *Manage Prompts...* edits them. A prompt can be set to **run by itself** at a time of day (every day, weekdays or one weekday): while Tiger Build is open it then starts a new chat and sends it, with the model new chats start with.
- **Try with another model.** *Try Last Message with Another Model...* copies the chat up to your last message into a new chat beside this one, set to the service and model you pick, and sends it, so two answers can be compared.
- **Quick Ask.** *Chat → Quick Ask...* opens a small box; Return sends the question in a new chat. With the Privacy setting on, Control-Option-Space opens it from any application, and in other applications the **Services** menu (Application menu → Services → Tiger Build) works on the selected text: **Ask** puts it in a new chat's message box, **Add to Message** adds it to the open chat's message box, **Summarize** and **Explain** show the answer in a small panel (with Copy, or copy it automatically), and **Rewrite** replaces the selection with the improved text. Shortcuts: Control-Option-Command S (Summarize), E (Explain), R (Rewrite), A (Add to Message); on Snow Leopard they can be changed in System Preferences, Keyboard, Keyboard Shortcuts. If the entries are missing after an install, log out and in once.
- **Cost report.** *Chat → Cost Report...* shows the estimated cost of this workspace's chats, by model and for the most expensive chats, plus the last 7 and 30 days across all workspaces.
- **Import from ChatGPT or Claude.** *Chat → Import ChatGPT or Claude Export...* reads the conversations of the export you downloaded (the `.zip` or its `conversations.json`) and adds them as chats (text only).
- **Lock.** Preferences, Privacy: a lock password (kept as a salted hash in the Keychain). *Chat → Lock Tiger Build* covers every screen until the password is typed; it can also lock when Tiger Build starts and after 10 idle minutes in the background. It keeps casual users out; it does not encrypt the chat files.
- **Copy Diagnostics** (Tiger Build menu) puts the version, system, which services have keys (never the keys) and which features are on on the clipboard, for a bug report.
- **Models.** The popups under the chat list pick service and model. A new chat starts with the last chat's model, tools and approvals, or a fixed model chosen in Preferences. Or **auto**: in Preferences, General, *New chats start with* "Choose the best model for the first message", and pick under *Auto mode asks* which model makes the choice. When you send the first message, that model reads it and the list of models you can use (only the chat's own service when files are attached) and the chat takes the one it names; it then looks and behaves as if you had picked it. The chooser sees every model you can use, each with facts the app knows (name, pictures, context, price) and a short note that the same model writes in the background, searching the web when it needs to (15 models at a time, at most once an hour; *Update Model Notes Now* in Preferences starts a round), so the choice itself is quick. The choosing call, the notes and titles, summaries and memory updates are all counted in the chat's cost and in your spending limits (notes, which belong to no chat, only in the day's total). *Preferences, General, Show Auto in model list* (always on while auto is the default for new chats) adds **Auto** to the service list, so any chat can be set to choose its model from its first message. Changing a chat's service or model later also resets what depends on it: the context readout, and a longest answer too large for the new model. Services with no key or no working model are dimmed with the reason.
- **Stop and guidance.** Stop (⌘.) ends a reply at once, even mid-command. While a model uses tools, Send becomes **Guide**: a note typed then reaches the model between steps (Grok, ChatGPT, Claude, Gemini, Mistral, Muse and local models).
- **Edit and retry.** Retry resends your last message. Edit Last takes it back into the message box (Cancel Edit restores). Right-click any message for **Edit From Here** or **Branch Chat From Here**.
- **Appearance** (Tiger Build → Appearance, ⌥⌘K), in four tabs. **Chat**: as in iChat, the bubble colour, text colour and font for your messages and for replies, and a solid colour, gradient or picture behind the chat. **Tool Calls**: font, text colour and box colour of the cards that show each tool run. **Status Text**: font, colour and an optional shadow or glow for the words outside the bubbles ("Working on the next step..."). **Interface**: font and colours for the chat list, labels, buttons and menus, and the window's look (brushed metal, plain gray, pinstripes, a gradient or a colour). Changes show at once; Reset to Default restores the original look. Settings windows stay in front of the chat. While a reply has not started, a thought cloud with three moving dots shows, like iChat's typing indicator.
- **Find in Chats** (⌘F), **Custom Instructions** (⌥⌘T, per chat or per workspace), and **View → Bigger/Smaller Text** (⌥⌘= and ⌥⌘-).
- **Export and import.** Chat → Export This Chat (⌥⌘E) saves one chat with its files, or as Markdown, text or a PDF to read or print, or as JSON for other chat tools: a ChatGPT-style `conversations.json`, a Claude-style `conversations.json`, or LibreChat's own JSON (words only; tool cards, status lines and attachments, which are named, are left out; written to match what those tools' importers read, not tried against them) (code blocks, headings, bold and the pictures in the chat are kept); Import Chat (⌥⌘I) adds it to any workspace. History → Export All History covers every workspace; exports and import backups hold references only. Each workspace file keeps five rolling backups.

**Files and replies**
- **Attach** (button, ⇧⌘A, drag onto the chat or Dock icon, or paste). Text, code, PDF, RTF and HTML are read on the Mac. Word, Excel, PowerPoint (both the modern `.docx`, `.xlsx`, `.pptx` and the old `.doc`, `.xls`, `.ppt`), Pages, Numbers, Keynote, OpenDocument, EPUB books (title, author and text), ZIP archives (the list of files), audio and video files (see below), HEIC, WebP (animated too, up to four frames), AVIF, JPEG XL (also animated, with transparency shown on white) and SVG (`.svg`, and gzipped `.svgz`: the source as text, so the model can read and edit it, plus a picture of the drawing) are converted by Tiger Build itself (text slide by slide or sheet by sheet, plus a preview picture; Pages/Numbers/Keynote text is recovered, not exact; old Office files give text only). HEIC (iPhone photos) is decoded with libde265, which sits in the app as its own library; AVIF uses libaom's AV1 decoder, which takes a few seconds for a big picture on a G4. SVG is drawn with NanoSVG: shapes, paths, strokes, fills, gradients and transforms, and text in a standard font (position, size, colour, bold, centring and the transforms around it); filters, masks, CSS in style blocks and embedded pictures are not drawn (the source is always sent, so the model still reads those). A drawing the model writes is shown too: an SVG code block gets a *View* button (beside Copy and Save) that opens the drawing in a window, and an `.svg` file the model hands over is shown in the chat with its Save As button. JPEG XL uses [jxldec](third_party/jxldec/README.md), a plain-C decoder (about 5 seconds for 1536x1024 on a G4). BMP and TIFF pictures work too. Pictures are shrunk to 1600 pixels and sent to models that can see them; sideways phone photos are turned upright.
  - A PDF that is mostly drawings or a scan also sends its first three pages as pictures; Chat → Attach PDF Pages (⇧⌘P) adds pages you name, such as `7, 10-12`.
  - The first attach for each service explains the files go to that service. A file too big for the model's context is offered shortened. Stop cancels a read in progress.
  - Copies are kept in Application Support and the model is told where, so Commander can use them. Only the last six pictures are re-sent.
- **Audio and video.** Attach an audio file (mp3, m4a, aac, wav, aiff, caf and others) and it is transcribed in pieces of three minutes (the first 30 minutes) by the same speech-to-text service as dictation (OpenAI, Mistral or Google, whichever has a key), with times; the model gets the words. A video (mov, mp4, m4v, mpg, 3gp, avi) gives four pictures from it and the words from its sound. The sound is decoded by the Mac (CoreAudio), so what the Mac cannot play it cannot read: Tiger cannot take the sound out of an mp4 or mov (it still gives the pictures), and 64-bit programs on Leopard have no QuickTime for the pictures. The recording goes to the speech service you have a key for, so Tiger Build asks first, like any attachment.
- **Files from the model.** The model can hand over a file with a **Save As...** button. A name ending `.docx`, `.xlsx` or `.pdf` makes a real Word, Excel or PDF file. Pictures a tool looks at are shown in the chat.
- **Emoji.** Macs before Lion have no emoji font, so Tiger Build draws each emoji as a colour picture from the Twemoji set (flags, skin tones and joined emoji too). The chat list shows them too, and copying selected text copies the emoji themselves. Lion and later use the system's own.
- **Code blocks.** Dark panels name the language and colour about 40 languages, with **Save** and **Copy**. Replies also show bold, italics, `inline code`, headings, bullets, links and tables. Chat → Copy Last Code Block (⇧⌘C) copies without clicking.
- **Thinking.** Returned reasoning shows in its own card and stays visible above the message box while the model runs (Claude, ChatGPT reasoning models, Grok, Gemini, Mistral Magistral, local reasoning models). Turn it off in Tools settings.
- **Cost and context.** The line above the chat shows context use and an **estimated cost** (hover for the breakdown), from a public price list Tiger Build fetches once a day; local models show N/A. A full context is summarized (also Chat → Compact Chat Now), and a reply that hits the output limit ends with a note.

**Tools**
- **The Tools button** switches each tool on or off for the chat: Commander, **Administrator (sudo) for Commander** (turning it on turns Commander on, and asks for the account password once), the agent toolbox, web search, other models and every MCP server. **Ask Before Running** waits for your answer, for all tools or chosen ones. The question names the chat that asks; "Always Allow" turns it off for that tool in that chat. It is on by default for tools that act on the Mac in chats with attachments. Each call shows as a card; click for the command and output.
- **Screen control.** The Tools menu has **Screen control (mouse and keyboard)**, off for each chat and asking before every use: after `take_screenshot` a model can click, drag, scroll, type and press keys (`screen_click`, `screen_move`, `screen_drag`, `screen_scroll`, `screen_type`, `screen_key`, `screen_info`), using the screenshot's pixel positions. Keys follow the US layout. It acts on whatever is on the screen, so watch it: a model can type into the wrong window. **From another computer or program:** Preferences, **Screen**, *Let other computers and programs use this Mac's screen, mouse and keyboard* makes the same tools (and `take_screenshot`) available to a Commander started over SSH, whatever program is on the other end; *Use screen control without asking first* removes the approval question. From a terminal: `ppc-commander --screen on|off|status`. Someone must be logged in at the Mac, and Allow Other Computers must be on for another computer.
- **Commander from Claude Desktop, Claude Code and other MCP programs.** Any program that can start an MCP server over SSH can use a Mac running Tiger Build: its files, shell, administrator commands and (if you allow it) screen, mouse and keyboard. Setup, the exact `ssh` commands and the config entries are in [Using Commander from Claude Desktop, Claude Code and other programs](#using-commander-from-claude-desktop-claude-code-and-other-programs).
- **Commander Options** (Preferences): **commands to block** on top of the built-in ones (checked by the words of a command, so it stops mistakes, not a determined attempt), **a diff** in the result of every file write or edit, and, only while Allow Other Computers is on, **Open Tiger Build at login, hidden** (a normal Login Item in System Preferences, Accounts; turning Allow Other Computers off removes it).
- **File converters through Commander.** `convert_file` runs Tiger Build's own converter (`TigerBuild --convert FILE OUTDIR` inside the app) so a model can read Word, Excel and PowerPoint files (also the old `.doc`, `.xls`, `.ppt`), OpenDocument, Pages, Keynote and Numbers files as text, and HEIC, AVIF, WebP and other pictures as an upright JPEG, on this Mac or on another Mac that has Tiger Build.
- **Screenshots.** `take_screenshot` shows the Mac's screen (someone must be logged in); `view_image` shows a picture file. Models without vision are not offered either.
- **Source control.** `repo_info`, `git_read`, `git_write`, `svn_read` and `svn_write` let a model check status, read diffs and logs, and commit. Read tools never ask first; write tools follow Ask Before Running. A diff or commit shows `2 files +3 −0` on its card.
  - Subversion ships with Mac OS X 10.5 and later. git does not (before Lion): install it yourself, for example from MacPorts, and the tools find it.
  - Nothing runs through a shell. Force pushes, deleting remote branches, skipping hooks, passwords on the command line, interactive rebase and commits without `-m` are refused, and paths must stay in the allowed folders. A repository can contain hooks that run code, so use trusted ones.
- **Read a web page.** With web search on, `agent_read_page` reads a page by its address (text only, the first 40,000 characters, public addresses only), so a link you paste or one from a search result can be read.
- **Knowledge folder.** Workspace Settings can name a folder of your own notes and documents (text, code, PDF, Word, Excel, PowerPoint, EPUB and the like). The model then gets `knowledge_search` (best passages, ranked by how rare the words are) and `knowledge_open` (a whole file, from inside the folder only). The index is kept in memory, built the first time it is searched and refreshed when files change; nothing leaves the Mac except the passages the model asks for.
- **Mac apps (read only).** The Tools menu item *Mac apps: Calendar, Contacts, Mail* (off for each chat, asks first) gives `mac_calendar_events` (the coming days), `mac_contacts_search` (names, emails and phones) and `mac_mail_unread` (date, sender and subject of the newest unread messages, never bodies), asked through AppleScript. The applications open if they are not running.
- **Ask other models.** `consult_model` asks another working model for a second opinion; its usage counts in the chat's cost.
- **Menu shortcuts.** Every menu item has a shortcut (Chat → Pin Chat ⌘D, Bookmark Last Message ⌘B, Model Parameters ⌥⌘A, Skills ⌥⌘L, Quick Ask ⌥⌘J, Cost Report ⌥⌘C, Lock ⌥⌘X, and so on; the menus show them all).
- **Skills.** A skill is a folder in `~/Library/Application Support/Tiger Build/skills/` holding a `SKILL.md` (a `name:` and `description:` header between `---` lines, then instructions) and any files it mentions; Claude skill folders work as they are. Chat → *Skills...* lists them with a switch each and can create, import (copy in a folder), delete and show them. The model is told each skill's name and description and calls `skill_load` when a task fits (and `skill_read_file` for the files inside, which cannot reach outside the skill's folder). The Tools menu item *Skills* turns them off for a chat. In the Skills window, *Edit...* changes a skill, and *From This Chat...* has the chat's model draft a skill from the conversation (the name, a one-line description and the instructions), which opens in the editor for you to adjust before it is saved.
- **Subagents.** For Macs with more than one core. Turn on *Let models start subagents* (Tool Settings → Built-in Tools), then tick *Subagents* in a chat's Tools menu. The model gets `run_subagents`: several tasks at once, each handled by a helper with its own conversation and the chat's tools (not sudo, screen control or more subagents). Tool Settings → Subagents sets how many tasks one request may hold (1 to 16, default 8), how many run at once (1 to 8; the Mac's cores up to 4 by default) and which model the helpers use: *the model picks for each task* (default; the model is shown the usable models with short notes and may give a task its own model, so a Sonnet-class model can hand simple searching or checking to a Haiku-class one, and uses the chat's own model otherwise), *always the chat's own model*, or one fixed model. While they work, a progress card in the chat shows each helper's model, how many steps it has taken and what it is doing. Their tool cards appear in the chat, they ask before running tools exactly as the chat does, Stop stops them, and their usage is counted in the chat's cost and your spending limits. Each helper stops after 25 tool steps.
- **Download tool.** Off by default (Tool Settings → Web Search, then the per-chat Tools menu item). A model may download a file over https only (certificate checked, public addresses); you are asked first, and it lands in the chat's files. The size limit is 50 MB unless you change it (Tool Settings → Web Search, *Largest download or web response*, 1 to 2000 MB); it applies to the web requests server's `curl` as well.
- **Tool steps.** A reply may use up to 40 tool steps (1 to 1000 in Tools settings; 0 turns the limit off, at your own risk); then Tiger Build stops it and you can say "continue".

- **Model parameters.** Chat → *Model Parameters...* sets a temperature, top P and a longest answer for the chat (or for every new chat in the workspace). Only ticked values are sent. Some models refuse some of them (reasoning models often refuse temperature); the request is then repeated without that value and the chat says so.
- **Bookmarks.** A faint star appears beside a message when the pointer is over it: click it to bookmark the message (bookmarked messages keep a yellow star), or use Chat → *Bookmark Last Message* (⌘B) or right-click → *Bookmark This Message*. Right-click → *Bookmark Note...* adds a short note to find it by. Chat → *Bookmarks* lists them and jumps to one; *Manage Bookmarks...* (⇧⌘B) is a searchable list of every bookmark in the workspace with Go To, Note and Remove. *Find in Chats* has a *Bookmarked only* box, and bookmarks (with their notes) are marked in Markdown, text and PDF exports.
- **Tokens and time.** Chat → View → *Show Tokens and Time* (⌥⇧⌘T) shows under each reply how many tokens went in and came out (all the model calls the reply took, including subagents) and how long it took from sending to the last token. The numbers are kept with each reply, so switching it on also shows them for replies made after this version was installed. Replies from services that do not report usage show only the time.
- **Time of completion.** Chat → View → *Show Time of Completion* (⌥⇧⌘Z) adds when each reply finished ("finished 3:41 PM", with the date for another day) to the line under it, with or without the tokens and time. Only replies made after this version was installed have the time.
- **Please Continue.** Chat → *Please Continue* (⇧⌘Return) sends "Please continue" at once, keeping whatever is half typed in the message field; while a reply is running it goes in as guidance.
- **Pin Chat** (Chat, ⌘D) keeps a chat at the top of the list with a ★; new chats go in below the pinned ones. Drag a pinned chat to put the pinned ones in order, or use Chat → *Move Pinned Chat Up* and *Down* (⌥⌘↑, ⌥⌘↓).

**Voice** (optional, off until switched on, under Chat → Voice)
- **Speaking.** Speak Last Reply (⌥⌘S), Stop Speaking (⌥⌘.), Speak Replies Automatically (⇧⌥⌘J) and Choose Voice (⌥⌘V) use the Mac's own voices ("Alex" needs 10.5) or, if you choose, a service's voices: Choose Voice has *Voices from:* This Mac, ChatGPT (13 voices), Gemini (30), Grok (5) and Mistral (the service's own list), for the services that have a key here. A service's voice sends the reply to that service as text (using your key, and billed by it; Tiger Build asks once per service and does not count it in the spending limits) and plays the audio once the whole reply has arrived; if the service cannot be reached the reply is read with this Mac's voice. Replies are cut at 4000 characters. Code and tables are not read out.
- **Voice Commands** (⌥⌘G) listens, while Tiger Build is in front, for "Send message", "Stop", "New chat", "Read that again" and "Stop talking".
- **Dictate** (⌥⌘R) records, press again to stop (⌘. cancels), and puts the words in the message box. The clip (16 kHz mono, up to 90 seconds) goes to OpenAI, Mistral or Google, whichever has a key, and is not kept; Tiger Build says so the first time. Send Dictation Automatically (⌥⌘Y) sends it straight away. It needs a working microphone.

**Several Macs and windows**
- Commander runs on the Mac you chat from. To let a chat use another Mac, add that Mac as an MCP server over SSH (Tool Settings → MCP Servers → *Commander on another computer*); the other Mac must allow it (Commander → Allow Other Computers). Windows share each workspace's chats (a chat working in one window cannot be sent to from another).

**Status and menus**
- **Alerts** (Preferences, Alerts): a sound (and a bouncing Dock icon) when a reply finishes in a chat that is not on screen, or while Tiger Build is in the background. **Spending limits** stop a reply when its chat, or all chats today, pass an amount you set (estimates from the cost line above each chat; a limit is checked after each model call, and the chat stays blocked until you raise or clear it). **Check for Updates...** (Tiger Build menu, and once a day at start unless you turn it off) asks GitHub for the latest release of this repository; when the release carries the installer (`.pkg.zip`) it offers to download it into your Downloads folder (your Desktop on Mac OS X 10.4, which has none by default) and open it (a window shows the progress, with Cancel; the file is checked against GitHub's checksum), otherwise it opens the download page. The installer closes every open copy of Tiger Build before it installs (its `preflight` script, so it also does when you open the package yourself).
- **Uninstall Tiger Build...** (Configuration menu) removes everything the installer put on the Mac, with or without your chats, settings and saved keys, after asking for the administrator password. Without the app: `sudo /usr/local/tbssh/bin/tiger-build-uninstall` (add `--data /Users/NAME` to remove that account's chats and settings too).
- A red line at the top says what is wrong with the service you picked (no key, not reachable); an orange one says why Commander cannot run, with the fix. Long runs show their progress, so slow commands never look like a lost connection.
- **Commander menu:** Start and Stop, **Allow Other Computers** (off by default: with it off, only Tiger Build on this Mac can use Commander), and this Mac's model, OS and addresses. **Configuration menu:** MCP servers and agent tools, and export/import of all settings. VoiceOver labels are set on controls and messages.

## Using Commander from Claude Desktop, Claude Code and other programs

Commander is an ordinary MCP server on standard input and output, so a modern computer running Claude Desktop, Claude Code, Cursor or any other MCP program can drive an old Mac running Tiger Build. The program starts it with `ssh`, through Tiger Build's own SSH server (port 2222), which lets in only the public keys you list and can run nothing but Commander. Commander itself runs only on the old Mac (PowerPC or Intel), so it is always reached this way from a modern one.

**Commander without Tiger Build's chat.** This works even if you never add an API key or set up a local model server. Commander is a tool server, not an AI: the model is whatever the program on the other end uses (Claude Desktop and Claude Code sign in to Claude themselves). The old Mac needs only Tiger Build installed (Commander is inside the app), Allow Other Computers on, and your public key allowed; Tiger Build does not have to be running or have a service configured. That makes an old Mac a machine that a modern assistant can work on directly: read and write its files, run its shell, build and test code on it (for instance with the old Xcode), look at its screen and use its mouse and keyboard. The exceptions are administrator (sudo) commands, which need Tiger Build running on that Mac with the password saved (step 5), and screen control, which needs someone logged in at that Mac. The chat window is for talking to models from the old Mac itself.

**1. On the old Mac.** Commander → *Allow Other Computers* (it asks for the administrator password and starts the server on port 2222). Optional: Preferences → **Screen**, *Let other computers and programs use this Mac's screen, mouse and keyboard* (a logged-in user is needed), and *Use screen control without asking first* for Tiger Build's own approval question.

**2. Get your key onto the old Mac** (no copy and paste between the computers needed). Make a key if you have none: `ssh-keygen -t ed25519`. Then any one of:

```bash
# a. through Remote Login (System Preferences, Sharing) with the account's password or an RSA key it already accepts;
#    Tiger Build's server also reads the account's ordinary ~/.ssh/authorized_keys, for Commander only
ssh-copy-id -i ~/.ssh/id_ed25519.pub you@old-mac

# b. through Tiger Build's server, from a computer whose key it already allows
ssh-copy-id -p 2222 -i ~/.ssh/id_ed25519.pub -o IdentitiesOnly=yes -o HostKeyAlgorithms=ssh-ed25519 -o PubkeyAcceptedAlgorithms=ssh-ed25519 you@old-mac

# c. or paste the key under Preferences, SSH Server, Allowed Keys... on the old Mac
```

**3. Test the login by hand** (and trust the host once; compare the fingerprint with *Copy Host Fingerprint* in Preferences → SSH Server). It starts Commander and waits for input; press Control-D to leave:

```bash
ssh -p 2222 -i ~/.ssh/id_ed25519 \
    -o IdentitiesOnly=yes -o HostKeyAlgorithms=ssh-ed25519 -o PubkeyAcceptedAlgorithms=ssh-ed25519 \
    you@old-mac commander
```

The server has one host key, **ssh-ed25519**, and takes ed25519 and RSA user keys. The `-o` options matter if your `~/.ssh/config` has an entry for the same Mac written for its old Remote Login, such as `HostKeyAlgorithms ssh-rsa` and `PubkeyAcceptedAlgorithms ssh-rsa`: a `Host` entry applies to port 2222 as well, and ssh then says `no matching host key type found. Their offer: ssh-ed25519`. Options on the command line win over the file. For an RSA user key, use `-o PubkeyAcceptedAlgorithms=ssh-rsa` instead (or leave it out). A cleaner way is an entry of its own:

```
Host old-mac-commander
  HostName 10.0.1.129
  Port 2222
  User you
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  HostKeyAlgorithms ssh-ed25519
  PubkeyAcceptedAlgorithms ssh-ed25519
```

after which `ssh old-mac-commander commander` is the whole command.

**4a. Claude Desktop.** Settings → Developer → Edit Config opens `~/Library/Application Support/Claude/claude_desktop_config.json`. Add the server to `mcpServers` and quit and reopen Claude with ⌘Q:

```json
{
  "mcpServers": {
    "old-mac": {
      "command": "ssh",
      "args": ["-p", "2222", "-i", "~/.ssh/id_ed25519",
               "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
               "-o", "HostKeyAlgorithms=ssh-ed25519", "-o", "PubkeyAcceptedAlgorithms=ssh-ed25519",
               "you@old-mac", "commander"]
    }
  }
}
```

With the alias from step 3 the arguments are just `["old-mac-commander", "commander"]`. Claude cannot answer a question, so do step 3 by hand first and use a key without a passphrase (or one loaded in your SSH agent).

**4b. Claude Code.**

```bash
claude mcp add --transport stdio old-mac -- ssh -p 2222 -i ~/.ssh/id_ed25519 \
    -o IdentitiesOnly=yes -o BatchMode=yes \
    -o HostKeyAlgorithms=ssh-ed25519 -o PubkeyAcceptedAlgorithms=ssh-ed25519 you@old-mac commander
```

Preferences → Screen → *Copy Claude Code Command* and *Copy MCP Settings* on the old Mac give these lines filled in for it.

**5. Administrator (sudo) commands.** On the old Mac turn on *Let other computers run administrator (sudo) commands here* (Preferences → Commander Options) with the administrator password saved (Commander tab), then *Copy Key*; it shows the key. Tiger Build must be running there, because it holds the password. Give the program the key in its environment and tell ssh to carry it; the server accepts only this one variable, and Commander takes it once and removes it so no command can see it:

```json
"args": ["-p", "2222", "-i", "~/.ssh/id_ed25519", "-o", "IdentitiesOnly=yes",
         "-o", "HostKeyAlgorithms=ssh-ed25519", "-o", "PubkeyAcceptedAlgorithms=ssh-ed25519",
         "-o", "SendEnv=TB_SUDO_KEY", "you@old-mac", "commander"],
"env": {"TB_SUDO_KEY": "the key Copy Key showed"}
```

**Claude Code**, as a command (`--scope user` keeps it in `~/.claude.json` for every project):

```bash
claude mcp add --scope user --transport stdio \
    -e TB_SUDO_KEY=6d088737fbcec5092b13a42b962b77d7 \
    old-mac -- ssh -p 2222 -i ~/.ssh/id_ed25519 \
    -o IdentitiesOnly=yes -o BatchMode=yes \
    -o HostKeyAlgorithms=ssh-ed25519 -o PubkeyAcceptedAlgorithms=ssh-ed25519 \
    -o SendEnv=TB_SUDO_KEY you@old-mac commander
```

or as the entry in a project's `.mcp.json` (or in `~/.claude.json`), where the key goes in `env`:

```json
{
  "mcpServers": {
    "old-mac": {
      "type": "stdio",
      "command": "ssh",
      "args": ["-p", "2222", "-i", "~/.ssh/id_ed25519",
               "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
               "-o", "HostKeyAlgorithms=ssh-ed25519", "-o", "PubkeyAcceptedAlgorithms=ssh-ed25519",
               "-o", "SendEnv=TB_SUDO_KEY", "you@old-mac", "commander"],
      "env": { "TB_SUDO_KEY": "6d088737fbcec5092b13a42b962b77d7" }
    }
  }
}
```

(The key shown is an example.) A project's `.mcp.json` is usually committed, so keep the key out of it: write `"env": { "TB_SUDO_KEY": "${TB_SUDO_KEY}" }` there and put `export TB_SUDO_KEY=...` in your shell's startup file, or use the `--scope user` command above. `env` reaches the server only because `-o SendEnv=TB_SUDO_KEY` is in the `ssh` arguments. Anything that holds the key can use sudo on that Mac through Tiger Build, so keep it to programs you trust. This needs Tiger Build 2.6.3 or later installed on the old Mac (the installer changes the SSH server's settings).

| You see | Cause and fix |
| --- | --- |
| `no matching host key type found. Their offer: ssh-ed25519` | An `~/.ssh/config` entry limits the host key types; add `-o HostKeyAlgorithms=ssh-ed25519` (above) |
| `Permission denied (publickey)` | The key is not in Allowed Keys yet (step 2), or ssh offered a different key: use `-i` with `-o IdentitiesOnly=yes`; for an RSA key add `-o PubkeyAcceptedAlgorithms=ssh-rsa` |
| `Connection refused` on port 2222 | Allow Other Computers is off on the old Mac, or the Tiger Build installer's SSH server is not installed |
| `Host key verification failed` | The old Mac's host key changed (reinstall), or you never trusted it: do step 3 by hand |
| The tools list is empty, or screen tools are missing | Commander is stopped (Commander → Start), or the Screen setting is off on the old Mac |
| `screen control is off` | Preferences → Screen on the old Mac, or `ppc-commander --screen on` there |

### A regular SSH login, sftp and scp (port 2223)

Tiger Build's server on port 2222 runs only Commander. For an ordinary login (a terminal, `sftp`, `scp`) Preferences → **Shell** has *Allow SSH logins with a shell, sftp and scp*. It starts a second OpenSSH server on **port 2223**, for the accounts you name there (your own by default), with keys only: no passwords, no root login, no port forwarding. It is off until you tick it and give the administrator password (turn it off the same way), and it changes neither Remote Login (port 22) nor the Commander server.

It accepts the same public keys as the Commander server (*Allowed Keys...*) and the account's own `~/.ssh/authorized_keys`, so a computer that is already allowed can add another key itself:

```sh
ssh-copy-id -p 2223 -i ~/.ssh/id_ed25519.pub -o IdentitiesOnly=yes -o HostKeyAlgorithms=ssh-ed25519 -o PubkeyAcceptedAlgorithms=ssh-ed25519 you@old-mac
ssh  -p 2223 -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o HostKeyAlgorithms=ssh-ed25519 -o PubkeyAcceptedAlgorithms=ssh-ed25519 you@old-mac
sftp -P 2223 -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o HostKeyAlgorithms=ssh-ed25519 -o PubkeyAcceptedAlgorithms=ssh-ed25519 you@old-mac
scp  -P 2223 -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o HostKeyAlgorithms=ssh-ed25519 -o PubkeyAcceptedAlgorithms=ssh-ed25519 file you@old-mac:
```

A key in Allowed Keys therefore works for both servers, so list only computers you would let run anything as that account (Commander can already do that).

### Tiger Build in the Terminal (`tb`)

`tb` (or `tigerbuild`) is the chat client for a terminal, on the old Mac or over SSH from any computer. It uses the same chats, models, tools and keys as the window.

    tb                      start (or tb "first message")
    tb -c                   continue the latest chat       tb -r 12   open chat 12
    tb -p "question"        answer once and exit           tb -m claude:claude-sonnet-5-5
    tb login openai_api_key keep a key for use over SSH    tb keys   which keys are set

`sudo` works in `tb` too when administrator mode is on (Preferences, Commander) and the chat has the sudo tool on (`/tools sudo on`): `tb` serves the saved password to Commander on a socket of its own, and the Keychain asks about it once at the start, not in the middle of a command. Not over SSH, where the Keychain cannot ask.

Inside: `/help` lists the commands; `/model` and `/models` switch service, `/tools` turns tools and their approvals on and off, `/mode` (or Shift-Tab) picks ask, edits, plan or auto, `@path` adds a file, `!cmd` runs a command, `Esc` stops a reply. Pictures, videos and posts are noted in the terminal and shown in the window when you open the chat there.

### Spotlight search of chats

Preferences → Privacy → *Let Spotlight search my chats* (off by default). Tiger Build then keeps one small file per chat (`.tbchat`: its title and words, not pictures, files or tool output; up to 300,000 characters) in `Application Support/Tiger Build/Spotlight/`, updates them half a minute after a chat stops changing, and installs a Spotlight importer in `~/Library/Spotlight`. Searching in Spotlight then finds chats by title or content, and opening a result opens that chat (switching workspace if needed). Anyone who can search this Mac can find that text, and the lock does not hide it. Turning it off removes the files and the importer.

### SMB file sharing, both ways

**Sharing this Mac's files** (Preferences → **Sharing**, needs the installer's files; off until you turn it on, with the administrator password). Tiger Build's own server, `tbsmbd`, speaks SMB 2 and 3 (with signed messages and NTLMv2 passwords), so current Windows, Linux and Mac computers can open one folder of this Mac, even though they no longer talk to the old SMB 1 that Tiger through Snow Leopard have built in. Choose the folder, a share name and the port (445 is what other computers expect; the Mac's own File Sharing must not be using it), tick *Read only* if you want, and use **People...** to list who may sign in (`name:password` per line, kept in a file only your account can read). Other computers then use `smb://this-mac/Name` (Finder: Go, Connect to Server) or `\\this-mac\Name` (Windows). It runs as your account, so it can reach only what you can; links in the folder are neither shown nor followed; there is no guest access. It is a plain file server: no Windows permissions, no streams or change notification, and Macs that connect keep their extra data in `._` files next to yours. It is meant for a home network you trust.

**Using other computers' shares**: the *SMB file shares* server (Tool Settings → MCP Servers, off until you turn it on) lets a chat list, read, write, rename and delete files on any SMB 2 or 3 share (Windows PCs, NAS boxes, Samba, other Macs, Tiger Build's own sharing). Give the share as `smb://user@server/share/path`, or save it in Preferences → Sharing → **Saved Shares...** (`name = smb://user:password@server/share`, kept in the Keychain) and tell the chat to use the share by name, so the password never appears in a chat. `output_path` and `local_path` (to and from this Mac) work only in a chat with Commander on. Finder and Windows-style mounting of a modern share on these old systems is not offered: Tiger to Snow Leopard cannot mount SMB 2 shares, so the tools are the way in.

**Mounting a saved share as a disk in the Finder**: Preferences → **Sharing** → *Mount in Finder...* mounts one of the saved shares (*Saved Shares...*) as a disk. Snow Leopard and earlier can only speak SMB 1 themselves, which modern servers have switched off, so Tiger Build does the SMB 2/3 talking (libsmb2) and gives the Finder the share as WebDAV, which every system from Tiger on mounts: a small web server on this Mac's loopback address only, at an address with a secret in it. Reading, writing, folders, renaming, copying and deleting work; the disk stays mounted only while Tiger Build is open (*Eject* in the same window, or quitting, unmounts it). Over SSH or in `tb` there is no Finder, so the tools are the way there.

## Models, tools and search

- **Model list.** The models of each service come with the app (`models.txt`). Configuration → *Update Model List* (⌥⇧⌘M), and Tiger Build by itself at start and every six hours, asks each service that has a key (Grok, ChatGPT, Claude, Mistral, Gemini and Muse) for its own list of models, keeps the chat models (not embedding, image, audio, preview or dated-copy models) that are not already in the list, tries each new one with a one-word question, and adds the ones that answer to that service's models, each in its place by version (a 6.1 goes just above the 6 of its own family; a new family among the versions it falls between) (kept in `model-live.plist`, so they are there offline at the next start; a model that fails is not tried again for a week). A model that comes with the app but is no longer in the service's list is tried once too; if it really fails it is hidden (the service's default model is never hidden), and it comes back by itself if the service lists it again. A service that cannot be asked is left as it was, and the dialog says why. The same command reads the local server's models (LM Studio, Ollama, OpenRouter) again; they are also read when you choose Local or save the Local LLM settings. The more powerful models tend to do a much better job of working within the confines of the old OS environments than the less powerful ones.
- **OpenRouter.** Use it through the Local LLM Server settings: the address `https://openrouter.ai/api` and your OpenRouter key as the local API key. The model menu then lists the models that can use tools (a few hundred, by OpenRouter's own names, with their context lengths), and the cost line uses the prices OpenRouter publishes, so spending limits work.
- **Local LLM server.** None is assumed. Give its address: `http://127.0.0.1:1234` for LM Studio or `http://127.0.0.1:11434` for Ollama (`/v1` is added if left off). Tiger Build reads each model's context length from the server. With Ollama, set its context length in Ollama's settings; the default can be small, and Ollama then drops the oldest part of a long chat without saying so.
- **Custom MCP servers.** Add a program that runs on the Mac (path, arguments, environment), a program on **another computer over SSH** (user@address and the command to run there, using Tiger Build's own key and a host list you confirm), or an `http://` or `https://` address of a Streamable HTTP server (a token goes in the environment as `MCP_AUTH_TOKEN`) in Configuration → MCP Servers and Agent Tools; double-click to edit. Each server can have a **description** for the model: what it is for, or extra instructions, added to each of its tools. They can be set to ask first, and plain `http://` is only allowed on your own network. Enable only servers you trust. Both HTTP transports work: Streamable HTTP, and the older **HTTP+SSE** one (used when the address ends in `/sse` or the server answers the first message with 404, 405 or 400). A server that asks you to **sign in** (OAuth, as the MCP specification describes: the server's metadata is discovered, Tiger Build registers itself, and you sign in in your own web browser) is signed in to the first time it is used, after you agree; the access it gives is kept in the Keychain and renewed when it runs out. Configuration, *Forget Saved MCP Sign-Ins...* removes them. Only servers that allow programs to register themselves are supported.
- **Example servers.** The first launch adds built-in servers: a calculator and unit converter, a notebook, system info (host, displays, disk space, time; with `slow_task` and `always_fails` for testing Stop), weather from wttr.in, currency exchange rates (Frankfurter, with open.er-api.com as a second source) and US inflation (built-in CPI-U yearly averages from 1913, with the latest months from the Bureau of Labor Statistics), **web requests** (`curl`: any method, headers and body; text comes back as text, pictures and videos are shown, other files get a Save As button; with Commander on in the chat, `output_path` writes the response straight to a file on this Mac, however large, with its SHA-256; it asks before each use unless you allow it) and **X posts** (`x_post`, below). New built-in servers are added, switched on, after an update (the notebook and web requests servers ask before each use); removing one sticks. They need no Python; remove or switch off any you do not want and it stays that way. Any program that speaks MCP over standard input and output works as a server of your own. The official servers work too, for example program `/path/to/npx`, arguments `-y|@modelcontextprotocol/server-filesystem|/some/folder`.
- **Grok and X (Twitter).** Grok searches X posts itself, through xAI's own `x_search` tool (Tool Settings, Built-in Tools, *Grok search of X (Twitter) posts*, on by default; it follows the chat's Web search switch and xAI bills tool calls to your key). Other services have no way to read X. The **X posts** server (switched on at first launch, no key needed) gives any model `x_post`: give it a post's address and it reads the author, text, counts, and the pictures and video. By default it puts the post in the chat as a bubble of its own: the author's picture and name (with the verified badge: blue for people, gold for businesses, grey for government accounts), the text, its photos (or a video's first picture with a play button, which plays the video in QuickTime Player when clicked), the counts, and a Share button that copies the post's link. `show` can also be `media` (pictures at full size and the video), `all` or `text` (text only). Reply, like and repost counts (and views, when there are any) are shown; reposts and views come from fxtwitter's public service, which is asked for them alongside X's own embed service, and the card goes without them if it does not answer. It reads public posts only.
- **Web search and pictures.** It works with no key (DuckDuckGo, with Wikipedia as a fallback); a Brave or Tavily key broadens it, and a refused key falls back to the free search. Models can find pictures (Brave or Tavily, else Wikimedia Commons) and show them in the chat; Tiger Build downloads them, and only from public addresses. Grok uses its own search while that switch is on, and Gemini can search with Google (Grounding with Google Search, answers come back with their sources; the switch is in Tool Settings, and it falls back to the ordinary search if Google refuses).
- **Agent toolbox** adds UTC time and scratch notes. **Show model thinking** (Tool Settings, Built-in Tools) shows the reasoning a service sends back, on the services that provide it: Grok, ChatGPT, Claude, Gemini, Mistral, Muse and local models, whenever the model returns it. **Claude thinking** passes signed blocks back unchanged, as Anthropic requires in their more recent updates for 5.5 and later models.
- **Settings backups.** Export/Import All Settings. Backups hold API keys in plain text; imported MCP servers stay disabled.

## Security

- Connections to the AI services use TLS 1.3 or 1.2 and check the server's certificate against the Mozilla list that ships in the app; there is no option to skip the check. Keys are in the Keychain and go only to the service that owns them.
- A model cannot change Commander's blocked commands, allowed folders or shell, or edit its files.
- **Commander is local unless you allow otherwise.** It starts as part of a chat on the same Mac and nothing listens on the network. Another computer or program can use it over SSH only if you turn on Commander → Allow Other Computers, which starts Tiger Build's own SSH server (port 2222), or, if you prefer the Mac's Remote Login, needs that and the public key in the account's `~/.ssh/authorized_keys` (Tiger Build never uses a password); otherwise the program refuses to run for it. Tiger Build's server lets in only public keys: the ones you list under Preferences, SSH Server, the ones `ssh-copy-id -p 2222` adds to that list through a key already allowed, and the account's ordinary `~/.ssh/authorized_keys` (what `ssh-copy-id` to Remote Login adds), and it gives all of them Commander and nothing else. Commander lets whoever reaches it run commands and change files as that account, so only list keys you trust.
- File conversion refuses XML entity definitions and oversized archives. A model can only fetch pictures from public web addresses, never from your own network.
- **Programs on other computers** (an MCP server over SSH, such as another Mac's Commander) use a key only Tiger Build knows (`ssh/` in Application Support) and a host list you confirm by fingerprint; if that computer's key ever changes, Tiger Build refuses to connect. Tiger Build makes an ed25519 key for modern hosts and an RSA one for old hosts, which a recent macOS must be told to accept.
- **Administrator (sudo) mode** is off. To let agents run commands as root on a Mac, open Preferences, Commander, tick *Let agents run administrator (sudo) commands*, and type the account password once. Tiger Build checks it and keeps it in that Mac's Keychain, where only Tiger Build can read it. Commander cannot open that Keychain item, so when a command contains `sudo`, it asks the running Tiger Build for the password over a socket only that account can use, and gives it to sudo through a pipe that is closed before the model's command starts. A chat can use sudo only when its Tools menu has the sudo item ticked (which turns Commander on); the Preferences setting saves the password and the setting for other uses of the program. It works for Commander on this Mac, and for another computer's or program's Commander only through the key described below. The model never sees the password, but it runs as the same account, so with sudo on it can do anything root can. `Tiger Build.app/Contents/Resources/ppc-commander --sudo on|off|status` does the same from a terminal, and a root-owned `/etc/ppc-commander.json` containing `{"sudoMode": false}` keeps it off. Blocked commands such as `shutdown` stay blocked under sudo, the approval question marks sudo commands, and `sudo` is refused with `detach`. The login keychain must be unlocked, so stay logged in.
- **Tiger Build's SSH server and client.** The app carries a current OpenSSH client (ed25519 and RSA keys, ML-KEM key exchange, LibreSSL linked in) and uses it to reach other computers (`ssh:user@address`, or `ssh:user@address:2222` for another Tiger Build's server); a host that only speaks the old algorithms (a stock Remote Login on Tiger to Snow Leopard) is detected when you choose Trust Host and reached with the same client, an RSA key and the old algorithms switched back on. The installer also puts Tiger Build's own SSH server in `/usr/local/tbssh` (root-owned). It is **off** until you tick *Allow other computers to use Commander on this Mac* and give the administrator password in the system's dialog; it then listens on port 2222, accepts only public keys (those you list in Preferences, SSH Server, *Allowed Keys...*, the ones `ssh-copy-id` adds, and the account's `~/.ssh/authorized_keys`), and can run nothing but Commander (no shell, terminal or forwarding; it also lets `ssh-copy-id` add keys, and carries one environment variable, `TB_SUDO_KEY`). Turning Allow Other Computers off stops it. Remote Login (port 22) is not changed. *Copy Host Fingerprint* gives the fingerprint to compare when the other computer trusts this one. The full client set (`ssh`, `scp`, `sftp`, `ssh-add`, `ssh-agent`, `ssh-keygen`, `ssh-keyscan`) is in `/usr/local/tbssh/bin` for terminal use (every key type; LibreSSL is linked in), with `sshfs` beside it (`sshfs -o ssh_command=/usr/local/tbssh/bin/ssh user@host:/path ~/mnt`; needs MacFUSE; see `third_party/sshfs`). On Leopard and Snow Leopard the installer adds a Quick Look generator for HEIC, AVIF, WebP and JPEG XL pictures, Markdown and CSV files (as pages), JSON files (as text), ZIP archives (the file list), EPUB books (cover and text) and Word, Excel, PowerPoint and OpenDocument files.
- **How sudo is kept apart between chats and computers.** The password is handed over only against a key. Each Commander that Tiger Build starts for a chat with the sudo item ticked gets its own random key, sent over its standard input (not its environment or arguments, which other programs of the account can read) and valid only while that Commander runs; a chat without the item has no key, so a model there cannot get the password whatever else is open (several chats can differ, each has its own Commander). New chats never start with sudo, download or screen control ticked. **Other computers and programs** can use sudo on this Mac only if you tick *Let other computers run administrator (sudo) commands here* in Preferences, Commander Options (needs Allow Other Computers and the saved password, with Tiger Build running to hold it) and give them this Mac's key (**Copy Key**, kept in the Keychain, shown in its dialog). Another Tiger Build gets it as `TB_SUDO_KEY=...` in the server's Environment and sends it over standard input, only for chats that have the sudo item ticked. A program such as Claude Desktop or Claude Code puts `TB_SUDO_KEY` in the server's environment and has `ssh` carry it (`-o SendEnv=TB_SUDO_KEY`); the SSH server accepts that one variable, and Commander reads it once and removes it, so no command it runs can see it. This Mac's own chats are unaffected by that setting either way. Anyone who has this Mac's key and an SSH login can use sudo here, so treat the key like a password.
- With tools on, a model runs shell commands as your account. The guards stop mistakes and simple tricks, not a determined attacker; use a separate account for real separation.

## Troubleshooting

| You see | Try |
| --- | --- |
| "No usable service configured" | Open Preferences and add a key, or the address of a local LLM server |
| "Certificate ... not trusted" or a failed handshake | Check the Mac's date and time (a wrong clock fails every certificate), then try again |
| A service is dimmed | Add its key, or wait for its models to finish testing |
| The orange Commander line, or "tools are offline" | The message says why. Usually Commander was stopped (Commander → Start), or for another computer: Remote Login (or Tiger Build's SSH server) is off, Allow Other Computers is off there, the key is not in its `authorized_keys`, or the host is not trusted yet |
| Claude asks for `anthropic-workspace-id` | Enter the Workspace ID |
| "The model sent an empty reply ... so it is being asked to carry on" | A service answered with nothing (Gemini sometimes does, after thinking, or because its own filter blocked the reply: the notice then says so). Tiger Build asks the model to carry on, up to three empty replies in a row, and asks Gemini 3 and 4 to think less each time; `empty-replies.log` in Application Support keeps what the service sent. If it keeps happening, say "continue" (⇧⌘Return), rephrase, or switch model |
| Typing or scrolling is slow in a chat of thousands of messages | Start a new chat (the old one stays in the list); a very long chat is laid out in full every time it changes, which 2.6.2 made much lighter but not free |
| An `ssh` login to Tiger Build's server is refused, or "no matching host key type" | See the table in [Using Commander from Claude Desktop, Claude Code and other programs](#using-commander-from-claude-desktop-claude-code-and-other-programs) |
| The first reply is slow on a PowerPC Mac | The first connection to a service does a TLS handshake (about 0.2 s on a G4); later ones are quicker |

## Building, testing and packages

```bash
cd tiger-build && make test                   # unit tests on the Mac you build on
sh tests/engine/run-host.sh                   # engine tests against mock services (run on a current Mac)
SMOKE_SSH="ssh user@host" scripts/smoke-test.sh   # on an old Mac that has the checkout's tiger-build/ in ~/TigerBuild-dev: unit tests, the converter on the files in tests/engine/fixtures, the app starting, the uninstaller's dry run
```

| Script | Makes |
| --- | --- |
| `scripts/build-tiger-pkg.sh` | `dist/TigerBuild-2.7.pkg` (the installer for the old Macs) |
| `third_party/mbedtls/fetch.sh`, `build-mac.sh` | The TLS libraries (already built and kept in git) |
| `third_party/libwebp/fetch.sh`, `build-mac.sh` | The WebP decoder (already built and kept in git) |
| `third_party/libde265/fetch.sh`, `old-compilers.patch`, `build-mac.sh` | The HEIC video decoder as a dynamic library, patched for the old compilers (already built and kept in git) |
| `third_party/libaom/fetch.sh`, `build-mac.sh` | The AV1 decoder for AVIF pictures, plain C (already built and kept in git) |
| `third_party/nanosvg/` | NanoSVG, the SVG drawing code (two header files, kept in git) |
| `third_party/jxldec/fetch.sh`, `patches/old-macs.patch` | The JPEG XL decoder, one plain-C file with the changes for the old Macs (kept in git) |
| `commander/Makefile` | Commander, built with the app (`make host` builds it for the Mac you are on) |
| `scripts/make-prices.m`, `make-icns.m`, `pack-emoji.c`, `scan-secrets.sh` | Small helpers: the price list, the icon, the emoji pack, and a check that a package holds no keys (each file says how to build it) |

## Why Do This?

This is just a project for fun.  I saw people creating similar chat environments for older operating systems like Windows 95 and decided to give this a try myself.  As far as I can tell at the time of writing, this is the only LLM chat app for PowerPC Mac OS X that supports interaction with the system itself and is not just a chat interface only.  This app was made with heavy LLM support from Grok Build and Claude Code (with a little bit of ChatGPT) for fun so don't expect perfection.  However, I think it's actually a decently cromulent LLM chat build environment.  Don't expect any future updates or support for this.  I might add some but no promises.  Feel free to suggest improvements.  As stated above, Mac OS X Tiger is a very old operating system with security vulnerabilities, use at your own risk.
