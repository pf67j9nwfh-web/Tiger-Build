# Tiger Build release review

## 1.4

### What changed
- **Attach files.** Attach... button (beside Edit Last and Retry), Chat → Attach File (⇧⌘A), drop on the chat or the Dock icon. Text and code files, PDF (text via PDFKit, or the first page as a picture when there is none), RTF, Word, HTML, and pictures (kept as they are when small, else redrawn as a JPEG of at most 1600 pixels). Each is a message in the chat; the model gets the text (with where the copy is on that Mac) or the picture, and keeps it for the rest of the conversation. PDFs made mostly of drawings (little text for their pages) also send the first three pages as pictures, and text scraps such as one-letter-per-line watermarks are dropped. Non-vision models are told a picture was attached. Files kept for deleted chats, workspaces and cleared history are removed (a file stays while any chat uses it, and for ten minutes). Compaction summarizes older attachments.
- **Conversion on the relay** (`relay/extract.py`, `POST /v1/extract`): Word, Excel, PowerPoint and OpenDocument files become text; Pages, Numbers and Keynote files become the text read from their stored text objects plus the preview picture; HEIC, WebP, AVIF and JPEG photos become upright JPEGs (rotation tags are applied to the pixels, since Tiger ignores them). Standard library only, except pictures (`sips`, Pillow or ImageMagick).
- **Files from the model.** `agent_save_file` (not tied to the agent toolbox switch) puts a file in the chat with Save As. Each code block has Save and Copy.
- **Pictures a tool looks at** (`view_image`, `take_screenshot`) are also shown in the chat.
- **Code blocks.** Dark panels with the language named, syntax colours for about 30 languages and aliases, wrapping, selectable text; bold, inline code, headings and bullets in prose.
- **One chat to a file and back.** Export This Chat (⌥⌘E): a Tiger Build file with its attachments and pictures inside, Markdown, or plain text. Import Chat (⌥⌘I) adds it to the current workspace. No relay involved.

### Verified
- `make test` on Tiger 10.4.11 PowerPC and Snow Leopard 10.6.8 (new checks: fence splitting, language names, colouring, attachment text, base64, file names); relay tests and self-test.
- On both Macs, in the app: attaching text, RTF and pictures (Snow Leopard also PDF), a model reading them, Grok fixing an attached script through Commander and viewing the attached picture, `agent_save_file` giving a Save As file, export and import of a chat with a picture and a file, code blocks on PowerPC (including a long streamed answer). Pictures reach Claude, Grok, Gemini, ChatGPT and Mistral; the local model without vision is told.
- Menu shortcuts unique on both Macs (`--list-shortcuts`: 0 problems).

- Conversion run on real documents from both Macs' desktops: .docx, .xlsx, .pptx, .pages, .numbers, .key, .heic, .webp, a phone-style JPEG with a rotation tag, and a truncated 20 MB .key (clear error). Models answered questions about each on Tiger and Snow Leopard.

### Not verified
- Pages, Numbers and Keynote text is recovered, not exact: slide order can differ, table layout is lost. Keynote/Pages '09 packages that are folders (sent zipped) were not available to test. Dropping files by dragging (the same code path as the Dock icon and Attach, tested through those), Word documents (`.doc`/`.docx` rely on what the OS can open), PDFs on Tiger (no PDF tool there to make one).
- Leopard 10.5 and the `ppc64` slice, as before.

## 1.3

## What changed
- **Platforms.** One universal app for Mac OS X 10.4 Tiger, 10.5 Leopard and 10.6 Snow Leopard: `ppc` and `i386` (10.4 SDK) joined with `ppc64` and `x86_64` (10.6 SDK when installed, else 10.5) when built on Leopard or Snow Leopard. Brushed metal stays on Tiger; Leopard and Snow Leopard use their native textured look. 64-bit-safe delegate types (`TBCompat.h`), 64-bit CoreGraphics callbacks, inline QuickTime playback in the 32-bit slices and in x86_64 on 10.6+ (QTKit weak-linked, checked at run time; other 64-bit cases open the default player), Quick Look on 10.5+ for pictures, Tiger-only private menu calls skipped on 10.5+.
- **Chats.** Stop (⌘.), guidance while a model works, Retry and Edit Last, thinking strip above the message box, estimated cost per chat (summed across models, tiered rates, N/A for local), real context readout, graceful output-limit note, automatic and manual compaction, relay heartbeats instead of false disconnection warnings, throttled and cached transcript layout, Commander status read off the main thread.
- **Tools.** Tools button replaces the Commander button: per-chat on/off for Commander, toolbox, web search, other models and each MCP server; per-chat Ask Before Running (all or per tool) with Always Allow; model consult tool; web and picture search on the relay (free with no key; models can show pictures in the chat); Commander screenshots; workspace directory restriction.
- **Workspaces and history.** Delete a workspace; deleting the last creates a new Default; Clear All History removes workspaces; export, import and relay copy cover all workspaces; new chats start from the last chat's model and tools or a chosen default.
- **Setup.** SSH key made by the relay; Tiger Build installs it on its own Mac with no password (Configuration, Connect Commander over SSH); Tiger Mac address, user and home settable in the relay apps and in Preferences; SSH failures explained with the fix; `setup.sh` no longer needs config.sh edited first, can install the key from a terminal, and the Mac package runs it for the logged-in user.
- **UI.** Preferences and the tools window are tabbed and fit 1024x768 (and smaller windows clamp to the screen); MCP servers are a table with an edit sheet; Commander menu is named Commander; bubbles drawn like iOS 6 Messages on a pinstriped backdrop.

