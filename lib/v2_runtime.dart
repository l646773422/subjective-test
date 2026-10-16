part of 'domain.dart';

List<Trial> buildV2Schedule(Experiment e, int seed) {
  final d = e.definition!, cfg = d.schedule, random = StableRandom(seed);
  List<StudyCase> ordered(Iterable<StudyCase> items) {
    final result = items.toList();
    if (cfg['itemOrder'] == 'random') result.permute(random);
    return result;
  }

  Trial make(StudyCase item, int repetition, bool aFirst) => Trial(
    '${item.id}:$repetition',
    item.id,
    aFirst,
    role: item.kind,
    repetition: repetition,
  );
  final practice = ordered(e.cases.where((c) => c.kind == 'practice'));
  final practiceTrials = [
    for (final (i, c) in practice.indexed)
      make(
        c,
        1,
        cfg['practicePairOrder'] == 'alternating'
            ? i.isEven
            : random.nextBool(),
      ),
  ];
  final blocks = <String, List<StudyCase>>{};
  for (final item in e.cases.where((c) => c.kind == 'main')) {
    blocks
        .putIfAbsent(cfg['blockByGroup'] == true ? item.sequence : '', () => [])
        .add(item);
  }
  final groups = blocks.keys.toList();
  if (cfg['itemOrder'] == 'random') groups.permute(random);
  final main = <Trial>[];
  for (final group in groups) {
    final firstOrder = {
      for (final c in blocks[group]!) c.id: random.nextBool(),
    };
    for (int round = 1; round <= (cfg['repetitions'] as int); round++) {
      final items = ordered(blocks[group]!);
      if (cfg['avoidAdjacentRepeats'] == true &&
          main.isNotEmpty &&
          items.first.id == main.last.caseId) {
        check(
          cfg['itemOrder'] == 'random' && items.length > 1,
          '无法在清单顺序下避免相邻重复',
        );
        final second = items[1];
        items[1] = items[0];
        items[0] = second;
      }
      for (final c in items) {
        main.add(
          make(
            c,
            round,
            cfg['pairOrder'] == 'balanced'
                ? (round.isOdd ? firstOrder[c.id]! : !firstOrder[c.id]!)
                : random.nextBool(),
          ),
        );
      }
    }
  }
  final controls = ordered(e.cases.where((c) => c.kind == 'control'));
  final controlFirst = random.nextBool();
  final result = [...practiceTrials];
  int controlIndex = 0;
  for (int i = 0; i < main.length; i++) {
    while (controlIndex < controls.length &&
        controlIndex * main.length ~/ controls.length == i) {
      result.add(
        make(
          controls[controlIndex],
          1,
          cfg['controlPairOrder'] == 'balanced'
              ? (controlIndex.isEven ? controlFirst : !controlFirst)
              : random.nextBool(),
        ),
      );
      controlIndex++;
    }
    result.add(main[i]);
  }
  return result;
}

void validatePhotorealism(Experiment e) {
  final d = e.definition!, p = d.profile!, s = d.schedule;
  final main = e.cases.where((c) => c.kind == 'main').toList();
  final practice = e.cases.where((c) => c.kind == 'practice').toList();
  check(
    practice.length >= (p['practiceMin'] as int) &&
        practice.length <= (p['practiceMax'] as int),
    '真实感模板的练习题数量不符合方案',
  );
  check(
    e.cases.where((c) => c.kind == 'control').length == p['controlCount'],
    '真实感模板的控制题数量不符合方案',
  );
  check(
    s['repetitions'] == 2 &&
        s['pairOrder'] == 'balanced' &&
        s['blockByGroup'] == true &&
        s['avoidAdjacentRepeats'] == true &&
        s['controlPairOrder'] == 'balanced' &&
        d.quality['minControlAccuracy'] == 1,
    '真实感模板需要两轮、分组、次序平衡及控制题全对',
  );
  check(
    e.promptMs >= 1000 &&
        e.promptMs <= 3000 &&
        e.imageMs >= 3000 &&
        e.imageMs <= 5000,
    '真实感模板的呈现时间不符合方案',
  );
  final views = jsonMap(p['sequenceViews'], 'sequenceViews');
  check(
    main.length == views.values.fold<int>(0, (n, v) => n + (v as List).length),
    '真实感模板的正式题数量不符',
  );
  for (final entry in views.entries) {
    final group = main.where((c) => c.sequence == entry.key).toList();
    final expected = (entry.value as List).cast<int>();
    check(
      group.length == expected.length &&
          group.every((c) => c.frame >= 0) &&
          group.map((c) => c.view).toSet().containsAll(expected) &&
          group.map((c) => c.view).toSet().length == expected.length &&
          group.map((c) => c.frame).toSet().length == 1,
      '真实感模板的 ${entry.key} 帧或视点覆盖不完整，请在 metadata 填写 frame/view',
    );
    final resolution = (p['resolutions'] as Map)[entry.key] as List;
    check(
      e.isDemo ||
          group.every(
            (c) =>
                c.width == resolution[0] &&
                c.height == resolution[1] &&
                c.bWidth == resolution[0] &&
                c.bHeight == resolution[1],
          ),
      '${entry.key} 分辨率不符合真实感模板',
    );
  }
  check(
    e.cases.every(
      (c) => c.answer == 'a' && c.width == c.bWidth && c.height == c.bHeight,
    ),
    '真实感模板要求 a 为真实拍摄图，且两图尺寸一致',
  );
  final hashes = main.expand((c) => [c.gtHash, c.renderHash]).toSet();
  check(
    practice.every(
      (c) => !hashes.contains(c.gtHash) && !hashes.contains(c.renderHash),
    ),
    '练习图片不能与正式图片相同',
  );
}

