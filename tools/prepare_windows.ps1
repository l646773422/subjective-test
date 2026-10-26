param(
    [string]$Flutter = 'D:/tools/flutter/bin/flutter.bat',
    [switch]$Offline,
    [switch]$ShowDetails,
    [hashtable]$BuildContext
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/build_support.ps1"
$studyProject = Split-Path -Parent $PSScriptRoot
$studyOwnContext = $null -eq $BuildContext
Push-Location $studyProject
try {
    if ($studyOwnContext) {
        $BuildContext = New-StudyBuildContext $studyProject -ShowDetails:$ShowDetails
        Write-StudyBuildStatus $BuildContext ("依赖准备日志：{0}" -f $BuildContext.LogPath)
    }
    if (-not (Test-Path -LiteralPath $Flutter -PathType Leaf)) { throw "Flutter 不存在：$Flutter" }
    $Flutter = (Resolve-Path -LiteralPath $Flutter).Path
    if ($Flutter -match '["\r\n%!]') { throw 'Flutter 路径包含不支持的命令行字符' }
    $studyArguments = @('--no-version-check', '--verbose', 'pub', 'get')
    if ($Offline) { $studyArguments += '--offline' }
    $BuildContext.PubOffline = $Offline.IsPresent
    $studyCode = Invoke-StudyBuildTool $BuildContext $Flutter $studyArguments '项目依赖准备'
    if ($studyCode -eq 0) { return }
    if (-not (Test-Path -LiteralPath '.flutter-plugins-dependencies')) {
        throw '依赖准备失败，尚无插件清单；请查看日志。离线模式缺少缓存时，可去掉 -Offline 后重试。'
    }
    Write-StudyBuildStatus $BuildContext '首次准备未成功，检查插件链接，再用本地缓存重试一次。' 'Yellow'
    $studyPlugins = Get-Content '.flutter-plugins-dependencies' -Raw | ConvertFrom-Json
    $studyLinks = Join-Path $studyProject 'windows/flutter/ephemeral/.plugin_symlinks'
    New-Item -ItemType Directory -Path $studyLinks -Force | Out-Null
    foreach ($studyPlugin in $studyPlugins.plugins.windows) {
        $studyLink = Join-Path $studyLinks $studyPlugin.name
        if (-not (Test-Path -LiteralPath $studyLink)) {
            Write-StudyBuildStatus $BuildContext ("创建插件目录链接：{0}" -f $studyPlugin.name)
            New-Item -ItemType Junction -Path $studyLink -Value ([IO.Path]::GetFullPath($studyPlugin.path)) | Out-Null
        }
    }
    $BuildContext.PubOffline = $true
    $studyCode = Invoke-StudyBuildTool $BuildContext $Flutter @('--no-version-check', '--verbose', 'pub', 'get', '--offline') '依赖离线重试'
    if ($studyCode -ne 0) { throw "依赖准备仍失败，退出码 $studyCode；离线模式缺少缓存时，可去掉 -Offline 后重试。" }
} catch {
    if ($studyOwnContext -and $BuildContext) {
        Write-StudyBuildStatus $BuildContext ("依赖准备失败：{0}；日志：{1}" -f $_.Exception.Message, $BuildContext.LogPath) 'Red'
    }
    throw
} finally {
    if ($studyOwnContext -and $BuildContext) { $BuildContext.Writer.Dispose() }
    Pop-Location
}