## Requirement checklist (1.3 list)

| Requirement | Status |
| --- | --- |
| Formal Snow Leopard and Leopard support | Snow Leopard 10.6.8 tested (x86_64 and i386). Leopard: built against the 10.5 SDK and uses the same code paths, but no Leopard machine was available |
| Brushed metal still on Tiger | Yes (screenshots) |
| Extra capability on newer systems | 64-bit slices, native Cocoa look, Quick Look on pictures (10.5+), no private menu calls on 10.5+. Modest by design |
| Delete all history deletes workspaces | Yes, tested |
| Delete one workspace; deleting all makes a new Default | Yes, tested on Snow Leopard |
| Intel client and Commander, 32 and 64-bit | Yes: i386 and x86_64 tested on Snow Leopard, Commander on Python 2.6 |
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
| Run needed shell commands in setup | `setup.sh` now makes the key and installs it from a terminal; the Mac package runs setup for the logged-in user (not run here: needs root) |
| Context compaction | Yes: automatic and manual in the app (tested), trimming and summary inside long tool runs (unit-tested) |
| Model consult MCP | Yes, tested live (Claude asked Gemini) |

## Verified
- 69 relay tests, relay self-test, `make test` on Tiger 10.4.11 PowerPC and Snow Leopard 10.6.8 Intel, `ppc_commander.py --self-test` on Python 2.3.5 (Tiger) and 2.6.1 (Snow Leopard).
- Live, against real models: Claude, Grok and Gemini replies with usage and cost frames; guidance delivered between steps; Stop ending a 15 s command in under 4 s; approval allow/deny; screenshot seen by Claude; model consult (Claude asked Gemini and the cost was counted); mid-run trimming; output-limit note; price list fetched and tiered rates applied.
- On Tiger (screenshots over SSH, driven with AppleScript and synthetic clicks): all windows and tabs, Stop, Guide, Edit Last, Tools menu, workspace restriction blocking `cat /etc/hosts`, Commander connect flow restoring a removed SSH key, commander auto-update 0.3.0 to 0.3.1.
- On Snow Leopard: x86_64 and i386 slices launch and chat; menu bar, workspaces create/delete, history export/clear/import across workspaces, approval dialog, thinking strip, SSH error line.
- Commander per client: Power Mac G4 and MacBook Pro chatted at the same time through one relay and each ran its own `uname`; a computer that was never connected got a clear refusal. (Found after a model on the MacBook described the G4: the relay had one global Commander target.)
- Menu bar: `TigerBuild --list-shortcuts` lists every item; all have unique shortcuts on Tiger and Snow Leopard.
- Custom MCP servers: three example servers (`mcp-examples/`) plus the official filesystem, reference ("everything") and time servers, 41 tools, run through the relay, the Tools menu, per-server approval and Stop.
- Linux (Ubuntu 26.04 ARM64) and Windows 11 ARM64 relays installed from the packages, connected to Tiger over SSH, and ran a tool turn with a local model.
- Packages built: relay `.pkg`, `.deb`, Windows zip, Tiger `.pkg`.

## Not verified
- No Leopard (10.5) machine and no G5 (`ppc64`) were available: those slices compile but have not been run.
- Windows: run `setup.py` from your own desktop session. From an elevated SSH session the settings folder gets an ACL the desktop user cannot read, and `ssh.exe` output pipes hang; neither happens when run normally (shown by running setup through a scheduled task in the desktop session).
- The Tk settings window was rendered (Linux, virtual display) but its Tiger Mac tab was not clicked; its backing `control.py` commands were run.
- x64 Windows/Linux runtime is as untested as before.
- The Mac relay package's post-install step (runs setup for the logged-in user) was not run: it needs root.
- The relay Mac app (Swift) was rendered with its snapshot mode, not clicked through.
- Beach-ball reduction is by design (cache, throttle, background thread), not measured against 1.2.