void validateV2Session(StudySession s, Experiment e) {
  check(
    s.schema == 2 &&
        s.studyId == e.studyId &&
        s.experimentId == e.id &&
        s.schedulerVersion == e.release!['implementations']['scheduler'],
    '会话与发布版本不符',
  );
  check(
    RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(s.id) &&
        nonEmpty(s.participantId) &&
        nonEmpty(s.display['conditionId']) &&
        nonEmpty(s.display['condition']) &&
        DateTime.tryParse(s.startedAt) != null &&
        s.seed >= 0 &&
        s.seed <= 0xffffffff,
    '会话身份、条件、种子或时间无效',
  );
  e.definition!.validateParticipant(s.participant);
  if (e.definition!.profile != null) {
    check(
      nonEmpty(s.display['device']) &&
          s.display['distanceCm'] is num &&
          (s.display['distanceCm'] as num).isFinite &&
          (s.display['distanceCm'] as num) > 0,
      '真实感会话缺少有效设备和观看距离',
    );
  }
  check(
    digestJson(s.trials.map((t) => t.toJson()).toList()) ==
        digestJson(buildSchedule(e, s.seed).map((t) => t.toJson()).toList()),
    '实际排程与执行版本不符',
  );
  check(
    s.answers.length <= s.trials.length &&
        (s.completedAt == null ||
            (DateTime.tryParse(s.completedAt!) != null &&
                s.answers.length == s.trials.length)),
    '会话完成状态无效',
  );
  for (int i = 0; i < s.answers.length; i++) {
    final a = s.answers[i], t = s.trials[i];
    final position = a['selectedPosition'];
    check(
      a['trialId'] == t.id &&
          [1, 2].contains(position) &&
          a['selectedAlternative'] == t.selected(position as int) &&
          a['responseMs'] is int &&
          (a['responseMs'] as int) >= 0 &&
          DateTime.tryParse(a['answeredAt'] as String? ?? '') != null,
      '答案存在缺失、重复或素材与位置不匹配',
    );
  }
}

bool v2Eligible(StudySession s, Experiment e) =>
    (e.definition!.quality['requiredTrue'] as List).every(
      (key) => s.participant[key] == true,
    );
bool v2ControlsPass(StudySession s, Experiment e) {
  final count = e.cases.where((c) => c.kind == 'control').length;
  return count == 0 ||
      s.controlCorrect(e) / count >=
          (e.definition!.quality['minControlAccuracy'] as num);
}

