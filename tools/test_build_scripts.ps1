# Isolated native-process smoke checks. No Flutter build or external download.
$ErrorActionPreference = 'Stop'
$studyProject = Split-Path -Parent $PSScriptRoot
$studyFixtureRoot = Join-Path $studyProject ('validation/build-script-tests-' + [guid]::NewGuid().ToString('N'))
$studyFixtureSdk = Join-Path $studyFixtureRoot 'with spaces & 中文'
New-Item -ItemType Directory -Path $studyFixtureSdk -Force | Out-Null
$studyFixtureFlutter = Join-Path $studyFixtureSdk 'flutter.cmd'
$studyFixtureProject = Join-Path $studyFixtureRoot 'project with spaces & 中文'
$studyFixtureTools = Join-Path $studyFixtureProject 'tools'
New-Item -ItemType Directory -Path $studyFixtureTools -Force | Out-Null
foreach ($studyScript in @('build.ps1', 'prepare_windows.ps1', 'build_support.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $studyScript) -Destination $studyFixtureTools
}
$studyFixtureRelease = Join-Path $studyFixtureProject 'build/windows/x64/runner/Release'
$studyFixtureData = Join-Path $studyFixtureRelease 'data/flutter_assets/中文资源'
New-Item -ItemType Directory -Path $studyFixtureData -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $studyFixtureRelease 'data/empty') -Force | Out-Null
'fixture executable' | Set-Content -LiteralPath (Join-Path $studyFixtureRelease 'subjective_study.exe') -Encoding ascii
'fixture runtime' | Set-Content -LiteralPath (Join-Path $studyFixtureRelease 'flutter_windows.dll') -Encoding ascii
'fixture assets' | Set-Content -LiteralPath (Join-Path $studyFixtureData 'asset.txt') -Encoding ascii
$studyHiddenFile = Join-Path $studyFixtureRelease 'data/.hidden-resource'
'hidden fixture' | Set-Content -LiteralPath $studyHiddenFile -Encoding ascii
(Get-Item -LiteralPath $studyHiddenFile).Attributes = [IO.FileAttributes]::Hidden
$studyFixtureOutputs = Join-Path $studyFixtureProject 'outputs'
. "$PSScriptRoot/build_support.ps1"
$studySavedCalls = $env:STUDY_BUILD_TEST_CALLS
$studySavedMode = $env:STUDY_BUILD_TEST_MODE
$env:STUDY_BUILD_TEST_CALLS = Join-Path $studyFixtureRoot 'calls.txt'
@'
@echo off
echo %*>>"%STUDY_BUILD_TEST_CALLS%"
if "%STUDY_BUILD_TEST_MODE%"=="fail" if "%~3"=="build" (
  echo error: simulated compiler failure 1>&2
  exit /b 7
)
echo [ +1 ms] Resolving dependencies...
echo [ +1 ms] verbose-only-diagnostic
echo diagnostic-from-stderr 1>&2
powershell.exe -NoProfile -Command "Start-Sleep -Seconds 2"
echo [ +1 ms] Got dependencies!
exit /b 0
'@ | Set-Content -LiteralPath $studyFixtureFlutter -Encoding ascii

function Assert-StudyBuildTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAILED: $Message" }
}

