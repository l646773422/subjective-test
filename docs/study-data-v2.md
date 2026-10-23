# 主观评价平台数据与操作规范 v2

日期：2026-10-16；2026-10-23 补充素材目录独立、每位参与者抽样、双眼 SBS 与 Patch。

执行层统一使用 `study.json` 和相对图片路径。来源可以由外部转换器处理，也可以使用真实感模板的目录适配器直接加载 `*_renders/frame*/test/primitive/{gt,renders}`。来源规则不进入通用排程和呈现层。当前方法只开放图片顺序呈现的 `2afc`。

当前 Windows 新版本的实验包与素材分离：包内只有 `study.json` 与 `release.json`，本机 `materials.json` 绑定独立素材目录，不进入包。旧的自带图片包继续兼容。renders 素材池发布清单可以用 `sha256: null` 与 `bytes` 记录尚未抽中的文件；每位参与者开始前完整解码所选图片、保存 `materialHashes`，之后呈现、恢复和合并都核对实际指纹。目录索引不等于全池像素校验。

可选 `sampling: {"mode":"per_participant","perGroup":{"组名":4}}` 将该组的 main 图片对作为候选池，每人不放回抽取指定数量，再按 schedule 做重复与次序平衡。省略字段保留固定题库旧行为。新会话使用 `2afc-schedule@2`，每题记录 sample.group/frame/view；同一会话恢复不重新抽样。抽样组必须覆盖全部 main 题，数量不能超过该组候选数。旧定义不增加新的默认字段，原 manifest 和排程实现保持兼容。

Flutter 已接入标准目录 / ZIP 导入、持久化草稿、预览与发布、v2 采集和结果交换。Python 校验器与旧包转换器负责源数据。schema 1 的包、会话、排程和统计实现继续保留。

## 1 准备一个实验只需要这些内容

```text
my-study/
  study.json
  photos/
    first.png
  another-folder/
    second.jpg
```

```json
{
  "schema": 2,
  "studyId": "my-first-study",
  "name": "图片二选一实验",
  "method": "2afc",
  "question": "哪一幅看起来更自然？",
  "items": [
    {
      "id": "pair-001",
      "a": "photos/first.png",
      "b": "another-folder/second.jpg"
    }
  ]
}
```

这是完整的最小源文件。默认没有练习和控制题，每道正式题测一次，两张图片顺序随机；每张提示 2 秒、显示 3 秒，随后强制二选一，答题不限时且不能回看。统计每道题中 a、b 被选中的比例。

可直接校验的示例在 `examples/study-v2/`，包含两张演示图片。`images`、`photos` 等素材目录名没有特殊含义。

## 2 研究者填写的字段

| 字段 | 必填 | 含义 |
|---|---|---|
| `schema` | 是 | 固定整数 `2`，表示文件格式版本 |
| `studyId` | 是 | 实验的稳定身份；修改或重新发布同一实验时不变 |
| `name` | 是 | 显示名称，可以使用中文 |
| `method` | 是 | 当前固定 `2afc` |
| `question` | 是 | 所有题目共用的作答问题 |
| `items` | 是 | 素材题目列表，至少一题 `main` |
| `instructions` | 否 | 开始前的补充说明，默认空字符串 |
| `isDemo` | 否 | 演示数据标记，默认 `false`；演示素材必须设为 `true` |
| `presentation` | 否 | 呈现设置，省略时使用下文默认值 |
| `schedule` | 否 | 排程设置，省略时使用下文默认值 |
| `quality` | 否 | 控制题质量要求 |
| `analysis` | 否 | 基础分析指标 |
| `metadata` | 否 | 来源、备注或业务标签，默认空对象，不影响执行 |
| `participantFields` | 否 | 实验自行定义的登记字段，默认空列表 |
| `sampling` | 否 | 每人独立从各分组抽取指定数量；省略时使用全部正式题 |

`studyId` 和题目 `id` 使用 1～80 位英文字母、数字、点、下划线或连字符，第一位为字母或数字。界面创建实验时自动生成 `studyId`；脚本可以填写易读的名称。题目 ID 在本实验内唯一，不要求与文件名相同。

### 每道题的字段

