# 主观评价平台

Windows / Android 离线主观评价工作台，当前支持静态图片顺序呈现的 2AFC。通过标准数据描述创建实验，预览后发布不可变版本，再登记参与者、采集和分析。真实感评测保留为模板，schema 1 历史数据继续使用原排程及统计实现。

## 快速体验

1. 开发阶段直接运行调试版：Windows 使用 `flutter run -d windows`，Android 使用 `flutter run -d <device-id>`。
2. 点击“体验通用演示”。这是一个仅含一对图片的 v2 实验，无练习、控制或年龄要求。
3. 点击“进入采集”，填写匿名参与者编号和观看条件，设备与观看距离可按需要记录。
4. 每题先后显示两幅图片，随后强制选择第一幅或第二幅。默认提示 2 秒、图片 3 秒，作答不限时，无默认答案和回看。
5. 结果页面按观看条件显示逐题选择比例，并导出逐题 CSV 和完整 JSON。演示数据不能用于正式结论。

测试时保持全屏、横屏和屏幕常亮。Esc / 系统返回会暂停并保存，恢复时完整重播未完成题次。Android 首次全屏的系统提示需要先确认。

## 建立自己的实验

选择“新建通用 2AFC”，编辑问题、添加图片对、设置可选的标准答案与分组。草稿修改自动保存，可以预览完整题次，返回实验页面后点击“发布版本”。每次发布生成新版本；已有发布包和会话不会随草稿编辑而变化。

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

草稿的“03 呈现与排程”可开启 **3D 双眼 SBS** 和 **随机 Patch**。3D 用 `a/b` 指定左眼、`aRight/bRight` 指定对应右眼，A、B 仍先后播放；图片阶段隐藏鼠标，作答 UI 和指针在双眼绘制。Patch 按原图面积百分比配置，中心偏重抽样，A/B、双眼与重复题共用同一矩形，恢复不重抽。具体配置、SBS 比例和连续鼠标操作见 [双眼与 Patch](docs/stereo-and-patch.md)。

详细字段、默认值、操作与导出合同见 [数据与操作规范 v2](docs/study-data-v2.md)。完整样例在 [examples/study-v2](examples/study-v2/study.json)。来源差异在外部适配器中解决，平台不识别训练目录、固定场景或相机映射。

Python 3.10+ 参考工具无需额外依赖：

```powershell
python tools/study_data.py validate examples/study-v2
python tools/study_data.py migrate demo-data/demo.study.zip validation/migrated-study --study-id photorealism-demo
```

转换输出目录不能已存在，父目录需存在。原包不会被修改，素材不重编码，旧答案不能只更换 ID 后合入新版本。

## 真实感模板与旧数据

Windows 点击“加载真实感素材目录”，直接选择包含四个 `*_renders` 序列的上级目录。软件读取 `frame*/test/primitive/{gt,renders}` 的全部候选图片，不复制原图。每位参与者独立随机抽帧和视点，VRU 各 4 对、Dance / Show 各 6 对；每对两种次序各一次，共 40 次判断。恢复会话沿用已抽出的题目。当前没有练习和控制素材，自动载入版本明确标记为演练。

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

Windows 插件链接受限时可运行 `tools/prepare_windows.ps1` 创建项目内 junction。`tools/build.ps1` 默认使用 `D:/tools/flutter`，路径可通过参数覆盖。两端构建按顺序执行，Android Release 使用内部调试签名。`tools/package.ps1` 整理 Release 产物及 SHA-256 清单到 dist。

当前阶段只运行 Windows 调试版，不执行发布构建或打包。如果终端找不到 `flutter`，本机可在项目目录运行 `& 'D:\tools\flutter\bin\flutter.bat' run -d windows`。

原 v1 验证见 [docs/validation.md](docs/validation.md)，v2 验证见 [docs/validation-v2.md](docs/validation-v2.md)。四序列真实素材的结构检查、转换和调试流程见 [真实素材流程演练](docs/real-materials-workflow.md)。
