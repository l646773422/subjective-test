import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'domain.dart';
import 'repository.dart';
import 'presentation.dart';
import 'platform_bridge.dart';
import 'legacy_participant.dart';
import 'draft_editor.dart';
import 'participant_dialog.dart';

const workbenchInk = Color(0xff173e3a);

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
  List<StudyDraft> drafts = [];
  List<StudySession> sessions = [];
  Experiment? active;
  StudyDraft? selectedDraft;
  String? selectedStudy, failure;
  int page = 0;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    await perform(() async {
      repo = widget.repository ?? await StudyRepository.open();
      await reload();
    });
  }

  Future<void> reload({Experiment? select, StudyDraft? draft}) async {
    repo!.issues.clear();
    experiments = await repo!.experiments();
    drafts = await repo!.drafts();
    selectedStudy =
        draft?.id ??
        select?.studyId ??
        selectedStudy ??
        (drafts.isNotEmpty
            ? drafts.first.id
            : experiments.firstOrNull?.studyId);
    selectedDraft = drafts.where((d) => d.id == selectedStudy).firstOrNull;
    final versions = experiments
        .where((e) => e.studyId == selectedStudy)
        .toList();
    active =
        versions.where((e) => e.id == (select?.id ?? active?.id)).firstOrNull ??
        versions.firstOrNull;
    sessions = active == null ? [] : await repo!.sessions(active!);
  }

  Future<void> perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      failure = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => failure = error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> saveBytes(Uint8List bytes, String name) async {
    final path = await FilePicker.platform.saveFile(
      fileName: name,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: [name.split('.').last],
    );
    if (path == null) return;
    if (Platform.isWindows) await File(path).writeAsBytes(bytes, flush: true);
    message('已导出 $name');
  }

  Future<Uint8List?> pickBytes(String extension) async {
    final files = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [extension],
      withData: true,
    );
    return files?.files.single.bytes;
  }

  Future<void> create(bool photo) => perform(() async {
    final draft = await repo!.createDraft(photorealism: photo);
    await reload(draft: draft);
  });
  Future<void> importZip() => perform(() async {
    final bytes = await pickBytes('zip');
    if (bytes == null) return;
    final outcome = await repo!.importStudyZip(bytes);
    await reload(select: outcome.experiment, draft: outcome.draft);
    message(outcome.draft != null ? '已导入草稿，请预览并发布' : '发布版本已验证，可开始采集');
  });
  Future<void> importFolder() => perform(() async {
    final path = Platform.isAndroid
        ? await PlatformBridge.pickDirectory()
        : await FilePicker.platform.getDirectoryPath(
            dialogTitle: '选择包含 study.json 的实验目录',
          );
    if (path == null) return;
    final outcome = await repo!.importStudyDirectory(Directory(path));
    await reload(draft: outcome.draft, select: outcome.experiment);
  });
  Future<void> loadRenderMaterials() => perform(() async {
    check(Platform.isWindows, '本轮先在 Windows 验证素材目录流程，Android 端将在流程敲定后接入。');
    StudyDraft draft;
    if (Platform.isAndroid) {
      final tree = await PlatformBridge.pickMaterialDirectory();
      if (tree == null) return;
      draft = await repo!.createRenderPool(tree);
    } else {
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择包含四个 *_renders 序列的目录',
      );
      if (path == null) return;
      draft = await repo!.loadRenderDirectory(Directory(path));
    }
    final existing = experiments
        .where(
          (e) =>
              e.studyId == draft.id &&
              e.isV2 &&
              digestJson(e.definition!.toJson()) ==
                  digestJson(draft.definition.toJson()),
        )
        .firstOrNull;
    final experiment = existing ?? await repo!.publishDraft(draft);
    if (existing != null) {
      await repo!.bindMaterialSource(
        repo!.revisionDir(existing.id),
        repo!.bindingAt(repo!.draftDir(draft.id))!,
      );
    }
    await reload(select: experiment);
    message('完整素材目录已加载，每位参与者独立随机抽帧和视点。当前为流程演练。');
  });
  Future<void> reloadMaterials() => perform(() async {
    if (Platform.isAndroid) {
      final tree = await PlatformBridge.pickMaterialDirectory();
      if (tree != null) await repo!.loadMaterialTree(active!, tree);
    } else {
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '加载此实验对应的测试素材目录',
      );
      if (path != null) {
        await repo!.loadMaterialDirectory(active!, Directory(path));
      }
    }
    message('测试素材目录已加载');
  });
  Future<void> editDraft() async {
    if (selectedDraft == null || busy) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => DraftEditor(repository: repo!, draft: selectedDraft!),
      ),
    );
    if (mounted) await perform(() => reload());
  }

  Future<void> launch(StudySession session) async {
    await perform(() async {
      await repo!.verify(active!);
      await repo!.verifySelection(
        active!,
        session.trials,
        hashes: session.materialHashes,
      );
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
      await reload();
      page = 1;
    });
  }

  Future<void> newSession() async {
    if (active == null || busy) return;
    final e = active!;
    if (e.release?['materials'] == 'external@1' &&
        repo!.bindingAt(repo!.revisionDir(e.id)) == null) {
      message('请先点击“加载 / 更换测试素材目录”，再登记参与者');
      return;
    }
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => e.isV2
          ? GenericParticipantDialog(definition: e.definition!)
          : const ParticipantDialog(),
    );
    if (data == null || !mounted) return;
    StudySession? created;
    await perform(() async {
      final id = data['participantId'] as String;
      final conditionKey = e.isV2 ? 'conditionId' : 'condition';
      check(
        !sessions.any(
          (s) =>
              s.participantId == id &&
              s.display[conditionKey] == data[conditionKey],
        ),
        '此参与者在该观看条件下已有会话，请恢复已有会话',
      );
      if (e.isV2) {
        check(
          !sessions.any(
            (s) =>
                s.display['conditionId'] == data['conditionId'] &&
                s.display['condition'] != data['condition'],
          ),
          '相同观看条件编号已使用其他名称，请保持名称一致',
        );
      }
      final view = View.of(context), seed = Random.secure().nextInt(0x7fffffff);
      created = StudySession(
        id: e.isV2 ? uuid() : uniqueId(),
        experimentId: e.id,
        participantId: id,
        startedAt: DateTime.now().toUtc().toIso8601String(),
        seed: seed,
        schema: e.isV2 ? 2 : 1,
        studyId: e.isV2 ? e.studyId : null,
        schedulerVersion: e.isV2
            ? e.release!['implementations']['scheduler'] as String
            : null,
        participant: e.isV2
            ? jsonMap(data['participant'], 'participant')
            : {
                'age': data['age'],
                'expert': data['expert'],
                'normalVision': true,
                'normalColorVision': true,
                'organizerOrDeveloper': false,
              },
        display: {
          'condition': data['condition'],
          if (e.isV2) 'conditionId': data['conditionId'],
          'device': data['device'],
          'distanceCm': data['distanceCm'],
          'displayNotes': data['displayNotes'],
          'platform': Platform.operatingSystem,
          'osVersion': Platform.operatingSystemVersion,
          'screenWidthPx': view.physicalSize.width,
          'screenHeightPx': view.physicalSize.height,
          'dpr': view.devicePixelRatio,
        },
        trials: buildSchedule(e, seed),
      );
      await repo!.pinSelection(e, created!);
      created!.validate(e);
      await repo!.save(created!);
      await reload();
    });
    if (created != null && mounted && failure == null) await launch(created!);
  }

  Widget card(String title, String subtitle, Widget content) => Card(
    margin: const EdgeInsets.only(bottom: 20),
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              color: workbenchInk,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xff67796e), height: 1.6),
          ),
          const SizedBox(height: 20),
          content,
        ],
      ),
    ),
  );
  Widget badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: const Color(0xffeaf0e9),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(color: workbenchInk, fontSize: 12),
    ),
  );
  Widget button(
    String text,
    IconData icon,
    VoidCallback action, {
    Key? key,
    bool primary = false,
  }) => primary
      ? FilledButton.icon(
          key: key,
          onPressed: busy ? null : action,
          icon: Icon(icon),
          label: Text(text),
        )
      : OutlinedButton.icon(
          key: key,
          onPressed: busy ? null : action,
          icon: Icon(icon),
          label: Text(text),
        );

  Widget library() {
    final ids = {
      ...drafts.map((d) => d.id),
      ...experiments.map((e) => e.studyId),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        card(
          '建立你的实验',
          '以同一份实验描述完成准备、发布与采集。当前支持图片顺序呈现的 2AFC。',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  button(
                    '新建通用 2AFC',
                    Icons.add,
                    () => create(false),
                    key: const Key('create-study'),
                    primary: true,
                  ),
                  button(
                    '真实感评测模板',
                    Icons.filter_frames_outlined,
                    () => create(true),
                    key: const Key('create-photo'),
                  ),
                  button('导入 ZIP', Icons.folder_zip_outlined, importZip),
                  button('导入标准目录', Icons.folder_open_outlined, importFolder),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  TextButton.icon(
                    key: const Key('load-render-materials'),
                    onPressed: busy || !Platform.isWindows
                        ? null
                        : loadRenderMaterials,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('加载真实感素材目录'),
                  ),
                  TextButton.icon(
                    key: const Key('load-demo'),
                    onPressed: busy
                        ? null
                        : () => perform(() async {
                            final e = await repo!.loadGenericDemo();
                            await reload(select: e);
                          }),
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('体验通用演示'),
                  ),
                  TextButton.icon(
                    key: const Key('load-legacy-demo'),
                    onPressed: busy
                        ? null
                        : () => perform(() async {
                            final e = await repo!.loadDemo();
                            await reload(select: e);
                          }),
                    icon: const Icon(Icons.history),
                    label: const Text('载入旧版真实感演示'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (ids.isNotEmpty)
          card(
            '实验库',
            '${ids.length} 个实验 · 草稿与发布版本分别保留',
            Column(
              children: [
                for (final id in ids)
                  Builder(
                    builder: (_) {
                      final draft = drafts.where((d) => d.id == id).firstOrNull;
                      final versions = experiments
                          .where((e) => e.studyId == id)
                          .toList();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: Colors.transparent,
                          child: ListTile(
                            selected: selectedStudy == id,
                            selectedTileColor: const Color(0xffeaf0e9),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            leading: Icon(
                              draft != null
                                  ? Icons.edit_note
                                  : Icons.inventory_2_outlined,
                            ),
                            title: Text(
                              draft?.definition.name ?? versions.first.name,
                            ),
                            subtitle: Text(
                              '${draft != null ? '有草稿 · ' : ''}${versions.length} 个发布版本${versions.any((e) => !e.isV2) ? ' · 含旧版数据' : ''}',
                            ),
                            trailing: selectedStudy == id
                                ? const Icon(
                                    Icons.check_circle,
                                    color: workbenchInk,
                                  )
                                : const Icon(Icons.chevron_right),
                            onTap: busy
                                ? null
                                : () => perform(() async {
                                    selectedStudy = id;
                                    active = null;
                                    await reload();
                                  }),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        if (selectedDraft != null) draftSummary(),
        if (active != null) releaseSummary(),
      ],
    );
  }

  Widget draftSummary() {
    final d = selectedDraft!.definition;
    final profile = d.profile != null;
    return card(
      '实验草稿',
      d.name,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(d.question, style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              badge(profile ? '真实感评测模板' : '通用 2AFC'),
              badge(
                d.sampling == null
                    ? '${d.items.length} 道素材题'
                    : '素材池 ${d.items.length} 对 · 每人 ${d.selectedMainCount} 对',
              ),
              badge('${d.trialCount} 次作答'),
              badge('尚未发布'),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              button(
                '编辑与预览',
                Icons.tune,
                editDraft,
                key: const Key('edit-draft'),
                primary: true,
              ),
              button(
                '发布版本',
                Icons.lock_outline,
                () => perform(() async {
                  final e = await repo!.publishDraft(selectedDraft!);
                  await reload(select: e);
                  message('新版本已发布，素材与配置已冻结');
                }),
                key: const Key('publish-draft'),
              ),
              button(
                '复制实验',
                Icons.copy_outlined,
                () => perform(() async {
                  await reload(draft: await repo!.copyDraft(selectedDraft!));
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget get versionSelector {
    final versions = experiments
        .where((e) => e.studyId == selectedStudy)
        .toList();
    return DropdownButtonFormField<String>(
      key: ValueKey(active?.id),
      initialValue: active?.id,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '当前发布版本'),
      items: versions
          .map(
            (e) => DropdownMenuItem(
              value: e.id,
              child: Text(
                '${(DateTime.tryParse(e.createdAt)?.toUtc().toIso8601String() ?? '0000-00-00T00:00').substring(0, 16).replaceFirst('T', ' ')} UTC · ${e.isV2 ? e.id.substring(0, 8) : '旧版'}${e.isDemo ? ' · 演示' : ''}',
              ),
            ),
          )
          .toList(),
      onChanged: busy
          ? null
          : (id) => perform(() async {
              await reload(select: versions.firstWhere((e) => e.id == id));
            }),
    );
  }

  Widget releaseSummary() {
    final e = active!, count = buildSchedule(e, 0).length;
    return card(
      '已发布 · 可采集',
      e.name,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          versionSelector,
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              badge(e.isV2 ? '标准 v2' : '旧版兼容'),
              badge(
                e.definition?.sampling == null
                    ? '${e.cases.where((c) => c.kind == 'main').length} 道正式题 / $count 次作答'
                    : '素材池 ${e.cases.where((c) => c.kind == 'main').length} 对 · 每人随机 ${e.definition!.selectedMainCount} 对 / $count 次作答',
              ),
              badge(e.isDemo ? '演示数据' : '正式数据'),
              if (e.definition?.sampling != null) badge('每人重新抽帧与视点'),
            ],
          ),
          const SizedBox(height: 12),
          Text(e.question),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              button(
                '进入采集',
                Icons.person_add_alt_1,
                () => setState(() => page = 1),
                key: const Key('go-sessions'),
                primary: true,
              ),
              button(
                '导出发布包',
                Icons.ios_share,
                () => perform(() async {
                  await saveBytes(
                    await repo!.exportPackage(e),
                    'study-${e.id.substring(0, 8)}.zip',
                  );
                }),
              ),
              if (e.isV2 && Platform.isWindows)
                button('加载 / 更换测试素材目录', Icons.folder_open, reloadMaterials),
              if (e.release?['materials'] == 'external@1')
                const Text('实验包仅保存规则和清单，原图从独立素材目录读取。'),
              if (selectedDraft == null || !e.isV2)
                button(
                  e.isV2 ? '基于此版本编辑' : '复制为 v2 真实感草稿',
                  Icons.edit_outlined,
                  () => perform(() async {
                    await reload(draft: await repo!.forkDefinition(e));
                  }),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget collection() {
    if (active == null) {
      return card(
        '尚未发布实验',
        '先在实验页面准备并发布一个版本，再开始采集。',
        button('前往实验', Icons.arrow_back, () => setState(() => page = 0)),
      );
    }
    return Column(
      children: [
        card(
          '采集会话',
          active!.definition?.sampling == null
              ? '每位参与者使用独立排程，答案逐题保存，中断后可以恢复。'
              : '每位参与者重新随机抽帧和视点。答案与抽样逐题保存，恢复时沿用本次题目。',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              versionSelector,
              const SizedBox(height: 18),
              button(
                '新建参与者会话',
                Icons.person_add_alt_1,
                newSession,
                key: const Key('new-session'),
                primary: true,
              ),
            ],
          ),
        ),
        card(
          '本版本的会话记录',
          '${sessions.length} 条记录 · ${sessions.where((s) => s.complete).length} 条完成',
          sessions.isEmpty
              ? const Text('还没有采集记录。')
              : Column(
                  children: [
                    for (final s in sessions)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          s.complete
                              ? Icons.task_alt
                              : Icons.pause_circle_outline,
                          color: workbenchInk,
                        ),
                        title: Text(s.participantId),
                        subtitle: Text(
                          '${s.display['condition']} · 已答 ${s.answers.length}/${s.trials.length} · ${s.status(active!)}',
                        ),
                        trailing: s.complete
                            ? badge(s.status(active!))
                            : OutlinedButton(
                                onPressed: busy ? null : () => launch(s),
                                child: const Text('恢复'),
                              ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget results() {
    if (active == null) {
      return card('尚无结果', '选择一个发布版本，采集后在这里查看结果。', const SizedBox.shrink());
    }
    final e = active!,
        report = buildReport(e, sessions),
        metric = e.definition?.analysis['metric'] ?? 'accuracy';
    return Column(
      children: [
        card(
          '结果与原始数据',
          metric == 'selection_rate'
              ? '逐题显示素材 a 的选择比例，练习和控制题不计入。'
              : '显示正式题准确率，练习和控制题不计入。',
          Column(
            children: [
              versionSelector,
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  button(
                    '导出逐题 CSV',
                    Icons.table_view_outlined,
                    () => perform(() async {
                      await saveBytes(
                        repo!.resultsCsv(e, sessions),
                        'study-results.csv',
                      );
                    }),
                  ),
                  button(
                    '导出完整 JSON',
                    Icons.save_alt,
                    () => perform(() async {
                      await saveBytes(
                        repo!.resultsJson(e, sessions),
                        'study-results.json',
                      );
                    }),
                  ),
                  button(
                    '合并结果 JSON',
                    Icons.merge_outlined,
                    () => perform(() async {
                      final bytes = await pickBytes('json');
                      if (bytes == null) return;
                      final count = await repo!.mergeResults(e, bytes);
                      await reload();
                      message('已合并 $count 条新会话');
                    }),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (sessions.isEmpty)
          card('等待第一份记录', '本版本还没有采集结果。', const SizedBox.shrink()),
        for (final group in records(report['conditions']))
          card(
            group['condition'] as String,
            group['status'] as String,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    badge('有效参与者 ${group['validObservers']}'),
                    badge('会话 ${group['sessions']}'),
                    if (group['controlCheck'] != null)
                      badge(group['controlCheck'] as String),
                  ],
                ),
                const SizedBox(height: 20),
                for (final row in records(
                  metric == 'accuracy' ? group['sequences'] : group['images'],
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                (metric == 'accuracy'
                                        ? row['sequence']
                                        : row['caseId'])
                                    .toString(),
                              ),
                            ),
                            Text(
                              row['rate'] == null
                                  ? '—'
                                  : '${((row['rate'] as num) * 100).toStringAsFixed(1)}%',
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        LinearProgressIndicator(
                          value: (row['rate'] as num?)?.toDouble() ?? 0,
                          minHeight: 7,
                          borderRadius: BorderRadius.circular(8),
                          color: workbenchInk,
                          backgroundColor: const Color(0xffeaf0e9),
                        ),
                      ],
                    ),
                  ),
                if (e.isV2 && e.definition!.profile != null)
                  Text(
                    e.definition!.profile!['version'] == 2
                        ? '真实感模板 · 每个序列至少 ${e.definition!.profile!['minObserversPerSequence']} 位有效参与者；每人独立抽样。'
                        : '真实感模板 · 每题至少 ${e.definition!.profile!['minObserversPerItem']} 位有效参与者；专家比例与覆盖按发布配置检查。',
                  ),
                if (e.isV2 && e.definition!.profile == null)
                  const Text('基础指标为描述性统计，不自动给出通过或真实感结论。'),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 920;
    const destinations = [
      (Icons.layers_outlined, '实验'),
      (Icons.people_outline, '采集会话'),
      (Icons.bar_chart_outlined, '结果汇总'),
    ];
    return Scaffold(
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (i) => setState(() => page = i),
              destinations: [
                for (final (icon, label) in destinations)
                  NavigationDestination(icon: Icon(icon), label: label),
              ],
            ),
      body: SafeArea(
        child: Row(
          children: [
            if (wide)
              Container(
                width: 226,
                color: const Color(0xffeaf0e9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(26, 36, 24, 36),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.filter_frames_outlined,
                            color: workbenchInk,
                            size: 34,
                          ),
                          SizedBox(height: 16),
                          Text(
                            '主观评价平台',
                            style: TextStyle(
                              fontSize: 23,
                              fontWeight: FontWeight.w700,
                              color: workbenchInk,
                            ),
                          ),
                          SizedBox(height: 7),
                          Text(
                            'SUBJECTIVE STUDY',
                            style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 1.7,
                              color: Color(0xff627368),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final (i, entry) in destinations.indexed)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: ListTile(
                            selected: page == i,
                            selectedTileColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            leading: Icon(entry.$1, color: workbenchInk),
                            title: Text(entry.$2),
                            onTap: () => setState(() => page = i),
                          ),
                        ),
                      ),
                    const Spacer(),
                    const Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                        '离线采集 · 本机保存\n2AFC / 0.2.0',
                        style: TextStyle(
                          height: 1.9,
                          color: Color(0xff738477),
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
                                  badge('2AFC · 顺序呈现'),
                                  badge('离线工作台'),
                                  badge(
                                    Platform.isWindows ? 'WINDOWS' : 'ANDROID',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 22),
                              Text(
                                [
                                  '从一个问题，建立一次实验',
                                  '让参与者专注于判断',
                                  '让每一次判断可追溯',
                                ][page],
                                style: TextStyle(
                                  fontSize: wide ? 32 : 26,
                                  fontWeight: FontWeight.w700,
                                  height: 1.3,
                                  color: workbenchInk,
                                ),
                              ),
                              const SizedBox(height: 10),
                              const Text(
                                '准备素材  /  预览发布  /  采集与分析',
                                style: TextStyle(color: Color(0xff728078)),
                              ),
                              const SizedBox(height: 28),
                              if (failure != null)
                                card(
                                  '操作未完成',
                                  failure!,
                                  TextButton(
                                    onPressed: () =>
                                        setState(() => failure = null),
                                    child: const Text('关闭提示'),
                                  ),
                                ),
                              if (repo != null && repo!.issues.isNotEmpty)
                                card(
                                  '部分本地记录无法读取',
                                  '其他实验可以继续使用。异常文件保留原位。',
                                  SelectableText(
                                    repo!.issues.join('\n'),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              if (repo != null)
                                switch (page) {
                                  0 => library(),
                                  1 => collection(),
                                  _ => results(),
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
