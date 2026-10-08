# Changelog

## 2.0
- **Commander is a native program** (Objective-C, inside the app), not Python. It starts with a chat that uses it, listens on no port, and runs only for Tiger Build on the same Mac unless you turn on **Commander → Allow Other Computers**. Nothing needs Remote Login unless you want another computer to use this one.
- **Other computers** are added as MCP servers over SSH (user@address and a command), with *Commander on another computer* as a preset; Tiger Build's own key and a host list you confirm are used. Every MCP server can have a description or instructions for the model.
- **Administrator (sudo)** is also a per-chat switch in the Tools menu; turning it on turns Commander on and asks for the password once.
- **Appearance** has four tabs: Chat, Tool Calls, Status Text (with shadow or glow), and Interface (chat list, labels, buttons, menus, and the window look). All settings windows stay in front of the chat.
- **Old Office files**: Word `.doc`, Excel `.xls` and PowerPoint `.ppt` (97 to 2003) are read as text. **AVIF** pictures are converted (libaom, with rotation, mirroring, colour and alpha), including on PowerPC.
- **Several chats can work at once** in one window: start a reply, switch to another chat and start another; each keeps going, and a dot marks the working chats in the list. Stop, Guide and the thinking strip follow the chat on screen. **System info** reports the displays (count, resolution, refresh rate, size). **Currency** and **US inflation** example servers, and **Gemini** can search with Google. ChatGPT video is gone because OpenAI closed its Videos API.
- **Download tool** (off by default; Tool Settings → Web Search, then the Tools menu item per chat): a model can fetch a file over https (TLS 1.2/1.3, certificate checked, public addresses only, 50 MB cap) into the chat's files after you approve it. Tool steps per reply can be set up to 1000, or 0 for no limit.
- **Screen control** for agents (a per-chat Tools menu item, ask-first): click, drag, scroll, type and key presses on the main display, in the pixels of the last screenshot. **Commander Options**: your own command blocklist, optional unified diffs on every write and edit, and an optional hidden Login Item for when other computers use this Mac.
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
