# Changelog

## 2.6.1
- **Web requests for agents** (new built-in server *Web requests (curl)*): one `curl` tool with a url, method, headers and body, like the command. Text comes back as text with the status line and content type, pictures and videos are shown in the chat, other files are kept with a Save As button; redirects are followed and public addresses only. With Commander on in the chat, `output_path` (and `overwrite`) saves the response straight to a file on this Mac without holding it in memory. It asks before each use. The largest response or download (50 MB until changed) is now a setting, 1 to 2000 MB (Tool Settings, Web Search). (The old *download tool* is still there as an option.)
- **X posts with pictures and video** (new built-in server *X (Twitter) posts*): `x_post` reads a post from its address and shows it in the chat as a bubble: the author's picture and name with the verified badge, the text, replies, reposts, likes and views, its photos in X's arrangement or a video's picture with a play button (click it to play the video in QuickTime Player), and a Share button that copies the link. The verified badge is blue for a person, gold for a business and grey for a government account, and businesses have a square picture, as on X. It can also show the pictures at full size or give text only. Works with any model, with no key. Grok's own X search stays as it was.
- A short reply now stretches its bubble to hold the line of tokens and time, when that is switched on, instead of letting it spill out.
- The tool result can now put several pictures, videos or files in the chat at once.
- The host info tool reports the model, CPU type and speed, cores, caches and memory.
- The installer opens Tiger Build when its window is closed.
- **Fixed a crash in long chats** (worst on the 32-bit build on Snow Leopard, after about half an hour of streaming in a chat of over a thousand messages): drawing each message made a separate string for every character, millions of them each time the chat was laid out, until the app ran out of memory. Text that cannot hold an emoji is now left as it is, and each streamed frame has its own memory pool.
- **Fixed**: when a model (Gemini mostly) sent an empty reply right after a tool ran, the turn ended and the tool's output was printed as if it were the answer. Tiger Build now tells the model its reply was empty and asks it to carry on (up to three times, with the service's stated reason shown), and only then gives up, saying so plainly. The three tries count empty replies in a row, so a long run is not cut short by scattered ones; the notice says whether the reply was only thinking or nothing at all; and Gemini 3 and 4 are asked to think less (low, then minimal) on each retry, because a reply of all thinking and no answer is how an overlong think ends.
- **Fixed**: the Commander could be left spinning at full CPU, forever, if it was told to stop at the instant it was freeing memory at exit (its stop handler used Objective-C, which waited on the lock the interrupted code held). The handler now uses only plain system calls.
- Reset to Default in Appearance puts the drop-down menus' font and colour back at once on Mac OS X 10.4.

## 2.5
- **Grok can search X (Twitter)** through xAI's `x_search` tool (switch in Tool Settings); **Guide** now works with Muse and local models too; **Gemini 4 shows its thinking** (it only sends summaries when its thinking level is named, so Tiger Build asks for "high"; other Gemini models are asked as before, with a fallback and a note if a model will not show thinking); the Send button is wide enough for "Working." and "Guide".
- **Update Model List** shows a progress window (the update takes a few minutes on a slow Mac), and pressing it while the automatic update at start is still running now waits for that one and shows its result, instead of saying it is running.
- Models found by an update are placed in version order in the list, not at the top.

## 2.4
- **Updates**: the installer download shows its progress (with Cancel), and the installer closes every open copy of Tiger Build when it starts (a `preflight` script in the package).
- **Fixed**: a chat with one very tall reply (over about a thousand pixels) was left blank on screen, and the chats viewed after it; *Show model thinking* now says it works on the services that provide it (Grok was missing from the list); **SpaceXAI** is now **SpaceXSI**.
- **SVG support**: `.svg` and `.svgz` files can be attached and are read by `convert_file`: the model gets the source as text and a picture of the drawing (drawn with NanoSVG, plus text in a standard font; not filters, masks or CSS style blocks). An SVG code block in a reply has a *View* button that opens the drawing, and an `.svg` file the model hands over is shown in the chat as well as offered for saving.
- **Model list**: models a service has withdrawn are hidden (after a test call), Muse (Meta) is asked too, the command also refreshes the local server's models, the dialog is compact, and a service that cannot be asked says why.
- **The model list updates itself**: Configuration, *Update Model List* (⌥⇧⌘M), and automatically at start and every six hours, asks each service with a key for its models, tests the new chat models with a one-word question and adds those that answer. The README's old "live model list" paragraph described the 1.x relay and is corrected.

