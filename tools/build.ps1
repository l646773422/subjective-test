param(
    [string]$Flutter = 'D:/tools/flutter/bin/flutter.bat',
    [switch]$Android,
    [switch]$Offline,
    [switch]$ShowDetails,
    [ValidateRange(1, 300)][int]$HeartbeatSeconds = 15
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/build_support.ps1"
$studyProject = Split-Path -Parent $PSScriptRoot
Push-Location $studyProject
$studyContext = $null
try {
    $studyTimer = [Diagnostics.Stopwatch]::StartNew()
    $studySteps = if ($Android) { 5 } else { 4 }
    $studyContext = New-StudyBuildContext $studyProject -ShowDetails:$ShowDetails -HeartbeatSeconds $HeartbeatSeconds
    Write-StudyBuildStatus $studyContext '开始构建；成功后自动将 Windows 程序打包为 ZIP，保存到 outputs。'
    Write-StudyBuildStatus $studyContext ("完整日志：{0}" -f $studyContext.LogPath)
    $studyContext.Stage = '检查 Flutter 和项目路径'
    Write-StudyBuildStatus $studyContext ("[1/{0}] 检查 Flutter 和项目路径" -f $studySteps)
    if (-not (Test-Path -LiteralPath $Flutter -PathType Leaf)) { throw "Flutter 不存在：$Flutter" }
    $Flutter = (Resolve-Path -LiteralPath $Flutter).Path
    if ($Flutter -match '["\r\n%!]') { throw 'Flutter 路径包含不支持的命令行字符' }
    $studyCommit = Get-StudyBuildCommit $studyProject
    Write-StudyBuildStatus $studyContext ("代码版本：{0}" -f $studyCommit)
    Write-StudyBuildStatus $studyContext ("Flutter：{0}" -f $Flutter)
    $studyMode = if ($Offline) { '只使用已缓存的 pub 依赖' } else { '允许 pub 联网解析/下载依赖' }
    Write-StudyBuildStatus $studyContext ("依赖模式：{0}；已关闭 Flutter SDK 联网版本检查。" -f $studyMode)
    Write-StudyBuildStatus $studyContext ("[2/{0}] 准备项目依赖和 Windows 插件链接" -f $studySteps)
    & "$PSScriptRoot/prepare_windows.ps1" -Flutter $Flutter -Offline:$Offline -BuildContext $studyContext
    Write-StudyBuildStatus $studyContext ("[3/{0}] 编译 Windows Release（Dart 代码、原生程序和资源）" -f $studySteps)
    $studyCode = Invoke-StudyBuildTool $studyContext $Flutter @('--no-version-check', '--verbose', 'build', 'windows', '--release', '--no-pub') 'Windows Release 编译'
    if ($studyCode -ne 0) { throw "Windows 构建失败，退出码 $studyCode" }
    if ($Android) {
        Write-StudyBuildStatus $studyContext ("[4/{0}] 编译 Android Release" -f $studySteps)
        $studyCode = Invoke-StudyBuildTool $studyContext $Flutter @('--no-version-check', '--verbose', 'build', 'apk', '--release', '--target-platform', 'android-arm64,android-x64') 'Android Release 编译'
        if ($studyCode -ne 0) { throw "Android 构建失败，退出码 $studyCode" }
        Write-StudyBuildStatus $studyContext ("APK：{0}" -f (Join-Path $studyProject 'build/app/outputs/flutter-apk/app-release.apk'))
    }
    $studyContext.Stage = '生成 Windows ZIP'
    Write-StudyBuildStatus $studyContext ("[{0}/{0}] 打包完整 Windows Release（包含 DLL 和 data）" -f $studySteps)
    $studyZipTimer = [Diagnostics.Stopwatch]::StartNew()
    $studyZip = New-StudyWindowsArchive $studyProject $studyCommit
    Write-StudyBuildStatus $studyContext ("ZIP 完成，耗时 {0}；大小 {1:N1} MB" -f (Format-StudyBuildDuration $studyZipTimer.Elapsed), ((Get-Item -LiteralPath $studyZip).Length / 1MB)) 'Green'
    Write-StudyBuildStatus $studyContext ("压缩包：{0}" -f $studyZip) 'Green'
    Write-StudyBuildStatus $studyContext ("全部构建完成，总耗时 {0}" -f (Format-StudyBuildDuration $studyTimer.Elapsed)) 'Green'
    Write-StudyBuildStatus $studyContext ("Windows 程序：{0}" -f (Join-Path $studyProject 'build/windows/x64/runner/Release/subjective_study.exe')) 'Green'
    Write-StudyBuildStatus $studyContext ("完整日志：{0}" -f $studyContext.LogPath)
    Write-StudyBuildStatus $studyContext '分发 outputs 中的 ZIP，解压后运行 subjective_study.exe；测试素材单独提供。'
} catch {
    if ($studyContext) {
        Write-StudyBuildStatus $studyContext ("构建中止｜{0}｜{1}" -f $studyContext.Stage, $_.Exception.Message) 'Red'
        Write-StudyBuildStatus $studyContext ("请查看完整日志：{0}" -f $studyContext.LogPath) 'Yellow'
    }
    throw
} finally {
    if ($studyContext) { $studyContext.Writer.Dispose() }
    Pop-Location
}