try {
    foreach ($studyScript in @('build.ps1', 'prepare_windows.ps1', 'build_support.ps1')) {
        $studyTokens = $null; $studyErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $studyScript), [ref]$studyTokens, [ref]$studyErrors)
        Assert-StudyBuildTest ($studyErrors.Count -eq 0) "Parse $studyScript"
    }
    $studyBeforeLogs = @(Get-ChildItem (Join-Path $studyFixtureProject 'build-logs') -Filter '*.log' -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $env:STUDY_BUILD_TEST_MODE = 'ok'
    & "$studyFixtureTools/build.ps1" -Flutter $studyFixtureFlutter -Offline -HeartbeatSeconds 1
    $studyCalls = @(Get-Content -LiteralPath $env:STUDY_BUILD_TEST_CALLS)
    Assert-StudyBuildTest ($studyCalls.Count -eq 2) 'Dependency preparation must return to the Windows build exactly once'
    Assert-StudyBuildTest ($studyCalls[0] -match '"pub" "get" "--offline"') 'Offline mode reaches pub'
    Assert-StudyBuildTest ($studyCalls[1] -match '"build" "windows" "--release" "--no-pub"') 'Default builds only Windows'
    $studyLog = Get-ChildItem (Join-Path $studyFixtureProject 'build-logs') -Filter '*.log' | Where-Object { $studyBeforeLogs -notcontains $_.FullName } | Select-Object -Last 1
    $studyText = Get-Content -LiteralPath $studyLog.FullName -Raw -Encoding utf8
    Assert-StudyBuildTest ($studyText.Contains('仍在运行')) 'Quiet subprocess emits heartbeat'
    Assert-StudyBuildTest ($studyText.Contains('diagnostic-from-stderr')) 'stderr is drained and saved'
    Assert-StudyBuildTest ($studyText.Contains('verbose-only-diagnostic')) 'Hidden verbose lines remain in the log'
    Assert-StudyBuildTest ($studyText.Contains('全部构建完成')) 'Chinese status and success summary are saved'
    Assert-StudyBuildTest ($studyText.Contains('[4/4]') -and $studyText.Contains('压缩包：')) 'ZIP is a visible final stage'
    $studyZip = @(Get-ChildItem -LiteralPath $studyFixtureOutputs -Filter '*.zip')
    Assert-StudyBuildTest ($studyZip.Count -eq 1) 'Successful build creates exactly one ZIP'
    $studyCommit = Get-StudyBuildCommit $studyProject
    Assert-StudyBuildTest ($studyZip[0].Name -match ("^subjective-study-windows-x64-\d{{8}}-\d{{6}}-{0}\.zip$" -f $studyCommit)) 'ZIP name includes date, time and current short commit'
    $studyArchive = [IO.Compression.ZipFile]::OpenRead($studyZip[0].FullName)
    try {
        $studyEntries = @($studyArchive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        Assert-StudyBuildTest ($studyEntries -contains 'subjective_study.exe' -and $studyEntries -contains 'flutter_windows.dll') 'Executable and DLL are at archive root'
        Assert-StudyBuildTest ($studyEntries -contains 'data/flutter_assets/中文资源/asset.txt') 'Nested Unicode asset paths survive'
        Assert-StudyBuildTest ($studyEntries -contains 'data/.hidden-resource' -and $studyEntries -contains 'data/empty/') 'Hidden resources and empty folders survive'
    } finally { $studyArchive.Dispose() }
    $studyExtracted = Join-Path $studyFixtureRoot 'extracted'
    [IO.Compression.ZipFile]::ExtractToDirectory($studyZip[0].FullName, $studyExtracted)
    Assert-StudyBuildTest ((Get-FileHash -LiteralPath (Join-Path $studyExtracted 'data/flutter_assets/中文资源/asset.txt')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $studyFixtureData 'asset.txt')).Hash) 'Extracted resource bytes match the build output'
    $studyFirstHash = (Get-FileHash -LiteralPath $studyZip[0].FullName).Hash
    $studySecondZip = New-StudyWindowsArchive $studyFixtureProject $studyCommit
    Assert-StudyBuildTest ($studySecondZip -ne $studyZip[0].FullName -and (Get-FileHash -LiteralPath $studyZip[0].FullName).Hash -eq $studyFirstHash) 'Repeated packaging preserves the first ZIP'
    $studyOutputCount = @(Get-ChildItem -LiteralPath $studyFixtureOutputs -Filter '*.zip').Count

    $studyBeforeLogs = @(Get-ChildItem (Join-Path $studyFixtureProject 'build-logs') -Filter '*.log' | ForEach-Object FullName)
    $env:STUDY_BUILD_TEST_MODE = 'fail'
    $studyFailed = $false
    try {
        & "$studyFixtureTools/build.ps1" -Flutter $studyFixtureFlutter -Offline -HeartbeatSeconds 1
    } catch {
        $studyFailed = $_.Exception.Message -match '7'
    }
    Assert-StudyBuildTest $studyFailed 'Nonzero compiler exit is a failed build'
    $studyLog = Get-ChildItem (Join-Path $studyFixtureProject 'build-logs') -Filter '*.log' | Where-Object { $studyBeforeLogs -notcontains $_.FullName } | Select-Object -Last 1
    $studyText = Get-Content -LiteralPath $studyLog.FullName -Raw -Encoding utf8
    Assert-StudyBuildTest ($studyText.Contains('simulated compiler failure')) 'Compiler error remains in the log'
    Assert-StudyBuildTest ($studyText.Contains('构建中止') -and -not $studyText.Contains('全部构建完成')) 'Failure reports its stage and never reports success'
    Assert-StudyBuildTest (@(Get-ChildItem -LiteralPath $studyFixtureOutputs -Filter '*.zip').Count -eq $studyOutputCount) 'Failed compilation never packages stale output'

    $studyLocked = [IO.File]::Open((Join-Path $studyFixtureRelease 'subjective_study.exe'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $studyFailed = $false
        try { New-StudyWindowsArchive $studyFixtureProject $studyCommit | Out-Null } catch { $studyFailed = $true }
        Assert-StudyBuildTest $studyFailed 'Unreadable output fails packaging'
    } finally { $studyLocked.Dispose() }
    Assert-StudyBuildTest (@(Get-ChildItem -LiteralPath $studyFixtureOutputs -Filter '*.partial').Count -eq 0 -and @(Get-ChildItem -LiteralPath $studyFixtureOutputs -Filter '*.zip').Count -eq $studyOutputCount) 'Failed compression leaves no partial or misleading ZIP'
    Remove-Item -LiteralPath (Join-Path $studyFixtureRelease 'flutter_windows.dll')
    $studyFailed = $false
    try { New-StudyWindowsArchive $studyFixtureProject $studyCommit | Out-Null } catch { $studyFailed = $_.Exception.Message -match 'flutter_windows.dll' }
    Assert-StudyBuildTest $studyFailed 'Incomplete Release fails instead of producing a broken package'
    $studyIgnored = & git -C $studyProject check-ignore -- outputs/example.zip
    Assert-StudyBuildTest ($LASTEXITCODE -eq 0 -and $studyIgnored -eq 'outputs/example.zip') 'Root outputs directory is ignored'

    $studyParserContext = New-StudyBuildContext $studyFixtureProject
    $studyParserContext.Stage = '解析提示验证'
    $studyParserContext.PubOffline = $true
    try {
        $studyConsole = (& {
            Write-StudyBuildToolLine $studyParserContext '[ +1 ms] compiler.exe --verbosity=error' 'stdout'
            Write-StudyBuildToolLine $studyParserContext '       {"instanceId": "verbose-json-only"}' 'stdout'
            Write-StudyBuildToolLine $studyParserContext '[ +1 ms] Downloading packages...' 'stdout'
            Write-StudyBuildToolLine $studyParserContext '[ +1 ms] file.vcxproj: error MSB3073: simulated failure' 'stderr'
            Write-StudyBuildToolLine $studyParserContext '[ +1 ms] CMake Error at cmake_install.cmake:41 (file):' 'stderr'
            Write-StudyBuildToolLine $studyParserContext '  cannot copy runtime file' 'stderr'
        } 6>&1 | Out-String)
        Assert-StudyBuildTest ($studyConsole.Contains('从本地缓存读取依赖包')) 'Offline cached packages are not described as network downloads'
        Assert-StudyBuildTest ($studyConsole.Contains('error MSB3073')) 'Real compiler diagnostics remain visible'
        Assert-StudyBuildTest ($studyConsole.Contains('CMake Error') -and $studyConsole.Contains('cannot copy runtime file')) 'Multiline CMake failure context remains visible'
        Assert-StudyBuildTest (-not $studyConsole.Contains('--verbosity=error') -and -not $studyConsole.Contains('verbose-json-only')) 'Verbose commands and JSON do not flood the console'
    } finally { $studyParserContext.Writer.Dispose() }
    Write-Host 'PASS: Windows PowerShell parsing, paths with spaces/Unicode, streaming logs, heartbeat, offline flags, dated commit ZIPs, complete resources, repeat packaging and failure cleanup.' -ForegroundColor Green
} finally {
    $env:STUDY_BUILD_TEST_CALLS = $studySavedCalls
    $env:STUDY_BUILD_TEST_MODE = $studySavedMode
}
