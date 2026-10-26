import 'dart:convert';

void check(bool ok, String message) {
  if (!ok) throw FormatException(message);
}

Map<String, dynamic> jsonMap(Object? value, String location) {
  check(value is Map, '$location 必须是对象');
  return Map<String, dynamic>.from(value as Map);
}

void keys(
  Map<String, dynamic> value,
  Iterable<String> allowed,
  String location,
) {
  final extra = value.keys.toSet().difference(allowed.toSet());
  check(extra.isEmpty, '$location 包含未知字段 ${extra.join(', ')}；业务标签请放入 metadata');
}

bool validId(Object? value) =>
    value is String &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$').hasMatch(value);
bool nonEmpty(Object? value) => value is String && value.trim().isNotEmpty;

Object? immutableJson(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(
      value.map((key, item) => MapEntry(key as String, immutableJson(item))),
    );
  }
  if (value is List) {
    return List<dynamic>.unmodifiable(value.map(immutableJson));
  }
  return value;
}

String assetPath(Object? value) {
  check(nonEmpty(value), '素材路径不能为空');
  final path = value as String;
  check(
    !path.contains('\\') &&
        !path.contains(':') &&
        path.split('/').every((s) => s.isNotEmpty && s != '.' && s != '..') &&
        RegExp(r'\.(png|jpe?g)$', caseSensitive: false).hasMatch(path),
    '不支持或不安全的图片路径：$path',
  );
  return path;
}

Iterable<String> itemAssets(Map<String, dynamic> item) sync* {
  for (final key in ['a', 'b', 'aRight', 'bRight']) {
    if (item[key] != null) yield item[key] as String;
  }
}

class StudyDefinition {
  final Map<String, dynamic> _data;
  StudyDefinition._(this._data);
  static const defaults = <String, Map<String, dynamic>>{
    'presentation': {'mode': 'sequential', 'promptMs': 2000, 'imageMs': 3000},
    'schedule': {
      'repetitions': 1,
      'pairOrder': 'random',
      'itemOrder': 'random',
      'blockByGroup': false,
      'avoidAdjacentRepeats': false,
      'controlPlacement': 'spread',
      'practicePairOrder': 'random',
      'controlPairOrder': 'random',
    },
    'quality': {'minControlAccuracy': 1.0, 'requiredTrue': <String>[]},
    'analysis': {'metric': 'selection_rate'},
  };