## 2.3
- **Tokens and time for each reply** (Chat, View, *Show Tokens and Time*, ⌥⇧⌘T): tokens in and out and the time taken, shown under the reply.
- **Auto model and cost**: the call that picks a model, the background model notes, and chat titles, summaries and memory updates now count toward the chat's cost and your spending limits (notes, which belong to no chat, toward the day's total).
- **Subagents**: a live progress card (each helper's model, steps and current tool), settings for how many tasks a request may hold and how many run at once, and a choice of which model helpers use: the model picks per task (shown the usable models with notes, so a larger model can send simple work to a smaller one such as Haiku 5.5), always the chat's own, or one fixed model (Tool Settings, Subagents). Sonnet 5.5 and Haiku 5.5 are in the Claude model list.
- **Skills**: edit a skill in the app, and *From This Chat...* drafts one from the conversation with the chat's model.
- **Bookmarks**: notes, *Manage Bookmarks...* (searchable), a *Bookmarked only* filter in Find in Chats, and bookmark marks in Markdown, text and PDF exports.
- **Pinned chats** can be put in order by dragging, or with Chat, *Move Pinned Chat Up / Down*.

## 2.2
- **Pin Chat**, a clickable **bookmark star** (shown beside the message under the pointer, and kept on bookmarked ones) (and Chat, *Bookmark Last Message*), **Auto** in the service list (Preferences, *Show Auto in model list*), an option to **play the finished-reply sound for the chat on screen** too, a **shortcut for every menu item**; the chat name box now closes when you click elsewhere; Preferences wording and layout fixes, and the *Let models start subagents* switch moved to Built-in Tools (its setting was not being saved).
- **Auto model** (optional, Preferences, General): the first message of a new chat is read by the model you choose, which picks the most suitable of your usable models; the chat then uses it as if you had picked it. A chat's context readout and longest answer now follow its model when it changes.
- **Export a chat as JSON for other tools**: ChatGPT-style and Claude-style `conversations.json`, and LibreChat JSON.
- **Skills** (folders with a `SKILL.md`, Claude-skill compatible; Chat, *Skills...*), **subagents** (`run_subagents`: parallel helpers on Macs with several cores, off until switched on in Tool Settings, Built-in Tools, and per chat), **model parameters** (temperature, top P, longest answer, per chat or workspace; refused values are dropped with a note), and **bookmarks** (star a message, jump from Chat, *Bookmarks*).
- **Fix**: requests to a server on a port other than 80 or 443 now name the port in the `Host` header.
- **Saved and scheduled prompts**, **Try Last Message with Another Model**, **Quick Ask** (with an optional global shortcut and a Services entry), a **Cost Report**, **import of ChatGPT and Claude exports**, a **lock** with a password (Preferences, Privacy), and **Copy Diagnostics**.
- **Three more tools for the model**: reading a web page by its address, a per-workspace **knowledge folder** it can search and open, and read-only **Calendar, Contacts and Mail** questions (`mac_calendar_events`, `mac_contacts_search`, `mac_mail_unread`).
- **MCP servers over the older HTTP+SSE transport** (found automatically), and **OAuth sign-in** for servers that ask for it (discovery, self-registration, PKCE, browser sign-in on a loopback port, token refresh; Configuration, *Forget Saved MCP Sign-Ins...*).
- **OpenRouter** through the Local LLM Server settings: the model list shows the tool-capable models by name with their context lengths, priced from OpenRouter's own list.
- **Automatic memory per workspace** (optional): a few notes about you, kept up to date after each reply and told to the model in every chat of the workspace; viewable, editable and clearable.
- **Audio and video attachments**: audio files are transcribed (up to 30 minutes, in pieces, with times) through the speech-to-text service you have a key for; videos give four pictures and the words of their sound (Tiger cannot read the sound of mp4 and mov files).
- **Export a chat as PDF** (Chat, Export This Chat): paginated, with code blocks, headings and the chat's pictures.
- **EPUB books** (title, author, chapter text and cover) and **ZIP archives** (the file list) can be attached and read by `convert_file`. **Quick Look** previews them too, and shows **Markdown** and **CSV** files as formatted pages.
- **Uninstaller**: Configuration, *Uninstall Tiger Build...* (or `sudo /usr/local/tbssh/bin/tiger-build-uninstall`), with an option to delete your data and saved keys too.
- **A sound when a reply finishes** off screen or in the background, and a Dock bounce; **spending limits** per chat and per day; **Check for Updates...** against the latest GitHub release (once a day at start, switchable). Preferences has a new Alerts tab.
- **JPEG XL pictures** (`.jxl`) can be attached and are read by `convert_file`: lossy and lossless, with transparency (shown on white), 16-bit and grey pictures, and animations (up to four frames of the first 120 are shown). The decoder is [jxldec](https://github.com/kjk/jxldec), plain C, built into the app for PowerPC and Intel; it matches libjxl to within one step on the files tried. See `third_party/jxldec`.
- **Quick Look** (Leopard and Snow Leopard) shows JPEG XL pictures and previews `.json` files as text.

## 2.1
- **The approval prompt names the chat** that wants to run the tool, which matters when several chats work at once.

## 2.0
- **Commander is a native program** (Objective-C, inside the app), not Python. It starts with a chat that uses it, listens on no port, and runs only for Tiger Build on the same Mac unless you turn on **Commander → Allow Other Computers**. Nothing needs Remote Login unless you want another computer to use this one.
- **Other computers** are added as MCP servers over SSH (user@address and a command), with *Commander on another computer* as a preset; Tiger Build's own key and a host list you confirm are used. Every MCP server can have a description or instructions for the model.
- **Administrator (sudo)** is also a per-chat switch in the Tools menu; turning it on turns Commander on and asks for the password once.
- **Appearance** has four tabs: Chat, Tool Calls, Status Text (with shadow or glow), and Interface (chat list, labels, buttons, menus, and the window look). All settings windows stay in front of the chat.
- **Old Office files**: Word `.doc`, Excel `.xls` and PowerPoint `.ppt` (97 to 2003) are read as text. **AVIF** pictures are converted (libaom, with rotation, mirroring, colour and alpha), including on PowerPC.
- **Several chats can work at once** in one window: start a reply, switch to another chat and start another; each keeps going, and a dot marks the working chats in the list. Stop, Guide and the thinking strip follow the chat on screen. **System info** reports the displays (count, resolution, refresh rate, size). **Currency** and **US inflation** example servers, and **Gemini** can search with Google. ChatGPT video is gone because OpenAI closed its Videos API.
- **Download tool** (off by default; Tool Settings → Web Search, then the Tools menu item per chat): a model can fetch a file over https (TLS 1.2/1.3, certificate checked, public addresses only, 50 MB cap) into the chat's files after you approve it. Tool steps per reply can be set up to 1000, or 0 for no limit.
- **Screen control** for agents (a per-chat Tools menu item, ask-first): click, drag, scroll, type and key presses on the main display, in the pixels of the last screenshot. **Commander Options**: your own command blocklist, optional unified diffs on every write and edit, and an optional hidden Login Item for when other computers use this Mac.
- **Installer extras**: `sshfs` in `/usr/local/tbssh/bin` (mount another computer over the bundled ssh; needs MacFUSE) and a **Quick Look generator** on Leopard and Snow Leopard (previews and thumbnails for HEIC, AVIF and WebP pictures, and docx, xlsx, pptx and OpenDocument files; Tiger has no Quick Look).
- **Third-party READMEs** in `third_party/` (what each library is for, source, licence, changes, how to rebuild) and `tiger-build/THIRD-PARTY.md` for the certificate list and emoji.
- **Hardening**: pictures and downloads connect only to public addresses (checked on the address actually dialled, so DNS tricks cannot reach the local network); keys and tokens are not sent on redirects to another host or to plain http; file parsers (Word, zip, HEIC and AVIF) check sizes without integer wrap-around; scratch files are in a private folder; HTTP MCP servers on a private network must be an IP address, not a name starting with `10.`.
- **Remote sudo as its own option**: Preferences, Commander Options, *Let other computers run administrator (sudo) commands here* (needs Allow Other Computers), with a Keychain key to copy into the other computer's server Environment (`TB_SUDO_KEY`). Whether sudo runs still depends on the chat that is running: every Commander gets its own key and only chats with the sudo item ticked have one, so chats in several windows can differ, and local chats use their own item whatever the remote setting says. New chats no longer start with sudo, download or screen control ticked.
- **A current OpenSSH on the old Macs**: the app carries OpenSSH 10.6p1 with LibreSSL linked in (ed25519, ECDSA and RSA keys, ML-KEM key exchange; ppc, i386 and x86_64) and uses it for other computers, switching the old algorithms back on and using an RSA key for a stock old Remote Login, per host. For Allow Other Computers the installer adds **Tiger Build's own SSH server** (`/usr/local/tbssh`, port 2222, off until Allow Other Computers is turned on, with the system's administrator dialog): key login only, from the keys listed in Preferences, SSH Server, and it can run nothing but Commander. Remote Login on port 22 is not touched.
- **Commander `convert_file`**: a model can read Word, Excel, PowerPoint (also the old formats), OpenDocument, iWork files and HEIC, AVIF, WebP and other pictures through Tiger Build's own converter, on this Mac or another one that has the app.
- **Hide Chat List** (Window menu, Command-backslash).
- **Security fixes**: the administrator password is handed only to a Commander that holds the key of a chat with the sudo item ticked; text typed into a running program (`interact_with_process`) goes through the same blocked-command, workspace and sudo checks as a new command; `git grep -O` (which runs a program) is refused; an imported chat or history file no longer carries approval choices or the sudo and download switches; `read_file` no longer reads `file:` or other non-web addresses; git options that run programs or write outside the workspace are refused (including abbreviated and `--opt=/path` forms); sudo is available only to a chat that ticks its Tools menu item.
- No Python remains in the app, the installer or the build: helper tools are C, Objective-C or shell, and the test servers are native too.
- **No relay.** Tiger Build now talks to the AI services itself, over TLS 1.3 and 1.2 from a built-in Mbed TLS 3.6 (patched for gcc 4.0 and the old SDKs, with the Mozilla certificate list). Tested on PowerPC and Intel, Tiger to Snow Leopard. Handshakes take about 0.1 to 0.25 s on a G4 or G3.
- Everything the relay did is in the app: providers (Grok, ChatGPT, Claude, Gemini, Mistral, Muse, local), the tool loop with Stop, guidance, approvals, compaction and consulting other models, cost estimates, file conversion (Word, Excel, PowerPoint, OpenDocument, Pages, Numbers, Keynote, WebP, HEIC, AVIF and other pictures), dictation, picture and video making, files from the model (`.docx`, `.xlsx`, `.pdf`), web and picture search, and the agent toolbox.
- **Keys are kept in the Keychain**; there is no relay token or address any more.
- **MCP servers**: programs on the Mac, or `http://` and `https://` Streamable HTTP servers. The four example servers are built in.
- Removed: the relay, its Mac, Windows and Linux apps and installers, "history on the relay", and the SSH link the relay used. The installer no longer turns on Remote Login.
- Importing a 1.x settings backup brings the keys across.

## 1.5
- **Appearance** (⌥⌘K): iChat-style bubble colours, text colours, fonts and chat background (solid, gradient or picture), with Reset to Default; iChat's thought cloud shows while a reply is starting.
- **Administrator (sudo) mode** for Commander 0.5.0, off by default: tick it in Preferences, Commander and type the password once; it is kept in the Keychain and the model never sees it. Without the mode, commands containing `sudo` are refused.
- **Emoji** as colour pictures (Twemoji, CC-BY 4.0) in chats and the chat list on Macs before 10.7, which have no emoji font.
- The `.deb` also depends on systemd and ca-certificates and recommends the HEIC decoder and xdg-utils.
- **Example MCP servers** are added on first setup, now with a weather one (wttr.in through `curl`); removing one sticks.
- **Local models**: Ollama works as well as LM Studio. The relay reads each Ollama model's context length from the server instead of assuming 32k.
- **Provider icons** beside each service in the provider popup and the Model menu.
- The chat list shows a chat's full title when you hover over it.

## 1.4
- **Attach files** by button, drag, Dock icon or paste: text, code, PDF, Word, Excel, PowerPoint, Pages, Numbers, Keynote, RTF, HTML and pictures (including HEIC and WebP). The relay converts what old Macs cannot read. Each attach is read one at a time, checked against the model's context, and explained the first time per service.
- **Files from the model**: real .docx, .xlsx, .pdf or any file, with Save As. Pictures a tool views appear in the chat.
- **Replies**: code blocks that name the language, colour about 40 languages and offer Save and Copy; tables, links, italics and headings; emoji shown as text on Macs that cannot draw them.
- **Chats**: export and import one chat with its files; Edit From Here and Branch Chat From Here; Find in Chats; Custom Instructions; text size for the chat, list and message box; rolling backups of every workspace file; VoiceOver labels.
- **Source control** in Commander 0.4.0: `repo_info`, `git_read`, `git_write`, `svn_read`, `svn_write`, with totals on the tool card. Read tools never ask first.
- **Voice** (optional, off by default): speak replies, spoken commands, and Dictate, which records on the Mac and transcribes on the relay with OpenAI, Mistral or Google.
- **Relay**: Claude prompt caching, a version check, an SSH tunnel helper (`relay/tunnel.py`), conversion limits and picture conversion on Windows.
- Tools that act on the Mac ask first, by default, in chats with attachments.

## 1.3.1
- Relay web and picture search, inline video on 64-bit Snow Leopard, Commander `view_image`.

## 1.3
- Leopard and Snow Leopard support, Stop and guidance, cost estimate, compaction, per-tool approvals, screenshots, directory restriction and connected Macs. See [`docs/RELEASE-REVIEW.md`](docs/RELEASE-REVIEW.md).
