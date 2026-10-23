import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/main.dart';
import 'package:subjective_study/presentation.dart';
import 'package:subjective_study/repository.dart';
import 'flow_test.dart' as support;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'one-page Windows setup starts real material sessions and isolates changed parameters',
    (tester) async {
      const materialRoot = String.fromEnvironment('STUDY_RENDER_ROOT');
      expect(materialRoot, isNotEmpty);
      final root = Directory('validation/quick-start-${uuid()}');
      final repo = StudyRepository(root);
      await repo.initializeV2();
      support.integrationBinding.reportData = {
        'purpose': 'one-page real-material workflow simulation',
        'testTimingMode': 'real image files, 30ms test-only stage timers',
        'repository': root.absolute.path,
      };
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture-root'),
          child: StudyApp(repository: repo, testDurationMs: 30),
        ),
      );
      final bench = tester.state<WorkbenchState>(find.byType(Workbench));
      await support.until(
        tester,
        () =>
            bench.repo != null &&
            !bench.busy &&
            find
                .byKey(const Key('quick-material-directory'))
                .evaluate()
                .isNotEmpty,
      );
      Future<void> click(Key key) async {
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.ensureVisible(find.byKey(key));
        await tester.pump();
        await tester.tap(find.byKey(key));
        await tester.pump();
      }

      Future<void> enter(Key key, String text) async {
        await tester.ensureVisible(find.byKey(key));
        await tester.pump();
        await tester.enterText(find.byKey(key), text);
        await tester.pump();
      }

      await enter(const Key('quick-material-directory'), materialRoot);
      await click(const Key('quick-load-materials'));
      await support.until(
        tester,
        () =>
            find.byKey(const Key('quick-count-VRU_gz')).evaluate().isNotEmpty &&
            tester
                    .widget<TextField>(
                      find.byKey(const Key('quick-count-VRU_gz')),
                    )
                    .enabled ==
                true,
      );
      expect((await repo.drafts()).single.definition.items.length, 5000);
      expect(await repo.experiments(), isEmpty);
      for (final group in protocolViews.keys) {
        await enter(Key('quick-count-$group'), '1');
      }
      await click(const Key('quick-patch-enabled'));
      await enter(const Key('quick-patch-width'), '512');
      await enter(const Key('quick-patch-height'), '320');
      expect(find.text('抽 4 组，共需答 8 题'), findsOneWidget);
      expect(find.text('Patch 512 × 320 像素'), findsOneWidget);
      await click(const Key('quick-stereo-enabled'));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('quick-start-test')))
            .onPressed,
        isNull,
      );
      await click(const Key('quick-stereo-enabled'));
      await tester.ensureVisible(find.byKey(const Key('quick-start-test')));
      await tester.pump();
      await support.capture(tester, repo, 'quick-settings');
      await click(const Key('quick-start-test'));
      await support.until(
        tester,
        () => find.byKey(const Key('participant-id')).evaluate().isNotEmpty,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        await repo.experiments(),
        isEmpty,
        reason: 'Cancel does not create an unused revision',
      );
      Future<TestScreenState> begin(String id) async {
        await click(const Key('quick-start-test'));
        await support.until(
          tester,
          () => find.byKey(const Key('participant-id')).evaluate().isNotEmpty,
        );
        await tester.enterText(find.byKey(const Key('participant-id')), id);
        await tester.tap(find.byKey(const Key('create-session')));
        await support.until(
          tester,
          () =>
              find.byType(TestScreen).evaluate().isNotEmpty &&
              support.canPress(tester, const Key('begin-phase')),
        );
        await click(const Key('begin-phase'));
        return tester.state<TestScreenState>(find.byType(TestScreen));
      }

      Future<void> answer(TestScreenState screen) async {
        while (true) {
          await support.until(
            tester,
            () => [
              StudyStage.answer,
              StudyStage.error,
              StudyStage.interrupted,
            ].contains(screen.runner.stage),
          );
          if (screen.runner.stage == StudyStage.error) {
            fail(screen.runner.error!);
          }
          if (screen.runner.stage == StudyStage.answer) break;
          await screen.runner.begin();
        }
        final before = screen.runner.session.answers.length;
        await tester.tap(find.byKey(const Key('answer-1')));
        await support.until(
          tester,
          () =>
              screen.runner.session.answers.length == before + 1 &&
              !screen.runner.saving,
        );
      }

      Future<void> leave(TestScreenState screen) async {
        await screen.leave();
        await tester.pump();
        await click(const Key('confirm-leave'));
        await support.until(
          tester,
          () => find.byType(TestScreen).evaluate().isEmpty && !bench.busy,
        );
      }

      var screen = await begin('QUICK-001');
      final first = screen.runner.experiment, session = screen.runner.session;
      expect(session.trials.length, 8);
      expect(first.definition!.patch!['width'], 512);
      final frozen = jsonEncode(session.trials.map((t) => t.toJson()).toList());
      await answer(screen);
      await answer(screen);
      await leave(screen);
      expect(bench.page, 3);
      await support.until(
        tester,
        () => find.text('恢复测试').evaluate().length == 1,
      );
      await support.capture(tester, repo, 'quick-resume');
      await tester.ensureVisible(find.text('恢复测试'));
      await tester.pump();
      await tester.tap(find.text('恢复测试'));
      await support.until(
        tester,
        () =>
            find.byType(TestScreen).evaluate().isNotEmpty &&
            support.canPress(tester, const Key('begin-phase')),
      );
      await click(const Key('begin-phase'));
      screen = tester.state<TestScreenState>(find.byType(TestScreen));
      expect(
        jsonEncode(
          screen.runner.session.trials.map((t) => t.toJson()).toList(),
        ),
        frozen,
      );
      while (!screen.runner.session.complete) {
        await answer(screen);
      }
      await tester.pump();
      await click(const Key('finish-session'));
      await support.until(
        tester,
        () => !bench.busy && find.byType(TestScreen).evaluate().isEmpty,
      );
      screen = await begin('QUICK-002');
      expect(screen.runner.experiment.id, first.id);
      expect(
        screen.runner.session.trials.map((t) => t.toJson()).toList(),
        isNot(session.trials.map((t) => t.toJson()).toList()),
      );
      await answer(screen);
      await leave(screen);
      expect((await repo.experiments()).length, 1);
      await enter(const Key('quick-patch-width'), '640');
      await enter(const Key('quick-patch-height'), '360');
      for (final group in protocolViews.keys) {
        await enter(Key('quick-count-$group'), '2');
      }
      screen = await begin('QUICK-003');
      final second = screen.runner.experiment;
      expect(second.id, isNot(first.id));
      expect(screen.runner.session.trials.length, 16);
      expect(second.definition!.patch!['width'], 640);
      await answer(screen);
      await leave(screen);
      final previous = await repo.sessions(first);
      expect(
        previous
            .firstWhere((s) => s.participantId == 'QUICK-001')
            .answers
            .length,
        8,
      );
      expect(
        previous
            .firstWhere((s) => s.participantId == 'QUICK-002')
            .answers
            .length,
        1,
      );
      expect(first.definition!.patch!['width'], 512);
      final oldPending = previous.firstWhere(
        (s) => s.participantId == 'QUICK-002',
      );
      await support.until(
        tester,
        () => find
            .byKey(Key('quick-resume-${oldPending.id}'))
            .evaluate()
            .isNotEmpty,
      );
      await support.capture(tester, repo, 'quick-mixed-parameters');
      await click(Key('quick-resume-${oldPending.id}'));
      await support.until(
        tester,
        () =>
            find.byType(TestScreen).evaluate().isNotEmpty &&
            support.canPress(tester, const Key('begin-phase')),
      );
      screen = tester.state<TestScreenState>(find.byType(TestScreen));
      expect(screen.runner.experiment.id, first.id);
      expect(screen.runner.experiment.definition!.patch!['width'], 512);
      await click(const Key('begin-phase'));
      await answer(screen);
      await leave(screen);
      expect(
        (await repo.sessions(
          first,
        )).firstWhere((s) => s.participantId == 'QUICK-002').answers.length,
        2,
      );
      expect(find.text('Patch 640 × 360 像素'), findsOneWidget);
      expect((await repo.lastQuickDraft())!.definition.patch!['width'], 640);
      support.integrationBinding.reportData!.addAll(<String, dynamic>{
        'poolPairs': 5000,
        'firstJudgments': 8,
        'changedJudgments': 16,
        'firstCompleted': true,
        'resumeMatches': true,
        'sameSettingsReuse': true,
        'changedSettingsIsolated': true,
        'oldConfigurationResumedFromSamePage': true,
        'firstRevision': first.id,
        'changedRevision': second.id,
      });
      await File(
        '${root.path}/results.json',
      ).writeAsBytes(repo.resultsJson(first, await repo.sessions(first)));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
