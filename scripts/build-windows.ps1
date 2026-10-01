# Build the same source archive for x64 and ARM64. Python 3.8+ is required.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Candidates = @()
$Python = Get-Command python -ErrorAction SilentlyContinue
if ($Python -and $Python.Source -notmatch 'WindowsApps') { $Candidates += $Python.Source }
$Base = Join-Path $env:LOCALAPPDATA 'Programs\Python'
if (Test-Path $Base) {
    $Candidates += Get-ChildItem $Base -Directory | ForEach-Object {
        $Exe = Join-Path $_.FullName 'python.exe'
        if (Test-Path $Exe) { $Exe }
    }
}
$Py = $null
foreach ($Candidate in $Candidates) {
    & $Candidate -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)' 2>$null
    if ($LASTEXITCODE -eq 0) { $Py = $Candidate; break }
}
if (-not $Py) { throw 'Install Python 3.8 or later from python.org (x64 or ARM64), then retry.' }
& $Py (Join-Path $Root 'scripts\build-windows-zip.py')
if ($LASTEXITCODE -ne 0) { throw 'Windows package failed.' }