| 字段 | 必填 | 含义 |
|---|---|---|
| `id` | 是 | 稳定的题目编号 |
| `a`、`b` | 是 | 两张图片相对于 `study.json` 所在目录的路径 |
| `role` | 否 | `main` 正式题、`practice` 练习题、`control` 控制题；默认 `main` |
| `answer` | 否 | 有标准答案时填 `a` 或 `b`；控制题必须填写 |
| `group` | 否 | 分组标签，可以是任意场景、内容类别或条件名称 |
| `metadata` | 否 | 业务元数据，例如视点、帧号、算法名或压缩参数 |
| `aRight`、`bRight` | 3D 必填 | `a/b` 为左眼；这两个字段为同一刺激对应的右眼图片路径 |

`a`、`b` 是素材身份，**不表示先后顺序、真实/渲染、好/坏或对/错**。即使 b 先出现，`answer: "a"` 的含义仍然是 a 对应的素材正确。界面向受试者显示“第一幅 / 第二幅”，不暴露文件名、标准答案或来源标签。

例如，识别任务可以写成：

```json
{
  "id": "pair-002",
  "a": "inputs/original.png",
  "b": "outputs/variant.png",
  "answer": "a",
  "group": "室外",
  "metadata": {"camera": 10, "algorithm": "method-x"}
}
```

偏好任务通常省略正式题的 `answer`。`answer` 和选项身份分开保存，避免把所有二选一任务都解释成准确率。

### 图片与路径约定

- 当前接收静态 PNG、JPEG 图片，扩展名为 `.png`、`.jpg`、`.jpeg`。
- 使用 UTF-8 JSON；源文件允许 BOM。路径统一使用 `/`，支持中文和空格。
- 图片可以处在任意子目录，同一张图可以被多道题引用。不要求同名或固定场景/视点数量。默认 2D 可不同分辨率；3D 或 Patch 要求同题所有图片尺寸一致。
- 所有引用必须位于当前实验目录内部；不接收绝对路径、上级路径、远程 URL 或符号链接。
- 不同素材路径不能仅以大小写区分，保证 Windows 与 Android 的发布包能够相互导入。
- 新发布包只包含定义和清单，原图由独立素材目录提供。Patch 只改变绘制时的源区域，不写入裁剪图片或重编码原图。
- 归档包的根目录直接放 `study.json`。不额外嵌套一个未知名称的外层文件夹。

Python 工具检查字段、路径、文件存在性和非空性；不执行完整图片解码。客户端发布前必须进一步解码，拒绝损坏或动画文件，并记录真实宽高。扩展名不是图片有效性的证明。

源数据校验工具遇到 `release.json` 会明确拒绝，交给支持发布包的客户端验证，不会忽略它并把发布包降为普通草稿。

## 3 可选配置与固定语义

完整默认值如下。研究者只需填写要修改的字段，客户端发布时展开全部默认值，旧版本不受未来默认值变化影响。

```json
{
  "presentation": {
    "mode": "sequential",
    "promptMs": 2000,
    "imageMs": 3000
  },
  "schedule": {
    "repetitions": 1,
    "pairOrder": "random",
    "itemOrder": "random",
    "blockByGroup": false,
    "avoidAdjacentRepeats": false,
    "controlPlacement": "spread",
    "practicePairOrder": "random",
    "controlPairOrder": "random"
  },
  "quality": {
    "minControlAccuracy": 1.0,
    "requiredTrue": []
  },
  "analysis": {
    "metric": "selection_rate"
  }
}
```

### 呈现

`mode` 当前只支持 `sequential`。流程固定为提示第一幅、第一幅图片、提示第二幅、第二幅图片、作答；背景中性灰，图片等比完整显示，记录实际呈现尺寸。`promptMs` 为 0～60000 的整数，0 表示跳过提示；`imageMs` 为 1～600000 的整数。单位全部为毫秒。

正式界面不提供跳题、答题超时、默认选择、回看或每题正确率。中断后保留记录，恢复时从当前题开头重播。A/B 仍顺序播放，双眼可用 SBS 同时显示。

可选 `presentation.stereo={layout:"full_sbs",uiDisparity:0,pointerMapping:"screen"}` 开启双眼。用户确认设备使用 Full SBS，新配置默认 full_sbs，既有显式 half_sbs 继续兼容；UI 双眼总水平视差为 -64～64 逻辑像素。pointerMapping 为 screen（整屏连续）或 per_eye（普通屏幕分半调试）。两眼 UI 和软件指针同步，图片阶段隐藏所有鼠标。立体实现为 `2afc-stereo@1`。

