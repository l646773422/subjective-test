import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/repository.dart';
import 'package:subjective_study/quick_test_settings.dart';
import 'package:subjective_study/quick_test_panel.dart';
import 'material_pool_test.dart' show tree;
import 'support/stereo_fixture.dart';

StudyDefinition smallSource() => StudyDefinition.fromJson({
  'schema': 2,
  'studyId': 'quick-test',
  'name': '测试素材',
  'method': '2afc',
  'question': '选择更自然的一幅',
  'schedule': {
    'repetitions': 2,
    'pairOrder': 'balanced',
    'blockByGroup': true,
    'avoidAdjacentRepeats': true,
  },
  'sampling': {
    'mode': 'per_participant',
    'perGroup': {'sceneA': 2, 'sceneB': 2},
  },
  'items': [
    for (final group in ['sceneA', 'sceneB'])
      for (int i = 0; i < 3; i++)
        {
          'id': '$group-$i',
          'group': group,
          'a': '$group-$i-a.png',
          'b': '$group-$i-b.png',
        },
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'quick settings permit one-pair groups, reject invalid counts and cannot invent stereo eyes',
    () {
      final model = QuickTestSettings(smallSource());
      expect(model.selectedCount, 4);
      expect(model.judgments, 8);
      final values = {'sceneA': '1', 'sceneB': '2'};
      final d = model.definition(values);
      expect(d.selectedMainCount, 3);
      expect(d.trialCount, 6);
      expect(d.schedule['avoidAdjacentRepeats'], false);
      expect(d.schedule['pairOrder'], 'balanced');
      for (final invalid in ['', '0', '-1', '4', '1.5']) {
        expect(model.error({...values, 'sceneA': invalid}), isNotNull);
      }
      model.stereoEnabled = true;
      expect(model.error(values), contains('右眼'));
      expect(() => model.definition(values), throwsFormatException);
      model.stereoEnabled = false;
      model.patchEnabled = true;
      model.patchWidth = '0';
      expect(model.error(values), contains('Patch'));
      model.patchWidth = '144';
      model.patchHeight = '96';
      expect(model.definition(values).patch!['width'], 144);
    },
  );

  test(
    'automatic configuration freezes changes, reuses identical settings and preserves old material bindings',
    () async {
      final temp = await Directory.systemTemp.createTemp('quick-repository-');
      addTearDown(() => temp.delete(recursive: true));
      final repo = StudyRepository(Directory('${temp.path}/repo'));
      final draft = await repo.createRenderPool(tree());
      final model = QuickTestSettings(draft.definition);
      expect(
        model.groupNames['Dance_Dunhuang_Pair_1080'],
        'Dance_Dunhuang_Pair_1080_0.001_1.0_renders',
      );
      final values = {
        for (final e in model.counts.entries) e.key: '${e.value}',
      };
      final first = await repo.prepareQuickTest(
        draft,
        model.definition(values),
      );
      expect(first.definition!.trialCount, 40);
      final original = first.definition!.toJson();
      model.patchEnabled = true;
      model.patchWidth = '512';
      model.patchHeight = '320';
      for (final group in values.keys) {
        values[group] = '1';
      }
      final modified = model.definition(values);
      final second = await repo.prepareQuickTest(draft, modified);
      expect(second.id, isNot(first.id));
      expect(second.definition!.trialCount, 8);
      expect(first.definition!.toJson(), original);
      final again = await repo.prepareQuickTest(draft, modified);
      expect(again.id, second.id);
      expect((await repo.experiments()).length, 2);
      expect((await repo.lastQuickDraft())!.definition.patch, modified.patch);
      final oldRoot = repo.materialRoot(second).path;
      final moved = await Directory('${temp.path}/other-materials').create();
      await repo.bindMaterialRoot(repo.draftDir(draft.id), moved);
      final third = await repo.prepareQuickTest(draft, modified);
      expect(third.id, isNot(second.id));
      expect(repo.materialRoot(second).path, oldRoot);
      expect(repo.materialRoot(third).path, await moved.resolveSymbolicLinks());
    },
  );

  test(
    'standard stereo source is re-readable without duplicate import errors or copying images',
    () async {
      final temp = await Directory.systemTemp.createTemp('quick-source-');
      addTearDown(() => temp.delete(recursive: true));
      final repo = StudyRepository(Directory('${temp.path}/repo'));
      final source = Directory('${temp.path}/source');
      final draft = await stereoFixture(repo, source);
      final loaded = await repo.loadQuickDirectory(source);
      expect(loaded.id, draft.id);
      final model = QuickTestSettings(loaded.definition);
      expect(model.stereoMissing, 0);
      expect(model.layout, 'full_sbs');
      final d = model.definition({
        for (final e in model.counts.entries) e.key: '${e.value}',
      });
      final first = await repo.prepareQuickTest(loaded, d);
      expect(first.definition!.stereo!['layout'], 'full_sbs');
      expect(
        first.cases.every((c) => c.aRight != null && c.bRight != null),
        true,
      );
      expect((await repo.loadQuickDirectory(source)).id, draft.id);
      expect(
        await repo
            .draftDir(draft.id)
            .list(recursive: true)
            .where((e) => e.path.endsWith('.png'))
            .length,
        0,
      );
    },
  );

  for (final size in [const Size(1280, 900), const Size(411, 850)]) {
    testWidgets(
      'one-page settings at $size show the exact configuration used by start',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        StudyDefinition? started;
        late Directory temp;
        late StudyRepository repo;
        await tester.runAsync(() async {
          temp = await Directory.systemTemp.createTemp('quick-widget-');
          repo = StudyRepository(temp);
          await repo.initializeV2();
          final d = await repo.saveDraft(smallSource().toJson());
          await repo.bindMaterialRoot(repo.draftDir(d.id), Directory.current);
        });
        addTearDown(() => temp.delete(recursive: true));
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
                  onStart: (draft, settings) async {
                    started = settings;
                  },
                  onResume: (s, e) async {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (int i = 0; i < 50; i++) {
          final input = find.byKey(const Key('quick-count-sceneA'));
          if (input.evaluate().isNotEmpty &&
              tester.widget<TextField>(input).enabled == true) {
            break;
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        Future<void> enter(String key, String value) async {
          final finder = find.byKey(Key(key));
          await tester.ensureVisible(finder);
          await tester.enterText(finder, value);
          await tester.pump();
        }

        Future<void> click(String key) async {
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          final finder = find.byKey(Key(key));
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        await enter('quick-count-sceneA', '1');
        await enter('quick-count-sceneB', '2');
        await click('quick-patch-enabled');
        await enter('quick-patch-width', '144');
        await enter('quick-patch-height', '96');
        expect(find.text('抽 3 组，共需答 6 题'), findsOneWidget);
        expect(find.text('Patch 144 × 96 像素'), findsOneWidget);
        await click('quick-open-settings');
        await enter('quick-prompt-seconds', '-1');
        await click('quick-settings-apply');
        expect(find.byKey(const Key('quick-settings-error')), findsOneWidget);
        await click('quick-settings-cancel');
        expect(find.text('提示 2 秒 · 每张图片 3 秒'), findsOneWidget);
        await click('quick-open-settings');
        await enter('quick-prompt-seconds', '.5');
        await enter('quick-image-seconds', '1.25');
        await enter('quick-question', '选择你认为更自然的一幅');
        await enter('quick-instructions', '保持当前观看位置');
        await click('quick-settings-apply');
        expect(find.text('提示 0.5 秒 · 每张图片 1.25 秒'), findsOneWidget);
        expect(find.text('作答问题：选择你认为更自然的一幅'), findsOneWidget);
        await click('quick-stereo-enabled');
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('quick-start-test')))
              .onPressed,
          isNull,
        );
        expect(find.textContaining('尚未指定右眼'), findsOneWidget);
        await click('quick-stereo-enabled');
        await click('quick-start-test');
        expect(started!.sampling!['perGroup'], {'sceneA': 1, 'sceneB': 2});
        expect(started!.patch!['width'], 144);
        expect(started!.patch!['height'], 96);
        expect(started!.presentation['promptMs'], 500);
        expect(started!.presentation['imageMs'], 1250);
        expect(started!.question, '选择你认为更自然的一幅');
        expect(started!.instructions, '保持当前观看位置');
        await enter(
          'quick-material-directory',
          '${Directory.current.path}/not-yet-read',
        );
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('quick-start-test')))
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
