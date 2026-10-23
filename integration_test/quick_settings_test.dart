import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:subjective_study/main.dart';
import 'package:subjective_study/presentation.dart';
import 'package:subjective_study/repository.dart';
import 'package:subjective_study/stimulus_view.dart';
import 'package:subjective_study/labeled_control.dart';
import 'flow_test.dart' as support;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows setup uses folder names, legible labels and applied timing settings',
    (tester) async {
      const materialRoot = String.fromEnvironment('STUDY_RENDER_ROOT');
      expect(materialRoot, isNotEmpty);
      final repo = StudyRepository(
        Directory('validation/quick-settings-${uuid()}'),
      );
      await repo.initializeV2();
      support.integrationBinding.reportData = {
        'purpose':
            'Windows setup and registration layout, folder names and configurable timing',
        'repository': repo.root.absolute.path,
        'testTimingMode':
            'configured 250ms prompts, 750ms images; no test-only timer override',
      };
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture-root'),
          child: StudyApp(repository: repo),
        ),
      );
      final bench = tester.state<WorkbenchState>(find.byType(Workbench));
      await support.until(tester, () => bench.repo != null && !bench.busy);
      Future<void> enter(String key, String value) async {
        final finder = find.byKey(Key(key));
        await tester.ensureVisible(finder);
        await tester.enterText(finder, value);
        await tester.pump();
      }

      Future<void> click(String key) async {
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        final finder = find.byKey(Key(key));
        await tester.ensureVisible(finder);
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(finder);
        await tester.pump(const Duration(milliseconds: 250));
      }

      await enter('quick-material-directory', materialRoot);
      await click('quick-load-materials');
      await support.until(
        tester,
        () =>
            find
                .byKey(const Key('quick-count-Dance_Dunhuang_Pair_1080'))
                .evaluate()
                .isNotEmpty &&
            tester
                    .widget<TextField>(
                      find.byKey(
                        const Key('quick-count-Dance_Dunhuang_Pair_1080'),
                      ),
                    )
                    .enabled ==
                true,
      );
      expect(
        find.text('Dance_Dunhuang_Pair_1080_0.001_1.0_bitstreams_renders'),
        findsOneWidget,
      );
      expect(find.text('敦煌双人舞'), findsNothing);
      await support.capture(tester, repo, 'setup-folder-names');
      await click('quick-stereo-details');
      await tester.ensureVisible(find.byKey(const Key('quick-disparity')));
      await tester.pumpAndSettle();
      await support.capture(tester, repo, 'setup-stereo-labels');
      await click('quick-open-settings');
      await enter('quick-prompt-seconds', '0.25');
      await enter('quick-image-seconds', '0.75');
      await enter('quick-question', '哪一幅看起来更真实？');
      await enter('quick-instructions', '保持当前观看位置，比较两幅画面。');
      await tester.ensureVisible(find.byKey(const Key('quick-prompt-seconds')));
      await tester.pumpAndSettle();
      await support.capture(tester, repo, 'setup-settings-dialog');
      await click('quick-settings-apply');
      expect(find.text('提示 0.25 秒 · 每张图片 0.75 秒'), findsOneWidget);
      expect(find.text('作答问题：哪一幅看起来更真实？'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('quick-open-settings')));
      await tester.pumpAndSettle();
      await support.capture(tester, repo, 'setup-effective-settings');
      await click('quick-start-test');
      await enter('participant-id', 'SETTINGS-SIMULATED');
      await tester.ensureVisible(
        find
            .ancestor(
              of: find.byKey(const Key('participant-id')),
              matching: find.byType(LabeledControl),
            )
            .first,
      );
      await tester.pump(const Duration(milliseconds: 250));
      await support.capture(tester, repo, 'setup-registration-focused');
      await click('create-session');
      await support.until(
        tester,
        () =>
            find.byKey(const Key('begin-phase')).evaluate().length == 2 &&
            tester
                    .widget<FilledButton>(
                      find.byKey(const Key('begin-phase')).first,
                    )
                    .onPressed !=
                null,
      );
      final screen = tester.state<TestScreenState>(find.byType(TestScreen));
      final runner = screen.runner;
      expect(runner.experiment.promptMs, 250);
      expect(runner.experiment.imageMs, 750);
      expect(runner.experiment.question, '哪一幅看起来更真实？');
      Future<void> clickBinocular(String key) async {
        final center = tester.getCenter(find.byKey(Key(key)).first);
        final origin = tester.getTopLeft(find.byType(StereoSurface));
        await tester.tapAt(
          Offset(origin.dx + (center.dx - origin.dx) * 2, center.dy),
        );
        await tester.pump();
      }

      await clickBinocular('begin-phase');
      await support.until(
        tester,
        () => [StudyStage.answer, StudyStage.error].contains(runner.stage),
      );
      if (runner.stage == StudyStage.error) fail(runner.error!);
      final events = runner.session.events
          .where((e) => e['type'] == 'presentation')
          .toList();
      expect(
        events
            .where((e) => ['promptA', 'promptB'].contains(e['stage']))
            .map((e) => e['plannedMs'])
            .toList(),
        [250, 250],
      );
      expect(
        events
            .where((e) => ['imageA', 'imageB'].contains(e['stage']))
            .map((e) => e['plannedMs'])
            .toList(),
        [750, 750],
      );
      await clickBinocular('answer-1');
      await support.until(
        tester,
        () => runner.session.answers.length == 1 && !runner.saving,
      );
      await screen.leave();
      await tester.pumpAndSettle();
      await clickBinocular('confirm-leave');
      await support.until(
        tester,
        () =>
            find
                .byKey(const Key('quick-open-settings'))
                .evaluate()
                .isNotEmpty &&
            !bench.busy &&
            find.byType(TestScreen).evaluate().isEmpty &&
            tester
                    .widget<TextButton>(
                      find.byKey(const Key('quick-open-settings')),
                    )
                    .onPressed !=
                null,
      );
      await click('quick-open-settings');
      await enter('quick-prompt-seconds', '0');
      await enter('quick-image-seconds', '2.5');
      await click('quick-settings-apply');
      final frozen = (await repo.experiments()).single;
      expect(frozen.promptMs, 250);
      expect(frozen.imageMs, 750);
      expect((await repo.sessions(frozen)).single.answers.length, 1);
      expect(find.text('提示 0 秒 · 每张图片 2.5 秒'), findsOneWidget);
      support.integrationBinding.reportData!.addAll(<String, dynamic>{
        'folderNameFromPath': true,
        'promptMs': frozen.promptMs,
        'imageMs': frozen.imageMs,
        'answers': 1,
        'oldSessionSettingsPreserved': true,
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
