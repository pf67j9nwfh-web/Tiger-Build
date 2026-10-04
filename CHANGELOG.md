# Changelog

## 1.4
- Attach files (text, code, PDF, Word, Excel, PowerPoint, Pages, Numbers, Keynote, RTF, HTML, pictures including HEIC and WebP), by button, drag, Dock icon or paste; read one at a time, with a context-fit check and a notice before they go to a cloud service. The relay converts what old Macs cannot read.
- Models can hand back files (real .docx, .xlsx, .pdf, or any file) with a Save As button; pictures a tool looks at are shown in the chat.
- Code blocks with the language named, syntax colours (about 40 languages, script/style inside HTML) and Save/Copy; tables, links, italics and headings in replies; emoji shown as text on Macs that cannot draw them.
- Export and import a single chat (with its files); History export carries attachments; five rolling backups of every workspace file.
- Edit From Here, Branch Chat From Here, Find in Chats, Custom Instructions, text size, Attach PDF Pages, Stop cancels attaching.
- Relay: prompt caching for Claude (about 90% cheaper on long attached chats), conversion limits, media pruning, version check, tunnel helper (`scripts/relay-tunnel.sh`), Windows picture conversion built in.
- Source control: `repo_info`, `git_read`/`git_write`, `svn_read`/`svn_write` in Commander 0.4.0 (read-only tools never prompt; unsafe options refused).
- Text size covers the chat list and message box; VoiceOver labels; Claude one-hour prompt cache for big prompts.
- Optional voice mode (off by default): read replies aloud, auto-speak, five spoken commands, choose a voice, and Dictate (record on the Mac, transcribe on the relay with OpenAI, Mistral or Google).
- Tools ask first, by default, in chats that have attached files.
- Tested on Tiger 10.4.11 PowerPC, Leopard 10.5.8 (i386, x86_64 and ppc under Rosetta) and Snow Leopard 10.6.8; relays on macOS, Ubuntu 26.04 ARM64 and Windows 11 ARM64. Not tested: ppc64 and Intel Tiger hardware.

## 1.3.1
- Relay web and picture search, inline video on 64-bit Snow Leopard, Commander `view_image`.

## 1.3
- Leopard and Snow Leopard support, Stop and guidance, cost estimate, compaction, per-tool approvals, screenshots, directory restriction, connected Macs, and more. See docs/RELEASE-REVIEW.md.
