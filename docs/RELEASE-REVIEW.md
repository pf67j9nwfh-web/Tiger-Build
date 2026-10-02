# Tiger Build 1.3 — release review

## What changed
- **Platforms.** One universal app for Mac OS X 10.4 Tiger, 10.5 Leopard and 10.6 Snow Leopard: `ppc` and `i386` (10.4 SDK) joined with `ppc64` and `x86_64` (10.5 SDK) when built on Leopard or Snow Leopard. Brushed metal stays on Tiger; Leopard and Snow Leopard use their native textured look. 64-bit-safe delegate types (`TBCompat.h`), 64-bit CoreGraphics callbacks, QuickTime playback only in 32-bit slices (64-bit opens videos in the default player), Quick Look on 10.5+ for pictures, Tiger-only private menu calls skipped on 10.5+.
- **Chats.** Stop (⌘.), guidance while a model works, Retry and Edit Last, thinking strip above the message box, estimated cost per chat (summed across models, tiered rates, N/A for local), real context readout, graceful output-limit note, automatic and manual compaction, relay heartbeats instead of false disconnection warnings, throttled and cached transcript layout, Commander status read off the main thread.
- **Tools.** Tools button replaces the Commander button: per-chat on/off for Commander, toolbox, web search, other models and each MCP server; per-chat Ask Before Running (all or per tool) with Always Allow; model consult tool; Commander screenshots; workspace directory restriction.
- **Workspaces and history.** Delete a workspace; deleting the last creates a new Default; Clear All History removes workspaces; export, import and relay copy cover all workspaces; new chats start from the last chat's model and tools or a chosen default.
- **Setup.** SSH key made by the relay; Tiger Build installs it on its own Mac with no password (Configuration, Connect Commander over SSH); Tiger Mac address, user and home settable in the relay apps and in Preferences; SSH failures explained with the fix; `setup.sh` no longer needs config.sh edited first, can install the key from a terminal, and the Mac package runs it for the logged-in user.
- **UI.** Preferences and the tools window are tabbed and fit 1024x768 (and smaller windows clamp to the screen); MCP servers are a table with an edit sheet; Commander menu is named Commander; bubbles drawn like iOS 6 Messages on a pinstriped backdrop.

## Verified
- 69 relay tests, relay self-test, `make test` on Tiger 10.4.11 PowerPC and Snow Leopard 10.6.8 Intel, `ppc_commander.py --self-test` on Python 2.3.5 (Tiger) and 2.6.1 (Snow Leopard).
- Live, against real models: Claude, Grok and Gemini replies with usage and cost frames; guidance delivered between steps; Stop ending a 15 s command in under 4 s; approval allow/deny; screenshot seen by Claude; model consult (Claude asked Gemini and the cost was counted); mid-run trimming; output-limit note; price list fetched and tiered rates applied.
- On Tiger (screenshots over SSH, driven with AppleScript and synthetic clicks): all windows and tabs, Stop, Guide, Edit Last, Tools menu, workspace restriction blocking `cat /etc/hosts`, Commander connect flow restoring a removed SSH key, commander auto-update 0.3.0 to 0.3.1.
- On Snow Leopard: x86_64 and i386 slices launch and chat; menu bar, workspaces create/delete, history export/clear/import across workspaces, approval dialog, thinking strip, SSH error line.
- Packages built: relay `.pkg`, `.deb`, Windows zip.

## Not verified
- No Leopard (10.5) machine and no G5 (`ppc64`) were available: those slices compile but have not been run.
- The Windows and Ubuntu relay builds were produced on the Mac but not installed or run on those machines, and the Tk settings window changes (Tiger Mac tab) are untested.
- x64 Windows/Linux runtime is as untested as before.
- The relay Mac app (Swift) was rendered with its snapshot mode, not clicked through.
- Beach-ball reduction is by design (cache, throttle, background thread), not measured against 1.2.
