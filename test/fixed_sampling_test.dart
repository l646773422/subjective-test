import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/quick_test_panel.dart';
import 'package:subjective_study/quick_test_settings.dart';
import 'package:subjective_study/repository.dart';
import 'material_pool_test.dart' show tree;
import 'support/stereo_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'fixed six-pair content and order survive participant seeds, repetitions, disk restore and revisions',
    () async {
      final temp = await Directory.systemTemp.createTemp('fixed-sampling-');
      addTearDown(() => temp.delete(recursive: true));
      final repo = StudyRepository(Directory('${temp.path}/repo'));
      final draft = await stereoFixture(
        repo,
        Directory('${temp.path}/source'),
        packed: true,
      );
      final model = QuickTestSettings(draft.definition)..setFixedSampling(true);
      const text = '3,2\n0,1\n2,0\n1,2\n0,2\n3,0';
      model.counts['scene'] = 6;
      model.fixedIds['scene'] = model.resolveFixed('scene', text, 6);
      final e = await repo.prepareQuickTest(
        draft,
        model.definition({'scene': '6'}),
      );
      final ids = model.fixedIds['scene']!;
      expect(e.definition!.schedulerVersion, '2afc-schedule@6');
      final crops = <String>{}, firstOrders = <bool>{};
      for (int seed = 1; seed <= 40; seed++) {
        final trials = buildSchedule(e, seed);
        expect(trials.map((t) => t.caseId).toList(), [...ids, ...ids]);
        for (int i = 0; i < 6; i++) {
          expect(trials[i].capturedFirst, !trials[i + 6].capturedFirst);
          expect(trials[i].patch, trials[i + 6].patch);
          expect(trials[i].sample!['position'], i + 1);
        }
        crops.add(jsonEncode(trials.first.patch));
        firstOrders.add(trials.first.capturedFirst);
      }
      expect(crops.length, greaterThan(1));
      expect(firstOrders, {true, false});
      final session = stereoSession(e);
      await repo.pinSelection(e, session);
      await repo.save(session);
      final restored = (await repo.sessions(e)).single;
      restored.validate(e);
      expect(
        restored.trials.map((t) => t.toJson()),
        session.trials.map((t) => t.toJson()),
      );
      final tampered =
          jsonDecode(jsonEncode(restored.toJson())) as Map<String, dynamic>;
      final trials = tampered['trials'] as List;
      final first = trials[0];
      trials[0] = trials[1];
      trials[1] = first;
      expect(
        () => StudySession.fromJson(tampered).validate(e),
        throwsFormatException,
      );
      expect(
        utf8.decode(repo.resultsCsv(e, [restored])),
        contains('fixed_position'),
      );
      model.fixedIds['scene'] = ids.reversed.toList();
      final changed = await repo.prepareQuickTest(
        draft,
        model.definition({'scene': '6'}),
      );
      expect(changed.id, isNot(e.id));
      restored.validate(e);
      expect(buildSchedule(e, 10).first.caseId, ids.first);
      expect(buildSchedule(changed, 10).first.caseId, ids.last);
      final saved = QuickTestSettings(
        (await repo.lastQuickDraft())!.definition,
      );
      expect(saved.fixedSampling, true);
      expect(saved.fixedIds['scene'], ids.reversed.toList());
      for (final invalid in ['3,2', 'x,y\n0,1', '999,2\n0,1', '0,1\n0,1']) {
        expect(
          () => model.resolveFixed('scene', invalid, 2),
          throwsFormatException,
        );
      }
      final bad = e.definition!.toJson();
      (bad['sampling'] as Map)['fixedOrder'] = ['unknown'];
      expect(() => StudyDefinition.fromJson(bad), throwsFormatException);
      model.setFixedSampling(false);
      expect(
        model.definition({'scene': '6'}).sampling!.containsKey('fixedOrder'),
        false,
      );
    },
  );

  test(
    'fixed group order and each round keep the entered sequence even with random itemOrder',
    () async {
      final temp = await Directory.systemTemp.createTemp('fixed-groups-');
      addTearDown(() => temp.delete(recursive: true));
      final repo = StudyRepository(temp);
      final draft = await repo.createRenderPool(tree());
      final model = QuickTestSettings(draft.definition)..setFixedSampling(true);
      for (final group in model.available.keys) {
        model.fixedIds[group] = model.resolveFixed(group, '29, 20\n1, 0', 2);
      }
      final e = await repo.prepareQuickTest(
        draft,
        model.definition({for (final g in model.available.keys) g: '2'}),
      );
      final expected = [
        for (final g in model.available.keys) ...[
          ...model.fixedIds[g]!,
          ...model.fixedIds[g]!,
        ],
      ];
      expect(buildSchedule(e, 1).map((t) => t.caseId).toList(), expected);
      expect(buildSchedule(e, 999).map((t) => t.caseId).toList(), expected);
      final bad = e.definition!.toJson();
      final order = (bad['sampling'] as Map)['fixedOrder'] as List;
      final a = order[1];
      order[1] = order[2];
      order[2] = a;
      expect(() => StudyDefinition.fromJson(bad), throwsFormatException);
    },
  );

  for (final size in [const Size(1280, 900), const Size(411, 850)]) {
    testWidgets(
      'fixed list UI validates six bindings and uses the displayed order at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        late Directory temp;
        late StudyRepository repo;
        await tester.runAsync(() async {
          temp = await Directory.systemTemp.createTemp('fixed-widget-');
          repo = StudyRepository(temp);
          await repo.initializeV2();
          final d = await repo.saveDraft({
            'schema': 2,
            'studyId': 'fixed-widget',
            'name': '固定测试',
            'method': '2afc',
            'question': '请选择',
            'schedule': {'repetitions': 2, 'pairOrder': 'balanced'},
            'items': [
              for (int f = 0; f < 3; f++)
                for (final v in [0, 10])
                  {
                    'id': 'f$f-v$v',
                    'group': 'scene',
                    'a': 'a.png',
                    'b': 'b.png',
                    'metadata': {'frame': f, 'view': v},
                  },
            ],
          });
          await repo.bindMaterialRoot(repo.draftDir(d.id), Directory.current);
        });
        addTearDown(() => temp.delete(recursive: true));
        StudyDefinition? started;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: QuickTestPanel(
                  repository: repo,
                  busy: false,
                  active: null,
                  sessions: const [],
                  onSource: (_) async {},
                  onStart: (_, d) async {
                    started = d;
                  },
                  onResume: (_, _) async {},
                ),
              ),
            ),
          ),
        );
        for (int i = 0; i < 60; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 30));
          final mode = find.byKey(const Key('quick-sampling-mode-false'));
          if (mode.evaluate().isNotEmpty &&
              tester.widget<DropdownButtonFormField<bool>>(mode).onChanged !=
                  null) {
            break;
          }
        }
        Future<void> tap(Finder f) async {
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.ensureVisible(f);
          await tester.pumpAndSettle();
          await tester.tap(f);
          await tester.pumpAndSettle();
        }

        await tap(find.byKey(const Key('quick-sampling-mode-false')));
        await tester.tap(find.text('固定帧和视点（所有人相同）').last);
        await tester.pump(const Duration(milliseconds: 30));
        await tap(find.byKey(const Key('quick-fixed-list-scene')));
        await tester.enterText(
          find.byKey(const Key('fixed-sampling-input')),
          '2,10',
        );
        await tap(find.byKey(const Key('fixed-sampling-apply')));
        expect(find.byKey(const Key('fixed-sampling-error')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('fixed-sampling-input')),
          '2,10\n0,0\n1,10\n2,0\n0,10\n1,0',
        );
        await tap(find.byKey(const Key('fixed-sampling-apply')));
        expect(find.text('固定 6 组，共需答 12 题'), findsOneWidget);
        await tap(find.byKey(const Key('quick-start-test')));
        expect(started!.fixedOrder, [
          'f2-v10',
          'f0-v0',
          'f1-v10',
          'f2-v0',
          'f0-v10',
          'f1-v0',
        ]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
