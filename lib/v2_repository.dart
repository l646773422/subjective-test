part of 'repository.dart';

String uuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Map<String, dynamic> inspectStaticImage(Uint8List bytes) {
  final png =
      bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71;
  final jpeg =
      bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255;
  check(png || jpeg, '只支持静态 PNG、JPEG 图片');
  final info = img.findDecoderForData(bytes)?.startDecode(bytes);
  check(
    info != null &&
        info.width > 0 &&
        info.height > 0 &&
        info.width * info.height <= 40000000,
    '图片损坏或超过 4000 万像素',
  );
  final decoded = img.decodeImage(bytes);
  check(decoded != null && decoded.numFrames == 1, '图片无法解码或包含动画');
  return {
    'sha256': fileHash(bytes),
    'width': decoded!.width,
    'height': decoded.height,
    'mediaType': png ? 'image/png' : 'image/jpeg',
  };
}

class StudyDraft {
  final StudyDefinition definition;
  StudyDraft(this.definition);
  String get id => definition.studyId;
}

class StudyImport {
  final StudyDraft? draft;
  final Experiment? experiment;
  StudyImport({this.draft, this.experiment});
}

extension V2Repository on StudyRepository {
  Directory revisionDir(String id) =>
      Directory(p.join(root.path, 'revisions', id));
  Directory draftDir(String id) {
    check(validId(id), '草稿身份无效');
    return Directory(p.join(root.path, 'drafts', id));
  }

  void noteIssue(String issue) {
    if (!issues.contains(issue)) issues.add(issue);
  }

  Future<void> initializeV2() async {
    for (final folder in ['experiments', 'sessions', 'drafts', 'revisions']) {
      await Directory(p.join(root.path, folder)).create(recursive: true);
    }
  }

  Future<List<StudyDraft>> readDrafts() async {
    final dir = Directory(p.join(root.path, 'drafts'));
    if (!await dir.exists()) return [];
    final all = <StudyDraft>[];
    await for (final child in dir.list(followLinks: false)) {
      if (child is! Directory) continue;
      try {
        final d = StudyDefinition.fromJson(
          jsonMap(
            jsonDecode(
              await File(p.join(child.path, 'study.json')).readAsString(),
            ),
            'study',
          ),
          draft: true,
        );
        check(d.studyId == p.basename(child.path), '草稿目录与身份不符');
        all.add(StudyDraft(d));
      } catch (error) {
        noteIssue('${child.path}：$error');
      }
    }
    all.sort((a, b) => a.definition.name.compareTo(b.definition.name));
    return all;
  }

