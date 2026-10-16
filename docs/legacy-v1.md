# 真实感评测

离线的顺序呈现二选一（successive 2AFC）评测工具，独立 Flutter 项目，支持 Windows 与 Android。

## 快速使用

1. Windows 解压 dist/subjective-study-windows-x64.zip，运行其中的 subjective_study.exe（保留同目录 DLL 和 data）；安卓（Android 7.0+，ARM64）安装 dist/subjective-study-android.apk。
2. 点击“载入演示题库”即可体验。内置的 52 张合成图只用于功能验证，所有相关结果明确标记为演示，不能用于照片级真实的正式结论。
3. 在“采集会话”登记匿名编号、年龄、设备、观看距离、观看条件分组及参与条件。
4. 先完成四道练习，再进入正式阶段。每题 A 提示 2 秒、A 图 3 秒、B 提示 2 秒、B 图 3 秒，之后必须二选一，无答题超时。
5. 安卓首次全屏可能弹出系统操作提示，先确认提示，再点击开始。评测时保持横屏、全屏和屏幕常亮。
6. 整轮共 46 题：4 道练习、40 次正式判断、2 道控制题。PC 可按 1/2，安卓点击大按钮。Esc/系统返回可暂停并保存；回到会话页面可恢复。
7. 结果页导出 CSV 与完整 JSON。跨设备传递同一个测试包后，可合并对应题库的结果 JSON。重复文件不会重复计数；内容冲突或同一观看条件下的受试者编号冲突会报错。

## 正式素材

添加四个序列的图片根目录。目录结构：

    场景/参数目录/frameXXXXXX/test/ours_迭代数/gt/00000.png
    场景/参数目录/frameXXXXXX/test/ours_迭代数/renders/00000.png

每帧按数值取最大的 ours_迭代目录。该目录不完整时报告错误，不退回旧迭代。GT/render 以同名文件配对，检查图片尺寸。

VRU_gz、VRU_dg4 使用视点 0/10/20/30；Dance_Dunhuang_Pair_1080、Show_Groups_4K 使用 0/10/20/30/40/50。默认每序列随机抽一帧并保留全部指定视点，固定 20 对正式图片。

相机编号可写入每个 ours 目录下的 view_ids.json，例如：

    {"00000.png":0,"00001.png":10,"00002.png":20,"00003.png":30,"00004.png":40,"00005.png":50}

若文件名本身是所需相机编号，则直接采用编号；否则按导出文件顺序映射，组织者必须核对。软件检查数据配对，无法仅凭两张图片证明相机位姿和时间对齐。

另外添加 3～5 道独立练习图片对、恰好两道明显差异控制图片对。组织者选择的第一张必须为真实拍摄图像，第二张为对应渲染/控制图像。练习图片不能与正式图片相同。正式冻结前确认图片和控制题答案。

正式分辨率按方案为 1920×1080、Show_Groups_4K 为 3840×2160。测试保持等比完整显示，记录实际呈现尺寸，不自动裁切或美化。两端都可正式采集；观看条件不同的数据按登记的分组分别汇总。

安卓可通过系统目录选择器导入图片树，仅复制需要的图片和视点映射，读取最大迭代目录。大批量素材建议先在 PC 冻结并导出精简 ZIP 测试包，再到安卓导入。

demo-data 提供可独立导入的演示 ZIP、四个示例原始序列目录、练习及控制素材。示例原始根目录带 DEMO_ONLY.txt，使用这些目录生成的题库仍被标记为演示。

## 统计合同

- 每对正式图片以两种次序各测一次，共 40 次判断，两种先后次序各占 50%。
- 四个序列的分组顺序随机，组内两轮分别随机，同一对不会紧邻重复。
- 控制题全局两道、次序平衡，放在正式阶段开头与中段；必须两道全对才达到 95% 要求。
- 只有完成整轮、参与条件符合且控制题通过的会话计入正式识别率；其余数据保留并标记原因。
- 正式识别率不包含练习/控制题。同一人重复两次不算两位观看员。
- 每张图至少 15 位有效观看员、视点人数均衡、专家不超过 1/3 后，才具备判定条件。
- 四个序列全部满足 S_seq≤75% 才整体通过。演示题库始终不作正式判定。
- JSON 包含逐题原始答案、逐图/序列统计、呈现时间、设备信息和中断记录；CSV 为逐题明细。
- 随机算法固定为 schema 1 的 xorshift32 + Fisher–Yates，不依赖系统默认随机实现；保存种子及实际排程。

## 本地记录与恢复

Windows 数据位于 LOCALAPPDATA/PCNL/SubjectiveStudy/studies-v1；安卓位于 App 私有 files/studies-v1。

题库使用内容校验 ID；图片通过 SHA-256 校验，开始会话前再次检查。题库配置不可原地编辑。新配置生成新版本。

答案通过串行化、flush 和临时文件替换逐题保存。未完成会话不计入最终统计；中断会保留并在返回后完整重播当前题。导出的完整 JSON 可备份和跨设备合并，导出的 ZIP 为可移植题库。

单个 ZIP 上限 512 MB、解压总量上限 1 GB；不允许目录穿越、符号链接和重复路径。原始安卓目录导入上限 1 GB，超过时请先导出精简题库。

## 开发与验证

已使用 Flutter 3.47.7 / Dart 3.13.5、Visual Studio 2022、JDK 17、Android SDK 36 / NDK 29.0.13599879。依赖版本由 pubspec.lock 固定。

    flutter pub get
    flutter analyze
    flutter test test
    $env:STUDY_ARTIFACT_DIR="validation/windows"
    flutter drive --driver=test_driver/driver.dart --target=integration_test/flow_test.dart -d windows
    $env:STUDY_ARTIFACT_DIR="validation/android"
    flutter drive --driver=test_driver/driver.dart --target=integration_test/flow_test.dart -d emulator-5580
    flutter build windows --release
    flutter build apk --release --target-platform android-arm64,android-x64

Windows 若不能创建插件 symlink，可使用 tools/prepare_windows.ps1 创建项目内 junction，无需修改系统开发者模式。不要先运行 flutter clean 后直接使用 --no-pub；应重新准备插件文件。

tools/package.ps1 将两端 Release 产物和演示题库整理到 dist，并生成 SHA-256 清单。

tools/build.ps1 使用当前机器 D:/tools/flutter，调用时可传 Flutter 参数替换路径。Android 构建使用 JDK 17。Android Release 构建保留 pub 阶段，以重新生成不含 integration_test 的生产插件注册；两端构建按顺序执行。APK 使用 Flutter 模板的本地调试签名，供内部安装验证；公开发行前应配置项目专用签名。

tools/generate_demo.py 通过 Python/Pillow 生成确定性的合成测试夹具，不依赖图片生成服务，也不属于正式测试素材。

原生集成测试会先按真实 2/3 秒计时验证一题、等待答题超过 5 秒并检查中断保存，再以明确的测试计时覆盖完整 46 题、数据持久化、控制题、统计和去重。加速只由测试入口注入，不提供给正式界面。

## 当前验证范围

24 项单元/界面测试、静态分析通过；Windows 和 Android 36 模拟器各完成两项原生流程验证，记录见 [docs/validation.md](docs/validation.md)。实体安卓设备和用户正式图片序列将在素材准备好后联调；模拟器的显示不能替代实际屏幕观看条件验证。
