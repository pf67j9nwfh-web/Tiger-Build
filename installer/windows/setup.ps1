# User-level unpack used by the Windows installer and by hand.
$ErrorActionPreference = "Stop"
$Dest = Join-Path $env:LOCALAPPDATA "Tiger Build Relay\package"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$Zip = Join-Path $PSScriptRoot "tiger-build-relay-payload.zip"
if (-not (Test-Path $Zip)) { throw "missing payload" }
tar -xf $Zip -C $Dest
Write-Output "Unpacked to $Dest"
Write-Output "Next, as your user: python `"$Dest\scripts\setup.py`""
