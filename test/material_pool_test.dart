import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/repository.dart';
import 'package:subjective_study/study_templates.dart';

Map<String, dynamic> tree({bool android = false}) => {
  'root': android ? 'content://test/tree/materials' : Directory.current.path,
  'entries': <Map<String, dynamic>>[
    for (final e in protocolViews.entries)
      for (int f = 0; f < 30; f++)
        for (int v = 0; v < e.value.length; v++)
          for (final side in ['gt', 'renders'])
            {
              'path':
                  '${e.key}_0.001_1.0_renders/frame${f.toString().padLeft(6, '0')}/test/primitive/$side/${v.toString().padLeft(5, '0')}.png',
              'bytes': 0,
              if (android)
                'uri': 'content://test/document/${e.key}-$f-$v-$side',
            },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late StudyRepository repo;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('material-pool-');
    repo = StudyRepository(temp);
    await repo.initializeV2();
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test(
    'every participant samples frame and viewpoint from the full pool; resume is deterministic',
    () async {
      final draft = await repo.createRenderPool(tree()),
          e = await repo.publishDraft(draft);
      expect(e.cases.length, 600);
      expect(e.definition!.trialCount, 40);
      final fingerprints = <String>{},
          views = <String, Set<int>>{},
          frames = <String, Set<int>>{};
      for (int seed = 1; seed <= 120; seed++) {
        final trials = buildSchedule(e, seed);
        expect(trials.length, 40);
        expect(trials.map((t) => t.caseId).toSet().length, 20);
        expect(
          trials.map((t) => t.toJson()).toList(),
          buildSchedule(e, seed).map((t) => t.toJson()).toList(),
        );
        fingerprints.add(trials.map((t) => t.caseId).join(','));
        for (final entry in protocolViews.entries) {
          final selected = trials
              .map((t) => e.caseById(t.caseId))
              .where((c) => c.sequence == entry.key)
              .toSet();
          expect(selected.length, entry.value.length);
          frames
              .putIfAbsent(entry.key, () => {})
              .addAll(selected.map((c) => c.frame));
          views
              .putIfAbsent(entry.key, () => {})
              .addAll(selected.map((c) => c.view));
          for (final c in selected) {
            final pair = trials.where((t) => t.caseId == c.id).toList();
            expect(pair.length, 2);
            expect(pair.first.capturedFirst, !pair.last.capturedFirst);
            expect(pair.first.sample!['frame'], c.frame);
          }
        }
        for (int i = 1; i < trials.length; i++) {
          expect(trials[i].caseId, isNot(trials[i - 1].caseId));
        }
      }
      expect(fingerprints.length, 120);
      for (final entry in protocolViews.entries) {
        expect(frames[entry.key]!.length, 30);
        expect(views[entry.key], entry.value.toSet());
      }
    },
  );

  test(
    'metadata-only package needs an independent material binding and keeps Android URIs local',
    () async {
      final draft = await repo.createRenderPool(tree(android: true)),
          e = await repo.publishDraft(draft);
      final bytes = await repo.exportPackage(e),
          zip = ZipDecoder().decodeBytes(bytes);
      expect(zip.files.map((f) => f.name).toSet(), {
        'study.json',
        'release.json',
      });
      for (final entry in zip.files) {
        expect(utf8.decode(entry.content), isNot(contains('content://test')));
      }
      final other = StudyRepository(Directory('${temp.path}/other'));
      final imported = (await other.importStudyZip(bytes)).experiment!;
      await expectLater(other.verify(imported), throwsFormatException);
      await other.loadMaterialTree(imported, tree(android: true));
      await other.verify(imported);
      expect(imported.toJson(), e.toJson());
      final actual = Uint8List.fromList([1, 2, 3]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('cn.pcnl.study/platform'),
            (call) async {
              expect(call.method, 'readMaterial');
              return actual;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('cn.pcnl.study/platform'),
              null,
            ),
      );
      final path = e.cases.first.gt;
      expect(await other.materialBytes(other.revisionDir(e.id), path), actual);
      expect(
        await File('${other.revisionDir(e.id).path}/$path').exists(),
        false,
      );
    },
  );

  test(
    'an incomplete pair or duplicate export for one sequence is refused',
    () async {
      final broken = tree();
      (broken['entries'] as List).removeLast();
      await expectLater(repo.createRenderPool(broken), throwsFormatException);
      final duplicate = tree();
      final entry = Map<String, dynamic>.from(
        (duplicate['entries'] as List).first as Map,
      );
      entry['path'] = (entry['path'] as String).replaceFirst(
        '_0.001_1.0_renders',
        '_other_renders',
      );
      (duplicate['entries'] as List).add(entry);
      await expectLater(
        repo.createRenderPool(duplicate),
        throwsFormatException,
      );
    },
  );

  test(
    'reloading the same pool reuses its identity and preserves edited rules',
    () async {
      final first = await repo.createRenderPool(tree());
      await repo.saveDraft(
        first.definition.toJson()..['question'] = '保留修改后的问题',
      );
      final moved = tree()..['root'] = temp.absolute.path;
      final second = await repo.createRenderPool(moved);
      expect(second.id, first.id);
      expect(second.definition.question, '保留修改后的问题');
      expect((await repo.drafts()).length, 1);
    },
  );

  test(
    'new photo template samples per participant and legacy template stays fixed',
    () {
      final modern = newStudySource('modern', photorealism: true),
          old = newStudySource(
            'old',
            photorealism: true,
            legacyPhotorealism: true,
          );
      expect((modern['analysis'] as Map)['profile']['version'], 2);
      expect(modern['sampling'], isNotNull);
      expect((old['analysis'] as Map)['profile']['version'], 1);
      expect(old.containsKey('sampling'), false);
    },
  );
}