  Future<StudyDraft> writeDraft(Map<String, dynamic> source) async {
    final d = StudyDefinition.fromJson(source, draft: true);
    final snapshot = const JsonEncoder.withIndent('  ').convert(d.toJson());
    final next = _pendingSave.catchError((Object error) {}).then((_) async {
      final dir = draftDir(d.studyId);
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'study.json'));
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(snapshot, flush: true);
      await temp.rename(file.path);
    });
    _pendingSave = next;
    await next;
    return StudyDraft(d);
  }

  Future<StudyDraft> createDraft({bool photorealism = false}) =>
      saveDraft(newStudySource(uuid(), photorealism: photorealism));

  Future<File> sourceFile(Directory root, String relative) async {
    assetPath(relative);
    var path = root.path;
    for (final segment in relative.split('/')) {
      path = p.join(path, segment);
      check(
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.link,
        '素材不能使用符号链接：$relative',
      );
    }
    final file = File(path);
    check(await file.exists(), '素材缺失：$relative');
    final resolvedRoot = await root.resolveSymbolicLinks();
    check(
      p.isWithin(resolvedRoot, await file.resolveSymbolicLinks()),
      '素材超出实验目录：$relative',
    );
    return file;
  }

  Future<StudyDraft> importSourceDirectory(Directory source) async {
    final released = File(p.join(source.path, 'release.json'));
    if (await released.exists()) {
      throw const FormatException('发布目录请压缩为 ZIP 后导入，不能忽略 release.json');
    }
    final definitionFile = File(p.join(source.path, 'study.json'));
    check(
      await definitionFile.exists(),
      '所选目录缺少 study.json。请先将原始素材转换为标准实验目录，再导入。',
    );
    final d = StudyDefinition.fromJson(
      jsonMap(jsonDecode(await definitionFile.readAsString()), 'study'),
    );
    await initializeV2();
    final target = draftDir(d.studyId);
    check(!await target.exists(), '此实验已有草稿，请先编辑或复制现有草稿');
    final temp = await Directory(
      p.join(root.path, 'draft-import-${uuid()}'),
    ).create();
    try {
      final binding = await readMaterialBinding(source);
      final materials = binding == null
          ? source
          : Directory(binding['root'] as String);
      for (final relative in d.assets) {
        await sourceFile(materials, relative);
      }
      await bindMaterialRoot(temp, materials);
      if (binding?['assets'] != null) {
        await File(
          p.join(temp.path, 'catalog.json'),
        ).writeAsString(jsonEncode(binding!['assets']));
      }
      await File(p.join(temp.path, 'study.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(d.toJson()),
        flush: true,
      );
      await temp.rename(target.path);
      return StudyDraft(d);
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }

  Future<StudyImport> importStudyDirectory(Directory source) async {
    if (!await File(p.join(source.path, 'release.json')).exists()) {
      return StudyImport(draft: await importSourceDirectory(source));
    }
    final e = await readRelease(source);
    final archive = Archive();
    final external = e.release!['materials'] == 'external@1';
    for (final name in [
      'study.json',
      'release.json',
      if (!external) ...e.definition!.assets,
    ]) {
      final file = name == 'study.json' || name == 'release.json'
          ? File(p.join(source.path, name))
          : await sourceFile(source, name);
      final bytes = await file.readAsBytes();
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    final result = await importStudyZip(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );
    if (external) {
      final binding = await readMaterialBinding(source);
      if (binding != null) {
        await bindMaterialSource(revisionDir(result.experiment!.id), binding);
      }
    }
    return result;
  }

  Future<StudyDraft> forkDefinition(
    Experiment e, {
    bool keepStudyId = true,
    bool photorealism = false,
  }) async {
    await verify(e);
    final id = keepStudyId && e.isV2 ? e.studyId : uuid();
    check(!await draftDir(id).exists(), '该实验已有草稿，请编辑现有草稿');
    final source =
        e.definition?.toJson() ??
        newStudySource(id, photorealism: true, legacyPhotorealism: true);
    source['studyId'] = id;
    source['name'] = e.name;
    source['isDemo'] = e.isDemo;
    if (!e.isV2) {
      source['items'] = e.cases
          .map(
            (c) => {
              'id': c.id,
              'a': c.gt,
              'b': c.render,
              'role': c.kind,
              'answer': 'a',
              'group': c.sequence,
              'metadata': {
                'frame': c.frame,
                'view': c.view,
                'iteration': c.iteration,
                'mapping': c.mapping,
              },
            },
          )
          .toList();
      source['presentation'] = {
        'mode': 'sequential',
        'promptMs': e.promptMs,
        'imageMs': e.imageMs,
      };
      source['metadata'] = {
        'sourceExperimentId': e.id,
        'sourceFormat': 'schema-1',
      };
    }
    if (photorealism && e.isV2) {
      final template = newStudySource(id, photorealism: true);
      for (final key in [
        'question',
        'instructions',
        'schedule',
        'quality',
        'analysis',
        'participantFields',
        'sampling',
      ]) {
        if (template.containsKey(key)) source[key] = template[key];
      }
    }
    final d = StudyDefinition.fromJson(source, draft: true);
    final dir = await draftDir(id).create(recursive: true);
    final binding = e.isV2 ? bindingAt(revisionDir(e.id)) : null;
    if (binding != null) {
      await bindMaterialSource(dir, binding);
    } else {
      await bindMaterialRoot(
        dir,
        e.isV2 ? materialRoot(e) : experimentDir(e.id),
      );
    }
    if (e.isV2) {
      await File(
        p.join(dir.path, 'catalog.json'),
      ).writeAsString(jsonEncode(e.release!['assets']));
    }
    return saveDraft(d.toJson());
  }

  Future<StudyDraft> copyDraft(StudyDraft draft) async {
    final source = draft.definition.toJson();
    final id = uuid();
    source['studyId'] = id;
    source['name'] = '${source['name']}（副本）';
    final dir = await draftDir(id).create(recursive: true);
    final binding = bindingAt(draftDir(draft.id));
    if (binding != null) {
      await bindMaterialSource(dir, binding);
    } else {
      await bindMaterialRoot(dir, await draftMaterialRoot(draft));
    }
    final catalog = File(p.join(draftDir(draft.id).path, 'catalog.json'));
    if (await catalog.exists()) {
      await catalog.copy(p.join(dir.path, 'catalog.json'));
    }
    return saveDraft(source);
  }

  Future<String> addDraftAsset(
    StudyDraft draft,
    Uint8List bytes,
    String filename,
  ) async {
    check(
      !await materialBinding(draftDir(draft.id)).exists(),
      '此草稿使用独立素材目录，请在素材目录和数据描述中添加图片，再重新导入。',
    );
    final info = await compute(inspectStaticImage, bytes);
    final ext = info['mediaType'] == 'image/png' ? '.png' : '.jpg';
    final relative = 'assets/${info['sha256']}$ext';
    final file = File(
      p.joinAll([draftDir(draft.id).path, ...relative.split('/')]),
    );
    await file.parent.create(recursive: true);
    if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
    return relative;
  }

  Future<Experiment> publishDraft(StudyDraft draft) async {
    final d = StudyDefinition.fromJson(draft.definition.toJson());
    await initializeV2();
    final id = uuid();
    final temp = await Directory(p.join(root.path, 'publish-$id')).create();
    try {
      final assets = <Map<String, dynamic>>[];
      final names = d.assets.toList()..sort();
      final binding = bindingAt(draftDir(draft.id));
      final catalogFile = File(
        p.join(draftDir(d.studyId).path, 'catalog.json'),
      );
      final catalog = await catalogFile.exists()
          ? records(jsonDecode(await catalogFile.readAsString()))
          : <Map<String, dynamic>>[];
      final indexed = {for (final a in catalog) a['path'] as String: a};
      for (final relative in names) {
        final Map<String, dynamic> info =
            indexed[relative] ??
            await compute<Uint8List, Map<String, dynamic>>(
              inspectStaticImage,
              await materialBytes(draftDir(draft.id), relative),
            );
        assets.add({'path': relative, ...info});
      }
      if (binding != null) {
        await bindMaterialSource(temp, binding);
      } else {
        await bindMaterialRoot(temp, draftDir(draft.id));
      }
      final bytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(d.toJson()),
      );
      await File(
        p.join(temp.path, 'study.json'),
      ).writeAsBytes(bytes, flush: true);
      final release = {
        'schema': 2,
        'studyId': d.studyId,
        'revisionId': id,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'definition': {'path': 'study.json', 'sha256': fileHash(bytes)},
        'assets': assets,
        'materials': 'external@1',
        'implementations': {
          'method': d.methodVersion,
          'scheduler': d.schedulerVersion,
          'quality': 'basic-quality@1',
          'analysis': d.profile == null
              ? 'basic-analysis@1'
              : 'photorealism-analysis@${d.profile!['version']}',
        },
      };
      final e = Experiment.fromRelease(d.toJson(), release);
      buildSchedule(e, 0); // Check all constraints before publishing.
      await File(
        p.join(temp.path, 'release.json'),
      ).writeAsString(jsonEncode(release), flush: true);
      await temp.rename(revisionDir(id).path);
      return e;
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }

  Future<Experiment> readRelease(Directory dir) async {
    final release = jsonMap(
      jsonDecode(await File(p.join(dir.path, 'release.json')).readAsString()),
      'release',
    );
    final bytes = await File(p.join(dir.path, 'study.json')).readAsBytes();
    check(
      fileHash(bytes) == (release['definition'] as Map)['sha256'],
      '实验定义校验失败',
    );
    final source = jsonMap(jsonDecode(utf8.decode(bytes)), 'study');
    final e = Experiment.fromRelease(source, release);
    check(
      digestJson(source) == digestJson(e.definition!.toJson()),
      '发布定义必须展开全部默认值',
    );
    return e;
  }

  Future<List<Experiment>> v2Experiments() async {
    final dir = Directory(p.join(root.path, 'revisions'));
    if (!await dir.exists()) return [];
    final all = <Experiment>[];
    await for (final child in dir.list(followLinks: false)) {
      if (child is! Directory) continue;
      try {
        final e = await readRelease(child);
        check(e.id == p.basename(child.path), '发布目录与版本身份不符');
        all.add(e);
      } catch (error) {
        noteIssue('${child.path}：$error');
      }
    }
    return all;
  }

  Future<void> verifyV2(Experiment e) async {
    final dir = revisionDir(e.id);
    final stored = await readRelease(dir);
    check(digestJson(stored.toJson()) == digestJson(e.toJson()), '版本内容已变化');
    if (e.release!['materials'] == 'external@1') {
      final binding = bindingAt(dir);
      check(binding != null, '请先加载测试素材目录');
      final source = binding!['root'] as String;
      check(
        source.startsWith('content://') || await Directory(source).exists(),
        '测试素材目录不存在，请重新加载测试素材目录',
      );
      return;
    }
    for (final asset in records(e.release!['assets'])) {
      final file = await sourceFile(dir, asset['path'] as String);
      check(
        fileHash(await file.readAsBytes()) == asset['sha256'],
        '素材校验失败：${asset['path']}',
      );
    }
  }

  Archive safeArchive(Uint8List bytes) {
    check(bytes.length <= 512 * 1024 * 1024, 'ZIP 超过 512 MB');
    final archive = ZipDecoder().decodeBytes(bytes);
    int total = 0;
    final names = <String>{};
    for (final entry in archive) {
      final name = p.posix.normalize(entry.name.replaceAll('\\', '/'));
      total += entry.size;
      check(
        !entry.isSymbolicLink &&
            name != '..' &&
            !name.startsWith('../') &&
            !p.posix.isAbsolute(name) &&
            !name.contains(':') &&
            names.add(name.toLowerCase()) &&
            total <= 1024 * 1024 * 1024,
        'ZIP 包含不安全、重名或过大的内容',
      );
    }
    return archive;
  }

  Future<StudyImport> importStudyZip(Uint8List bytes) async {
    final archive = safeArchive(bytes);
    final study = archive.findFile('study.json');
    if (study == null) {
      check(archive.findFile('release.json') == null, '发布包缺少 study.json');
      return StudyImport(experiment: await importZip(bytes));
    }
    check(archive.findFile('experiment.json') == null, 'ZIP 同时包含两种实验定义');
    final d = StudyDefinition.fromJson(
      jsonMap(jsonDecode(utf8.decode(study.content)), 'study'),
    );
    await initializeV2();
    final temp = await Directory(
      p.join(root.path, 'v2-import-${uuid()}'),
    ).create();
    try {
      final releaseEntry = archive.findFile('release.json');
      final wanted = {
        'study.json',
        if (releaseEntry == null ||
            jsonDecode(utf8.decode(releaseEntry.content))['materials'] !=
                'external@1')
          ...d.assets,
        if (releaseEntry != null) 'release.json',
      };
      for (final relative in wanted) {
        final entry = archive.findFile(relative);
        check(entry != null && entry.isFile, 'ZIP 缺少 $relative');
        final output = File(p.joinAll([temp.path, ...relative.split('/')]));
        await output.parent.create(recursive: true);
        await output.writeAsBytes(entry!.content, flush: true);
      }
      if (releaseEntry == null) {
        // ZIP sources must keep their extracted materials after import.
        final retained = Directory(p.join(root.path, 'materials', uuid()));
        await retained.parent.create(recursive: true);
        await temp.rename(retained.path);
        return StudyImport(draft: await importSourceDirectory(retained));
      }
      final e = await readRelease(temp);
      for (final asset
          in e.release!['materials'] == 'external@1'
              ? <Map<String, dynamic>>[]
              : records(e.release!['assets'])) {
        final data = await (await sourceFile(
          temp,
          asset['path'] as String,
        )).readAsBytes();
        final actual = await compute(inspectStaticImage, data);
        for (final key in ['sha256', 'width', 'height', 'mediaType']) {
          check(actual[key] == asset[key], '发布资源校验失败：${asset['path']} / $key');
        }
      }
      final target = revisionDir(e.id);
      if (await target.exists()) {
        final existing = await readRelease(target);
        check(
          digestJson(existing.toJson()) == digestJson(e.toJson()),
          '相同版本 ID 对应不同内容',
        );
        if (e.release!['materials'] != 'external@1') await verify(existing);
      } else {
        await temp.rename(target.path);
      }
      return StudyImport(experiment: e);
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }

  Future<Uint8List> exportV2Package(Experiment e) async {
    final stored = await readRelease(revisionDir(e.id));
    check(digestJson(stored.toJson()) == digestJson(e.toJson()), '版本内容已变化');
    final archive = Archive();
    for (final name in [
      'study.json',
      'release.json',
      if (e.release!['materials'] != 'external@1') ...e.definition!.assets,
    ]) {
      final data = await File(
        p.joinAll([revisionDir(e.id).path, ...name.split('/')]),
      ).readAsBytes();
      archive.addFile(ArchiveFile(name, data.length, data));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Future<Experiment> loadGenericDemo() async {
    final existing = (await experiments())
        .where((e) => e.isV2 && e.studyId == 'simple-image-study' && e.isDemo)
        .firstOrNull;
    if (existing != null) return existing;
    final draft = (await drafts())
        .where((d) => d.id == 'simple-image-study')
        .firstOrNull;
    if (draft != null) {
      check(draft.definition.isDemo, '演示草稿已改为正式数据，请复制实验后再载入演示');
      return publishDraft(draft);
    }
    final data = await rootBundle.load('assets/generic.demo.zip');
    final outcome = await importStudyZip(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    return outcome.experiment ?? await publishDraft(outcome.draft!);
  }

  Uint8List v2Csv(Experiment e, List<StudySession> sessions) {
    final rows = <List<Object?>>[
      [
        'study_id',
        'revision_id',
        'demo',
        'session_id',
        'participant',
        'condition_id',
        'condition',
        'status',
        'trial_id',
        'item_id',
        'role',
        'group',
        'repetition',
        'order',
        'selected_alternative',
        'selected_position',
        'correct',
        'response_ms',
        'answered_at',
        'interrupted',
        if (e.definition!.sampling != null) ...[
          'frame',
          'view',
          'sampling_seed',
          'a_sha256',
          'b_sha256',
        ],
        if (e.definition!.patch != null) ...[
          'patch_seed',
          'patch_x',
          'patch_y',
          'patch_width',
          'patch_height',
        ],
        if (e.definition!.stereo != null) ...[
          'stereo_layout',
          'stereo_input',
          'ui_disparity',
          'a_right_sha256',
          'b_right_sha256',
        ],
      ],
    ];
    for (final s in sessions) {
      for (int i = 0; i < s.answers.length; i++) {
        final t = s.trials[i], c = e.caseById(t.caseId), a = s.answers[i];
        rows.add([
          e.studyId,
          e.id,
          e.isDemo,
          s.id,
          s.participantId,
          s.display['conditionId'],
          s.display['condition'],
          s.status(e),
          t.id,
          c.id,
          c.kind,
          c.sequence,
          t.repetition,
          t.order.join('/'),
          a['selectedAlternative'],
          a['selectedPosition'],
          c.answer == null ? null : a['selectedAlternative'] == c.answer,
          a['responseMs'],
          a['answeredAt'],
          s.events.any(
            (ev) => ev['trialId'] == t.id && ev['type'] == 'interruption',
          ),
          if (e.definition!.sampling != null) ...[
            c.frame,
            c.view,
            s.seed,
            s.materialHashes[c.gt],
            s.materialHashes[c.render],
          ],
          if (e.definition!.patch != null) ...[
            s.seed,
            t.patch!['x'],
            t.patch!['y'],
            t.patch!['width'],
            t.patch!['height'],
          ],
          if (e.definition!.stereo != null) ...[
            e.definition!.stereo!['layout'],
            e.definition!.stereo!['input'] ?? 'separate',
            e.definition!.stereo!['uiDisparity'],
            s.materialHashes[e.definition!.packedStereo ? c.gt : c.aRight],
            s.materialHashes[e.definition!.packedStereo ? c.render : c.bRight],
          ],
        ]);
      }
    }
    String cell(Object? value) {
      var text = value?.toString() ?? '';
      if (RegExp(r'^[=+\-@\t\r]').hasMatch(text)) text = "'$text";
      return '"${text.replaceAll('"', '""')}"';
    }

    return Uint8List.fromList(
      utf8.encode(
        '\uFEFF${rows.map((r) => r.map(cell).join(',')).join('\r\n')}',
      ),
    );
  }
}