可选 `presentation.patch={width:512,height:320,distribution:"center_triangular"}` 开启裁剪。width、height 为正整数原图像素，可独立设置宽高比，面积上限 4000 万像素；发布前检查不能超过任何候选图，预览也检查越界。裁剪结果按自身宽高比等比适应显示区域。先完成帧/视点和次序排程，再用独立 PRNG 抽取中心偏重三角分布位置，每题四张图及重复轮次共享区域。会话 trial.patch 保存 x/y/width/height 像素矩形；像素配置使用 `2afc-schedule@4`，旧面积配置 area（0.001～1）及 `2afc-schedule@3` 继续沿用原平方根算法，不能混用两种配置。恢复与导入校验区域，CSV 导出实际矩形、种子及右眼指纹。省略字段关闭，不向旧定义补写默认值。详见 [操作与完整示例](stereo-and-patch.md)。

### 排程

- `repetitions` 为 1～1000 的整数，**只影响正式题**。练习和控制题各出现一次。
- `pairOrder: "random"` 为每个题次独立随机先后次序；`balanced` 要求正式题重复次数为偶数，每一道正式题有一半 a 先、一半 b 先。
- `itemOrder: "listed"` 使用清单顺序；`random` 在每轮内随机排列。练习题和控制题也使用该字段选择清单顺序或随机顺序。
- `blockByGroup: true` 按 `group` 将正式题分块，各块完成全部轮次再进入下一块。此时每道正式题必须有 `group`。块顺序按首次出现顺序形成，再按 `itemOrder` 保留或随机排列。
- 练习题先于正式阶段。控制题按正式题次均匀插入：第 k 道控制题放在正式题次索引 `floor(k × M / C)` 之前，k 从 0 开始，M 为正式题次总数，C 为控制题数。例如 40 次正式判断、两道控制题，插在第 1 和第 21 次正式判断前。没有控制题时跳过。
- `avoidAdjacentRepeats: true` 要求正式题次中相同题目不紧邻，即使中间插入控制题也视为重复。随机排程在轮次边界交换后续题目以满足该约束。单题分块重复等不可满足的配置必须在发布前报错；`listed` 与该约束冲突时也必须报错，不改变研究者指定的顺序。
- 练习、控制题的素材先后顺序默认独立随机；`pairOrder: "balanced"` 的保证只针对正式题。真实感模板显式使用 `practicePairOrder: "alternating"` 和 `controlPairOrder: "balanced"`；后者要求控制题为偶数道，按控制题出现次序交替先后。

每个会话自动生成排程种子，同时保存完整实际排程及排程实现版本。研究者不用手工管理种子。输入文件中的列表顺序有意义；适配器扫描源目录时应先排序，不能依赖文件系统枚举顺序。

题目描述叫 `item`，一次实际呈现叫 `trial`。同一 item 重复两次，会形成两个 trial，拥有独立 ID 和展示顺序。预计作答数为：

```text
正式题数 × repetitions + 练习题数 + 控制题数
```

### 质量与分析

`minControlAccuracy` 为 0～1 的数，默认要求控制题全对。无控制题时标记为“未配置控制检查”，不按失败处理。未完成、未通过检查的会话保留原始记录，并给出排除原因。默认分析只纳入完成且通过已配置检查的会话。

`analysis.metric` 支持：

- `selection_rate`：逐题统计 a、b 的选择次数、选择比例、实际参与人数和判断次数。不同题目的 a 不具有共同含义，不默认跨题合并成一个 a 选择率。
- `accuracy`：每道正式题都必须有 `answer`，统计逐题、分组和整体准确率。

练习与控制题不计入正式指标。参与人数与判断次数分开记录，重复呈现不能增加参与人数。结果按采集时选定的观看条件分别展示，默认不跨条件合并。

基础分析不设置统一的最低人数、专家比例或通过阈值。当前真实感方案中的 15 人、专家不超过 1/3、序列识别率不超过 75% 等规则应进入独立实验模板和分析模块。模板在创建时提供配置，发布版本保存实际采用的配置；不能仅保存一个模板名并依赖未来模板的默认值。

转换工具将旧方案规则保存在 `metadata.legacyProtocol` 中用于追溯；**metadata 不激活旧规则，也不等于统计模块已迁移**。默认基础分析不会自动输出“照片级真实”“通过”等旧方案结论。

### 登记字段与真实感模板

