# Release review

What was tested, where, and what was not. Features are listed in [`CHANGELOG.md`](../CHANGELOG.md).

## 1.4

### Test machines
Tiger 10.4.11 (PowerPC G4) and 10.4.12 (iMac G3 700 MHz), Leopard 10.5.8 (Intel), Snow Leopard 10.6.8 (Intel). Relays: macOS, Ubuntu 26.04 ARM64, Windows 11 ARM64. Services: Claude, Grok, Gemini, ChatGPT, Mistral and a local model.

### Verified
- **Automated.** The relay test suite and self-test (also on Ubuntu and Windows), `make test` on every client Mac, and the Commander self-test on Python 2.3, 2.5 and 2.6. Menu shortcuts are unique everywhere (`--list-shortcuts`).
- **Leopard.** The app launches and works as i386, x86_64 and ppc under Rosetta. Video plays inline in i386 and ppc; x86_64 offers double-click playback, because 64-bit QuickTime needs 10.6.
- **Attachments.** Text, RTF, PDF (including a 19-page drawing set), Word, Excel, PowerPoint, Pages, Numbers, Keynote, HEIC, WebP and sideways JPEGs were attached from real files and a model answered questions about each. A truncated Keynote file gives a clear error. Drag and drop, paste, cancel, the context-fit prompt and the relay-version notice were each exercised.
- **Models.** Pictures reach all five cloud services; a model without vision is told. Files from the model (Save As, Word, Excel, PDF) and pictures a tool views appear in the chat. Claude's prompt cache was confirmed live (a second turn over a 31k-token attachment cost $0.006 instead of $0.077).
- **Chats.** Export and import of a chat with files, edit and branch from any message, find, custom instructions, text size, emoji shown as text on Tiger, rolling backups.
- **Source control.** Real Subversion repositories on Leopard (1.4) and Snow Leopard (1.6), and a model completing status, diff, commit and log through the relay. git with a stand-in program only (arguments, environment, path limits, refusals, missing-git message); no test Mac has git.
- **Voice.** Reading replies aloud was heard on Tiger and Snow Leopard. Dictate recorded and transcribed correctly on Snow Leopard, Leopard (all three builds) and the iMac G3, and all three speech services transcribed a test clip. The G4 has no microphone and says so.
- **Relays.** Windows needed `os.replace` instead of `os.rename`, and converts HEIC and WebP with the built-in imaging component. Ubuntu needs `libheif-examples` and `libheif-plugin-libde265` for HEIC.

### Not verified
- The `ppc64` slice (no working G5) and Intel Tiger hardware. Both byte orders are covered by other runs.
- The spoken phrases of Voice Commands (they need a person speaking), and VoiceOver itself; only the labels were checked with `TigerBuild --list-accessibility`.
- Pages, Numbers and Keynote text is recovered, not exact: slide order can differ and table layout is lost.

## 1.3

### Requirements

| Requirement | Status |
| --- | --- |
| Formal Snow Leopard and Leopard support | Tested on Snow Leopard 10.6.8 and Leopard 10.5.8 (i386, x86_64, and ppc under Rosetta) |
| Brushed metal still on Tiger | Yes (screenshots) |
| Extra capability on newer systems | 64-bit slices, native Cocoa look, Quick Look on pictures (10.5+), no private menu calls on 10.5+. Modest by design |
| Delete all history deletes workspaces | Yes, tested |
| Delete one workspace; deleting all makes a new Default | Yes, tested on Snow Leopard |
| Intel client and Commander, 32 and 64-bit | Yes: i386 and x86_64 on Snow Leopard and Leopard; Commander on Python 2.5 and 2.6 |
| PPC64 where possible; G5 on Tiger falls back to 32-bit | `ppc64` slice builds; not run (no G5). Tiger has no 64-bit Cocoa, so it uses `ppc` |
| Export and import history for all workspaces at once | Yes, tested; 1.2 single-workspace files still import |
| Edit last message; retry last message | Yes, tested |
| Fits 1024x768 (800x600 nice to have) | Yes; checked at 1024x768, at an 800x550 window and at the 640x420 minimum |
| Menu bar item named Commander | Yes |
| Per-MCP on/off in the Tools menu, Commander included | Yes, tested with six servers |
| Tool approval on/off, per MCP server, remembered per chat | Yes, tested (Allow, Deny, Always Allow) |
| New chat uses last model and MCP options; default-model setting | Yes, tested |
| Commander limited to a directory per workspace | Yes; file tools strict, shell commands best-effort (documented) |
| Client user name and IP settable in relay settings | Mac app, Tk app (Linux, Windows), `control.py` and Tiger Build Preferences |
| Stop button | Yes, tested |
| Guidance messages, only on supported models, button shows running | Yes (Grok, ChatGPT, Claude, Gemini, Mistral); tested |
| Configuration panel fits; tidy MCP list with edit panel; tabs | Yes, tested with real servers |
| Commander runs on the Mac that is chatting (several Macs, one relay) | Yes, tested with two Macs at once |
| Auto-create and install shared SSH keys | Relay makes the key; Tiger Build installs it with no password; `setup.sh` can install it from a terminal. Tested |
| Active thinking at the bottom of the chat | Yes, tested |
| SSH error reporting | Yes: classified messages with the fix, shown on the chat |
| Screenshot tool for the model | Yes, tested |
| Avoid beach balls; no false disconnect warning on long runs | Warning fixed (75 s run, no warning). Beach balls reduced by design, not measured |
| Estimated cost, running total, price fetched at start, tiered rates | Yes ("Cost (est)"); local is N/A |
| Graceful exit at the output limit | Yes, tested live |
| Run needed shell commands in setup | `setup.sh` now makes the key and installs it from a terminal; the Mac package runs setup for the logged-in user (not run: needs root) |
| Context compaction | Yes: automatic and manual in the app (tested), trimming and summary inside long tool runs (unit-tested) |
| Model consult MCP | Yes, tested live (Claude asked Gemini) |

### Verified
- 69 relay tests, `make test` on Tiger and Snow Leopard, the Commander self-test, live runs against Claude, Grok and Gemini (usage and cost, guidance between steps, Stop ending a 15 s command in under 4 s, approvals, screenshots, model consult, output-limit note, price list and tiered rates).
- Custom MCP servers: the three examples plus the official filesystem, reference and time servers (41 tools), through the Tools menu, per-server approval and Stop.
- Commander per client: a Power Mac G4 and a MacBook Pro chatted at once through one relay and each ran its own `uname`; a computer that never connected was refused clearly.
- Ubuntu and Windows relays installed from the packages and ran a tool turn with a local model.

### Not verified
- Windows setup must run from your own desktop session; from an elevated SSH session the settings folder gets an ACL the desktop user cannot read.
- The Tk settings window's Tiger Mac tab was not clicked (its `control.py` commands were run), and the Swift relay app was rendered but not clicked through.
- The Mac package's post-install step needs root and was not run. x64 Windows and Linux are untested.
