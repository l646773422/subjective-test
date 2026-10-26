# Windows 构建状态与日志

在项目目录执行原命令即可，默认只构建 Windows：

    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build.ps1

依赖已缓存时可加 -Offline。脚本关闭 Flutter SDK 联网版本检查；离线选项只控制 pub，平台工具尚未缓存时仍可能需要下载。

## 终端会显示什么

- 启动时显示本次完整日志路径、Flutter 路径、代码短 commit hash、依赖是否允许联网。命名所需的 commit hash 在编译前读取。
- 第 1 步检查 Flutter 和项目路径，第 2 步准备依赖，第 3 步构建 Windows Release，第 4 步生成 ZIP。显式加 -Android 时第 4 步构建 Android，第 5 步生成 Windows ZIP。
- 从工具实际输出中识别等待 Flutter 锁、解析依赖、网络请求或下载、配置 CMake、编译 Dart、构建原生程序、整理 Release 文件等状态。不推算百分比或剩余时间。
- 每 15 秒报告工具进程仍在运行、当前阶段、本阶段耗时和距工具上次输出的秒数。“仍在运行”不表示已确认取得新进展；安静等待时可打开日志查看最后一条信息。
- 每阶段显示耗时。成功时汇总总耗时、程序路径、压缩包路径及大小；失败显示失败阶段、退出码及日志路径，并以失败退出，不继续报告成功。

普通终端保持简洁，完整的 Flutter verbose 标准输出与错误输出同步写入 UTF-8 日志。需要全部实时细节时执行：

    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build.ps1 -Offline -ShowDetails

也可以在另一个终端用打印出的实际日志路径查看末尾：

    Get-Content '.\build-logs\build-实际文件名.log' -Tail 50 -Wait -Encoding utf8

日志按每次调用单独命名，保留在本机，Git 忽略此目录。Windows PowerShell 5.1 所用脚本以带 BOM 的 UTF-8 保存，确保中文提示能正确读取。

## 产物和测试素材

构建成功后自动将完整 build/windows/x64/runner/Release 打包为 outputs/subjective-study-windows-x64-日期时间-短commit.zip，例如 outputs/subjective-study-windows-x64-20261026-183000-a1b2c3d.zip。outputs 已加入 Git ignore，构建时自动创建。每次保留旧包，同一秒同一 commit 再打包时追加 -2、-3 等序号。

ZIP 根目录直接包含 subjective_study.exe、DLL 和完整 data（包括隐藏资源与空目录），解压后运行程序即可。测试素材目录另行提供。Git hash 在构建开始时读取，命名不表示工作区一定没有未提交修改。

编译失败不打包旧产物；打包前检查程序、Flutter DLL 和 data 目录，压缩失败会清除临时文件，不留下不完整 ZIP。原 Release 目录也可直接运行。加 -Android 时仍按原路径生成 APK，自动 ZIP 只包含 Windows Release；旧 tools/package.ps1 的跨平台 dist 收集流程保留。

构建 Release 不改变实验的演示标记、练习/控制要求或已经冻结的会话参数。

## 脚本回归

    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test_build_scripts.ps1

在 validation 内的独立项目中使用模拟工具，验证带空格/中文的路径、标准输出/错误输出、静默提醒、离线参数、ZIP 命名与完整解压、重复打包保留旧包，以及编译/压缩失败处理。不执行 Flutter 构建或外部下载，不打包实际 Release 目录。
