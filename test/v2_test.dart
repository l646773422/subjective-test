import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/repository.dart';
import 'package:subjective_study/study_templates.dart';

StudySession sessionFor(
  Experiment e, {
  int seed = 117,
  String person = 'P1',
  bool complete = true,
  bool failControls = false,
}) {
  final s = StudySession(
    id: uuid(),
    schema: 2,
    studyId: e.studyId,
    experimentId: e.id,
    schedulerVersion: e.release!['implementations']['scheduler'] as String,
    participantId: person,
    startedAt: '2026-10-16T01:00:00Z',
    seed: seed,
    participant: e.definition!.profile == null
        ? {}
        : {
            'age': 26,
            'expert': false,
            'normalVision': true,
            'normalColorVision': true,
            'independent': true,
          },
    display: {
      'conditionId': 'lab',
      'condition': '实验室',
      'device': 'test',
      'distanceCm': 60,
    },
    trials: buildSchedule(e, seed),
  );
  for (final t in s.trials) {
    final c = e.caseById(t.caseId);
    final alternative = c.kind == 'control'
        ? (failControls ? (c.answer == 'a' ? 'b' : 'a') : c.answer!)
        : t.order.first;
    s.answers.add({
      'trialId': t.id,
      'selectedAlternative': alternative,
      'selectedPosition': t.order.indexOf(alternative) + 1,
      'responseMs': 123,
      'answeredAt': '2026-10-16T01:01:00Z',
    });
  }
  if (complete) s.completedAt = '2026-10-16T01:15:00Z';
  return s;
}

