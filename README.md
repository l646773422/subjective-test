# 主观评价平台

Windows / Android 离线主观评价工作台，当前支持静态图片顺序呈现的 2AFC。Windows 默认使用单页“开始测试”：选素材目录、设置每组抽样数与 Patch / 3D、登记后直接采集；参数自动冻结，旧会话保留原设置。真实感评测保留为模板，schema 1 历史数据继续使用原排程及统计实现。

## 快速体验

1. 在项目目录运行 Windows 调试版：`& 'D:\tools\flutter\bin\flutter.bat' run -d windows`。
2. 首页“开始测试”选择素材目录，或粘贴路径后点“读取目录”。原素材选四个 `*_renders` 的共同上级目录；通用数据选含 `study.json` 的源目录。
3. 同页填写每组抽样数量，开关并配置 Patch / 3D。在“本次测试参数”右侧点“测试设置”，调整提示时长、图片展示时长、问题和开始前说明，应用后核对生效值。时长用秒填写，0 秒提示表示跳过。
4. 点击“登记参与者并开始测试”，填匿名编号和观看条件，确认即进入测试，无需手动发布。中断后在本页下方直接恢复，下一位使用新编号。
5. 结果汇总页查看并导出逐题 CSV 和完整 JSON。流程演练数据始终保留演练标记。

操作与新流程验证见 [Windows 单页开始测试](docs/windows-start-test.md)。通用演示与旧版演示保留在“高级实验管理”；Android 仍使用原流程，本轮不接入新首页或制作安装包。

测试时保持全屏、横屏和屏幕常亮。Esc / 系统返回会暂停并保存，恢复时完整重播未完成题次。Android 首次全屏的系统提示需要先确认。

## 建立自己的实验

需要编辑问题、题目和分析规则时，进入“高级实验管理”，选择“新建通用 2AFC”。高级草稿可编辑问题、图片对、可选的标准答案与分组，修改自动保存，可以预览完整题次并手动发布。普通测试在“开始测试”页自动处理配置与版本；已有发布包和会话不会随新参数变化。

也可以导入含 `study.json` 的目录或 ZIP。文件名和目录自由组织，图片路径相对于描述文件：

```json
{
  "schema": 2,
  "studyId": "my-study",
  "name": "图片评价实验",
  "method": "2afc",
  "question": "哪一幅看起来更自然？",
  "items": [
    {"id": "pair-001", "a": "photos/first.png", "b": "outputs/second.png"}
  ]
}
```

`a/b` 是素材身份，与屏幕先后位置无关。有标准答案时填写 `answer: "a"` 或 `"b"` 并选择准确率指标；无标准答案时使用逐题选择比例。练习和控制题均可选，重复次数只影响正式题。默认完整显示 2D 图片，允许不同尺寸；启用 3D 或 Patch 后，每题全部图片需同尺寸。

“开始测试”页可直接开启 **3D 双目显示** 和 **随机 Patch**，高级草稿也保留对应设置。按当前裸眼设备确认的要求，新测试默认 **Half SBS（横向压缩一半）**：每眼先按完整屏幕排版，再压到半屏，图片、文字、按钮和鼠标同步压缩，高度不变。展开 3D 输出设置可选择 Half / Full SBS。既支持 `a/b` 各自是一张已拼好的 SBS 图，也支持 `a/b` 为左眼、`aRight/bRight` 为对应右眼的分图方式。A、B 仍先后播放；图片阶段隐藏全部鼠标。Patch 按单眼原图像素宽、高填写，左右半幅分别截取相同位置，再做对应输出。A/B、双眼与重复题共用裁剪坐标，恢复不重抽。旧会话继续使用其冻结的输出设置。具体配置见 [双眼与 Patch](docs/stereo-and-patch.md)。

详细字段、默认值、操作与导出合同见 [数据与操作规范 v2](docs/study-data-v2.md)。完整样例在 [examples/study-v2](examples/study-v2/study.json)。来源差异在外部适配器中解决，平台不识别训练目录、固定场景或相机映射。

Python 3.10+ 参考工具无需额外依赖：

```powershell
python tools/study_data.py validate examples/study-v2
python tools/study_data.py migrate demo-data/demo.study.zip validation/migrated-study --study-id photorealism-demo
```

转换输出目录不能已存在，父目录需存在。原包不会被修改，素材不重编码，旧答案不能只更换 ID 后合入新版本。

## 真实感模板与旧数据

“开始测试”的“选图方式”支持“每人随机抽取”和“固定帧和视点（所有人相同）”。固定模式按每个序列填写指定数量的帧/视点绑定，支持粘贴多行；所有参与者使用相同内容和列表顺序，A/B 次序平衡、Patch 每人随机。成功开始后配置自动保存，修改列表生成新版本，旧会话保持原设置。见 [固定采样列表](docs/fixed-sampling.md)。

Windows 首页“开始测试”选择包含 `*_renders` 序列的上级目录，允许只含一个序列。软件读取 `frame*/test/primitive/{gt,renders}` 或 `frame*/test/{gt,renders}` 的全部候选图片，不复制原图。新裸眼目录中的敦煌素材为 1,500 组已拼 SBS，读取后自动开启对应 3D 模式。每位参与者独立随机抽帧和视点，默认每个 VRU 序列抽 4 组、Dance / Show 各 6 组，可在同页修改；同一组交换顺序各答一次。当前没有练习和控制素材，自动载入版本明确标记为演练。

