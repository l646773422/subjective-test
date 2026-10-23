# 四序列真实素材流程演练

日期：2026-10-23。开发阶段直接运行调试版，本轮不制作或更新安装包。

## 实际素材结构

素材位于用户提供的 `13主观测试/*_renders`，每个目录均有 `frame000000`～`frame000249`：

```text
<sequence>_renders/
  frame000000/
    test/primitive/
      gt/00000.png
      renders/00000.png
      per_view_count.json
```

| 序列 | 帧数 | 每帧视点 | 图片对总数 | 两侧分辨率 | 本次抽取帧 |
| --- | ---: | ---: | ---: | --- | ---: |
| VRU_gz | 250 | 4 | 1,000 | 1920×1080 | 90 |
| VRU_dg4 | 250 | 4 | 1,000 | 1920×1080 | 234 |
| Dance_Dunhuang_Pair_1080 | 250 | 6 | 1,500 | 1920×1080 | 63 |
| Show_Groups_4K | 250 | 6 | 1,500 | 3840×2160 | 144 |

共 5,000 对、10,000 张图片，图片约 17.98 GiB，不计原 ZIP 副本。全量检查了每帧同名配对、视点覆盖、所有 PNG 的签名与尺寸，以及 1,000 份 `per_view_count.json` 的结构；选中的 40 张图片由 Flutter 完整解码。未对全部 10,000 张图片做像素解码。

用户已确认文件顺序对应相机号：VRU 的 `00000…00003` 对应 0、10、20、30；Dance / Show 的 `00000…00005` 对应 0、10、20、30、40、50。`per_view_count.json` 的计数原值保留在 `metadata.primitiveCount`；相机映射不从这些计数推导。

## 调整与转换

旧版原始目录扫描器要求 `ours_数字`，不能识别本次 `primitive`。v2 客户端继续只识别标准描述；新增 [外部适配器](../tools/prepare_renders.py)，不把来源规则写回 Flutter。

客户端补充了通用导入提示：选到缺少 `study.json` 的原始素材目录时，明确提示先做格式转换。当前每轮发布约 72 MiB，无需放宽导入容量或修改图片显示规则。

[转换配置](../examples/primitive-renders.json) 明确填写序列目录与文件到相机的映射。可以给每个序列加 `"frame": 90` 固定抽帧；省略时，按 `SHA-256(seed:sequenceId)` 的前 8 字节大端整数对排序后的帧列表取模，每个序列独立抽取，与 Python 随机库版本或配置排列无关。

在项目根目录执行：

```powershell
$source = 'D:/文档/鹏城项目/13专项-沉浸式/项目测试/13主观测试'
python tools/prepare_renders.py inspect $source --report validation/real-materials/inventory.json
python tools/prepare_renders.py prepare $source validation/real-materials/source --config examples/primitive-renders.json --seed 20261023
python tools/study_data.py validate validation/real-materials/source
```

输出目录必须尚不存在。脚本只读原始目录，将选中的 40 张图片按字节复制到输出目录，不重编码、缩放或修改源文件。配对、映射、头信息错误时停止，不跳过问题帧。

输出包含：

- `study.json`：20 对 main 素材，分组、两轮、次序平衡、避免相邻重复，共 40 次作答。a 为 GT，b 为 render，准确率的标准答案为 a。
- `source-manifest.json`：来源相对路径、所选帧、显式相机映射、每张图片的 SHA-256、字节数和尺寸。
- `inventory.json`：四序列的全量结构检查及本次复制量。本次选中图片 75,206,786 字节，约 71.72 MiB，符合客户端 1 GiB 上限。

全部真实素材、发布副本、截图和模拟答案放在被 Git 忽略的 `validation/real-materials/`。代码库只保存脚本、配置与测试，不提交原图。

## 自动流程测试与人工体验

Windows 原生集成测试直接使用本机的转换结果，不将真实素材写入应用 assets：

```powershell
$env:STUDY_ARTIFACT_DIR = 'validation/real-materials/windows'
flutter drive -d windows --no-pub --driver=test_driver/driver.dart --target=integration_test/real_materials_test.dart --dart-define=STUDY_REAL_SOURCE=D:/Projects/i3DV/subjective-test-app/validation/real-materials/source
```

测试使用隔离的 `native-<uuid>` 仓库，执行标准目录导入、发布、完整图片校验、界面登记与作答、答完两题后的中断和磁盘重载、剩余题次恢复、JSON / CSV 导出，以及相同发布版本的结果合并与重复合并。计时直接使用源配置的 2 秒提示、3 秒图片，不注入加速时长。

自动参与者编号为 `SIMULATED-WORKFLOW-001`，观看条件为 `simulated-windows`。按轮次生成一半正确、一半错误的确定性答案，用于核对统计和素材身份映射；这些答案不反映图像质量。

2026-10-23 本机 Windows 调试版实测通过，整轮约 7 分 21 秒。导入与发布耗时 3,719 ms。40 次答案完整保存，20 道题各有两次判断、a/b 各选一次，四序列模拟准确率均为 50%，与脚本预设一致。导出的 CSV 有 40 行答案；独立仓库首次合并 1 条会话、再次合并 0 条。

本轮保留 1 次主动保存重载和 3 次系统失焦中断。每次中断均重播当前题，没有产生额外答案。排除中断的未完成片段后，160 个完整呈现阶段中，提示实际计时 2,000～2,003 ms、图片 3,000～3,003 ms。这是应用计时与绘制回调记录，不是光学测量。呈现时记录到的视口为 2560×1440 逻辑像素、DPR 1.5，即 3840×2160 物理像素。

证据在 `validation/real-materials/windows/report.json` 及同目录七张截图；报告记录本轮隔离仓库的位置，仓库 `evidence/` 中另有完整结果 JSON 和逐题 CSV。对选中的全部图片再次比对原图、转换副本与来源清单的 SHA-256，40 张均一致。静态分析无问题，40 项 Flutter 回归测试、19 项 Python 测试通过。

人工体验时运行 `flutter run -d windows`，选择“导入标准目录”，导入 `validation/real-materials/source`，预览并发布，再登记新的演练编号开始采集。未设置 `STUDY_REAL_SOURCE` 时，真实素材集成测试自动跳过，普通开发检查不依赖本机数据。

## 正式测试的边界

用户确认当前没有独立练习题与明显差异的控制题，先完成真实素材流程测试。因此转换器始终写入 `isDemo: true` 与 `metadata.purpose: workflow-simulation`，不启用正式真实感判定 profile，也不从正式题抽出图片冒充独立练习或控制题。

当前 Windows 流程演练不能代替正式观察者试验。补齐 3～5 对独立练习、2 对控制题后，再建立新的正式草稿，套用真实感模板并发布。正式会话使用新的发布版本，演练答案不迁移进去。Android 和实验室实体显示设备的亮度、尺寸、观看距离另行实测。
