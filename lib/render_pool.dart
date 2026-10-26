part of 'repository.dart';

// Explicit adapter for the real-photography template. Generic v2 execution does
// not interpret training/export paths. The same adapter consumes filesystem and SAF lists.
extension RenderPoolRepository on StudyRepository {
  Future<StudyDraft> loadRenderDirectory(Directory directory) async {
    final entries = <Map<String, dynamic>>[];
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is File && p.extension(entry.path).toLowerCase() == '.png') {
        // Read dimensions without decoding or copying the full external image.
        final file = await entry.open();
        late final Uint8List header;
        try {
          header = await file.read(24);
        } finally {
          await file.close();
        }
        check(
          header.length == 24 &&
              header.take(8).join(',') == '137,80,78,71,13,10,26,10',
          'PNG 文件头无效：${entry.path}',
        );
        final dimensions = ByteData.sublistView(header);
        entries.add({
          'path': p
              .relative(entry.path, from: directory.path)
              .replaceAll('\\', '/'),
          'bytes': await entry.length(),
          'width': dimensions.getUint32(16),
          'height': dimensions.getUint32(20),
        });
      }
    }
    return createRenderPool({
      'root': await directory.resolveSymbolicLinks(),
      'entries': entries,
    });
  }

  Future<StudyDraft> createRenderPool(Map<String, dynamic> source) async {
    final all = records(source['entries']),
        groups = <String, Map<String, Map<String, dynamic>>>{};
    final directories = <String, Set<String>>{};
    final pattern = RegExp(
      r'^([^/]+_renders)/frame(\d+)/test/(?:primitive/)?(gt|renders)/(\d+\.png)$',
    );
    for (final entry in all) {
      final path = entry['path'] as String;
      final match = pattern.firstMatch(path);
      if (match == null) continue;
      final matches = protocolViews.keys
          .where((s) => match[1]!.startsWith('${s}_'))
          .toList();
      if (matches.isEmpty) continue;
      check(matches.length == 1, '序列目录无法唯一识别：${match[1]}');
      final sequence = matches.single, frame = int.parse(match[2]!);
      final camera = int.parse(p.basenameWithoutExtension(match[4]!));
      final views = protocolViews[sequence]!;
      check(camera >= 0 && camera < views.length, '导出视点编号不符：$path');
      directories.putIfAbsent(sequence, () => {}).add(match[1]!);
      final key = '$frame:$camera';
      final sides = groups
          .putIfAbsent(sequence, () => {})
          .putIfAbsent(key, () => {});
      check(!sides.containsKey(match[3]), '存在重复的帧与视点：$path');
      sides[match[3]!] = entry;
    }
    check(groups.isNotEmpty, '未找到可配对的 GT/渲染图。请选择包含 *_renders 序列的上级目录');
    check(
      directories.values.every((v) => v.length == 1),
      '同一序列有多套 renders 目录，请只保留本次测试的一套',
    );
    final definition = newStudySource('render-pool-${uuid()}');
    definition.addAll({
      'name': '真实素材 · 每人随机帧与视点',
      'question': '哪一幅是真实拍摄图像？',
      'isDemo': true,
      'instructions': '本次为流程演练。每位参与者独立随机抽取帧和视点；恢复时沿用本次抽样。',
      'sampling': {
        'mode': 'per_participant',
        'perGroup': {
          for (final e in protocolViews.entries.where(
            (e) => groups.containsKey(e.key),
          ))
            e.key: min(e.value.length, groups[e.key]!.length),
        },
      },
      'schedule': {
        'repetitions': 2,
        'pairOrder': 'balanced',
        'blockByGroup': true,
        'avoidAdjacentRepeats': true,
      },
      'analysis': {'metric': 'accuracy'},
      'metadata': {
        'sourceAdapter': 'primitive-renders@2',
        'purpose': 'workflow-simulation',
        'missingFormalMaterials': ['practice', 'control'],
      },
    });
    final items = <Map<String, dynamic>>[], assets = <Map<String, dynamic>>[];
    final packedKinds = <bool>{};
    for (final sequence in protocolViews.keys.where(groups.containsKey)) {
      final pairs = groups[sequence]!, views = protocolViews[sequence]!;
      final frameCoverage = <int, Set<int>>{};
      final sorted = pairs.keys.toList()
        ..sort((a, b) {
          final av = a.split(':').map(int.parse).toList(),
              bv = b.split(':').map(int.parse).toList();
          return av[0] != bv[0]
              ? av[0].compareTo(bv[0])
              : av[1].compareTo(bv[1]);
        });
      for (final key in sorted) {
        final numbers = key.split(':').map(int.parse).toList(),
            frame = numbers[0],
            camera = numbers[1];
        final sides = pairs[key]!;
        check(
          sides.keys.toSet().containsAll(['gt', 'renders']),
          'GT/render 配对缺失：$sequence frame$frame view$camera',
        );
        frameCoverage.putIfAbsent(frame, () => {}).add(camera);
        final view = views[camera],
            width = sequence == 'Show_Groups_4K' ? 3840 : 1920,
            height = sequence == 'Show_Groups_4K' ? 2160 : 1080;
        final item = <String, dynamic>{
          'id': '$sequence-f$frame-v$view',
          'group': sequence,
          'answer': 'a',
          'metadata': {
            'frame': frame,
            'view': view,
            'mapping': 'confirmed-export-order',
          },
        };
        for (final (alternative, role) in [('a', 'gt'), ('b', 'renders')]) {
          final entry = jsonMap(sides[role], 'file'),
              path = assetPath(entry['path']);
          final actualWidth = entry['width'] as int? ?? width;
          final actualHeight = entry['height'] as int? ?? height;
          packedKinds.add(actualWidth == width * 2 && actualHeight == height);
          item[alternative] = path;
          assets.add({
            'path': path,
            'sha256': null,
            'bytes': entry['bytes'] ?? 0,
            'width': actualWidth,
            'height': actualHeight,
            'mediaType': 'image/png',
          });
        }
        items.add(item);
      }
      check(
        frameCoverage.values.every((v) => v.length == views.length),
        '存在视点不完整的帧：$sequence',
      );
    }
    check(packedKinds.length == 1, '目录中混有普通图片和已拼 SBS 图片，请分开选择素材目录');
    final packed = packedKinds.single;
    if (packed) {
      definition['name'] = '双目真实素材 · 每人随机帧与视点';
      definition['presentation'] = {
        ...?definition['presentation'] as Map<String, dynamic>?,
        'stereo': {
          'input': 'sbs',
          'layout': 'half_sbs',
          'uiDisparity': 0,
          'pointerMapping': 'screen',
        },
      };
      (definition['metadata'] as Map)['sourceAdapter'] = 'sbs-renders@1';
      (definition['metadata'] as Map)['stereoOutputPolicy'] = 'half-default@1';
    }
    definition['items'] = items;
    definition['studyId'] =
        '${packed ? 'sbs' : 'render'}-pool-${digestJson(assets).substring(0, 24)}';
    final existing = (await drafts())
        .where((d) => d.id == definition['studyId'])
        .firstOrNull;
    final draft = existing ?? await saveDraft(definition),
        dir = draftDir(draft.id);
    final documents = {
      for (final e in all.where((e) => e['uri'] != null))
        e['path'] as String: e['uri'],
    };
    await bindMaterialSource(dir, {
      'root': source['root'],
      if (documents.isNotEmpty) 'documents': documents,
    });
    await File(
      p.join(dir.path, 'catalog.json'),
    ).writeAsString(jsonEncode(assets));
    return draft;
  }
}
