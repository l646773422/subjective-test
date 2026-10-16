param([string]$Flutter = 'D:/tools/flutter/bin/flutter.bat', [switch]$Android)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    & "$PSScriptRoot/prepare_windows.ps1" -Flutter $Flutter
    & $Flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
    if ($Android) {
        & $Flutter build apk --release --target-platform android-arm64,android-x64
        if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
    }
} finally { Pop-Location }