  factory StudyDefinition.fromJson(
    Map<String, dynamic> source, {
    bool draft = false,
  }) {
    final data = jsonMap(jsonDecode(jsonEncode(source)), 'study');
    keys(data, [
      'schema',
      'studyId',
      'name',
      'method',
      'question',
      'instructions',
      'isDemo',
      'presentation',
      'schedule',
      'quality',
      'analysis',
      'items',
      'metadata',
      'participantFields',
      'sampling',
    ], 'study');
    check(
      data['schema'] is int && data['schema'] == 2,
      '不支持的数据格式，请使用 schema 2',
    );
    check(validId(data['studyId']), 'studyId 需为 1～80 位字母、数字、点、下划线或连字符');
    check(nonEmpty(data['name']) && nonEmpty(data['question']), '实验名称和问题不能为空');
    check(data['method'] == '2afc', '当前只支持 2afc 方法');
    data.putIfAbsent('instructions', () => '');
    data.putIfAbsent('isDemo', () => false);
    data.putIfAbsent('metadata', () => <String, dynamic>{});
    data.putIfAbsent('participantFields', () => <dynamic>[]);
    check(
      data['instructions'] is String &&
          data['isDemo'] is bool &&
          data['metadata'] is Map,
      '说明、演示标记或 metadata 类型错误',
    );
    for (final entry in defaults.entries) {
      final supplied = jsonMap(data[entry.key] ?? {}, entry.key);
      keys(supplied, [
        ...entry.value.keys,
        if (entry.key == 'analysis') 'profile',
        if (entry.key == 'presentation') ...['stereo', 'patch'],
      ], entry.key);
      data[entry.key] = {...entry.value, ...supplied};
    }
    final presentation = jsonMap(data['presentation'], 'presentation');
    check(presentation['mode'] == 'sequential', '当前只支持顺序呈现');
    if (presentation.containsKey('stereo')) {
      final stereo = jsonMap(presentation['stereo'], 'presentation.stereo');
      keys(stereo, [
        'input',
        'layout',
        'uiDisparity',
        'pointerMapping',
      ], 'presentation.stereo');
      stereo.putIfAbsent('layout', () => 'full_sbs');
      stereo.putIfAbsent('uiDisparity', () => 0);
      stereo.putIfAbsent('pointerMapping', () => 'screen');
      check(
        !stereo.containsKey('input') ||
            ['separate', 'sbs'].contains(stereo['input']),
        '双眼素材格式应为 separate 或 sbs',
      );
      check(
        ['screen', 'per_eye'].contains(stereo['pointerMapping']),
        '鼠标坐标映射无效',
      );
      check(['half_sbs', 'full_sbs'].contains(stereo['layout']), 'SBS 格式无效');
      final disparity = stereo['uiDisparity'];
      check(
        disparity is num &&
            disparity.isFinite &&
            disparity >= -64 &&
            disparity <= 64,
        'UI 双眼视差必须为 -64～64 逻辑像素',
      );
      presentation['stereo'] = stereo;
    }
    if (presentation.containsKey('patch')) {
      final patch = jsonMap(presentation['patch'], 'presentation.patch');
      keys(patch, [
        'area',
        'width',
        'height',
        'distribution',
      ], 'presentation.patch');
      patch.putIfAbsent('distribution', () => 'center_triangular');
      check(
        patch.containsKey('area') !=
            (patch.containsKey('width') || patch.containsKey('height')),
        'Patch 需填写像素 width、height；不能同时填写旧 area',
      );
      if (patch.containsKey('area')) {
        final area = patch['area'];
        check(
          area is num && area.isFinite && area >= 0.001 && area <= 1,
          'Patch 面积比例必须为 0.001～1',
        );
      } else {
        check(
          patch['width'] is int &&
              patch['height'] is int &&
              (patch['width'] as int) > 0 &&
              (patch['height'] as int) > 0 &&
              (patch['width'] as int) <= 40000000 &&
              (patch['height'] as int) <= 40000000 &&
              (patch['width'] as int) * (patch['height'] as int) <= 40000000,
          'Patch 宽、高必须为正整数像素，面积不超过 4000 万像素',
        );
      }
      check(patch['distribution'] == 'center_triangular', 'Patch 分布无效');
      presentation['patch'] = patch;
    }
    data['presentation'] = presentation;
    for (final (key, low, high) in [
      ('promptMs', 0, 60000),
      ('imageMs', 1, 600000),
    ]) {
      final value = presentation[key];
      check(
        value is int && value >= low && value <= high,
        '$key 必须为 $low～$high 毫秒的整数',
      );
    }
    final schedule = jsonMap(data['schedule'], 'schedule');
    final repeat = schedule['repetitions'];
    check(repeat is int && repeat >= 1 && repeat <= 1000, '重复次数必须为 1～1000 的整数');
    check(
      ['random', 'balanced'].contains(schedule['pairOrder']),
      'pairOrder 无效',
    );
    check(
      schedule['pairOrder'] != 'balanced' || (repeat as int).isEven,
      '平衡先后次序需要偶数次重复',
    );
    check(['listed', 'random'].contains(schedule['itemOrder']), 'itemOrder 无效');
    check(
      ['random', 'alternating'].contains(schedule['practicePairOrder']),
      'practicePairOrder 无效',
    );
    check(
      ['random', 'balanced'].contains(schedule['controlPairOrder']),
      'controlPairOrder 无效',
    );
    check(
      schedule['blockByGroup'] is bool &&
          schedule['avoidAdjacentRepeats'] is bool &&
          schedule['controlPlacement'] == 'spread',
      '分组、重复约束或控制题位置设置无效',
    );
    final quality = jsonMap(data['quality'], 'quality');
    final threshold = quality['minControlAccuracy'];
    check(
      threshold is num &&
          threshold.isFinite &&
          threshold >= 0 &&
          threshold <= 1,
      '控制题最低准确率应在 0～1 之间',
    );
    check(
      quality['requiredTrue'] is List &&
          (quality['requiredTrue'] as List).every((v) => v is String),
      'requiredTrue 必须为字段名列表',
    );
    final analysis = jsonMap(data['analysis'], 'analysis');
    check(
      ['accuracy', 'selection_rate'].contains(analysis['metric']),
      '不支持的分析指标',
    );
    if (analysis.containsKey('profile')) {
      final profile = jsonMap(analysis['profile'], 'analysis.profile');
      keys(profile, [
        'type',
        'version',
        'minObserversPerItem',
        'minObserversPerSequence',
        'expertNumerator',
        'expertDenominator',
        'maxSequenceAccuracy',
        'equalCoverage',
        'sequenceViews',
        'resolutions',
        'practiceMin',
        'practiceMax',
        'controlCount',
      ], 'analysis.profile');
      check(
        profile['type'] == 'photorealism' &&
            [1, 2].contains(profile['version']) &&
            analysis['metric'] == 'accuracy',
        '不支持的分析模板或版本',
      );
      for (final k in [
        profile['version'] == 2
            ? 'minObserversPerSequence'
            : 'minObserversPerItem',
        'expertNumerator',
        'expertDenominator',
        'practiceMin',
        'practiceMax',
        'controlCount',
      ]) {
        check(profile[k] is int && (profile[k] as int) > 0, '模板字段 $k 无效');
      }
      check(
        profile['equalCoverage'] is bool &&
            profile['maxSequenceAccuracy'] is num &&
            (profile['maxSequenceAccuracy'] as num) >= 0 &&
            (profile['maxSequenceAccuracy'] as num) <= 1,
        '模板覆盖或判定阈值无效',
      );
      final views = jsonMap(profile['sequenceViews'], 'sequenceViews');
      final resolutions = jsonMap(profile['resolutions'], 'resolutions');
      check(
        views.isNotEmpty &&
            views.keys.toSet().containsAll(resolutions.keys) &&
            resolutions.keys.toSet().containsAll(views.keys),
        '模板序列与分辨率不匹配',
      );
      for (final k in views.keys) {
        check(
          views[k] is List &&
              (views[k] as List).isNotEmpty &&
              (views[k] as List).every((v) => v is int) &&
              (views[k] as List).toSet().length == (views[k] as List).length,
          '模板视点 $k 无效',
        );
        check(
          resolutions[k] is List &&
              (resolutions[k] as List).length == 2 &&
              (resolutions[k] as List).every((n) => n is int && n > 0),
          '模板分辨率 $k 无效',
        );
      }
    }
    check(data['participantFields'] is List, 'participantFields 必须为列表');
    final fieldIds = <String>{};
    final boolIds = <String>{};
    for (final value in data['participantFields'] as List) {
      final field = jsonMap(value, 'participantFields');
      keys(field, [
        'id',
        'label',
        'type',
        'required',
        'min',
        'max',
      ], 'participantFields');
      check(
        validId(field['id']) &&
            fieldIds.add(field['id'] as String) &&
            nonEmpty(field['label']),
        '登记字段编号重复或名称无效',
      );
      check(
        ['text', 'integer', 'number', 'boolean'].contains(field['type']),
        '登记字段类型无效',
      );
      check(
        !field.containsKey('required') || field['required'] is bool,
        '登记字段 required 应为布尔值',
      );
      for (final k in ['min', 'max']) {
        check(
          !field.containsKey(k) ||
              (field[k] is num && (field[k] as num).isFinite),
          '登记字段 $k 无效',
        );
      }
      check(
        (!field.containsKey('min') && !field.containsKey('max')) ||
            ['integer', 'number'].contains(field['type']),
        '只有数值登记字段可以设置 min/max',
      );
      check(
        !field.containsKey('min') ||
            !field.containsKey('max') ||
            (field['min'] as num) <= (field['max'] as num),
        '登记字段范围无效',
      );
      if (field['type'] == 'boolean') boolIds.add(field['id'] as String);
    }
    check(
      boolIds.containsAll((quality['requiredTrue'] as List).cast<String>()),
      '参与条件必须引用已定义的布尔登记字段',
    );
    check(data['items'] is List, 'items 必须为列表');
    final ids = <String>{};
    final items = <Map<String, dynamic>>[];
    for (final (index, raw) in (data['items'] as List).indexed) {
      final item = jsonMap(raw, 'items[$index]');
      keys(item, [
        'id',
        'a',
        'b',
        'aRight',
        'bRight',
        'answer',
        'role',
        'group',
        'metadata',
      ], 'items[$index]');
      check(
        validId(item['id']) && ids.add(item['id'] as String),
        '第 ${index + 1} 题编号无效或重复',
      );
      assetPath(item['a']);
      assetPath(item['b']);
      for (final key in ['aRight', 'bRight']) {
        check(
          draft ||
              presentation['stereo'] == null ||
              (presentation['stereo'] as Map)['input'] == 'sbs' ||
              nonEmpty(item[key]),
          '${item['id']} 缺少右眼图片 $key',
        );
        if (item.containsKey(key) ||
            (!draft &&
                presentation['stereo'] != null &&
                (presentation['stereo'] as Map)['input'] != 'sbs')) {
          assetPath(item[key]);
        }
      }
      item.putIfAbsent('role', () => 'main');
      item.putIfAbsent('metadata', () => <String, dynamic>{});
      check(
        ['main', 'practice', 'control'].contains(item['role']),
        '${item['id']} 题目角色无效',
      );
      check(item['metadata'] is Map, '${item['id']} metadata 应为对象');
      check(
        !item.containsKey('group') || nonEmpty(item['group']),
        '${item['id']} 分组不能为空',
      );
      check(
        !item.containsKey('answer') || ['a', 'b'].contains(item['answer']),
        '${item['id']} 标准答案无效',
      );
      check(
        item['role'] != 'control' || item.containsKey('answer'),
        '${item['id']} 控制题需要标准答案',
      );
      items.add(item);
    }
    data['items'] = items;
    final paths = {for (final item in items) ...itemAssets(item)};
    check(
      paths.map((path) => path.toLowerCase()).toSet().length == paths.length,
      '图片路径不能仅以大小写区分，以便 Windows 与 Android 交换',
    );
    final main = items.where((i) => i['role'] == 'main').toList();
    if (data.containsKey('sampling')) {
      final sampling = jsonMap(data['sampling'], 'sampling');
      keys(sampling, ['mode', 'perGroup', 'fixedOrder'], 'sampling');
      check(
        ['per_participant', 'fixed_order'].contains(sampling['mode']),
        '抽样模式无效',
      );
      final counts = jsonMap(sampling['perGroup'], 'sampling.perGroup');
      check(
        counts.isNotEmpty &&
            counts.entries.every(
              (e) => nonEmpty(e.key) && e.value is int && (e.value as int) > 0,
            ),
        '每组抽样数量必须为正整数',
      );
      if (!draft) {
        check(
          main.every((i) => counts.containsKey(i['group'])) &&
              counts.keys.every(
                (g) =>
                    main.where((i) => i['group'] == g).length >=
                    (counts[g] as int),
              ),
          '素材池分组或抽样数量不符',
        );
      }
      if (sampling['mode'] == 'fixed_order') {
        final order = sampling['fixedOrder'];
        final byId = {for (final i in main) i['id'] as String: i};
        check(
          order is List &&
              order.isNotEmpty &&
              order.every((id) => id is String && byId.containsKey(id)) &&
              order.toSet().length == order.length,
          '固定列表不能为空，必须引用不重复的正式题编号',
        );
        final selected = (order as List).map((id) => byId[id]!).toList();
        check(
          selected.length ==
                  counts.values.cast<int>().fold(0, (a, b) => a + b) &&
              counts.entries.every(
                (e) =>
                    selected.where((i) => i['group'] == e.key).length ==
                    e.value,
              ),
          '固定列表数量与各分组设置不符',
        );
        if (schedule['blockByGroup'] == true) {
          final closed = <String>{};
          String? previous;
          for (final item in selected) {
            final group = item['group'] as String;
            if (group != previous) {
              check(!closed.contains(group), '分组测试的固定列表中，同一分组必须连续排列');
              if (previous != null) closed.add(previous);
              previous = group;
            }
          }
        }
      } else {
        check(!sampling.containsKey('fixedOrder'), '随机抽样模式不能包含固定列表');
      }
      data['sampling'] = sampling;
    }
    check(draft || main.isNotEmpty, '至少需要一道正式题');
    check(
      draft ||
          analysis['metric'] != 'accuracy' ||
          main.every((i) => i.containsKey('answer')),
      '准确率分析要求所有正式题有标准答案',
    );
    check(
      draft ||
          schedule['blockByGroup'] != true ||
          main.every((i) => i.containsKey('group')),
      '分块排程要求所有正式题有分组',
    );
    if (!draft &&
        schedule['avoidAdjacentRepeats'] == true &&
        (repeat as int) > 1) {
      final counts = <String, int>{};
      for (final item in main) {
        final group = schedule['blockByGroup'] == true
            ? item['group'] as String
            : '';
        counts[group] = (counts[group] ?? 0) + 1;
      }
      if (data['sampling'] != null) {
        final selected = jsonMap(
          (data['sampling'] as Map)['perGroup'],
          'perGroup',
        );
        counts.clear();
        if (schedule['blockByGroup'] == true) {
          counts.addAll(selected.cast<String, int>());
        } else {
          counts[''] = selected.values.cast<int>().fold(0, (a, b) => a + b);
        }
      }
      check(counts.values.every((n) => n >= 2), '单题分块重复无法满足不相邻约束');
    }
    check(
      draft ||
          schedule['controlPairOrder'] != 'balanced' ||
          items.where((i) => i['role'] == 'control').length.isEven,
      '控制题次序平衡需要偶数道控制题',
    );
    return StudyDefinition._(jsonMap(immutableJson(data), 'study'));
  }

