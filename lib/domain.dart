import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'study_v2.dart';
export 'study_v2.dart';
part 'v2_runtime.dart';

const protocolViews = <String, List<int>>{
  'VRU_gz': [0, 10, 20, 30],
  'VRU_dg4': [0, 10, 20, 30],
  'Dance_Dunhuang_Pair_1080': [0, 10, 20, 30, 40, 50],
  'Show_Groups_4K': [0, 10, 20, 30, 40, 50],
};
const sequenceLabels = {
  'VRU_gz': '篮球场景 GZ',
  'VRU_dg4': '篮球场景 DG4',
  'Dance_Dunhuang_Pair_1080': '敦煌双人舞',
  'Show_Groups_4K': '多人场景 4K',
};

// Version 1 scheduling uses a specified PRNG and shuffle, independent of SDK changes.
class StableRandom implements Random {
  int _state;
  StableRandom(int seed) : _state = (seed ^ 0x9e3779b9) & 0xffffffff {
    if (_state == 0) _state = 1;
  }
  int _step() {
    var x = _state;
    x = (x ^ (x << 13)) & 0xffffffff;
    x = (x ^ (x >> 17)) & 0xffffffff;
    x = (x ^ (x << 5)) & 0xffffffff;
    return _state = x;
  }

  @override
  int nextInt(int max) {
    if (max <= 0 || max > 0x100000000) {
      throw RangeError.range(max, 1, 0x100000000);
    }
    final limit = 0x100000000 - 0x100000000 % max;
    int n;
    do {
      n = _step();
    } while (n >= limit);
    return n % max;
  }

  @override
  bool nextBool() => nextInt(2) == 0;
  @override
  double nextDouble() => _step() / 0x100000000;
}

extension StudyPermutation<T> on List<T> {
  void permute(StableRandom random) {
    for (int i = length - 1; i > 0; i--) {
      final j = random.nextInt(i + 1), old = this[i];
      this[i] = this[j];
      this[j] = old;
    }
  }
}

Object? canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((e) => e.toString()).toList()..sort();
    return {for (final key in keys) key: canonical(value[key])};
  }
  if (value is List) return value.map(canonical).toList();
  return value;
}

String digestJson(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(canonical(value)))).toString();

