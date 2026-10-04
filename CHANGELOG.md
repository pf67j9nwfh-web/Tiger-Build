# Changelog

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
