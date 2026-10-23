import 'dart:io';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'domain.dart';
import 'repository.dart';
import 'quick_test_settings.dart';

class QuickTestPanel extends StatefulWidget {
  final StudyRepository repository;
  final bool busy;
  final Experiment? active;
  final List<StudySession> sessions;
  final Future<void> Function(StudyDraft) onSource;
  final Future<void> Function(StudyDraft, StudyDefinition) onStart;
  final Future<void> Function(StudySession, Experiment) onResume;
  const QuickTestPanel({
    super.key,
    required this.repository,
    required this.busy,
    required this.active,
    required this.sessions,
    required this.onSource,
    required this.onStart,
    required this.onResume,
  });
  @override
  State<QuickTestPanel> createState() => _QuickTestPanelState();
}

class _QuickTestPanelState extends State<QuickTestPanel> {
  final directory = TextEditingController(),
      width = TextEditingController(),
      height = TextEditingController(),
      disparity = TextEditingController();
  final countInputs = <String, TextEditingController>{};
  StudyDraft? draft;
  QuickTestSettings? settings;
  String? loadedRoot, failure;
  bool working = true;
  List<(Experiment, StudySession)> pending = [];
  int pendingGeneration = 0;
  StudyRepository get repo => widget.repository;
  bool get locked => working || widget.busy;
  Map<String, String> get countValues => {
    for (final entry in countInputs.entries) entry.key: entry.value.text,
  };
  bool get sameDirectory =>
      loadedRoot != null &&
      p.equals(p.normalize(directory.text.trim()), p.normalize(loadedRoot!));
  @override
  void initState() {
    super.initState();
    restore();
  }