List<Map<String, dynamic>> records(Object? value) =>
    (value as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

class StudyCase {
  final String id, sequence, kind, gt, render, gtHash, renderHash, mapping;
  final int frame, view, iteration, width, height;
  final int bWidth, bHeight;
  final String? answer;
  final String? aRight, bRight;
  List<String> get assets => [gt, render, ?aRight, ?bRight];
  final Map<String, dynamic> metadata;
  const StudyCase({
    required this.id,
    required this.sequence,
    required this.kind,
    required this.gt,
    required this.render,
    required this.gtHash,
    required this.renderHash,
    required this.frame,
    required this.view,
    required this.iteration,
    required this.width,
    required this.height,
    this.mapping = 'explicit',
    int? bWidth,
    int? bHeight,
    this.answer = 'a',
    this.metadata = const {},
    this.aRight,
    this.bRight,
  }) : bWidth = bWidth ?? width,
       bHeight = bHeight ?? height;
  factory StudyCase.fromJson(Map<String, dynamic> j) => StudyCase(
    id: j['id'] as String,
    sequence: j['sequence'] as String,
    kind: j['kind'] as String,
    gt: j['gt'] as String,
    render: j['render'] as String,
    gtHash: j['gtHash'] as String,
    renderHash: j['renderHash'] as String,
    frame: j['frame'] as int,
    view: j['view'] as int,
    iteration: j['iteration'] as int,
    width: j['width'] as int,
    height: j['height'] as int,
    mapping: j['mapping'] as String? ?? 'explicit',
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'sequence': sequence,
    'kind': kind,
    'gt': gt,
    'render': render,
    'gtHash': gtHash,
    'renderHash': renderHash,
    'frame': frame,
    'view': view,
    'iteration': iteration,
    'width': width,
    'height': height,
    'mapping': mapping,
  };
}

class Experiment {
  final String id, name, createdAt;
  final bool isDemo;
  final int seed, promptMs, imageMs;
  final List<StudyCase> cases;
  final StudyDefinition? definition;
  final Map<String, dynamic>? release;
  bool get isV2 => definition != null;
  String get studyId => definition?.studyId ?? id;
  String get question => definition?.question ?? '哪一幅是真实拍摄图像？';
  const Experiment({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.isDemo,
    required this.seed,
    required this.cases,
    this.promptMs = 2000,
    this.imageMs = 3000,
    this.definition,
    this.release,
  });
  factory Experiment.fromRelease(
    Map<String, dynamic> source,
    Map<String, dynamic> release,
  ) {
    final definition = StudyDefinition.fromJson(source);
    check(
      release['schema'] == 2 &&
          release['studyId'] == definition.studyId &&
          release['revisionId'] is String &&
          RegExp(
            r'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$',
          ).hasMatch(release['revisionId'] as String) &&
          DateTime.tryParse(release['createdAt'] as String? ?? '') != null,
      '发布清单身份或时间无效',
    );
    final implementations = jsonMap(
      release['implementations'],
      'implementations',
    );
    final expected = {
      'method': definition.stereo == null ? '2afc@1' : '2afc-stereo@1',
      'scheduler': definition.schedulerVersion,
      'quality': 'basic-quality@1',
      'analysis': definition.profile == null
          ? 'basic-analysis@1'
          : 'photorealism-analysis@${definition.profile!['version']}',
    };
    check(
      digestJson(implementations) == digestJson(expected),
      '不支持此发布版本的执行或统计实现',
    );
    final manifest = jsonMap(release['definition'], 'definition');
    check(
      manifest['path'] == 'study.json' &&
          manifest['sha256'] is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(manifest['sha256'] as String),
      '定义文件校验信息无效',
    );
    final assets = records(release['assets']);
    final byPath = <String, Map<String, dynamic>>{};
    for (final asset in assets) {
      final path = assetPath(asset['path']);
      check(
        !byPath.containsKey(path) &&
            ((asset['sha256'] is String &&
                    RegExp(
                      r'^[a-f0-9]{64}$',
                    ).hasMatch(asset['sha256'] as String)) ||
                (release['materials'] == 'external@1' &&
                    asset['sha256'] == null &&
                    asset['bytes'] is int &&
                    (asset['bytes'] as int) >= 0)) &&
            asset['width'] is int &&
            asset['height'] is int &&
            (asset['width'] as int) > 0 &&
            (asset['height'] as int) > 0 &&
            (asset['width'] as int) * (asset['height'] as int) <= 40000000 &&
            ['image/png', 'image/jpeg'].contains(asset['mediaType']),
        '资源清单无效：$path',
      );
      byPath[path] = asset;
    }
    check(
      byPath.keys.toSet().containsAll(definition.assets) &&
          definition.assets.containsAll(byPath.keys),
      '资源清单与题目引用不一致',
    );
    final cases = definition.items.map((item) {
      final a = byPath[item['a']]!, b = byPath[item['b']]!;
      final patch = definition.patch;
      if (patch != null && patch.containsKey('width')) {
        check(
          (patch['width'] as int) <= (a['width'] as int) &&
              (patch['height'] as int) <= (a['height'] as int),
          '${item['id']} 的 Patch ${patch['width']}×${patch['height']} 超过原图 ${a['width']}×${a['height']}',
        );
      }
      if (definition.stereo != null || definition.patch != null) {
        check(
          itemAssets(item).every(
            (path) =>
                byPath[path]!['width'] == a['width'] &&
                byPath[path]!['height'] == a['height'],
          ),
          '${item['id']} 的 A、B 与双眼图片必须具有相同尺寸',
        );
      }
      final meta = jsonMap(item['metadata'], 'metadata');
      return StudyCase(
        id: item['id'] as String,
        sequence: item['group'] as String? ?? '',
        kind: item['role'] as String,
        gt: item['a'] as String,
        render: item['b'] as String,
        aRight: item['aRight'] as String?,
        bRight: item['bRight'] as String?,
        gtHash: a['sha256'] as String? ?? '',
        renderHash: b['sha256'] as String? ?? '',
        frame: meta['frame'] is int ? meta['frame'] as int : -1,
        view: meta['view'] is int ? meta['view'] as int : -1,
        iteration: meta['iteration'] is int ? meta['iteration'] as int : 0,
        width: a['width'] as int,
        height: a['height'] as int,
        bWidth: b['width'] as int,
        bHeight: b['height'] as int,
        answer: item['answer'] as String?,
        metadata: Map<String, dynamic>.unmodifiable(meta),
      );
    }).toList();
    final e = Experiment(
      id: release['revisionId'] as String,
      name: definition.name,
      createdAt: release['createdAt'] as String,
      isDemo: definition.isDemo,
      seed: 0,
      cases: List<StudyCase>.unmodifiable(cases),
      promptMs: definition.presentation['promptMs'] as int,
      imageMs: definition.presentation['imageMs'] as int,
      definition: definition,
      release: Map<String, dynamic>.unmodifiable(
        jsonMap(immutableJson(release), 'release'),
      ),
    );
    e.validate();
    return e;
  }
  factory Experiment.fromJson(Map<String, dynamic> j) {
    if (j['schema'] == 2) {
      return Experiment.fromRelease(
        jsonMap(j['study'], 'study'),
        jsonMap(j['release'], 'release'),
      );
    }
    if (j['schema'] != 1) throw const FormatException('不支持的题库版本');
    final e = Experiment(
      id: j['id'] as String,
      name: j['name'] as String,
      createdAt: j['createdAt'] as String,
      isDemo: j['isDemo'] as bool,
      seed: j['seed'] as int,
      promptMs: j['promptMs'] as int,
      imageMs: j['imageMs'] as int,
      cases: records(j['cases']).map(StudyCase.fromJson).toList(),
    );
    e.validate();
    if (e.id != digestJson(e.toJson(withId: false))) {
      throw const FormatException('题库标识与内容不符，文件可能被修改');
    }
    return e;
  }
  static Experiment freeze({
    required String name,
    required bool demo,
    required int seed,
    required List<StudyCase> cases,
    int promptMs = 2000,
    int imageMs = 3000,
  }) {
    final temp = Experiment(
      id: '',
      name: name,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      isDemo: demo,
      seed: seed,
      cases: cases,
      promptMs: promptMs,
      imageMs: imageMs,
    );
    final value = temp.toJson(withId: false);
    return Experiment.fromJson({...value, 'id': digestJson(value)});
  }

  Map<String, dynamic> toJson({bool withId = true}) => isV2
      ? {'schema': 2, 'study': definition!.toJson(), 'release': release}
      : {
          'schema': 1,
          if (withId) 'id': id,
          'name': name,
          'createdAt': createdAt,
          'isDemo': isDemo,
          'seed': seed,
          'promptMs': promptMs,
          'imageMs': imageMs,
          'cases': cases.map((c) => c.toJson()).toList(),
        };
  StudyCase caseById(String key) => cases.firstWhere((c) => c.id == key);
  void validate() {
    if (isV2) {
      StudyDefinition.fromJson(definition!.toJson());
      if (definition!.profile != null) validatePhotorealism(this);
      return;
    }
    if (name.trim().isEmpty ||
        promptMs < 1000 ||
        promptMs > 3000 ||
        imageMs < 3000 ||
        imageMs > 5000) {
      throw const FormatException('题库名称或呈现时间不符合测试方案');
    }
    if (cases.map((c) => c.id).toSet().length != cases.length ||
        cases.any((c) => !['main', 'practice', 'control'].contains(c.kind))) {
      throw const FormatException('题目编号重复或题目类型错误');
    }
    if (cases.where((c) => c.kind == 'control').length != 2) {
      throw const FormatException('必须配置两道控制题');
    }
    final practice = cases.where((c) => c.kind == 'practice').toList();
    if (practice.length < 3 || practice.length > 5) {
      throw const FormatException('需要配置 3～5 道独立练习题');
    }
    final main = cases.where((c) => c.kind == 'main').toList();
    if (main.length != 20) throw const FormatException('正式题库需要 20 对图片');
    for (final entry in protocolViews.entries) {
      final group = main.where((c) => c.sequence == entry.key).toList();
      if (group.length != entry.value.length ||
          group.map((c) => c.view).toSet().length != entry.value.length ||
          !group.map((c) => c.view).toSet().containsAll(entry.value) ||
          group.map((c) => c.frame).toSet().length != 1) {
        throw FormatException('序列 ${entry.key} 的帧或视点覆盖不完整');
      }
      if (!isDemo &&
          group.any(
            (c) =>
                c.width != (entry.key == 'Show_Groups_4K' ? 3840 : 1920) ||
                c.height != (entry.key == 'Show_Groups_4K' ? 2160 : 1080),
          )) {
        throw FormatException('序列 ${entry.key} 的分辨率不符合方案');
      }
    }
    final formalHashes = main.expand((c) => [c.gtHash, c.renderHash]).toSet();
    if (practice.any(
      (c) =>
          formalHashes.contains(c.gtHash) ||
          formalHashes.contains(c.renderHash),
    )) {
      throw const FormatException('练习图像不能与正式图像相同');
    }
  }
}

class Trial {
  final String id, caseId;
  final bool capturedFirst;
  final String? role;
  final int repetition;
  final Map<String, dynamic>? sample;
  final Map<String, dynamic>? patch;
  const Trial(
    this.id,
    this.caseId,
    this.capturedFirst, {
    this.role,
    this.repetition = 1,
    this.sample,
    this.patch,
  });
  factory Trial.fromJson(Map<String, dynamic> j) {
    if (j.containsKey('trialId')) {
      check(
        j['order'] is List &&
            (j['order'] == null ||
                jsonEncode(j['order']) == '["a","b"]' ||
                jsonEncode(j['order']) == '["b","a"]'),
        '呈现顺序无效',
      );
      return Trial(
        j['trialId'] as String,
        j['itemId'] as String,
        (j['order'] as List).first == 'a',
        role: j['role'] as String,
        repetition: j['repetition'] as int,
        sample: j['sample'] == null
            ? null
            : jsonMap(immutableJson(j['sample']), 'sample'),
        patch: j['patch'] == null
            ? null
            : jsonMap(immutableJson(j['patch']), 'patch'),
      );
    }
    return Trial(
      j['id'] as String,
      j['caseId'] as String,
      j['capturedFirst'] as bool,
    );
  }
  List<String> get order => capturedFirst ? ['a', 'b'] : ['b', 'a'];
  String selected(int position) => order[position - 1];
  Map<String, dynamic> toJson() => role != null
      ? {
          'trialId': id,
          'itemId': caseId,
          'role': role,
          'repetition': repetition,
          'order': order,
          if (sample != null) 'sample': sample,
          if (patch != null) 'patch': patch,
        }
      : {'id': id, 'caseId': caseId, 'capturedFirst': capturedFirst};
  int get correctChoice => capturedFirst ? 1 : 2;
}

List<Trial> buildSchedule(Experiment experiment, int seed) {
  if (experiment.isV2) return buildV2Schedule(experiment, seed);
  final random = StableRandom(seed);
  final practice = experiment.cases.where((c) => c.kind == 'practice').toList()
    ..permute(random);
  final groups = protocolViews.keys.toList()..permute(random);
  final main = <Trial>[];
  for (final group in groups) {
    final cases =
        experiment.cases
            .where((c) => c.kind == 'main' && c.sequence == group)
            .toList()
          ..permute(random);
    final first = {for (final c in cases) c.id: random.nextBool()};
    main.addAll(cases.map((c) => Trial('${c.id}:1', c.id, first[c.id]!)));
    final second = [...cases]..permute(random);
    if (second.first.id == cases.last.id) {
      final last = second.removeLast();
      second.insert(0, last);
    }
    main.addAll(second.map((c) => Trial('${c.id}:2', c.id, !first[c.id]!)));
  }
  final controls = experiment.cases.where((c) => c.kind == 'control').toList()
    ..permute(random);
  final controlFirst = random.nextBool();
  return [
    for (int i = 0; i < practice.length; i++)
      Trial('${practice[i].id}:practice', practice[i].id, i.isEven),
    Trial('${controls[0].id}:control', controls[0].id, controlFirst),
    ...main.take(20),
    Trial('${controls[1].id}:control', controls[1].id, !controlFirst),
    ...main.skip(20),
  ];
}

class StudySession {
  final Map<String, String> materialHashes;
  final String id, experimentId, participantId, startedAt;
  final int seed;
  final int schema;
  final String? studyId;
  final String? schedulerVersion;
  final Map<String, dynamic> participant, display;
  final List<Trial> trials;
  final List<Map<String, dynamic>> answers, events;
  String? completedAt;
  bool practiceStarted, formalStarted;
  StudySession({
    required this.id,
    required this.experimentId,
    required this.participantId,
    required this.startedAt,
    required this.seed,
    required this.participant,
    required this.display,
    required this.trials,
    List<Map<String, dynamic>>? answers,
    List<Map<String, dynamic>>? events,
    this.completedAt,
    this.practiceStarted = false,
    this.formalStarted = false,
    this.schema = 1,
    this.studyId,
    this.schedulerVersion,
    Map<String, String>? materialHashes,
  }) : answers = answers ?? [],
       events = events ?? [],
       materialHashes = materialHashes ?? {};
  bool get complete => completedAt != null && answers.length == trials.length;
  factory StudySession.fromJson(Map<String, dynamic> j) {
    if (![1, 2].contains(j['schema'])) throw const FormatException('不支持的结果版本');
    final v2 = j['schema'] == 2;
    if (v2) {
      check(
        j['conditionId'] == (j['display'] as Map)['conditionId'],
        '会话观看条件编号不一致',
      );
    }
    return StudySession(
      id: j[v2 ? 'sessionId' : 'id'] as String,
      experimentId: j[v2 ? 'revisionId' : 'experimentId'] as String,
      participantId: j['participantId'] as String,
      startedAt: j['startedAt'] as String,
      seed: j['seed'] as int,
      participant: Map<String, dynamic>.from(j['participant'] as Map),
      display: Map<String, dynamic>.from(j['display'] as Map),
      trials: records(j['trials']).map(Trial.fromJson).toList(),
      answers: records(j['answers']),
      events: records(j['events']),
      completedAt: j['completedAt'] as String?,
      practiceStarted: j['practiceStarted'] as bool? ?? false,
      formalStarted: j['formalStarted'] as bool? ?? false,
      schema: v2 ? 2 : 1,
      studyId: j['studyId'] as String?,
      schedulerVersion: j['schedulerVersion'] as String?,
      materialHashes: j['materialHashes'] == null
          ? null
          : Map<String, String>.from(j['materialHashes'] as Map),
    );
  }
  Map<String, dynamic> toJson() => {
    'schema': schema,
    if (schema == 2) ...{
      'sessionId': id,
      'studyId': studyId,
      'revisionId': experimentId,
      'conditionId': display['conditionId'],
      'schedulerVersion': schedulerVersion,
    } else ...{
      'id': id,
      'experimentId': experimentId,
    },
    'participantId': participantId,
    'startedAt': startedAt,
    'seed': seed,
    'participant': participant,
    'display': display,
    'trials': trials.map((t) => t.toJson()).toList(),
    'answers': answers,
    'events': events,
    if (materialHashes.isNotEmpty) 'materialHashes': materialHashes,
    'completedAt': completedAt,
    'practiceStarted': practiceStarted,
    'formalStarted': formalStarted,
  };
  void validate(Experiment e) {
    if (e.isV2) {
      validateV2Session(this, e);
      return;
    }
    check(schema == 1, '会话版本与实验不符');
    if (experimentId != e.id ||
        participantId.trim().isEmpty ||
        display['condition'] is! String ||
        (display['condition'] as String).trim().isEmpty ||
        participant['expert'] is! bool ||
        participant['normalVision'] is! bool ||
        participant['normalColorVision'] is! bool ||
        participant['organizerOrDeveloper'] is! bool ||
        participant['age'] is! int ||
        DateTime.tryParse(startedAt) == null ||
        (completedAt != null && DateTime.tryParse(completedAt!) == null) ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id) ||
        digestJson(trials.map((t) => t.toJson()).toList()) !=
            digestJson(
              buildSchedule(e, seed).map((t) => t.toJson()).toList(),
            ) ||
        answers.length > trials.length ||
        (completedAt != null && answers.length != trials.length)) {
      throw const FormatException('会话与题库或排程不匹配');
    }
    for (int i = 0; i < answers.length; i++) {
      if (answers[i]['trialId'] != trials[i].id ||
          ![1, 2].contains(answers[i]['choice']) ||
          answers[i]['responseMs'] is! int ||
          (answers[i]['responseMs'] as int) < 0) {
        throw const FormatException('结果包含重复、缺失或无效答案');
      }
    }
  }

  int controlCorrect(Experiment e) => answers.where((a) {
    final t = trials.firstWhere((t) => t.id == a['trialId']);
    return e.caseById(t.caseId).kind == 'control' &&
        (e.isV2
            ? a['selectedAlternative'] == e.caseById(t.caseId).answer
            : a['choice'] == t.correctChoice);
  }).length;
  bool get eligible =>
      participant['normalVision'] == true &&
      participant['normalColorVision'] == true &&
      participant['organizerOrDeveloper'] != true;
  bool valid(Experiment e) => e.isV2
      ? complete && v2Eligible(this, e) && v2ControlsPass(this, e)
      : complete && eligible && controlCorrect(e) == 2;
  String status(Experiment e) => e.isV2
      ? (!complete
            ? '未完成'
            : !v2Eligible(this, e)
            ? '参与条件不符'
            : !v2ControlsPass(this, e)
            ? '控制题未通过'
            : '有效')
      : !complete
      ? '未完成'
      : !eligible
      ? '参与条件不符'
      : controlCorrect(e) != 2
      ? '控制题未通过'
      : '有效';
}

