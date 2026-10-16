# 验证记录

日期：2026-10-16。演示素材验证，不构成主观评测的实验结论。

## 环境与产物

- Flutter 3.47.7、Dart 3.13.5；依赖固定在 pubspec.lock。
- Windows x64 本机，Visual Studio 2022 / MSVC；便携目录包含 Flutter、VC++ 运行库和资源。
- Android 36 x86_64 独立模拟器，1080×2400，密度 420；JDK 17、NDK 29.0.13599879。
- Release APK 最低 Android 7.0（API 24），target/compile API 36，包含 arm64-v8a / x86_64，应用 ID cn.pcnl.subjective_study；内部调试密钥签名。
- 两端使用同一个 26 对合成图片题库：20 对正式题、4 对练习、2 对控制题。

发布检查：Windows Release 启动存活；Android Release 覆盖安装、冷启动、载入内置题库成功，未发现 Flutter 未处理异常。APK/ZIP 内已检查原生库、演示资产及 Windows 运行库。

## 自动检查

静态分析 lib / test / integration_test / test_driver 无问题。24 项单元及界面测试通过，覆盖排程随机性与平衡、控制题有效性、人数/专家/阈值统计、目录最大迭代、ZIP 校验及非法路径、冻结题库、逐题保存、合并冲突和桌面/手机布局。

Windows 和 Android 各通过两项原生集成场景：

1. 默认真实 2 秒灰场 / 3 秒图片呈现，答题保持超过 6 秒仍不自动推进；中断落盘并保留当前题，恢复重播。
2. 从演示题库导入、真实表单登记、练习说明到正式说明，完成 46 次按钮作答，再验证磁盘记录、控制题、统计、CSV / JSON 导出和重复合并。

第二项为缩短自动检查时间，使用测试入口专属的 30 ms 阶段计时。生产入口无此设置，仍使用冻结题库内的 2/3 秒设置。没有声称完整 46 题都按真实时长进行。

默认计时实测，单位毫秒：

| 平台 | 灰场 A / 图片 A / 灰场 B / 图片 B | 答题停留后仍等待 | 保存答案 | 控制题 |
|---|---|---|---|---|
| windows | 2002 / 3000 / 2002 / 3001 | 6158 | 46 / 46 | 2 / 2 |
| android | 2002 / 3002 / 2002 / 3002 | 6170 | 46 / 46 | 2 / 2 |

完整流程固定选择第一幅，控制题使用合成夹具答案，因此 4 个序列各 50%，1 位有效演示观看员；应用正确显示“演示数据，不作正式判定”，且不会宣称达到 15 人要求。以上数字用于检查计算逻辑。

这些计时来自 Flutter 帧回调与进程计时，不是屏幕光学测量。

## 证据与复现

- tests-final.log、integration-windows-final.log、integration-android-final.log：成功日志。
- validation/windows/report.json、validation/android/report.json：原始阶段记录、完整答案和汇总。
- 同目录 preparation.png / stimulus.png / answer.png / results.png：真实 Flutter 界面截图。
- README 给出 flutter drive 命令；主机回调保存证据，即使模拟器清理应用数据仍可保留。

## 联调范围

尚未连接实体安卓设备，也未使用用户尚在准备的完整正式素材。真机安装、真实图片分辨率/视点映射、屏幕颜色和观看条件将在下一轮联调确认。模拟器流程通过不代表实际屏幕已经符合实验条件。

安卓初次全屏的系统提示须先确认。应用等待横屏、全屏准备和 resumed 生命周期就绪后才允许开始。演示原始目录与 ZIP 均明确带有演示标识。
