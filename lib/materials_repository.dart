part of 'repository.dart';

// Packages carry rules and relative paths; filesystem/SAF bindings stay local.
extension MaterialsRepository on StudyRepository {
  File materialBinding(Directory dir) =>
      File(p.join(dir.path, 'materials.json'));
  Map<String, dynamic>? bindingAt(Directory dir) {
    final file = materialBinding(dir);
    if (!file.existsSync()) return null;
    final value = jsonMap(jsonDecode(file.readAsStringSync()), 'materials');
    final root = value['root'];
    check(
      value['schema'] == 1 &&
          root is String &&
          (p.isAbsolute(root) || root.startsWith('content://')),
      '素材目录配置无效，请重新加载测试素材目录',
    );
    return value;
  }

  Future<Map<String, dynamic>?> readMaterialBinding(Directory dir) async =>
      bindingAt(dir);
  Future<void> bindMaterialSource(
    Directory dir,
    Map<String, dynamic> source,
  ) async {
    await dir.create(recursive: true);
    await materialBinding(
      dir,
    ).writeAsString(jsonEncode({'schema': 1, ...source}), flush: true);
  }

  Future<void> bindMaterialRoot(Directory dir, Directory materials) async {
    check(await materials.exists(), '测试素材目录不存在：$materials');
    await bindMaterialSource(dir, {
      'root': await materials.resolveSymbolicLinks(),
    });
  }

  Directory materialRoot(Experiment e) {
    final dir = revisionDir(e.id), binding = bindingAt(dir);
    check(
      binding != null || e.release?['materials'] != 'external@1',
      '请先加载测试素材目录',
    );
    final root = binding?['root'] as String? ?? dir.path;
    check(!root.startsWith('content://'), 'Android 素材通过目录授权读取');
    return Directory(root);
  }

  Future<Directory> draftMaterialRoot(StudyDraft draft) async {
    final dir = draftDir(draft.id), binding = bindingAt(draftDir(draft.id));
    final root = binding?['root'] as String? ?? dir.path;
    check(!root.startsWith('content://'), 'Android 素材通过目录授权读取');
    return Directory(root);
  }

  Future<void> loadMaterialDirectory(Experiment e, Directory directory) async {
    check(e.isV2, '旧版题库请继续使用原来的素材包');
    for (final relative in e.definition!.assets) {
      await sourceFile(directory, relative);
    }
    await bindMaterialRoot(revisionDir(e.id), directory);
  }

  Future<void> loadMaterialTree(Experiment e, Map<String, dynamic> tree) async {
    final documents = {
      for (final entry in records(tree['entries']))
        entry['path'] as String: entry['uri'],
    };
    check(e.definition!.assets.every(documents.containsKey), '目录缺少实验引用的素材');
    await bindMaterialSource(revisionDir(e.id), {
      'root': tree['root'],
      'documents': documents,
    });
  }

  Future<Uint8List> materialBytes(Directory dir, String relative) async {
    assetPath(relative);
    final binding = bindingAt(dir),
        root = binding?['root'] as String? ?? dir.path;
    if (root.startsWith('content://')) {
      final uri = (binding!['documents'] as Map)[relative];
      check(uri is String, '目录授权缺少素材：$relative，请重新加载素材目录');
      return PlatformBridge.readMaterial(uri as String);
    }
    return (await sourceFile(Directory(root), relative)).readAsBytes();
  }

  Future<Uint8List> verifiedImageData(
    Experiment e,
    String relative, {
    String? fingerprint,
  }) async {
    if (!e.isV2) return imageFile(e, relative).readAsBytes();
    final bytes = await materialBytes(revisionDir(e.id), relative);
    final asset = records(
      e.release!['assets'],
    ).firstWhere((a) => a['path'] == relative);
    final expected = asset['sha256'] ?? fingerprint;
    check(
      expected is String && fileHash(bytes) == expected,
      '素材已变化或损坏：$relative，请重新加载正确的素材目录。',
    );
    return bytes;
  }

  Future<void> pinSelection(Experiment e, StudySession session) async {
    if (!e.isV2) return;
    final assets = {
      for (final a in records(e.release!['assets'])) a['path'] as String: a,
    };
    final paths = <String>{};
    for (final t in session.trials) {
      final c = e.caseById(t.caseId);
      paths.addAll([c.gt, c.render]);
    }
    for (final path in paths) {
      final a = assets[path]!,
          bytes = await materialBytes(revisionDir(e.id), path);
      check(
        a['bytes'] == null || a['bytes'] == 0 || a['bytes'] == bytes.length,
        '抽中的素材文件大小已变化：$path',
      );
      final actual = await compute(inspectStaticImage, bytes);
      check(
        (a['sha256'] == null || a['sha256'] == actual['sha256']) &&
            a['width'] == actual['width'] &&
            a['height'] == actual['height'],
        '抽中的素材已变化或尺寸不符：$path',
      );
      session.materialHashes[path] = actual['sha256'] as String;
    }
    for (final previous in await sessions(e)) {
      for (final entry in session.materialHashes.entries) {
        final known = previous.materialHashes[entry.key];
        check(
          known == null || known == entry.value,
          '素材相较已有会话发生变化：${entry.key}，请建立新的素材版本。',
        );
      }
    }
  }

  Future<void> verifySelection(
    Experiment e,
    List<Trial> trials, {
    Map<String, String> hashes = const {},
  }) async {
    if (!e.isV2) return;
    final names = <String>{};
    for (final trial in trials) {
      final c = e.caseById(trial.caseId);
      names.addAll([c.gt, c.render]);
    }
    for (final name in names) {
      await verifiedImageData(e, name, fingerprint: hashes[name]);
    }
  }
}
