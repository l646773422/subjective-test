import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'domain.dart';
import 'platform_bridge.dart';
import 'study_templates.dart';
part 'v2_repository.dart';

String uniqueId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${Random.secure().nextInt(0x7fffffff).toRadixString(36)}';
String fileHash(List<int> bytes) => sha256.convert(bytes).toString();

Future<(int, int)> imageDimensions(File file) async {
  final bytes = await file.readAsBytes();
  final info = img.findDecoderForData(bytes)?.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 40000000) {
    throw FormatException('图片无效或尺寸过大：${p.basename(file.path)}');
  }
  return (info.width, info.height);
}

Future<StudyCase> readPair({
  required String id,
  required String sequence,
  required String kind,
  required File gt,
  required File render,
  int frame = -1,
  int view = -1,
  int iteration = 0,
  String mapping = 'explicit',
}) async {
  final a = await imageDimensions(gt), b = await imageDimensions(render);
  if (a != b) throw FormatException('GT 与 render 尺寸不一致：${p.basename(gt.path)}');
  return StudyCase(
    id: id,
    sequence: sequence,
    kind: kind,
    gt: gt.absolute.path,
    render: render.absolute.path,
    gtHash: fileHash(await gt.readAsBytes()),
    renderHash: fileHash(await render.readAsBytes()),
    frame: frame,
    view: view,
    iteration: iteration,
    width: a.$1,
    height: a.$2,
    mapping: mapping,
  );
}

Directory? highestIteration(List<Directory> dirs) {
  final candidates = dirs
      .where((d) => RegExp(r'^ours_\d+$').hasMatch(p.basename(d.path)))
      .toList();
  candidates.sort(
    (a, b) => int.parse(
      p.basename(b.path).substring(5),
    ).compareTo(int.parse(p.basename(a.path).substring(5))),
  );
  return candidates.isEmpty ? null : candidates.first;
}

class SourceScan {
  final String root, sequence;
  final List<List<StudyCase>> frames;
  final List<String> issues;
  final bool isDemo;
  SourceScan(
    this.root,
    this.sequence,
    this.frames,
    this.issues, {
    this.isDemo = false,
  });
}

Future<SourceScan> scanSource(String root, String sequence) async {
  final frames = <List<StudyCase>>[], issues = <String>[];
  final views = protocolViews[sequence]!;
  final dirs = await Directory(root)
      .list(followLinks: false)
      .where(
        (f) =>
            f is Directory &&
            RegExp(r'^frame\d+$').hasMatch(p.basename(f.path)),
      )
      .cast<Directory>()
      .toList();
  dirs.sort((a, b) => a.path.compareTo(b.path));
  for (final frame in dirs) {
    try {
      final test = Directory(p.join(frame.path, 'test'));
      if (!await test.exists()) {
        issues.add('${p.basename(frame.path)}：尚无 test 图片');
        continue;
      }
      final iterations = await test
          .list(followLinks: false)
          .where((d) => d is Directory)
          .cast<Directory>()
          .toList();
      final selected = highestIteration(iterations);
      if (selected == null) throw const FormatException('没有 ours_数字 目录');
      final gt = Directory(p.join(selected.path, 'gt'));
      final renders = Directory(p.join(selected.path, 'renders'));
      if (!await gt.exists() || !await renders.exists()) {
        throw const FormatException('最大迭代目录缺少 gt 或 renders');
      }
      final files = await gt
          .list(followLinks: false)
          .where(
            (f) =>
                f is File &&
                [
                  '.png',
                  '.jpg',
                  '.jpeg',
                ].contains(p.extension(f.path).toLowerCase()),
          )
          .cast<File>()
          .toList();
      files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      if (files.length != views.length) {
        throw FormatException('需要 ${views.length} 个测试视点');
      }
      Map<String, int>? mapping;
      final mapFile = File(p.join(selected.path, 'view_ids.json'));
      if (await mapFile.exists()) {
        mapping = Map<String, int>.from(
          jsonDecode(await mapFile.readAsString()) as Map,
        );
      }
      final numeric = files
          .map((f) => int.tryParse(p.basenameWithoutExtension(f.path)))
          .toList();
      final explicitNames = numeric.toSet().containsAll(views);
      final pairs = <StudyCase>[];
      for (int i = 0; i < files.length; i++) {
        final name = p.basename(files[i].path);
        final r = File(p.join(renders.path, name));
        if (!await r.exists()) throw FormatException('render 缺图：$name');
        final view = mapping?[name] ?? (explicitNames ? numeric[i]! : views[i]);
        pairs.add(
          await readPair(
            id: '${sequence}_${p.basename(frame.path)}_v$view',
            sequence: sequence,
            kind: 'main',
            gt: files[i],
            render: r,
            frame: int.parse(p.basename(frame.path).substring(5)),
            view: view,
            iteration: int.parse(p.basename(selected.path).substring(5)),
            mapping: mapping != null || explicitNames
                ? 'explicit'
                : 'export-order',
          ),
        );
      }
      if (pairs.map((c) => c.view).toSet().length != views.length ||
          !pairs.map((c) => c.view).toSet().containsAll(views)) {
        throw const FormatException('视点映射与方案不一致');
      }
      final renderNames = await renders
          .list(followLinks: false)
          .where(
            (f) =>
                f is File &&
                [
                  '.png',
                  '.jpg',
                  '.jpeg',
                ].contains(p.extension(f.path).toLowerCase()),
          )
          .map((f) => p.basename(f.path))
          .toList();
      if (renderNames
          .toSet()
          .difference(files.map((f) => p.basename(f.path)).toSet())
          .isNotEmpty) {
        throw const FormatException('renders 中有未配对的额外图片');
      }
      frames.add(pairs);
    } catch (error) {
      issues.add('${p.basename(frame.path)}：$error');
    }
  }
  if (dirs.isEmpty) throw const FormatException('目录中未找到 frameXXXXXX');
  return SourceScan(
    root,
    sequence,
    frames,
    issues,
    isDemo: await File(p.join(root, 'DEMO_ONLY.txt')).exists(),
  );
}

