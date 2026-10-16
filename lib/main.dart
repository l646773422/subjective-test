import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'domain.dart';
import 'platform_bridge.dart';
import 'presentation.dart';
import 'repository.dart';

const ink = Color(0xff173e3a);
const paper = Color(0xfff5f4ef);
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StudyApp());
}

class StudyApp extends StatelessWidget {
  final StudyRepository? repository;
  final int? testDurationMs;
  const StudyApp({super.key, this.repository, this.testDurationMs});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '真实感评测',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: ink,
        primary: ink,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: paper,
      fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xffe3e6df)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        ),
      ),
    ),
    home: Workbench(repository: repository, testDurationMs: testDurationMs),
  );
}

class Workbench extends StatefulWidget {
  final StudyRepository? repository;
  final int? testDurationMs;
  const Workbench({super.key, this.repository, this.testDurationMs});
  @override
  State<Workbench> createState() => WorkbenchState();
}

class WorkbenchState extends State<Workbench> {
  StudyRepository? repo;
  List<Experiment> experiments = [];
  List<StudySession> sessions = [];
  Experiment? active;
  final List<SourceScan> sources = [];
  final List<StudyCase> auxiliary = [];
  final name = TextEditingController(text: '照片级真实渲染主观评价');
  final seed = TextEditingController(text: '3917');
  bool busy = false, mappingConfirmed = false;
  String? failure;
  int page = 0, promptSeconds = 2, imageSeconds = 3;
  @override
  void initState() {
    super.initState();
    unawaited(initialize());
  }

  Future<void> initialize() async {
    setState(() {
      busy = true;
      failure = null;
    });
    try {
      repo = widget.repository ?? await StudyRepository.open();
      await reload();
    } catch (e) {
      failure = e.toString();
    }
    if (mounted) {
      setState(() {
        busy = false;
      });
    }
  }

  Future<void> reload({Experiment? select}) async {
    experiments = await repo!.experiments();
    active =
        select ?? active ?? (experiments.isEmpty ? null : experiments.first);
    sessions = active == null ? [] : await repo!.sessions(active!);
  }