`participantFields` 默认空列表。每项包含 `id`、`label` 和 `type`，类型支持 `text`、`integer`、`number`、`boolean`；可选 `required`、数值 `min/max`。匿名编号和观看条件是基础登记信息，不需要在列表中重复定义。`quality.requiredTrue` 引用已定义的布尔字段，指定参与条件；字段值不满足时不计入有效结果。

真实感模板显式保存年龄、视力、色觉、独立性和专家身份字段，以及设备型号、观看距离要求。`analysis.profile` 为可选分析配置。历史 `version: 1` 保留 `minObserversPerItem` 和固定单帧视点覆盖；新 `version: 2` 使用 `minObserversPerSequence`，允许候选池包含多帧，并要求每人抽样。两者都记录专家比例、阈值、序列允许视点、分辨率、练习和控制题数量。人数和阈值是实验配置，不等同于满足外部认证；实际当前材料缺少练习和控制，因此直接载入版本仍标记为演练。

在界面选择或应用模板会生成具体配置；直接修改 metadata 中的旧模板名称不会改变实验行为。规范的基础默认值在 Python 与 Dart 中通过同一份 `test/fixtures/v2-expanded.json` 校验。

## 4 统一操作流程

1. **创建或导入草稿。**界面填写名称和问题，选择 2AFC；导入标准目录或标准 ZIP。当前真实感原目录直接使用“加载真实感素材目录”，其他格式可使用外部适配器。
2. **检查和预览。**显示题量、练习/控制数量、预计作答数和预计观看时间，预览两张素材及一个完整题次；错误定位到具体题目和字段。作答时间不限，不能承诺固定总耗时。
3. **发布实验版本。**验证图片、排程约束和配置，生成不可变版本，冻结素材与说明。修改后保存草稿，再发布新版本。
4. **采集。**选择明确的发布版本，填写匿名参与者编号和观看条件，开始或恢复会话。登记表和参与条件由实验模板决定；通用入口不强制年龄、专家身份或某个观看距离。
5. **查看与导出。**先呈现采集完成度和质量情况，再显示实验指标；导出标准结果 JSON 和逐题 CSV。同一版本、同一观看条件下默认不重复建立同一参与者的正式会话，重测需使用明确的另一次采集。

草稿必须持久化，不能只存在于页面内存。新建、复制实验时分配新的 `studyId`；修改同一实验保留它。软件导入时检测到同一 `studyId` 的其他版本，应归入同一个实验，而非仅按名称猜测归属。

Windows 普通操作现已收为“开始测试”单页：选择素材、配置每组抽样与 Patch/3D、登记并开始。上述草稿/发布步骤由程序在后台完成；取消登记不创建版本，相同配置复用已有版本。不同设置自动隔离，未完成会话可在同页按原参数恢复。高级编辑仍保留完整流程，见 [单页操作](windows-start-test.md)。

## 5 客户端生成的发布与结果数据

以下内容由客户端生成，研究者和原始数据适配器不手填。当前 Python 工具不发布版本、不生成结果。

### 发布包

新发布 ZIP 内仅包含展开默认值的 `study.json` 和机器生成的 `release.json`，原图独立存放并由本机加载。旧版把素材放入包的格式继续读取。源数据导入入口遇到 `release.json` 时按发布包验证，不能把它当普通草稿而忽略校验。

`release.json` 的合同如下：

| 字段 | 含义 |
|---|---|
| `schema` | `2` |
| `studyId` | 与定义一致的实验身份 |
| `revisionId` | 发布时新生成的 UUID；复制或跨设备导入同一个包时保持不变 |
| `createdAt` | UTC ISO 8601 时间 |
| `definition` | `path: "study.json"` 与该文件精确字节的 `sha256` |
| `assets` | 按路径排序的数组，每项包含 `path`、`sha256`、`mediaType`、真实 `width` 和 `height` |
| `materials` | 新包为 `external@1`，由本机选择独立素材目录；未知 SHA 需用 `bytes` 标记，并在会话中冻结实际抽中图片指纹 |
| `implementations` | `method`、`scheduler`、`quality`、`analysis` 的明确实现版本标识 |

只保存一次被重复引用的资源。哈希校验精确文件字节，不通过跨语言重新序列化 JSON 来猜测相同内容。同一 `revisionId` 对应不同内容时拒绝覆盖。客户端不支持某种方法、实现版本或配置时明确报错。

### 原始会话与导出

