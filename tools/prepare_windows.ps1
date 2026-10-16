param([string]$Flutter = 'D:/tools/flutter/bin/flutter.bat')
$ErrorActionPreference = 'Stop'
$studyProject = Split-Path -Parent $PSScriptRoot
Push-Location $studyProject
try {
    & $Flutter pub get
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
    & $Flutter pub get --offline
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency preparation failed' }
} finally { Pop-Location }
