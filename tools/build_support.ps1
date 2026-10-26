# Shared logging and native process supervision, compatible with Windows PowerShell 5.1.
function Get-StudyBuildCommit {
    param([string]$Project)
    $commit = & git -C $Project rev-parse --short=7 HEAD
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{7,40}$') {
        throw '无法读取当前 Git commit，不能为构建包命名。'
    }
    return $commit.Trim()
}

function New-StudyWindowsArchive {
    param([string]$Project, [string]$Commit)
    if ($Commit -notmatch '^[0-9a-f]{7,40}$') { throw '构建包需要有效的短 commit hash' }
    $release = Join-Path $Project 'build/windows/x64/runner/Release'
    foreach ($file in @('subjective_study.exe', 'flutter_windows.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $release $file) -PathType Leaf)) {
            throw "Release 缺少 $file，无法打包"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $release 'data') -PathType Container)) {
        throw 'Release 缺少 data 资源目录，无法打包'
    }
    $outputs = Join-Path $Project 'outputs'
    New-Item -ItemType Directory -Path $outputs -Force | Out-Null
    $name = 'subjective-study-windows-x64-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Commit
    $destination = Join-Path $outputs ($name + '.zip')
    $suffix = 2
    while (Test-Path -LiteralPath $destination) {
        $destination = Join-Path $outputs ("{0}-{1}.zip" -f $name, $suffix)
        $suffix++
    }
    $partial = $destination + '.' + [guid]::NewGuid().ToString('N') + '.partial'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        # Unlike Compress-Archive, this includes hidden files and empty folders.
        # Put the Release contents at ZIP root so the executable runs after extraction.
        [IO.Compression.ZipFile]::CreateFromDirectory($release, $partial, [IO.Compression.CompressionLevel]::Optimal, $false)
        Move-Item -LiteralPath $partial -Destination $destination -ErrorAction Stop
        return $destination
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}

