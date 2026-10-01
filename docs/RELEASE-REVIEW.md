# Tiger Build 1.2 — final review

Consulted Claude Opus 5.5 and Grok 4.7 against concrete installer/GUI code.

## Corrections in this pass
- Checked old-relay stop results before upgrades, including Mac migration; captured output stays private.
- Staged app replacement with rollback; preserved installed app/.env when the package has none.
- Added controller timeouts and error results; Tk receives worker results on the main thread via a queue.
- Moved Tools/MCP load/save off the UI thread; exported backups atomically with private permissions.
- Made scheduled-task errors terminating and removed stale fallback startup files when disabling autostart.
- Hid the Windows supervisor's relay child as well as controller console subprocesses.
- Built the Mac settings app as universal x86_64/arm64; signed after writing final resources.
- Removed the ARM64-specific Python preference from the Windows build script.
- Corrected documentation about blank local-server URLs and package app locations.

## Verified
- 27 relay tests and relay self-test passed locally; 27 tests also passed on Ubuntu.
- Tiger make test and Commander self-test passed on the Tiger machine.
- Ubuntu settings window loaded status and opened Tools/MCP with no callback errors.
- Rebuilt Windows zip, Debian package, and Mac relay package match the reviewed sources.
- Windows zip has no native CPU binaries; Debian control declares Architecture: all and Version: 1.2.
- Package member lists exclude live settings, .env, relay tokens, and SSH private keys.
- No second packaged Linux service unit; the active service uses the per-user installation.
- Packaged Mac app has both CPU slices, verifies its ad-hoc signature, and installs non-relocatably into /Applications.
- README Why Do This? remains byte-identical to the preserved original.

## Limits / remaining installation steps
- x64 Windows/Linux runtime testing and reboot/autostart tests have not been done.
- Windows SSH was unavailable: this pass rebuilt its package but did not update its installed copy or Downloads files.
- Mac relay code is updated; replacing the protected /Applications GUI requires an administrator package install.
