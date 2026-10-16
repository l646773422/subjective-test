import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/repository.dart';

Experiment fixture() {
  final zip = ZipDecoder().decodeBytes(
    File('assets/demo.study.zip').readAsBytesSync(),
  );
  return Experiment.fromJson(
    jsonDecode(utf8.decode(zip.findFile('experiment.json')!.content)),
  );
}

StudySession completed(
  Experiment e,
  int number, {
  String condition = 'PC',
  bool fail = false,
  bool expert = false,
}) {
  final trials = buildSchedule(e, number + 111);
  final session = StudySession(
    id: 'session_$number',
    experimentId: e.id,
    participantId: 'P$number',
    startedAt: '2026-10-16T01:00:00Z',
    seed: number + 111,
    participant: {
      'normalVision': true,
      'normalColorVision': true,
      'organizerOrDeveloper': false,
      'age': 26,
      'expert': expert,
    },
    display: {'condition': condition, 'platform': 'windows'},
    trials: trials,
  );
  for (final t in trials) {
    final control = e.caseById(t.caseId).kind == 'control';
    session.answers.add({
      'trialId': t.id,
      'choice': control ? (fail ? 3 - t.correctChoice : t.correctChoice) : 1,
      'responseMs': 240,
      'answeredAt': '2026-10-16T01:01:00Z',
    });
  }
  session.completedAt = '2026-10-16T01:15:00Z';
  return session;
}