function New-StudyBuildContext {
    param([string]$Project, [switch]$ShowDetails, [int]$HeartbeatSeconds = 15)
    $logDirectory = Join-Path $Project 'build-logs'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $logPath = Join-Path $logDirectory ("build-{0}-{1}-{2}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID, [guid]::NewGuid().ToString('N').Substring(0, 6))
    $writer = [IO.StreamWriter]::new($logPath, $false, [Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    return @{ LogPath = $logPath; Writer = $writer; ShowDetails = $ShowDetails.IsPresent;
        HeartbeatSeconds = $HeartbeatSeconds; Stage = '准备'; Activity = '等待工具启动' }
}

function Write-StudyBuildStatus {
    param([hashtable]$Context, [string]$Message, [string]$Color = 'Cyan')
    $text = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $Context.Writer.WriteLine($text)
    Write-Host $text -ForegroundColor $Color
}

function Format-StudyBuildDuration {
    param([TimeSpan]$Duration)
    return '{0}分{1:00}秒' -f [math]::Floor($Duration.TotalMinutes), $Duration.Seconds
}

function Write-StudyBuildToolLine {
    param([hashtable]$Context, [string]$Line, [string]$Stream)
    $clean = $Line -replace '\x1b\[[0-?]*[ -/]*[@-~]', ''
    $Context.Writer.WriteLine(('[{0}][{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Stream, $clean))
    $plain = $clean
    while ($plain -match '^\s*\[[^\]]*ms\]\s*') {
        $plain = $plain -replace '^\s*\[[^\]]*ms\]\s*', ''
    }
    $activity = $null
    if ($plain -match '(?i)waiting for another flutter|startup lock|waiting.*cache.*lock') {
        $activity = '等待其他 Flutter 进程释放锁'
    } elseif ($plain -match '(?i)executing:.*git.*fetch') {
        $activity = '工具正在联网拉取 Git 数据，请查看日志中的地址'
    } elseif ($plain -match '(?i)resolving dependencies|version solving|SLVR:') {
        $activity = '解析项目依赖版本'
    } elseif ($plain -match '(?i)^Downloading packages') {
        $activity = if ($Context.PubOffline) { '从本地缓存读取依赖包' } else { '获取项目依赖包（缓存或联网下载）' }
    } elseif ($plain -match '(?i)downloading|HTTP (GET|POST)|HTTP request') {
        $activity = '工具正在请求网络或下载依赖/组件'
    } elseif ($plain -match '(?i)gen_snapshot|kernel_snapshot|frontend_server|aot_elf') {
        $activity = '编译 Dart 应用代码'
    } elseif ($plain -match '(?i)cmake_install\.cmake|installing:') {
        $activity = '整理 Release 运行文件和资源'
    } elseif ($plain -match '(?i)MSBuild\.exe|cl\.exe|\.vcxproj') {
        $activity = '构建 Windows 原生程序和插件'
    } elseif ($plain -match '(?i)building windows application|cmake.*--build') {
        $activity = '执行 Windows CMake / MSBuild 构建'
    } elseif ($plain -match '(?i)executing:.*cmake') {
        $activity = '配置 Windows 编译工程'
    } elseif ($plain -match '(?i)got dependencies|changed \d+ dependencies') {
        $activity = '依赖准备已完成'
    }
    if ($activity -and $activity -ne $Context.Activity) {
        $Context.Activity = $activity
        Write-StudyBuildStatus $Context ("{0}：{1}" -f $Context.Stage, $activity)
    }
    # Full verbose output goes to disk; the console keeps useful normal messages and errors.
    $diagnostic = $plain -match '(?i)(^|\s)(error|warning|fatal|错误|警告)(\s+[A-Z]+\d+)?\s*[:：]|^\s*(CMake (Error|Warning)\b|[A-Za-z.]*Exception\b|Error\b|FAILURE\b|Unhandled exception|fatal\b|warning\b)|(error|错误)\s+(MSB|LNK|C)\d+'
    $summary = $plain -match '(?i)^\s*(Resolving dependencies|Downloading packages|Got dependencies|Building (Windows|Android)|[√✓]?\s*Built\b)'
    if ($diagnostic) { $Context.DiagnosticRemaining = 8 }
    if ($Context.ShowDetails -or $diagnostic -or $summary -or $Context.DiagnosticRemaining -gt 0) {
        Write-Host $plain
    }
    if (-not $diagnostic -and $Context.DiagnosticRemaining -gt 0) { $Context.DiagnosticRemaining-- }
}

function Stop-StudyBuildToolTree {
    param([Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }
    # Only stop the tool tree created by this invocation (e.g. when Ctrl+C cancels it).
    $stopInfo = [Diagnostics.ProcessStartInfo]::new()
    $stopInfo.FileName = Join-Path $env:SystemRoot 'System32/taskkill.exe'
    $stopInfo.Arguments = "/PID $($Process.Id) /T /F"
    $stopInfo.UseShellExecute = $false
    $stopInfo.CreateNoWindow = $true
    $stopInfo.RedirectStandardOutput = $true
    $stopInfo.RedirectStandardError = $true
    $stop = [Diagnostics.Process]::Start($stopInfo)
    try { [void]$stop.WaitForExit(5000) } finally { $stop.Dispose() }
}

function Invoke-StudyBuildTool {
    param([hashtable]$Context, [string]$Flutter, [string[]]$Arguments, [string]$Stage)
    $Context.Stage = $Stage
    $Context.Activity = '启动工具，等待输出'
    $Context.DiagnosticRemaining = 0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastHeartbeat = [TimeSpan]::Zero
    $lastOutput = [TimeSpan]::Zero
    $quotedArguments = @($Arguments | ForEach-Object {
        if ($_ -match '["\r\n%!]') { throw '工具参数包含不支持的命令行字符' }
        '"' + $_ + '"'
    }) -join ' '
    $Context.Writer.WriteLine(('Command: "{0}" {1}' -f $Flutter, $quotedArguments))
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $env:ComSpec
    $info.Arguments = '/d /s /c ""' + $Flutter + '" ' + $quotedArguments + '"'
    $info.WorkingDirectory = (Get-Location).Path
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw '无法启动 Flutter 工具' }
        $streams = @{
            stdout = @{ Reader = $process.StandardOutput; Task = $process.StandardOutput.ReadLineAsync() }
            stderr = @{ Reader = $process.StandardError; Task = $process.StandardError.ReadLineAsync() }
        }
        while (-not $process.HasExited -or $streams.stdout.Task -or $streams.stderr.Task) {
            foreach ($name in @('stdout', 'stderr')) {
                $stream = $streams[$name]
                $lines = 0
                while ($stream.Task -and $stream.Task.IsCompleted -and $lines -lt 100) {
                    $line = $stream.Task.GetAwaiter().GetResult()
                    if ($null -eq $line) { $stream.Task = $null; break }
                    $lastOutput = $timer.Elapsed
                    Write-StudyBuildToolLine $Context $line $name
                    $stream.Task = $stream.Reader.ReadLineAsync()
                    $lines++
                }
            }
            if (($timer.Elapsed - $lastHeartbeat).TotalSeconds -ge $Context.HeartbeatSeconds) {
                Write-StudyBuildStatus $Context ("仍在运行｜{0}｜{1}｜本阶段耗时 {2}，距工具上次输出 {3} 秒" -f
                    $Stage, $Context.Activity, (Format-StudyBuildDuration $timer.Elapsed), [math]::Floor(($timer.Elapsed - $lastOutput).TotalSeconds)) 'DarkCyan'
                $lastHeartbeat = $timer.Elapsed
            }
            Start-Sleep -Milliseconds 100
        }
        $process.WaitForExit()
        $code = $process.ExitCode
        if ($code -eq 0) {
            Write-StudyBuildStatus $Context ("{0}完成，耗时 {1}" -f $Stage, (Format-StudyBuildDuration $timer.Elapsed)) 'Green'
        } else {
            Write-StudyBuildStatus $Context ("{0}未成功，退出码 {1}，耗时 {2}" -f $Stage, $code, (Format-StudyBuildDuration $timer.Elapsed)) 'Yellow'
        }
        return $code
    } finally {
        if ($started -and -not $process.HasExited) {
            Write-StudyBuildStatus $Context ("停止本次工具进程（PID {0}）及其子进程" -f $process.Id) 'Yellow'
            Stop-StudyBuildToolTree $process
        }
        $process.Dispose()
    }
}