void main() {
  late Directory temp;
  late StudyRepository repo;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('subjective-v2-test-');
    repo = StudyRepository(temp);
    await repo.initializeV2();
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test(
    'case-only image aliases are rejected before creating nonportable packages',
    () {
      final source = {
        'schema': 2,
        'studyId': 'case-test',
        'name': 'case test',
        'method': '2afc',
        'question': 'choose',
        'items': [
          {'id': 'one', 'a': 'images/a.png', 'b': 'images/A.png'},
        ],
      };
      expect(
        () => StudyDefinition.fromJson(source),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('大小写'),
          ),
        ),
      );
    },
  );

  test(
    'Dart normalization agrees with the shared Python contract fixture',
    () async {
      final source = jsonMap(
        jsonDecode(await File('examples/study-v2/study.json').readAsString()),
        'study',
      );
      final expected = jsonDecode(
        await File('test/fixtures/v2-expanded.json').readAsString(),
      );
      expect(StudyDefinition.fromJson(source).toJson(), expected);
    },
  );

  Future<StudyDraft> source({
    String id = 'arbitrary-study',
    List<Map<String, dynamic>>? items,
    Map<String, dynamic>? schedule,
    String metric = 'selection_rate',
  }) async {
    final root = await Directory(p.join(temp.path, 'source-$id')).create();
    final a = File(p.join(root.path, '任意子目录', 'first.png'));
    final b = File(p.join(root.path, 'other', 'second.png'));
    await a.parent.create();
    await b.parent.create();
    await File('examples/study-v2/images/a.png').copy(a.path);
    await b.writeAsBytes(img.encodePng(img.Image(width: 240, height: 180)));
    final definition = {
      'schema': 2,
      'studyId': id,
      'name': '任意图片实验',
      'method': '2afc',
      'question': '你更喜欢哪一幅？',
      'presentation': {'promptMs': 0, 'imageMs': 1},
      'schedule': ?schedule,
      'analysis': {'metric': metric},
      'items':
          items ??
          [
            {'id': 'one', 'a': '任意子目录/first.png', 'b': 'other/second.png'},
          ],
    };
    await File(
      p.join(root.path, 'study.json'),
    ).writeAsString('\uFEFF${jsonEncode(definition)}');
    return repo.importSourceDirectory(root);
  }

  test(
    'minimal arbitrary layout publishes with unequal image dimensions and no controls',
    () async {
      final draft = await source();
      final restored = (await repo.drafts()).single;
      expect(restored.definition.toJson(), draft.definition.toJson());
      final e = await repo.publishDraft(restored);
      expect(e.isV2, true);
      expect(e.cases.single.width, 960);
      expect(e.cases.single.bWidth, 240);
      expect(buildSchedule(e, 0).length, 1);
      expect(() => e.release!['createdAt'] = 'changed', throwsUnsupportedError);
      expect(() => e.cases.clear(), throwsUnsupportedError);
      await repo.verify(e);
      final s = sessionFor(e);
      s.validate(e);
      expect(s.valid(e), true);
      final group = records(buildReport(e, [s])['conditions']).single;
      expect(group['validObservers'], 1);
      expect(group['controlCheck'], '未配置控制检查');
      expect(group['status'], '描述性统计');
      expect(group['sequences'], isEmpty);
      expect(
        records(group['images']).single.containsKey('photoRealistic'),
        false,
      );
    },
  );

  test(
    'versions freeze rules and image hashes while external materials stay separate',
    () async {
      final d = await source();
      final first = await repo.publishDraft(d);
      final updated = d.definition.toJson()..['question'] = '第二个问题';
      final second = await repo.publishDraft(await repo.saveDraft(updated));
      expect(first.id, isNot(second.id));
      expect(first.studyId, second.studyId);
      expect(first.question, '你更喜欢哪一幅？');
      expect(second.question, '第二个问题');
      expect(
        await File(
          '${repo.revisionDir(first.id).path}/${d.definition.items.first['a']}',
        ).exists(),
        false,
      );
      final relative = d.definition.items.first['a'] as String;
      expect(await repo.verifiedImageData(first, relative), isNotEmpty);
      await repo.imageFile(first, relative).writeAsBytes([0]);
      await repo.verify(first);
      await repo.verify(second);
      await expectLater(
        repo.verifiedImageData(first, relative),
        throwsFormatException,
      );
      expect((await repo.experiments()).length, 2);
    },
  );

  test(
    'publish package round-trips its exact manifest bytes and rejects substitution',
    () async {
      final e = await repo.publishDraft(await source());
      final bytes = await repo.exportPackage(e);
      final other = StudyRepository(
        await Directory('${temp.path}/other').create(),
      );
      final imported = (await other.importStudyZip(bytes)).experiment!;
      expect(imported.id, e.id);
      expect(imported.toJson(), e.toJson());
      expect((await other.importStudyZip(bytes)).experiment!.id, e.id);
      final archive = ZipDecoder().decodeBytes(bytes);
      final def = archive.findFile('study.json')!;
      final changed = jsonMap(jsonDecode(utf8.decode(def.content)), 'study')
        ..['question'] = '被替换';
      final replacement = Archive();
      for (final entry in archive) {
        final data = entry.name == 'study.json'
            ? utf8.encode(jsonEncode(changed))
            : entry.content;
        replacement.addFile(ArchiveFile(entry.name, data.length, data));
      }
      await expectLater(
        other.importStudyZip(
          Uint8List.fromList(ZipEncoder().encode(replacement)),
        ),
        throwsFormatException,
      );
      await expectLater(other.verify(imported), throwsFormatException);
      await other.loadMaterialDirectory(imported, repo.materialRoot(e));
      await other.verify(imported);
    },
  );

  test(
    'source ZIP becomes a draft and a release directory stays a release',
    () async {
      final data = await File('assets/generic.demo.zip').readAsBytes();
      final d = (await repo.importStudyZip(data)).draft!;
      expect(d.definition.isDemo, true);
      final e = await repo.publishDraft(d);
      final other = StudyRepository(
        await Directory('${temp.path}/directory-device').create(),
      );
      final imported = await other.importStudyDirectory(repo.revisionDir(e.id));
      expect(imported.draft, isNull);
      expect(imported.experiment!.id, e.id);
    },
  );

  test(
    'randomization balances identities and repetitions, including control placement',
    () async {
      final d = await source(
        schedule: {
          'repetitions': 4,
          'pairOrder': 'balanced',
          'avoidAdjacentRepeats': true,
        },
        items: [
          for (int i = 0; i < 3; i++)
            {'id': 'pair$i', 'a': '任意子目录/first.png', 'b': 'other/second.png'},
          for (int i = 0; i < 2; i++)
            {
              'id': 'check$i',
              'role': 'control',
              'answer': 'b',
              'a': '任意子目录/first.png',
              'b': 'other/second.png',
            },
        ],
      );
      final e = await repo.publishDraft(d);
      final golden = jsonDecode(
        await File('test/fixtures/v2-schedule-117.json').readAsString(),
      );
      expect(buildSchedule(e, 117).map((t) => t.toJson()).toList(), golden);
      for (int seed = 0; seed < 150; seed++) {
        final schedule = buildSchedule(e, seed);
        expect(schedule.length, 14);
        final main = schedule.where((t) => t.role == 'main').toList();
        for (int i = 0; i < 3; i++) {
          final trials = main.where((t) => t.caseId == 'pair$i').toList();
          expect(trials.where((t) => t.capturedFirst).length, 2);
          expect(trials.map((t) => t.repetition).toSet(), {1, 2, 3, 4});
        }
        for (int i = 1; i < main.length; i++) {
          expect(main[i].caseId, isNot(main[i - 1].caseId));
        }
        expect(schedule[0].role, 'control');
        expect(schedule[7].role, 'control');
      }
      final valid = sessionFor(e);
      valid.validate(e);
      expect(valid.controlCorrect(e), 2);
      expect(sessionFor(e, failControls: true).valid(e), false);
    },
  );

  test(
    'answers preserve selected identity and position, serialization and merging',
    () async {
      final e = await repo.publishDraft(await source());
      final s = sessionFor(e);
      final t = s.trials.single;
      s.answers.single['selectedAlternative'] = 'a';
      s.answers.single['selectedPosition'] = t.order.indexOf('a') + 1;
      s.validate(e);
      await repo.save(s);
      final saved = (await repo.sessions(e)).single;
      expect(saved.toJson(), s.toJson());
      final export = repo.resultsJson(e, [s]);
      expect(await repo.mergeResults(e, export), 0);
      expect(
        utf8.decode(repo.resultsCsv(e, [s])),
        contains('selected_alternative'),
      );
      final other = StudyRepository(
        await Directory('${temp.path}/results-device').create(),
      );
      await other.importStudyZip(await repo.exportPackage(e));
      expect(await other.mergeResults(e, export), 1);
      expect(await other.mergeResults(e, export), 0);
      s.answers.single['selectedPosition'] =
          3 - (s.answers.single['selectedPosition'] as int);
      expect(() => s.validate(e), throwsFormatException);
    },
  );

  test('results never merge across revisions of the same study', () async {
    final d = await source();
    final first = await repo.publishDraft(d),
        second = await repo.publishDraft(d);
    await expectLater(
      repo.mergeResults(second, repo.resultsJson(first, [sessionFor(first)])),
      throwsFormatException,
    );
  });

  test(
    'unsupported implementations, impossible schedules and unknown fields fail explicitly',
    () async {
      final d = await source();
      final e = await repo.publishDraft(d);
      final release = jsonMap(jsonDecode(jsonEncode(e.release)), 'release');
      release['implementations']['scheduler'] = 'future@99';
      expect(
        () => Experiment.fromRelease(e.definition!.toJson(), release),
        throwsFormatException,
      );
      final sourceData = d.definition.toJson();
      sourceData['scheudle'] = {};
      expect(() => StudyDefinition.fromJson(sourceData), throwsFormatException);
      sourceData.remove('scheudle');
      sourceData['schedule'] = {'repetitions': 2, 'avoidAdjacentRepeats': true};
      expect(() => StudyDefinition.fromJson(sourceData), throwsFormatException);
      sourceData['schedule'] = {'pairOrder': 'balanced', 'repetitions': 1};
      expect(() => StudyDefinition.fromJson(sourceData), throwsFormatException);
    },
  );

  test(
    'corrupt records and unrelated unsupported sessions are isolated',
    () async {
      final e = await repo.publishDraft(await source());
      final s = sessionFor(e);
      await repo.save(s);
      await Directory('${temp.path}/experiments/broken').create();
      await File(
        '${temp.path}/experiments/broken/experiment.json',
      ).writeAsString('{');
      await File('${temp.path}/sessions/broken.json').writeAsString('{');
      await File(
        '${temp.path}/sessions/unrelated.json',
      ).writeAsString('{"schema":99,"experimentId":"other"}');
      expect((await repo.experiments()).single.id, e.id);
      expect((await repo.sessions(e)).single.id, s.id);
      expect(repo.issues.length, 2);
    },
  );

  test(
    'real archived schema-1 session retains schedule, raw serialization and old report',
    () async {
      final e = await repo.importZip(
        await File('assets/demo.study.zip').readAsBytes(),
      );
      final archived = jsonMap(
        jsonDecode(
          await File('test/fixtures/legacy-session.json').readAsString(),
        ),
        'session',
      );
      final s = StudySession.fromJson(archived);
      s.validate(e);
      expect(s.toJson(), archived);
      expect(
        buildSchedule(e, s.seed).map((t) => t.toJson()).toList(),
        archived['trials'],
      );
      final group = records(buildReport(e, [s])['conditions']).single;
      expect(group['validObservers'], 1);
      expect(records(group['sequences']).every((r) => r['rate'] == .5), true);
      await repo.save(s);
      expect((await repo.sessions(e)).single.toJson(), archived);
    },
  );

  test(
    'legacy experiment forks to the explicit v2 photorealism template',
    () async {
      final legacy = await repo.importZip(
        await File('assets/demo.study.zip').readAsBytes(),
      );
      final draft = await repo.forkDefinition(legacy);
      expect(draft.definition.profile!['minObserversPerItem'], 15);
      final e = await repo.publishDraft(draft);
      expect(buildSchedule(e, 0).length, 46);
      final cohort = [
        for (int i = 0; i < 15; i++) sessionFor(e, person: 'P$i', seed: i),
      ];
      for (final s in cohort) {
        s.validate(e);
      }
      final group = records(buildReport(e, cohort)['conditions']).single;
      expect(group['ready'], true);
      expect(group['status'], '演示数据，不作正式判定');
      expect(records(group['sequences']).every((r) => r['rate'] == .5), true);
      cohort.first.participant['independent'] = false;
      expect(cohort.first.valid(e), false);
      expect((await repo.sessions(legacy)), isEmpty);
    },
  );

  test(
    'template is explicit data and generic experiments have no imposed participant fields',
    () {
      final basic = StudyDefinition.fromJson(
        newStudySource('basic'),
        draft: true,
      );
      basic.validateParticipant({});
      expect(basic.participantFields, isEmpty);
      final photo = StudyDefinition.fromJson(
        newStudySource('photo', photorealism: true),
        draft: true,
      );
      expect(photo.participantFields.length, 5);
      expect(() => photo.validateParticipant({}), throwsFormatException);
    },
  );
}