void main() {
  late Experiment e;
  setUp(() => e = fixture());
  test('demo is explicitly marked and immutable manifest is verified', () {
    expect(e.isDemo, isTrue);
    expect(e.cases.length, 26);
    expect(
      () => Experiment.fromJson({...e.toJson(), 'imageMs': 4000}),
      throwsFormatException,
    );
  });
  test('each person receives both orders exactly once per main pair', () {
    for (int seed = 0; seed < 150; seed++) {
      final trials = buildSchedule(e, seed);
      expect(trials.length, 46);
      final main = trials
          .where((t) => e.caseById(t.caseId).kind == 'main')
          .toList();
      expect(main.length, 40);
      expect(main.where((t) => t.capturedFirst).length, 20);
      for (final c in e.cases.where((c) => c.kind == 'main')) {
        expect(
          main
              .where((t) => t.caseId == c.id)
              .map((t) => t.capturedFirst)
              .toSet(),
          {true, false},
        );
      }
      for (int i = 1; i < main.length; i++) {
        expect(main[i].caseId, isNot(main[i - 1].caseId));
      }
      final controls = trials
          .where((t) => e.caseById(t.caseId).kind == 'control')
          .toList();
      expect(controls.map((t) => t.capturedFirst).toSet(), {true, false});
      expect(e.caseById(trials[4].caseId).kind, 'control');
      expect(e.caseById(trials[25].caseId).kind, 'control');
    }
  });
  test('fixed seeds reproduce the identical schedule', () {
    final a = digestJson(
      buildSchedule(e, 3917).map((t) => t.toJson()).toList(),
    );
    final b = digestJson(
      buildSchedule(e, 3917).map((t) => t.toJson()).toList(),
    );
    final c = digestJson(
      buildSchedule(e, 3918).map((t) => t.toJson()).toList(),
    );
    expect(a, b);
    expect(a, isNot(c));
  });
  test('one failed control excludes the whole observer', () {
    final s = completed(e, 1);
    final index = s.trials.indexWhere(
      (t) => e.caseById(t.caseId).kind == 'control',
    );
    s.answers[index]['choice'] = 3 - s.trials[index].correctChoice;
    expect(s.controlCorrect(e), 1);
    expect(s.valid(e), isFalse);
    expect(s.status(e), '控制题未通过');
    expect(s.answers.length, 46);
  });
  test('repeated orders do not double the number of observers', () {
    final report = buildReport(e, [
      for (int i = 0; i < 8; i++) completed(e, i),
    ]);
    final group = records(report['conditions']).single;
    expect(group['validObservers'], 8);
    expect(group['ready'], isFalse);
    final row = records(group['images']).first;
    expect(row['viewers'], 8);
    expect(row['judgments'], 16);
  });
  test('15 valid nonexperts meet coverage with 50 percent identification', () {
    final group = records(
      buildReport(e, [
        for (int i = 0; i < 15; i++) completed(e, i),
      ])['conditions'],
    ).single;
    expect(group['ready'], isTrue);
    expect(records(group['sequences']).every((r) => r['rate'] == .5), isTrue);
    expect(group['status'], '演示数据，不作正式判定');
  });
  test('different viewing conditions are not pooled to reach 15', () {
    final sessions = [
      for (int i = 0; i < 8; i++) completed(e, i),
      for (int i = 8; i < 16; i++) completed(e, i, condition: 'Android'),
    ];
    final groups = records(buildReport(e, sessions)['conditions']);
    expect(groups.length, 2);
    expect(groups.every((r) => r['ready'] == false), isTrue);
  });
  test('expert ratio and duplicate observers prevent final judgment', () {
    final manyExperts = [
      for (int i = 0; i < 15; i++) completed(e, i, expert: i < 6),
    ];
    expect(
      records(buildReport(e, manyExperts)['conditions']).single['ready'],
      false,
    );
    final duplicates = [
      for (int i = 0; i < 15; i++) completed(e, i),
      completed(e, 0),
    ];
    expect(
      records(
        buildReport(e, duplicates)['conditions'],
      ).single['duplicateObservers'],
      true,
    );
  });
  test('incomplete and ineligible sessions are retained but excluded', () {
    final a = completed(e, 1)..completedAt = null;
    final b = completed(e, 2);
    b.participant['organizerOrDeveloper'] = true;
    expect(a.valid(e), false);
    expect(b.valid(e), false);
    expect(
      records(buildReport(e, [a, b])['conditions']).single['validObservers'],
      0,
    );
  });
  test('results reject substituted schedules or illegal choices', () {
    final s = completed(e, 1);
    s.validate(e);
    s.answers.first['choice'] = 0;
    expect(() => s.validate(e), throwsFormatException);
    final other = completed(e, 2);
    other.trials[0] = Trial('forged', other.trials[0].caseId, true);
    expect(() => other.validate(e), throwsFormatException);
  });
  test(
    'imported observer metadata must retain its typed eligibility fields',
    () {
      final s = completed(e, 1);
      s.participant['expert'] = 'no';
      expect(() => s.validate(e), throwsFormatException);
    },
  );
  test('maximum iteration uses numeric comparison', () {
    expect(
      highestIteration([
        Directory('ours_900'),
        Directory('ours_10000'),
        Directory('ours_30000'),
        Directory('ours_invalid'),
      ])!.path,
      'ours_30000',
    );
  });
  test(
    'formal classification and the inclusive 75 percent threshold follow the protocol',
    () {
      final formal = Experiment.freeze(
        name: 'Statistical fixture only',
        demo: false,
        seed: 3917,
        cases: e.cases
            .map(
              (c) => c.kind != 'main'
                  ? c
                  : StudyCase.fromJson({
                      ...c.toJson(),
                      'width': c.sequence == 'Show_Groups_4K' ? 3840 : 1920,
                      'height': c.sequence == 'Show_Groups_4K' ? 2160 : 1080,
                    }),
            )
            .toList(),
      );
      List<StudySession> cohort(List<double> rates) {
        final people = [for (int i = 0; i < 15; i++) completed(formal, i)];
        for (final entry in protocolViews.entries.indexed) {
          final answers = <(StudySession, int)>[];
          for (final person in people) {
            for (int i = 0; i < person.trials.length; i++) {
              final c = formal.caseById(person.trials[i].caseId);
              if (c.kind == 'main' && c.sequence == entry.$2.key) {
                answers.add((person, i));
              }
            }
          }
          final correct = (answers.length * rates[entry.$1]).round();
          for (int j = 0; j < answers.length; j++) {
            final person = answers[j].$1, i = answers[j].$2;
            person.answers[i]['choice'] = j < correct
                ? person.trials[i].correctChoice
                : 3 - person.trials[i].correctChoice;
          }
        }
        return people;
      }

      final atBoundary = records(
        buildReport(formal, cohort([.75, .75, .75, .75]))['conditions'],
      ).single;
      expect(atBoundary['ready'], true);
      expect(atBoundary['status'], '通过');
      final graded = records(
        buildReport(formal, cohort([.5, .75, .9, 1]))['conditions'],
      ).single;
      expect(graded['status'], '未通过');
      expect(
        records(graded['sequences']).map((r) => r['classification']).toList(),
        ['完全无法区分', '未明显察觉差异', '可察觉明显差异', '明显可区分'],
      );
    },
  );
}