Map<String, dynamic> buildReport(Experiment e, List<StudySession> sessions) {
  if (e.isV2) return buildV2Report(e, sessions);
  final conditions =
      sessions.map((s) => s.display['condition'].toString()).toSet().toList()
        ..sort();
  return {
    'schema': 1,
    'experimentId': e.id,
    'experimentName': e.name,
    'isDemo': e.isDemo,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'conditions': conditions.map((condition) {
      final all = sessions
          .where(
            (s) =>
                s.experimentId == e.id && s.display['condition'] == condition,
          )
          .toList();
      final valid = all.where((s) => s.valid(e)).toList();
      final people = valid.map((s) => s.participantId).toSet();
      final unique = people.length == valid.length;
      final experts = valid
          .where((s) => s.participant['expert'] == true)
          .length;
      final imageStats = e.cases.where((c) => c.kind == 'main').map((c) {
        int correct = 0, judgments = 0;
        final viewers = <String>{};
        for (final s in valid) {
          for (int i = 0; i < s.answers.length; i++) {
            if (s.trials[i].caseId == c.id) {
              judgments++;
              viewers.add(s.participantId);
              if (s.answers[i]['choice'] == s.trials[i].correctChoice) {
                correct++;
              }
            }
          }
        }
        return {
          'caseId': c.id,
          'sequence': c.sequence,
          'view': c.view,
          'viewers': viewers.length,
          'judgments': judgments,
          'correct': correct,
          'rate': judgments == 0 ? null : correct / judgments,
        };
      }).toList();
      final sequences = protocolViews.keys.map((seq) {
        final rows = imageStats.where((r) => r['sequence'] == seq).toList();
        final n = rows.fold(0, (v, r) => v + (r['judgments'] as int));
        final k = rows.fold(0, (v, r) => v + (r['correct'] as int));
        return {
          'sequence': seq,
          'judgments': n,
          'correct': k,
          'rate': n == 0 ? null : k / n,
        };
      }).toList();
      final ready =
          unique &&
          people.length >= 15 &&
          experts * 3 <= people.length &&
          imageStats.every((r) => (r['viewers'] as int) >= 15) &&
          imageStats.map((r) => r['viewers']).toSet().length == 1;
      for (final row in [...imageStats, ...sequences]) {
        final rate = row['rate'] as double?;
        row['classification'] = e.isDemo
            ? '演示数据'
            : !ready || rate == null
            ? '尚不满足判定条件'
            : rate <= .5
            ? '完全无法区分'
            : rate <= .75
            ? '未明显察觉差异'
            : rate <= .9
            ? '可察觉明显差异'
            : '明显可区分';
        row['photoRealistic'] = e.isDemo || !ready || rate == null
            ? null
            : rate <= .75;
      }
      return {
        'condition': condition,
        'sessions': all.length,
        'validObservers': people.length,
        'experts': experts,
        'duplicateObservers': !unique,
        'ready': ready,
        'status': e.isDemo
            ? '演示数据，不作正式判定'
            : !ready
            ? '尚不满足判定条件'
            : sequences.every((r) => (r['rate'] as double) <= .75)
            ? '通过'
            : '未通过',
        'images': imageStats,
        'sequences': sequences,
      };
    }).toList(),
  };
}
