param()
$ErrorActionPreference = 'Stop'
$studyRoot = Split-Path -Parent $PSScriptRoot
$studyRelease = Join-Path $studyRoot 'build/windows/x64/runner/Release'
$studyApk = Join-Path $studyRoot 'build/app/outputs/flutter-apk/app-release.apk'
if (-not (Test-Path (Join-Path $studyRelease 'subjective_study.exe'))) { throw 'Build Windows Release first' }
if (-not (Test-Path $studyApk)) { throw 'Build Android Release first' }
$studyDist = Join-Path $studyRoot 'dist'
New-Item -ItemType Directory -Path $studyDist -Force | Out-Null
Copy-Item -LiteralPath $studyApk -Destination (Join-Path $studyDist 'subjective-study-android.apk') -Force
Copy-Item -LiteralPath (Join-Path $studyRoot 'demo-data/demo.study.zip') -Destination (Join-Path $studyDist 'demo.study.zip') -Force
Copy-Item -LiteralPath (Join-Path $studyRoot 'README.md') -Destination (Join-Path $studyDist 'README.md') -Force
Compress-Archive -Path (Join-Path $studyRelease '*') -DestinationPath (Join-Path $studyDist 'subjective-study-windows-x64.zip') -Force
$studyHashes = Get-ChildItem -LiteralPath $studyDist -File | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object Name | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name
}
$studyHashes | Set-Content -LiteralPath (Join-Path $studyDist 'SHA256SUMS.txt') -Encoding utf8
Get-ChildItem -LiteralPath $studyDist -File | Select-Object Name, Length