新真实感模板使用每人抽样与 profile 2，保留登记字段、独立练习和控制要求。旧 profile 1 的固定单帧题库、逐图人数条件和统计实现继续兼容。具体抽样规则、测试状态和原目录操作见 [Windows 真实素材流程](docs/real-materials-workflow.md)。本轮先完成 Windows 联调，安卓目录读取和最终安装包发布后置。

导入旧 schema 1 测试包后，可继续建立或恢复旧会话、导出与合并旧 JSON，原随机算法与统计结果保持不变。已有本地目录和 Android 应用 ID 保留。单个损坏文件显示读取提示，不阻断其他实验。

旧版实验的“复制为 v2 真实感草稿”保留元数据和原模板规则，关联独立素材目录。Python 转换器仍用于历史源描述迁移；metadata 本身不激活统计行为。

旧目录读取与方案记录归档在 [schema 1 使用说明](docs/legacy-v1.md)，供旧工具或适配脚本参考。

## 保存与交换

本地根目录继续为 Windows `LOCALAPPDATA/PCNL/SubjectiveStudy/studies-v1`、Android App 私有 `files/studies-v1`。`experiments/` 保留旧实验，`sessions/` 保存全部会话，`drafts/<studyId>/` 保存可编辑定义和素材，`revisions/<revisionId>/` 保存冻结的发布版本。

软件包与测试素材分离：新发布的 v2 包只包含定义与清单；素材目录位置保存在本机，不进入发布包。导入包后加载对应的测试素材目录即可采集。原始 renders 池只索引目录，每位参与者抽样后完整解码所选图片并保存指纹，呈现与恢复时复核。完整 JSON 包含实际抽样、原始答案和呈现/中断事件；CSV 包含帧、视点、种子和图片指纹。旧版自带图片的包继续读取。

不同发布版本不能直接合并结果；相同会话重复导入幂等、不同内容报冲突。不同观看条件分别展示。旧素材 ZIP 上限 512 MB、展开上限 1 GiB；Windows 独立素材目录不受此限制。本轮未联调 Android 的大素材目录读取，也不生成安装包。

## 开发与验证

Flutter 3.47.7 / Dart 3.13.5、Visual Studio 2022、JDK 17、Android SDK 36；依赖由 pubspec.lock 固定。

```powershell
flutter pub get
flutter analyze
flutter test test
python -m unittest discover -s tools -p 'test_*.py' -v
$env:STUDY_ARTIFACT_DIR="validation/v2-windows"
flutter drive --driver=test_driver/driver.dart --target=integration_test/flow_test.dart -d windows
$env:STUDY_ARTIFACT_DIR="validation/stereo-windows"
flutter drive --driver=test_driver/driver.dart --target=integration_test/stereo_patch_test.dart -d windows
$env:STUDY_ARTIFACT_DIR="validation/v2-android"
flutter drive --driver=test_driver/driver.dart --target=integration_test/flow_test.dart -d emulator-5580
```

集成验证覆盖真实计时与中断、旧版完整 46 题、v2 最小实验与跨设备数据交换。加速计时只由测试入口注入，生产使用发布配置。实体设备和正式素材的显示条件须按实验要求另行联调。

Windows 插件链接受限时可运行 `tools/prepare_windows.ps1` 创建项目内 junction。`tools/build.ps1` 默认使用 `D:/tools/flutter`，路径可通过参数覆盖；默认只构建 Windows，添加 `-Android` 才同时构建 Android。构建脚本跳过 Flutter SDK 的联网版本检查，显示依赖准备与编译阶段；依赖已缓存时可加 `-Offline`，避免 pub 联网解析。`-Offline` 只控制 pub，尚未缓存的 Flutter/CMake 平台组件仍可能需要下载。示例：`powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build.ps1 -Offline`。两端构建按顺序执行，Android Release 使用内部调试签名。现有 `tools/package.ps1` 同时要求 Windows 和 Android 产物；仅 Windows 时压缩完整 `build/windows/x64/runner/Release/` 目录。

Windows Release 构建可运行 `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build.ps1`；依赖已缓存时添加 `-Offline`。构建完成后运行 `build/windows/x64/runner/Release/subjective_study.exe`，分发时携带整个 Release 目录，素材另行提供。需要调试时，本机可在项目目录运行 `& 'D:\tools\flutter\bin\flutter.bat' run -d windows`，无需将 Flutter 加入 PATH。

构建脚本显示带时间的中文阶段、实际工具状态、每 15 秒运行提醒和最终耗时；失败标出阶段、退出码和完整日志路径。完整 Flutter 输出保存在 build-logs/，加 -ShowDetails 可同时在终端显示。操作和验证说明见 [Windows 构建状态与日志](docs/windows-build.md)。

原 v1 验证见 [docs/validation.md](docs/validation.md)，v2 验证见 [docs/validation-v2.md](docs/validation-v2.md)。四序列真实素材的结构检查、转换和调试流程见 [真实素材流程演练](docs/real-materials-workflow.md)。
