param([string]$Flutter = 'D:/tools/flutter/bin/flutter.bat', [switch]$Offline)
$ErrorActionPreference = 'Stop'
$studyProject = Split-Path -Parent $PSScriptRoot
Push-Location $studyProject
try {
    $studyPubArguments = @('--no-version-check', 'pub', 'get')
    if ($Offline) { $studyPubArguments += '--offline' }
    Write-Host "Running Flutter pub get (offline=$($Offline.IsPresent))..."
    & $Flutter @studyPubArguments
    if ($LASTEXITCODE -eq 0) { exit 0 }
    if (-not (Test-Path '.flutter-plugins-dependencies')) {
        throw 'pub get failed before plugin metadata was generated'
    }
    $studyPlugins = Get-Content '.flutter-plugins-dependencies' -Raw | ConvertFrom-Json
    $studyLinks = Join-Path $studyProject 'windows/flutter/ephemeral/.plugin_symlinks'
    New-Item -ItemType Directory -Path $studyLinks -Force | Out-Null
    foreach ($studyPlugin in $studyPlugins.plugins.windows) {
        $studyLink = Join-Path $studyLinks $studyPlugin.name
        if (-not (Test-Path -LiteralPath $studyLink)) {
            New-Item -ItemType Junction -Path $studyLink -Value ([IO.Path]::GetFullPath($studyPlugin.path)) | Out-Null
        }
    }
    Write-Host 'Retrying dependency preparation offline after creating plugin junctions...'
    & $Flutter --no-version-check pub get --offline
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency preparation failed' }
} finally { Pop-Location }