  Map<String, dynamic> toJson() =>
      jsonMap(jsonDecode(jsonEncode(_data)), 'study');
  String get studyId => _data['studyId'] as String;
  String get name => _data['name'] as String;
  String get question => _data['question'] as String;
  String get instructions => _data['instructions'] as String;
  bool get isDemo => _data['isDemo'] as bool;
  Map<String, dynamic> get presentation =>
      jsonMap(_data['presentation'], 'presentation');
  Map<String, dynamic> get schedule => jsonMap(_data['schedule'], 'schedule');
  Map<String, dynamic>? get stereo => presentation['stereo'] == null
      ? null
      : jsonMap(presentation['stereo'], 'stereo');
  Map<String, dynamic>? get patch => presentation['patch'] == null
      ? null
      : jsonMap(presentation['patch'], 'patch');
  bool get packedStereo => stereo?['input'] == 'sbs';
  String get methodVersion => packedStereo
      ? '2afc-sbs@1'
      : stereo == null
      ? '2afc@1'
      : '2afc-stereo@1';
  bool get fixedSampling => sampling?['mode'] == 'fixed_order';
  List<String> get fixedOrder => fixedSampling
      ? (sampling!['fixedOrder'] as List).cast<String>()
      : const [];
  String get schedulerVersion => fixedSampling
      ? '2afc-schedule@6'
      : packedStereo
      ? '2afc-schedule@5'
      : patch != null
      ? patch!.containsKey('width')
            ? '2afc-schedule@4'
            : '2afc-schedule@3'
      : sampling != null
      ? '2afc-schedule@2'
      : '2afc-schedule@1';
  Map<String, dynamic> get quality => jsonMap(_data['quality'], 'quality');
  Map<String, dynamic> get analysis => jsonMap(_data['analysis'], 'analysis');
  Map<String, dynamic>? get profile => analysis['profile'] == null
      ? null
      : jsonMap(analysis['profile'], 'profile');
  Map<String, dynamic>? get sampling =>
      _data['sampling'] == null ? null : jsonMap(_data['sampling'], 'sampling');
  int get selectedMainCount => sampling == null
      ? items.where((i) => i['role'] == 'main').length
      : (sampling!['perGroup'] as Map).values.cast<int>().fold(
          0,
          (a, b) => a + b,
        );
  List<Map<String, dynamic>> get items =>
      (_data['items'] as List).map((i) => jsonMap(i, 'item')).toList();
  List<Map<String, dynamic>> get participantFields =>
      (_data['participantFields'] as List)
          .map((i) => jsonMap(i, 'field'))
          .toList();
  Set<String> get assets => {for (final item in items) ...itemAssets(item)};
  int get trialCount =>
      selectedMainCount * (schedule['repetitions'] as int) +
      items.where((i) => i['role'] != 'main').length;

  void validateParticipant(Map<String, dynamic> participant) {
    for (final field in participantFields) {
      final v = participant[field['id']];
      if (v == null && field['required'] != true) continue;
      final valid = switch (field['type']) {
        'text' => nonEmpty(v),
        'integer' => v is int,
        'number' => v is num && v.isFinite,
        'boolean' => v is bool,
        _ => false,
      };
      check(valid, '请填写有效的${field['label']}');
      if (v is num) {
        check(
          (field['min'] == null || v >= (field['min'] as num)) &&
              (field['max'] == null || v <= (field['max'] as num)),
          '${field['label']}超出范围',
        );
      }
    }
  }
}