class StudyRepository {
  final Directory root;
  final List<String> issues = [];
  Future<void> _pendingSave = Future.value();
  StudyRepository(this.root);
  Future<List<StudyDraft>> drafts() => readDrafts();
  Future<StudyDraft> saveDraft(Map<String, dynamic> source) =>
      writeDraft(source);
  static Future<StudyRepository> open() async {
    final root = Directory(
      p.join(await PlatformBridge.appDirectory(), 'studies-v1'),
    );
    await root.create(recursive: true);
    await Directory(p.join(root.path, 'experiments')).create();
    await Directory(p.join(root.path, 'sessions')).create();
    return StudyRepository(root);
  }

  Directory experimentDir(String id) =>
      Directory(p.join(root.path, 'experiments', id));
  File imageFile(Experiment e, String relative) {
    final normalized = p.posix.normalize(relative.replaceAll(r'\', '/'));
    if (p.posix.isAbsolute(normalized) ||
        normalized.startsWith('../') ||
        normalized == '..' ||
        normalized.contains(':')) {
      throw const FormatException('题库包含不安全的图片路径');
    }
    return File(
      p.joinAll([
        e.isV2 ? revisionDir(e.id).path : experimentDir(e.id).path,
        ...p.posix.split(normalized),
      ]),
    );
  }

  Future<List<Experiment>> experiments() async {
    final result = <Experiment>[];
    final dir = Directory(p.join(root.path, 'experiments'));
    await for (final child in dir.list(followLinks: false)) {
      if (child is! Directory) continue;
      final file = File(p.join(child.path, 'experiment.json'));
      if (await file.exists()) {
        try {
          result.add(
            Experiment.fromJson(jsonDecode(await file.readAsString())),
          );
        } catch (error) {
          noteIssue('${file.path}：$error');
        }
      }
    }
    result.addAll(await v2Experiments());
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<void> verify(Experiment e) async {
    if (e.isV2) {
      await verifyV2(e);
      return;
    }
    e.validate();
    for (final c in e.cases) {
      for (final pair in [(c.gt, c.gtHash), (c.render, c.renderHash)]) {
        final file = imageFile(e, pair.$1);
        if (!await file.exists() ||
            fileHash(await file.readAsBytes()) != pair.$2) {
          throw FormatException('题库图片缺失或已被修改：${pair.$1}');
        }
        if (await imageDimensions(file) != (c.width, c.height)) {
          throw FormatException('图片尺寸与题库记录不符：${pair.$1}');
        }
      }
    }
  }

  Future<Experiment> importZip(Uint8List bytes) async {
    if (bytes.length > 512 * 1024 * 1024) {
      throw const FormatException('测试包超过 512 MB，请只打包选中的图片');
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    int size = 0;
    final names = <String>{};
    for (final entry in archive) {
      final name = p.posix.normalize(entry.name.replaceAll(r'\', '/'));
      size += entry.size;
      if (entry.isSymbolicLink ||
          name.startsWith('../') ||
          name == '..' ||
          p.posix.isAbsolute(name) ||
          name.contains(':') ||
          !names.add(name) ||
          size > 1024 * 1024 * 1024) {
        throw const FormatException('测试包包含不安全、重复或过大的文件');
      }
    }
    final manifest = archive.findFile('experiment.json');
    if (manifest == null) throw const FormatException('测试包缺少 experiment.json');
    final e = Experiment.fromJson(jsonDecode(utf8.decode(manifest.content)));
    final dir = experimentDir(e.id);
    if (await dir.exists()) {
      await verify(e);
      return e;
    }
    final temp = Directory(p.join(root.path, 'import_${uniqueId()}'));
    await temp.create();
    try {
      final wanted = {
        'experiment.json',
        ...e.cases.expand((c) => [c.gt, c.render]),
      };
      for (final name in wanted) {
        final entry = archive.findFile(name);
        if (entry == null || !entry.isFile) {
          throw FormatException('测试包缺图：$name');
        }
        final normalized = p.posix.normalize(name.replaceAll(r'\', '/'));
        if (normalized != name ||
            name.startsWith('../') ||
            p.posix.isAbsolute(name) ||
            name.contains(':')) {
          throw const FormatException('题库图片路径无效');
        }
        final file = File(p.joinAll([temp.path, ...p.posix.split(name)]));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.content, flush: true);
      }
      // Validate the extracted data before publishing the directory.
      for (final c in e.cases) {
        for (final pair in [(c.gt, c.gtHash), (c.render, c.renderHash)]) {
          final file = File(p.joinAll([temp.path, ...p.posix.split(pair.$1)]));
          if (fileHash(await file.readAsBytes()) != pair.$2 ||
              await imageDimensions(file) != (c.width, c.height)) {
            throw const FormatException('测试包图片校验失败');
          }
        }
      }
      await temp.rename(dir.path);
      return e;
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }

  Future<Experiment> loadDemo() async {
    final data = await rootBundle.load('assets/demo.study.zip');
    return importZip(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  Future<Experiment> freezeSources({
    required String name,
    required int seed,
    required List<SourceScan> sources,
    required List<StudyCase> auxiliary,
    int promptMs = 2000,
    int imageMs = 3000,
  }) async {
    if (sources.map((s) => s.sequence).toSet().length != 4 ||
        sources.any((s) => s.frames.isEmpty)) {
      throw const FormatException('需要四个序列，每个至少有一个完整可用帧');
    }
    final random = StableRandom(seed);
    final selected = [
      for (final source in sources)
        ...source.frames[random.nextInt(source.frames.length)],
      ...auxiliary,
    ];
    final cases = <StudyCase>[];
    final archive = Archive();
    for (final c in selected) {
      final gtName = 'images/${c.id}_gt${p.extension(c.gt).toLowerCase()}';
      final renderName =
          'images/${c.id}_render${p.extension(c.render).toLowerCase()}';
      final gt = await File(c.gt).readAsBytes(),
          render = await File(c.render).readAsBytes();
      cases.add(
        StudyCase.fromJson({
          ...c.toJson(),
          'gt': gtName,
          'render': renderName,
          'gtHash': fileHash(gt),
          'renderHash': fileHash(render),
        }),
      );
      archive.addFile(ArchiveFile(gtName, gt.length, gt));
      archive.addFile(ArchiveFile(renderName, render.length, render));
    }
    final e = Experiment.freeze(
      name: name,
      demo: sources.any((s) => s.isDemo),
      seed: seed,
      cases: cases,
      promptMs: promptMs,
      imageMs: imageMs,
    );
    final json = utf8.encode(jsonEncode(e.toJson()));
    archive.addFile(ArchiveFile('experiment.json', json.length, json));
    return importZip(Uint8List.fromList(ZipEncoder().encode(archive)));
  }

  Future<Uint8List> exportPackage(Experiment e) async {
    if (e.isV2) return exportV2Package(e);
    await verify(e);
    final archive = Archive();
    final bytes = utf8.encode(jsonEncode(e.toJson()));
    archive.addFile(ArchiveFile('experiment.json', bytes.length, bytes));
    for (final name in e.cases.expand((c) => [c.gt, c.render]).toSet()) {
      final data = await imageFile(e, name).readAsBytes();
      archive.addFile(ArchiveFile(name, data.length, data));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Future<void> save(StudySession session) {
    final snapshot = jsonEncode(session.toJson());
    final id = session.id;
    final next = _pendingSave.catchError((Object error) {}).then((_) async {
      final file = File(p.join(root.path, 'sessions', '$id.json'));
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(snapshot, flush: true);
      await temp.rename(file.path);
    });
    _pendingSave = next;
    return next;
  }

  Future<List<StudySession>> sessions(Experiment e) async {
    final all = <StudySession>[];
    await for (final file in Directory(p.join(root.path, 'sessions')).list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      try {
        final body = jsonMap(jsonDecode(await file.readAsString()), 'session');
        if ((body['revisionId'] ?? body['experimentId']) != e.id) continue;
        final session = StudySession.fromJson(body);
        session.validate(e);
        all.add(session);
      } catch (error) {
        noteIssue('${file.path}：$error');
      }
    }
    all.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return all;
  }

  Future<int> mergeResults(Experiment e, Uint8List bytes) async {
    final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (e.isV2
        ? body['schema'] != 2 ||
              body['studyId'] != e.studyId ||
              body['revisionId'] != e.id ||
              digestJson(body['release'] ?? {}) != digestJson(e.release!) ||
              digestJson(body['definition'] ?? {}) !=
                  digestJson(e.definition!.toJson())
        : body['schema'] != 1 || body['experimentId'] != e.id) {
      throw const FormatException('结果属于其他题库，请先导入对应测试包');
    }
    final incoming = records(
      body['sessions'],
    ).map(StudySession.fromJson).toList();
    final existing = await sessions(e);
    final byId = {for (final s in existing) s.id: s};
    final byPerson = {
      for (final s in existing)
        jsonEncode([
          s.participantId,
          s.display[e.isV2 ? 'conditionId' : 'condition'],
        ]): s.id,
    };
    final added = <StudySession>[];
    for (final s in incoming) {
      s.validate(e);
      final old = byId[s.id];
      if (old != null) {
        if (digestJson(old.toJson()) != digestJson(s.toJson())) {
          throw FormatException('会话内容冲突：${s.participantId}');
        }
        continue;
      }
      final key = jsonEncode([
        s.participantId,
        s.display[e.isV2 ? 'conditionId' : 'condition'],
      ]);
      if (byPerson.containsKey(key)) {
        throw FormatException('同一观看条件下受试者编号重复：${s.participantId}');
      }
      byId[s.id] = s;
      byPerson[key] = s.id;
      added.add(s);
    }
    for (final s in added) {
      await save(s);
    }
    return added.length;
  }

  Uint8List resultsJson(Experiment e, List<StudySession> sessions) =>
      Uint8List.fromList(
        utf8.encode(
          const JsonEncoder.withIndent('  ').convert({
            'schema': e.isV2 ? 2 : 1,
            if (e.isV2) ...{
              'studyId': e.studyId,
              'revisionId': e.id,
              'release': e.release,
              'definition': e.definition!.toJson(),
            } else
              'experimentId': e.id,
            'isDemo': e.isDemo,
            'sessions': sessions.map((s) => s.toJson()).toList(),
            'report': buildReport(e, sessions),
          }),
        ),
      );
  Uint8List resultsCsv(Experiment e, List<StudySession> sessions) {
    if (e.isV2) return v2Csv(e, sessions);
    final rows = <List<Object?>>[
      [
        'experiment_id',
        'demo',
        'participant',
        'condition',
        'platform',
        'status',
        'trial',
        'kind',
        'sequence',
        'frame',
        'view',
        'iteration',
        'captured_first',
        'choice',
        'correct',
        'response_ms',
        'age',
        'expert',
        'interrupted',
      ],
    ];
    for (final s in sessions) {
      for (int i = 0; i < s.answers.length; i++) {
        final t = s.trials[i], c = e.caseById(t.caseId), a = s.answers[i];
        rows.add([
          e.id,
          e.isDemo,
          s.participantId,
          s.display['condition'],
          s.display['platform'],
          s.status(e),
          t.id,
          c.kind,
          c.sequence,
          c.frame,
          c.view,
          c.iteration,
          t.capturedFirst,
          a['choice'],
          a['choice'] == t.correctChoice,
          a['responseMs'],
          s.participant['age'],
          s.participant['expert'],
          s.events.any(
            (event) =>
                event['trialId'] == t.id && event['type'] == 'interruption',
          ),
        ]);
      }
    }
    String cell(Object? value) {
      var s = value?.toString() ?? '';
      if (RegExp(r'^[=+\-@\t\r]').hasMatch(s)) s = "'$s";
      return '"${s.replaceAll('"', '""')}"';
    }

    return Uint8List.fromList(
      utf8.encode(
        '\uFEFF${rows.map((r) => r.map(cell).join(',')).join('\r\n')}',
      ),
    );
  }
}