Map<String, dynamic> buildV2Report(Experiment e, List<StudySession> input) {
  final sessions = input.where((s) => s.experimentId == e.id).toList();
  final conditions =
      sessions.map((s) => s.display['conditionId'] as String).toSet().toList()
        ..sort();
  final metric = e.definition!.analysis['metric'];
  final profile = e.definition!.profile;
  return {
    'schema': 2,
    'studyId': e.studyId,
    'revisionId': e.id,
    'experimentName': e.name,
    'isDemo': e.isDemo,
    'metric': metric,
    'analysisVersion': e.release!['implementations']['analysis'],
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'conditions': conditions.map((condition) {
      final all = sessions
          .where((s) => s.display['conditionId'] == condition)
          .toList();
      final valid = all.where((s) => s.valid(e)).toList();
      final unique = <String, StudySession>{};
      for (final s in valid) {
        unique.putIfAbsent(s.participantId, () => s);
      }
      final people = unique.values.toList();
      final duplicate = people.length != valid.length;
      final experts = people
          .where((s) => s.participant['expert'] == true)
          .length;
      final rows = <Map<String, dynamic>>[];
      for (final c in e.cases.where((c) => c.kind == 'main')) {
        int aCount = 0, bCount = 0, correct = 0;
        final viewers = <String>{};
        for (final s in people) {
          for (int i = 0; i < s.answers.length; i++) {
            if (s.trials[i].caseId != c.id) continue;
            viewers.add(s.participantId);
            if (s.answers[i]['selectedAlternative'] == 'a') {
              aCount++;
            } else {
              bCount++;
            }
            if (c.answer != null &&
                s.answers[i]['selectedAlternative'] == c.answer) {
              correct++;
            }
          }
        }
        final n = aCount + bCount;
        rows.add({
          'caseId': c.id,
          'sequence': c.sequence,
          'view': c.view,
          'viewers': viewers.length,
          'judgments': n,
          'a': aCount,
          'b': bCount,
          'correct': c.answer == null ? null : correct,
          'rate': n == 0
              ? null
              : (metric == 'accuracy' ? correct / n : aCount / n),
        });
      }
      final sequences = <Map<String, dynamic>>[];
      if (metric == 'accuracy') {
        for (final group in rows.map((r) => r['sequence'] as String).toSet()) {
          final grouped = rows.where((r) => r['sequence'] == group);
          final n = grouped.fold(0, (v, r) => v + (r['judgments'] as int));
          final k = grouped.fold(0, (v, r) => v + (r['correct'] as int));
          sequences.add({
            'sequence': group.isEmpty ? '未分组' : group,
            'judgments': n,
            'correct': k,
            'rate': n == 0 ? null : k / n,
          });
        }
      }
      bool ready = !duplicate && people.isNotEmpty;
      if (profile != null) {
        final minimum = profile['minObserversPerItem'] as int;
        ready =
            ready &&
            people.length >= minimum &&
            experts * (profile['expertDenominator'] as int) <=
                people.length * (profile['expertNumerator'] as int) &&
            rows.every((r) => (r['viewers'] as int) >= minimum) &&
            (profile['equalCoverage'] != true ||
                rows.map((r) => r['viewers']).toSet().length == 1);
        for (final row in [...rows, ...sequences]) {
          final rate = row['rate'] as double?;
          row['classification'] = e.isDemo
              ? '演示数据'
              : !ready || rate == null
              ? '尚不满足判定条件'
              : rate <= .5
              ? '完全无法区分'
              : rate <= (profile['maxSequenceAccuracy'] as num)
              ? '未明显察觉差异'
              : rate <= .9
              ? '可察觉明显差异'
              : '明显可区分';
          row['photoRealistic'] = e.isDemo || !ready || rate == null
              ? null
              : rate <= (profile['maxSequenceAccuracy'] as num);
        }
      }
      return {
        'conditionId': condition,
        'condition': all.first.display['condition'],
        'sessions': all.length,
        'completedSessions': all.where((s) => s.complete).length,
        'validObservers': people.length,
        'experts': experts,
        'duplicateObservers': duplicate,
        'ready': ready,
        'controlCheck': e.cases.any((c) => c.kind == 'control')
            ? '已配置控制检查'
            : '未配置控制检查',
        'status': e.isDemo
            ? '演示数据，不作正式判定'
            : duplicate
            ? '存在重复参与者'
            : profile == null
            ? '描述性统计'
            : !ready
            ? '尚不满足判定条件'
            : sequences.every(
                (r) =>
                    (r['rate'] as num) <=
                    (profile['maxSequenceAccuracy'] as num),
              )
            ? '通过'
            : '未通过',
        'excluded': all
            .where((s) => !s.valid(e))
            .map((s) => {'sessionId': s.id, 'reason': s.status(e)})
            .toList(),
        'images': rows,
        'sequences': sequences,
      };
    }).toList(),
  };
}