  @override
  void didUpdateWidget(covariant QuickTestPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.sessions != widget.sessions) {
      unawaited(refreshPending());
    }
  }

  Future<void> refreshPending() async {
    final id = draft?.id, token = ++pendingGeneration;
    if (id == null) return;
    try {
      final all = <(Experiment, StudySession)>[];
      for (final experiment in (await repo.experiments()).where(
        (e) => e.studyId == id && e.isV2,
      )) {
        for (final session in await repo.sessions(experiment)) {
          if (!session.complete) all.add((experiment, session));
        }
      }
      if (mounted && token == pendingGeneration) setState(() => pending = all);
    } catch (e) {
      if (mounted && token == pendingGeneration) {
        setState(() => failure = '未完成会话暂时无法读取：$e');
      }
    }
  }

  Future<void> restore() async {
    try {
      final saved = await repo.lastQuickDraft();
      if (saved != null) await adopt(saved);
    } catch (e) {
      if (mounted) setState(() => failure = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> adopt(StudyDraft next) async {
    final root = repo.bindingAt(repo.draftDir(next.id))?['root'] as String?;
    check(
      root != null && !root.startsWith('content://'),
      '请重新选择 Windows 测试素材目录',
    );
    if (!mounted) return;
    for (final controller in countInputs.values) {
      controller.dispose();
    }
    countInputs.clear();
    final model = QuickTestSettings(next.definition);
    for (final entry in model.counts.entries) {
      countInputs[entry.key] = TextEditingController(text: '${entry.value}');
    }
    setState(() {
      draft = next;
      settings = model;
      loadedRoot = root;
      directory.text = root!;
      width.text = model.patchWidth;
      height.text = model.patchHeight;
      disparity.text = model.disparity;
      failure = null;
      pending = [];
    });
    await widget.onSource(next);
    await refreshPending();
  }

  Future<void> readDirectory() async {
    if (locked) return;
    setState(() {
      working = true;
      failure = null;
    });
    try {
      check(directory.text.trim().isNotEmpty, '请选择或输入素材目录');
      await adopt(
        await repo.loadQuickDirectory(Directory(directory.text.trim())),
      );
    } catch (e) {
      if (mounted) setState(() => failure = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> chooseDirectory() async {
    if (locked) return;
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择测试素材目录：renders 的上一级，或含 study.json 的目录',
    );
    if (selected == null || !mounted) return;
    directory.text = selected;
    await readDirectory();
  }

  Future<void> start() async {
    if (locked || settings == null || !sameDirectory) return;
    setState(() {
      working = true;
      failure = null;
    });
    try {
      await widget.onStart(draft!, settings!.definition(countValues));
    } catch (e) {
      if (mounted) setState(() => failure = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  void dispose() {
    pendingGeneration++;
    for (final controller in [
      directory,
      width,
      height,
      disparity,
      ...countInputs.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget card(String title, Widget child) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Color(0xff173e3a),
            ),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
  Widget chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0xffeaf0e9),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(text),
  );
  Widget number(
    String label,
    TextEditingController controller,
    String key,
    ValueChanged<String> change, {
    double size = 150,
  }) => SizedBox(
    width: size,
    child: TextField(
      key: Key(key),
      controller: controller,
      enabled: !locked,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (text) => setState(() {
        change(text);
        failure = null;
      }),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final model = settings;
    final error = model?.error(countValues);
    final ready = model != null && sameDirectory && error == null && !locked;
    final sourceCard = card(
      '1  选择测试素材',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('quick-material-directory'),
            controller: directory,
            enabled: !locked,
            decoration: InputDecoration(
              labelText: '素材目录',
              hintText: '选择 *_renders 的上级目录，或含 study.json 的目录',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                key: const Key('quick-browse'),
                tooltip: '浏览并读取目录',
                onPressed: locked ? null : chooseDirectory,
                icon: const Icon(Icons.folder_open),
              ),
            ),
            onChanged: (_) => setState(() => failure = null),
            onSubmitted: (_) => readDirectory(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const Key('quick-load-materials'),
                onPressed: locked || directory.text.trim().isEmpty
                    ? null
                    : readDirectory,
                icon: const Icon(Icons.refresh),
                label: const Text('读取目录'),
              ),
              if (working)
                const Text('正在准备，请稍候…')
              else if (model != null && sameDirectory)
                Text(
                  '${model.base.name} · ${model.available.values.fold(0, (a, b) => a + b)} 对候选素材 · ${model.available.length} 个分组',
                )
              else if (model != null)
                const Text(
                  '目录已修改，请先读取目录',
                  style: TextStyle(color: Color(0xffa04935)),
                )
              else
                const Text('原图保留在素材目录，读取后即可设置并开始。'),
            ],
          ),
        ],
      ),
    );
    if (model == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          sourceCard,
          if (failure != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                failure!,
                style: const TextStyle(color: Color(0xffa04935)),
              ),
            ),
        ],
      );
    }
    final sampling = card(
      '2  每位参与者抽取多少对',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('每人独立、不放回抽样，所有候选素材均可被选中。'),
          const SizedBox(height: 10),
          for (final entry in model.available.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sequenceLabels[entry.key] ?? entry.key,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '候选 ${entry.value} 对',
                          style: const TextStyle(
                            color: Color(0xff67796e),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  number(
                    '抽取 / 对',
                    countInputs[entry.key]!,
                    'quick-count-${entry.key}',
                    (value) {
                      model.counts[entry.key] = int.tryParse(value) ?? 0;
                    },
                    size: 100,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
            key: ValueKey('quick-repetitions-${model.repetitions}'),
            initialValue: model.repetitions,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '同一组图片测几遍',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final n in ({1, 2, model.repetitions}.toList()..sort()))
                DropdownMenuItem(
                  value: n,
                  child: Text(
                    n.isEven && model.base.schedule['pairOrder'] == 'balanced'
                        ? n == 2
                              ? '测 2 遍（图片顺序互换）'
                              : '测 $n 遍（两种顺序各 ${n ~/ 2} 遍）'
                        : '测 $n 遍',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: locked
                ? null
                : (n) => setState(() => model.repetitions = n!),
          ),
          const SizedBox(height: 8),
          Text(
            model.repetitions == 1
                ? '每组两张图只比较一次，答 1 题。'
                : model.repetitions.isEven &&
                      model.base.schedule['pairOrder'] == 'balanced'
                ? model.repetitions == 2
                      ? '同一组两张图，交换播放顺序，各答一次。'
                      : '每组两张图共比较 ${model.repetitions} 次，两种播放顺序各占一半。'
                : '每组两张图共比较 ${model.repetitions} 次，每次随机决定播放顺序。',
            style: const TextStyle(color: Color(0xff67796e), fontSize: 12),
          ),
        ],
      ),
    );
    final presentation = card(
      '3  图片显示方式',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: const Key('quick-patch-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('随机 Patch'),
            subtitle: const Text('中心区域概率更高；A/B、双眼和重复题共用区域。'),
            value: model.patchEnabled,
            onChanged: locked
                ? null
                : (value) => setState(() {
                    model.patchEnabled = value;
                    failure = null;
                  }),
          ),
          if (model.patchEnabled && model.legacyPatch != null) ...[
            Text(
              '沿用旧面积配置 ${((model.legacyPatch!['area'] as num) * 100).toStringAsFixed(1)}%',
            ),
            TextButton(
              onPressed: locked
                  ? null
                  : () => setState(() => model.legacyPatch = null),
              child: const Text('改用像素宽高'),
            ),
          ] else if (model.patchEnabled)
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                number(
                  model.stereoEnabled ? '宽 / 单眼像素' : '宽 / 原图像素',
                  width,
                  'quick-patch-width',
                  (text) => model.patchWidth = text,
                ),
                number(
                  model.stereoEnabled ? '高 / 单眼像素' : '高 / 原图像素',
                  height,
                  'quick-patch-height',
                  (text) => model.patchHeight = text,
                ),
              ],
            ),
          if (model.patchEnabled)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                model.stereoEnabled && model.stereoInput == 'sbs'
                    ? '宽高按单眼像素计算，左右半幅分别截取相同位置，再并排显示。'
                    : '截取后等比适应显示区域；尺寸不能超过原图。',
                style: const TextStyle(fontSize: 12, color: Color(0xff67796e)),
              ),
            ),
          const Divider(height: 28),
          SwitchListTile(
            key: const Key('quick-stereo-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('3D 双目显示'),
            subtitle: Text(
              model.stereoInput == 'sbs'
                  ? '图片已含左右眼；按钮和鼠标也按双目显示。'
                  : model.stereoMissing == 0
                  ? '已提供左右眼配对图片。'
                  : '当前素材未提供完整左右眼配对，可先使用 2D。',
            ),
            value: model.stereoEnabled,
            onChanged: locked
                ? null
                : (value) => setState(() {
                    model.stereoEnabled = value;
                    if (value) model.layout = 'full_sbs';
                    failure = null;
                  }),
          ),
          if (model.stereoEnabled) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('quick-stereo-input-${model.stereoInput}'),
              initialValue: model.stereoInput,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '3D 素材如何存放',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'sbs', child: Text('左右眼已拼在一张图（SBS）')),
                DropdownMenuItem(value: 'separate', child: Text('左右眼分别存成两张图')),
              ],
              onChanged: locked
                  ? null
                  : (value) => setState(() {
                      model.stereoInput = value!;
                      failure = null;
                    }),
            ),
          ],
          if (model.stereoEnabled)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                model.layout == 'full_sbs'
                    ? 'Full SBS · 左右各一幅完整画面'
                    : 'Half SBS · 旧配置',
              ),
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    number(
                      'UI 双眼视差',
                      disparity,
                      'quick-disparity',
                      (text) => model.disparity = text,
                    ),
                    SizedBox(
                      width: 200,
                      child: DropdownButtonFormField<String>(
                        initialValue: model.pointerMapping,
                        decoration: const InputDecoration(labelText: '鼠标映射'),
                        items: const [
                          DropdownMenuItem(
                            value: 'screen',
                            child: Text('整屏连续'),
                          ),
                          DropdownMenuItem(
                            value: 'per_eye',
                            child: Text('按半屏（调试）'),
                          ),
                        ],
                        onChanged: locked
                            ? null
                            : (v) => setState(() => model.pointerMapping = v!),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        sourceCard,
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, bounds) => bounds.maxWidth >= 760
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: sampling),
                    const SizedBox(width: 18),
                    Expanded(child: presentation),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    sampling,
                    const SizedBox(height: 18),
                    presentation,
                  ],
                ),
        ),
        const SizedBox(height: 18),
        card(
          '本次测试参数',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                key: const Key('quick-effective-settings'),
                spacing: 8,
                runSpacing: 8,
                children: [
                  chip(
                    '候选池 ${model.available.values.fold(0, (a, b) => a + b)} 对',
                  ),
                  chip('抽 ${model.selectedCount} 组，共需答 ${model.judgments} 题'),
                  chip(
                    model.stereoEnabled
                        ? '3D · ${model.layout == 'full_sbs' ? 'Full SBS' : 'Half SBS'}'
                        : '2D',
                  ),
                  if (model.stereoEnabled)
                    chip(model.stereoInput == 'sbs' ? '素材：已拼 SBS' : '素材：左右眼分图'),
                  if (model.stereoEnabled)
                    chip(
                      'UI 视差 ${model.disparity} · ${model.pointerMapping == 'screen' ? '整屏鼠标' : '半屏调试鼠标'}',
                    ),
                  chip(
                    !model.patchEnabled
                        ? '整图'
                        : model.legacyPatch != null
                        ? 'Patch · 旧面积配置'
                        : '${model.stereoEnabled ? '每眼 ' : ''}Patch ${model.patchWidth} × ${model.patchHeight} 像素',
                  ),
                  chip(
                    '提示 ${model.base.presentation['promptMs']} ms · 图片 ${model.base.presentation['imageMs']} ms',
                  ),
                  if (model.base.isDemo) chip('流程演练'),
                ],
              ),
              const SizedBox(height: 12),
              Text('作答问题：${model.base.question}'),
              if (error != null || !sameDirectory)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    !sameDirectory ? '目录尚未读取，当前参数不能用于开始测试。' : error!,
                    key: const Key('quick-validation-error'),
                    style: const TextStyle(color: Color(0xffa04935)),
                  ),
                ),
              if (failure != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    failure!,
                    key: const Key('quick-start-error'),
                    style: const TextStyle(color: Color(0xffa04935)),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('quick-start-test'),
                onPressed: ready ? start : null,
                icon: locked
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(locked ? '正在准备测试…' : '登记参与者并开始测试'),
              ),
              const SizedBox(height: 8),
              const Text(
                '本页参数直接用于新会话。中断恢复沿用原图片和参数。',
                style: TextStyle(fontSize: 12, color: Color(0xff67796e)),
              ),
            ],
          ),
        ),
        if (pending.isNotEmpty) ...[
          const SizedBox(height: 18),
          card(
            '继续上次未完成的测试',
            Column(
              children: [
                const Text('每条会话沿用各自原来的抽样和显示参数。'),
                for (final (current, session) in pending)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(session.participantId),
                    subtitle: Text(
                      '已答 ${session.answers.length}/${session.trials.length} · ${session.display['condition']}\n${current.definition?.stereo == null ? '2D' : '3D SBS'} · ${current.definition?.patch == null
                          ? '整图'
                          : current.definition!.patch!.containsKey('width')
                          ? 'Patch ${current.definition!.patch!['width']} × ${current.definition!.patch!['height']} 像素'
                          : '旧面积 Patch'}',
                    ),
                    trailing: OutlinedButton(
                      key: Key('quick-resume-${session.id}'),
                      onPressed: locked
                          ? null
                          : () => widget.onResume(session, current),
                      child: const Text('恢复测试'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
