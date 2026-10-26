# Isolated native-process smoke checks. No Flutter build or external download.
$ErrorActionPreference = 'Stop'
$studyProject = Split-Path -Parent $PSScriptRoot
$studyFixtureRoot = Join-Path $studyProject ('validation/build-script-tests-' + [guid]::NewGuid().ToString('N'))
$studyFixtureSdk = Join-Path $studyFixtureRoot 'with spaces & 中文'
New-Item -ItemType Directory -Path $studyFixtureSdk -Force | Out-Null
$studyFixtureFlutter = Join-Path $studyFixtureSdk 'flutter.cmd'
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
    $studyBeforeLogs = @(Get-ChildItem (Join-Path $studyProject 'build-logs') -Filter '*.log' -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $env:STUDY_BUILD_TEST_MODE = 'ok'
    & "$PSScriptRoot/build.ps1" -Flutter $studyFixtureFlutter -Offline -HeartbeatSeconds 1
    $studyCalls = @(Get-Content -LiteralPath $env:STUDY_BUILD_TEST_CALLS)
    Assert-StudyBuildTest ($studyCalls.Count -eq 2) 'Dependency preparation must return to the Windows build exactly once'
    Assert-StudyBuildTest ($studyCalls[0] -match '"pub" "get" "--offline"') 'Offline mode reaches pub'
    Assert-StudyBuildTest ($studyCalls[1] -match '"build" "windows" "--release" "--no-pub"') 'Default builds only Windows'
    $studyLog = Get-ChildItem (Join-Path $studyProject 'build-logs') -Filter '*.log' | Where-Object { $studyBeforeLogs -notcontains $_.FullName } | Select-Object -Last 1
    $studyText = Get-Content -LiteralPath $studyLog.FullName -Raw -Encoding utf8
    Assert-StudyBuildTest ($studyText.Contains('仍在运行')) 'Quiet subprocess emits heartbeat'
    Assert-StudyBuildTest ($studyText.Contains('diagnostic-from-stderr')) 'stderr is drained and saved'
    Assert-StudyBuildTest ($studyText.Contains('verbose-only-diagnostic')) 'Hidden verbose lines remain in the log'
    Assert-StudyBuildTest ($studyText.Contains('全部构建完成')) 'Chinese status and success summary are saved'

    $studyBeforeLogs = @(Get-ChildItem (Join-Path $studyProject 'build-logs') -Filter '*.log' | ForEach-Object FullName)
    $env:STUDY_BUILD_TEST_MODE = 'fail'
    $studyFailed = $false
    try {
        & "$PSScriptRoot/build.ps1" -Flutter $studyFixtureFlutter -Offline -HeartbeatSeconds 1
    } catch {
        $studyFailed = $_.Exception.Message -match '7'
    }
    Assert-StudyBuildTest $studyFailed 'Nonzero compiler exit is a failed build'
    $studyLog = Get-ChildItem (Join-Path $studyProject 'build-logs') -Filter '*.log' | Where-Object { $studyBeforeLogs -notcontains $_.FullName } | Select-Object -Last 1
    $studyText = Get-Content -LiteralPath $studyLog.FullName -Raw -Encoding utf8
    Assert-StudyBuildTest ($studyText.Contains('simulated compiler failure')) 'Compiler error remains in the log'
    Assert-StudyBuildTest ($studyText.Contains('构建中止') -and -not $studyText.Contains('全部构建完成')) 'Failure reports its stage and never reports success'

    . "$PSScriptRoot/build_support.ps1"
    $studyParserContext = New-StudyBuildContext $studyProject
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
    Write-Host 'PASS: Windows PowerShell parsing, paths with spaces/Unicode, streaming stdout/stderr, quiet heartbeat, offline flags, and failed-build reporting.' -ForegroundColor Green
} finally {
    $env:STUDY_BUILD_TEST_CALLS = $studySavedCalls
    $env:STUDY_BUILD_TEST_MODE = $studySavedMode
}
