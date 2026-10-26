param(
    [string]$Flutter = 'D:/tools/flutter/bin/flutter.bat',
    [switch]$Android,
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    $studyBuildTimer = [Diagnostics.Stopwatch]::StartNew()
    $studyBuildSteps = if ($Android) { 3 } else { 2 }
    Write-Host "[1/$studyBuildSteps] Preparing dependencies (Flutter SDK update check disabled)..."
    & "$PSScriptRoot/prepare_windows.ps1" -Flutter $Flutter -Offline:$Offline
    Write-Host "[2/$studyBuildSteps] Building Windows Release..."
    & $Flutter --no-version-check build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
    if ($Android) {
        Write-Host '[3/3] Building Android Release...'
        & $Flutter --no-version-check build apk --release --target-platform android-arm64,android-x64
        if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
    }
    Write-Host "Build completed in $([math]::Round($studyBuildTimer.Elapsed.TotalSeconds, 1)) seconds."
    Write-Host (Join-Path (Get-Location).Path 'build/windows/x64/runner/Release/subjective_study.exe')
} finally { Pop-Location }