标准结果 JSON 顶层包含 `schema: 2`、`studyId`、`revisionId`、发布清单、完整实验定义和 `sessions`。素材图片由独立测试目录提供，结果 JSON 不嵌入图片。随机抽样会话额外保存所选素材的 `materialHashes`。

每条会话至少记录 `sessionId`、`participantId`、`conditionId`、参与者登记信息、设备与显示环境、UTC 开始/完成时间、排程实现版本、随机种子、实际 `trials`、`answers` 和 `events`。观看条件使用稳定 ID，显示名称单独保存。

每个 trial 至少有 `trialId`、`itemId`、`role`、从 1 开始的 `repetition` 和 `order`。`order: ["b", "a"]` 表示先 b 后 a。每个 answer 至少有 `trialId`、`selectedAlternative`、从 1 开始的 `selectedPosition`、`responseMs` 和 `answeredAt`；位置与选中的素材必须一致。是否正确从定义中的 `answer` 推导，不能以导入文件中的 `correct` 布尔值为事实依据。

事件包含呈现阶段、计划与实际时长、显示尺寸，以及中断时间和原因。原始答案与事件不能因修改统计口径而重写。派生报告注明分析实现版本和配置。

JSON 是无损备份和合并格式；CSV 是分析明细。合并先核对 `revisionId` 及发布清单。同一会话的相同内容重复导入不增加计数，不同内容标记冲突，不静默覆盖。仅有相同 `studyId` 的两个版本不能直接汇成一个正式结果；需明确选择分析口径并标记版本。

## 6 现有数据怎样迁移

需要 Python 3.10 或更新版本，无额外依赖。在项目根目录运行：

```powershell
python tools/study_data.py validate examples/study-v2
python tools/study_data.py migrate demo-data/demo.study.zip validation/migrated-study --study-id photorealism-demo
python tools/study_data.py validate validation/migrated-study
python -m unittest discover -s tools -p test_study_data.py -v
```

输出目录必须尚不存在，父目录必须存在。转换器不会改动源 ZIP，也不会覆盖已有输出。它验证旧清单与图片哈希，复制被引用的图片，不重编码。转换失败时不留下发布到目标路径的半成品。

旧包字段映射：

| schema 1 | 新源数据 |
|---|---|
| 内容哈希实验 ID | `metadata.sourceExperimentId`；另设稳定的 `studyId` |
| `cases` | `items` |
| `gt`、`render` | `a`、`b`，标准答案为 `a` |
| `kind` | `role` |
| `sequence` | `group` |
| `frame/view/iteration/mapping/width/height` | 题目 `metadata` |
| `promptMs/imageMs` | `presentation` |
| 抽样种子 | `metadata.sourceSamplingSeed`，不冒充新会话排程种子 |
| `isDemo` | 原样保留 |

演示包迁移后仍为 20 对正式题、4 道练习、两道控制题，共 46 次作答。迁移保留素材身份、题目元数据、时间和旧方案来源，但新排程不承诺与 schema 1 相同。旧包、旧会话、旧统计继续按旧实现读取；禁止只替换 ID 后把旧答案当成新版本的答案。

本工具接收旧应用导出的固定测试包。尚未冻结的原始目录可以先由旧应用导出 ZIP，也可以另写一个原始目录适配器直接生成同一 v2 源格式。

未来适配器只承担四件事：读取源数据、确定素材配对、复制引用文件、生成本规范的 `study.json`。它不实现 UI、不决定受试者排程、不自动给真实感结论。场景名、文件名配对策略、相机映射和最大迭代选择只出现在适配器中；平台不再增加针对这些目录的导入分支。

## 7 接入验收

- 一对任意名称的图片，无练习、无控制、无视点和迭代信息，能建立并完成一次实验。
- 素材位于不同子目录，能被正确引用、预览、发布和跨设备导入。
- 新实验不修改 Dart、Kotlin 或统计代码，仅通过标准输入和已有配置建立。
- b 先显示、受试者选择第二幅时，正确记录为选择 a；可选标准答案不与屏幕位置混淆。
- 不可满足的平衡和排程要求在发布前报错，配置拼写错误不会静默变成默认值。
- 当前数据转换后逐文件字节不变、演示标记不丢失；旧会话仍由旧版本读取和复算。
- 无关实验中的损坏文件只影响该条记录，不阻断其他实验。
- 发布后配置不可编辑，旧版本不因新默认值或新排程实现而改变。