  Future<void> perform(Future<void> Function() task) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await task();
    } catch (e) {
      if (mounted) message(e.toString(), error: true);
    }
    if (mounted) setState(() => busy = false);
  }

  void message(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? const Color(0xff953e32) : ink,
      ),
    );
  }

  Future<void> demo() => perform(() async {
    final e = await repo!.loadDemo();
    await reload(select: e);
    message('演示题库已载入：20 对正式图片、4 道练习、2 道控制题');
  });
  Future<Uint8List?> pickBytes(String extension) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [extension],
      withData: true,
    );
    return result?.files.single.bytes;
  }

  Future<void> importPackage() => perform(() async {
    final bytes = await pickBytes('zip');
    if (bytes == null) return;
    final e = await repo!.importZip(bytes);
    await reload(select: e);
    message('测试包校验通过，题库已固定');
  });
  Future<void> saveBytes(Uint8List bytes, String filename) async {
    final path = await FilePicker.platform.saveFile(
      fileName: filename,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: [p.extension(filename).substring(1)],
    );
    if (path == null) return;
    if (Platform.isWindows) await File(path).writeAsBytes(bytes, flush: true);
    if (mounted) message('已导出 $filename');
  }

  Future<void> addSource() async {
    final sequence = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择要添加的测试序列'),
        children: [
          for (final key in protocolViews.keys)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, key),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text('${sequenceLabels[key]!}\n$key'),
              ),
            ),
        ],
      ),
    );
    if (sequence == null || !mounted) return;
    await perform(() async {
      final root = Platform.isAndroid
          ? await PlatformBridge.pickDirectory()
          : await FilePicker.platform.getDirectoryPath(
              dialogTitle: '选择包含 frameXXXXXX 的解码图片目录',
            );
      if (root == null) return;
      final scan = await scanSource(root, sequence);
      sources.removeWhere((s) => s.sequence == sequence);
      sources.add(scan);
      mappingConfirmed = false;
      message('找到 ${scan.frames.length} 个完整可用帧');
    });
  }

  Future<void> addAuxiliary(String kind) => perform(() async {
    final count = auxiliary.where((c) => c.kind == kind).length;
    if (count >= (kind == 'control' ? 2 : 5)) {
      throw const FormatException('该类型的素材数量已达到上限');
    }
    final gt = await FilePicker.platform.pickFiles(
      dialogTitle: '选择真实拍摄图像 GT',
      type: FileType.image,
      withData: true,
    );
    if (gt == null) return;
    final render = await FilePicker.platform.pickFiles(
      dialogTitle: kind == 'control' ? '选择明显差异的控制图像' : '选择对应的渲染图像',
      type: FileType.image,
      withData: true,
    );
    if (render == null) return;
    final dir = Directory(p.join(repo!.root.path, 'auxiliary', uniqueId()));
    await dir.create(recursive: true);
    final gtFile = File(
      p.join(dir.path, 'gt${p.extension(gt.files.single.name)}'),
    );
    final renderFile = File(
      p.join(dir.path, 'render${p.extension(render.files.single.name)}'),
    );
    await gtFile.writeAsBytes(gt.files.single.bytes!, flush: true);
    await renderFile.writeAsBytes(render.files.single.bytes!, flush: true);
    auxiliary.add(
      await readPair(
        id: '${kind}_${uniqueId()}',
        sequence: 'aux',
        kind: kind,
        gt: gtFile,
        render: renderFile,
      ),
    );
  });
  Future<void> freeze() => perform(() async {
    if (!mappingConfirmed) throw const FormatException('请先核对图片配对与视点映射');
    final value = int.tryParse(seed.text);
    if (value == null) throw const FormatException('随机种子需要填写整数');
    final e = await repo!.freezeSources(
      name: name.text.trim(),
      seed: value,
      sources: sources,
      auxiliary: auxiliary,
      promptMs: promptSeconds * 1000,
      imageMs: imageSeconds * 1000,
    );
    await reload(select: e);
    message('正式题库已固定，可开始采集或导出测试包');
  });
  Future<void> launch(StudySession session) async {
    try {
      await repo!.verify(active!);
    } catch (e) {
      if (mounted) message(e.toString(), error: true);
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TestScreen(
          repository: repo!,
          experiment: active!,
          session: session,
          testDurationMs: widget.testDurationMs,
        ),
      ),
    );
    if (!mounted) return;
    await perform(() async {
      await reload();
      page = 1;
    });
  }

  Future<void> newSession() async {
    if (active == null) return;
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const ParticipantDialog(),
    );
    if (data == null || !mounted) return;
    StudySession? created;
    await perform(() async {
      final id = (data['participantId'] as String).trim();
      if (sessions.any(
        (s) =>
            s.participantId == id &&
            s.display['condition'] == data['condition'],
      )) {
        throw const FormatException('该编号在此观看条件下已有会话，请恢复或查看已有记录');
      }
      final view = View.of(context);
      final scheduleSeed = Random.secure().nextInt(0x7fffffff);
      created = StudySession(
        id: uniqueId(),
        experimentId: active!.id,
        participantId: id,
        startedAt: DateTime.now().toUtc().toIso8601String(),
        seed: scheduleSeed,
        participant: {
          'age': data['age'],
          'expert': data['expert'],
          'normalVision': true,
          'normalColorVision': true,
          'organizerOrDeveloper': false,
        },
        display: {
          'condition': data['condition'],
          'distanceCm': data['distanceCm'],
          'device': data['device'],
          'displayNotes': data['displayNotes'],
          'platform': Platform.operatingSystem,
          'osVersion': Platform.operatingSystemVersion,
          'screenWidthPx': view.physicalSize.width,
          'screenHeightPx': view.physicalSize.height,
          'dpr': view.devicePixelRatio,
        },
        trials: buildSchedule(active!, scheduleSeed),
      );
      await repo!.save(created!);
      await reload();
    });
    if (created != null && mounted) await launch(created!);
  }

  @override
  void dispose() {
    name.dispose();
    seed.dispose();
    super.dispose();
  }

  Widget section(String title, String subtitle, Widget child) => Card(
    margin: const EdgeInsets.only(bottom: 20),
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xff66716a), height: 1.6),
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    ),
  );
  Widget badge(String text, {bool warning = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: warning ? const Color(0xffffeed1) : const Color(0xffe7efeb),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: warning ? const Color(0xff835718) : ink,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
  Widget get experimentSelector => DropdownButtonFormField<String>(
    initialValue: active?.id,
    isExpanded: true,
    decoration: const InputDecoration(labelText: '当前固定题库'),
    items: experiments
        .map(
          (e) => DropdownMenuItem(
            value: e.id,
            child: Text(
              (e.isDemo ? '[演示] ' : '') + e.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        )
        .toList(),
    onChanged: busy
        ? null
        : (id) => perform(() async {
            active = experiments.firstWhere((e) => e.id == id);
            await reload();
          }),
  );
  Widget preparePage() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      section(
        '先准备题库，再开始采集',
        '题库固定后，所有受试者观看相同素材，各自随机排列呈现顺序。',
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              key: const Key('load-demo'),
              onPressed: busy ? null : demo,
              icon: const Icon(Icons.auto_awesome_mosaic_outlined),
              label: const Text('载入演示题库'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : importPackage,
              icon: const Icon(Icons.folder_zip_outlined),
              label: const Text('导入测试包'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : addSource,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('添加图片序列'),
            ),
          ],
        ),
      ),
      if (active != null)
        section(
          '当前题库',
          '配置和素材已固定；修改时需生成新题库。',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              experimentSelector,
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  badge(
                    active!.isDemo ? '演示素材 · 不作正式判定' : '正式题库',
                    warning: active!.isDemo,
                  ),
                  badge('20 对图片 / 40 次判断'),
                  badge('2 道控制题'),
                  badge('作答不限时'),
                ],
              ),
              const SizedBox(height: 16),
              SelectableText(
                '题库 ID  ${active!.id}',
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 112,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: active!.cases
                      .where((c) => c.kind == 'main')
                      .length,
                  separatorBuilder: (_, index) => const SizedBox(width: 10),
                  itemBuilder: (_, index) {
                    final c = active!.cases
                        .where((c) => c.kind == 'main')
                        .elementAt(index);
                    return InkWell(
                      onTap: () => preview(c),
                      child: Column(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              repo!.imageFile(active!, c.render),
                              cacheWidth: 280,
                              width: 140,
                              height: 80,
                              fit: BoxFit.contain,
                              errorBuilder: (_, e, stack) => const SizedBox(
                                width: 140,
                                height: 80,
                                child: Icon(Icons.broken_image),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${sequenceLabels[c.sequence] ?? c.sequence} · ${c.view}',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    key: const Key('go-sessions'),
                    onPressed: busy ? null : () => setState(() => page = 1),
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('登记受试者并开始'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => perform(() async {
                            await saveBytes(
                              await repo!.exportPackage(active!),
                              'study-${active!.id.substring(0, 12)}.zip',
                            );
                          }),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('导出测试包'),
                  ),
                ],
              ),
            ],
          ),
        ),
      section(
        '建立正式题库',
        '每帧只读取 test/ours_最大迭代数；GT 与 renders 按文件名配对。',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final key in protocolViews.keys) sourceTile(key),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : () => addAuxiliary('practice'),
                  icon: const Icon(Icons.school_outlined),
                  label: Text(
                    '练习图片对 ${auxiliary.where((c) => c.kind == 'practice').length} / 3～5',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => addAuxiliary('control'),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: Text(
                    '控制图片对 ${auxiliary.where((c) => c.kind == 'control').length} / 2',
                  ),
                ),
              ],
            ),
            for (final c in auxiliary)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${c.kind == 'control' ? '控制题' : '练习题'} · ${p.basename(c.gt)}',
                ),
                trailing: IconButton(
                  onPressed: busy
                      ? null
                      : () => setState(() => auxiliary.remove(c)),
                  icon: const Icon(Icons.close),
                ),
              ),
            const SizedBox(height: 20),
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '实验名称'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: seed,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '抽样随机种子'),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: DropdownButtonFormField<int>(
                    initialValue: promptSeconds,
                    decoration: const InputDecoration(labelText: '灰场提示'),
                    items: [1, 2, 3]
                        .map(
                          (n) =>
                              DropdownMenuItem(value: n, child: Text('$n 秒')),
                        )
                        .toList(),
                    onChanged: busy
                        ? null
                        : (n) => setState(() => promptSeconds = n!),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: DropdownButtonFormField<int>(
                    initialValue: imageSeconds,
                    decoration: const InputDecoration(labelText: '每幅图片'),
                    items: [3, 4, 5]
                        .map(
                          (n) =>
                              DropdownMenuItem(value: n, child: Text('$n 秒')),
                        )
                        .toList(),
                    onChanged: busy
                        ? null
                        : (n) => setState(() => imageSeconds = n!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('已核对 GT/render 对齐、测试视点顺序及控制题标准答案'),
              subtitle: const Text('没有 view_ids.json 时，视点按导出文件顺序映射至方案规定编号。'),
              value: mappingConfirmed,
              onChanged: busy
                  ? null
                  : (value) => setState(() => mappingConfirmed = value!),
            ),
            FilledButton.icon(
              onPressed: busy ? null : freeze,
              icon: const Icon(Icons.lock_outline),
              label: const Text('抽样并固定正式题库'),
            ),
          ],
        ),
      ),
    ],
  );
  Widget sourceTile(String key) {
    final matches = sources.where((s) => s.sequence == key);
    final source = matches.isEmpty ? null : matches.first;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        source == null ? Icons.radio_button_unchecked : Icons.check_circle,
        color: source == null ? Colors.black26 : ink,
      ),
      title: Text(
        '${sequenceLabels[key]!}  ·  ${protocolViews[key]!.length} 视点',
      ),
      subtitle: Text(
        source == null
            ? '尚未添加'
            : '${source.frames.length} 个可用帧；${source.issues.length} 项待处理',
      ),
      trailing: source == null
          ? null
          : TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(sequenceLabels[key]!),
                  content: SizedBox(
                    width: 600,
                    height: 360,
                    child: SingleChildScrollView(
                      child: SelectableText(
                        '${source.root}\n\n${source.issues.isEmpty ? '未发现缺图或配对问题' : source.issues.join('\n')}',
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
              child: const Text('查看校验'),
            ),
    );
  }

  Future<void> preview(StudyCase c) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(c.id),
      content: SizedBox(
        width: 840,
        child: Wrap(
          spacing: 20,
          runSpacing: 16,
          children: [
            for (final image in [('真实拍摄 GT', c.gt), ('渲染 render', c.render)])
              SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(image.$1),
                    const SizedBox(height: 8),
                    Image.file(
                      repo!.imageFile(active!, image.$2),
                      fit: BoxFit.contain,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
  Widget sessionPage() {
    if (active == null) return empty('还没有固定题库', '先载入演示题库，或导入已经准备好的测试包。');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        section(
          '登记与采集',
          '每位受试者生成独立随机排程。开始前确认设备亮度、显示尺寸与观看距离。',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              experimentSelector,
              const SizedBox(height: 18),
              FilledButton.icon(
                key: const Key('new-session'),
                onPressed: busy ? null : newSession,
                icon: const Icon(Icons.person_add_alt),
                label: const Text('新建受试者会话'),
              ),
            ],
          ),
        ),
        section(
          '会话记录',
          '未完成的会话可以恢复；答案逐题保存，中断记录不会删除。',
          sessions.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('暂无采集记录。点击上方按钮开始第一位受试者的测试。'),
                )
              : Column(
                  children: sessions
                      .map(
                        (s) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            s.complete
                                ? Icons.task_alt
                                : Icons.pause_circle_outline,
                            color: ink,
                          ),
                          title: Text(s.participantId),
                          subtitle: Text(
                            '${s.display['condition']} · 已答 ${s.answers.length}/${s.trials.length} · ${s.status(active!)}',
                          ),
                          trailing: s.complete
                              ? badge(
                                  s.status(active!),
                                  warning: !s.valid(active!),
                                )
                              : OutlinedButton(
                                  onPressed: busy ? null : () => launch(s),
                                  child: const Text('恢复'),
                                ),
                        ),
                      )
                      .toList(),
                ),
        ),
      ],
    );
  }

  Widget resultPage() {
    if (active == null) return empty('还没有评测结果', '导入题库并完成采集后，在这里查看统计和导出结果。');
    final report = buildReport(active!, sessions);
    final conditions = records(report['conditions']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        section(
          '结果与数据导出',
          '练习和控制题不计入正式识别率。原始记录保留，包括未完成和未通过的数据。',
          Column(
            children: [
              experimentSelector,
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => perform(() async {
                            await saveBytes(
                              repo!.resultsCsv(active!, sessions),
                              'study-results.csv',
                            );
                          }),
                    icon: const Icon(Icons.table_view_outlined),
                    label: const Text('导出逐题 CSV'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => perform(() async {
                            await saveBytes(
                              repo!.resultsJson(active!, sessions),
                              'study-results.json',
                            );
                          }),
                    icon: const Icon(Icons.save_alt),
                    label: const Text('导出完整 JSON'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => perform(() async {
                            final bytes = await pickBytes('json');
                            if (bytes == null) return;
                            final count = await repo!.mergeResults(
                              active!,
                              bytes,
                            );
                            await reload();
                            message('已合并 $count 条新会话');
                          }),
                    icon: const Icon(Icons.merge_outlined),
                    label: const Text('合并结果 JSON'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (conditions.isEmpty)
          empty('尚未采集', '每张图片需要至少 15 位有效观看员；两次呈现仍只计一位观看员。'),
        for (final condition in conditions)
          section(
            condition['condition'] as String,
            condition['status'] as String,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    badge('有效观看员 ${condition['validObservers']} / ≥15'),
                    badge('专家 ${condition['experts']} · 不宜超过 1/3'),
                    badge('总会话 ${condition['sessions']}'),
                  ],
                ),
                const SizedBox(height: 20),
                for (final row in records(condition['sequences']))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                sequenceLabels[row['sequence']] ??
                                    row['sequence'].toString(),
                              ),
                            ),
                            Text(
                              row['rate'] == null
                                  ? '—'
                                  : '${((row['rate'] as num) * 100).toStringAsFixed(1)}%',
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: (row['rate'] as num?)?.toDouble() ?? 0,
                          minHeight: 7,
                          borderRadius: BorderRadius.circular(10),
                          backgroundColor: const Color(0xffedf0eb),
                          color: (row['rate'] as num? ?? 0) > .75
                              ? const Color(0xffa05c42)
                              : ink,
                        ),
                      ],
                    ),
                  ),
                const Text(
                  '识别率越低，说明真实拍摄与渲染越难区分。完整 JSON 同时包含逐视点统计与呈现时间。',
                  style: TextStyle(color: Colors.black54, height: 1.7),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget empty(String title, String subtitle) => section(
    title,
    subtitle,
    const Padding(
      padding: EdgeInsets.all(24),
      child: Icon(Icons.layers_outlined, size: 52, color: Color(0xffb2beb6)),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 920;
    return Scaffold(
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (i) => setState(() => page = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.layers_outlined),
                  label: '题库准备',
                ),
                NavigationDestination(
                  icon: Icon(Icons.people_outline),
                  label: '采集会话',
                ),
                NavigationDestination(
                  icon: Icon(Icons.bar_chart_outlined),
                  label: '结果汇总',
                ),
              ],
            ),
      body: SafeArea(
        child: Row(
          children: [
            if (wide)
              Container(
                width: 226,
                decoration: const BoxDecoration(
                  color: Color(0xffeaf0e9),
                  border: Border(right: BorderSide(color: Color(0xffdce4da))),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(28, 36, 24, 36),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.filter_frames_outlined,
                            color: ink,
                            size: 34,
                          ),
                          SizedBox(height: 14),
                          Text(
                            '真实感评测',
                            style: TextStyle(
                              fontSize: 23,
                              fontWeight: FontWeight.w700,
                              color: ink,
                            ),
                          ),
                          SizedBox(height: 5),
                          Text(
                            'PHOTOREALISM STUDY',
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xff627368),
                              letterSpacing: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final entry in [
                      (Icons.layers_outlined, '题库准备'),
                      (Icons.people_outline, '采集会话'),
                      (Icons.bar_chart_outlined, '结果汇总'),
                    ].indexed)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: Material(
                          type: MaterialType.transparency,
                          child: ListTile(
                            selected: page == entry.$1,
                            selectedTileColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            leading: Icon(entry.$2.$1, color: ink),
                            title: Text(entry.$2.$2),
                            onTap: () => setState(() => page = entry.$1),
                          ),
                        ),
                      ),
                    const Spacer(),
                    const Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                        '离线采集 · 本机保存\nPCNL / 0.1.0',
                        style: TextStyle(
                          color: Color(0xff738477),
                          height: 1.9,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Column(
                children: [
                  if (busy) const LinearProgressIndicator(minHeight: 3),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(wide ? 36 : 20),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1120),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  badge('顺序呈现 · 2AFC'),
                                  badge(
                                    Platform.isWindows ? 'WINDOWS' : 'ANDROID',
                                  ),
                                  badge('离线工作台'),
                                ],
                              ),
                              const SizedBox(height: 20),
                              Text(
                                ['准备一次，统一评测', '让受试者专注于观看', '保留每一次判断'][page],
                                style: TextStyle(
                                  fontSize: wide ? 32 : 26,
                                  fontWeight: FontWeight.w700,
                                  color: ink,
                                  height: 1.3,
                                ),
                              ),
                              const SizedBox(height: 10),
                              const Text(
                                '固定题库 · 随机次序 · 强制二选一',
                                style: TextStyle(
                                  color: Color(0xff728078),
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 28),
                              if (failure != null)
                                section(
                                  '初始化失败',
                                  failure!,
                                  FilledButton(
                                    onPressed: initialize,
                                    child: const Text('重试'),
                                  ),
                                )
                              else if (repo != null)
                                ...switch (page) {
                                  0 => [preparePage()],
                                  1 => [sessionPage()],
                                  _ => [resultPage()],
                                },
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ParticipantDialog extends StatefulWidget {
  const ParticipantDialog({super.key});
  @override
  State<ParticipantDialog> createState() => _ParticipantDialogState();
}

class _ParticipantDialogState extends State<ParticipantDialog> {
  final id = TextEditingController();
  final age = TextEditingController();
  final condition = TextEditingController(
    text: Platform.isWindows ? 'PC · 实验室显示器' : 'Android · 移动显示设备',
  );
  final distance = TextEditingController(
    text: Platform.isWindows ? '60' : '35',
  );
  final device = TextEditingController();
  final notes = TextEditingController();
  bool vision = false, colorVision = false, independent = false, expert = false;
  String? error;
  @override
  void dispose() {
    for (final c in [id, age, condition, distance, device, notes]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('登记受试者与观看条件'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('使用匿名编号。同一题库、同一观看条件下，每位受试者只建立一条会话。'),
            const SizedBox(height: 18),
            TextField(
              key: const Key('participant-id'),
              controller: id,
              decoration: const InputDecoration(labelText: '受试者编号（必填）'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('participant-age'),
                    controller: age,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '年龄（宜 18～40 岁）',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: distance,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '观看距离 / cm'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: condition,
              decoration: const InputDecoration(labelText: '观看条件分组（用于统计）'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('device-model'),
              controller: device,
              decoration: const InputDecoration(labelText: '显示设备型号（必填）'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notes,
              decoration: const InputDecoration(labelText: '亮度、色彩、环境等设置记录'),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('视力正常（含矫正视力）'),
              value: vision,
              onChanged: (v) => setState(() => vision = v!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('色觉正常'),
              value: colorVision,
              onChanged: (v) => setState(() => colorVision = v!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('非本次评价组织者及算法开发相关人员'),
              value: independent,
              onChanged: (v) => setState(() => independent = v!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('属于相关领域专家'),
              value: expert,
              onChanged: (v) => setState(() => expert = v!),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('create-session'),
        onPressed: () {
          final years = int.tryParse(age.text),
              cm = double.tryParse(distance.text);
          if (id.text.trim().isEmpty ||
              id.text.trim().length > 80 ||
              condition.text.trim().isEmpty ||
              device.text.trim().isEmpty ||
              years == null ||
              years < 1 ||
              years > 120 ||
              cm == null ||
              !cm.isFinite ||
              cm <= 0 ||
              !vision ||
              !colorVision ||
              !independent) {
            setState(() => error = '请填写有效编号、年龄、观看距离、设备，并确认参与条件。');
            return;
          }
          Navigator.pop(context, {
            'participantId': id.text.trim(),
            'age': years,
            'condition': condition.text.trim(),
            'distanceCm': cm,
            'device': device.text.trim(),
            'displayNotes': notes.text.trim(),
            'expert': expert,
          });
        },
        child: const Text('确认并进入测试'),
      ),
    ],
  );
}
