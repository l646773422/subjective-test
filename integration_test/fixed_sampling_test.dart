import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:subjective_study/main.dart';
import 'package:subjective_study/presentation.dart';
import 'package:subjective_study/repository.dart';
import 'package:subjective_study/stimulus_view.dart';
import 'flow_test.dart' as support;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows fixed six-pair list: real SBS materials, registration, resume and next participant',
    (tester) async {
      const materialRoot = String.fromEnvironment('STUDY_RENDER_ROOT');
      expect(materialRoot, isNotEmpty);
      final repo = StudyRepository(
        Directory('validation/fixed-sampling-${uuid()}'),
      );
      await repo.initializeV2();
      await repo.loadQuickDirectory(Directory(materialRoot));
      support.integrationBinding.reportData = {
        'purpose':
            'Fixed frame/view list and order with independently randomized A/B and Patch',
        'testTimingMode':
            '80ms test-only stage override; source retains configured timings',
        'repository': repo.root.absolute.path,
      };
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture-root'),
          child: StudyApp(repository: repo, testDurationMs: 80),
        ),
      );
      final bench = tester.state<WorkbenchState>(find.byType(Workbench));
      await support.until(
        tester,
        () =>
            !bench.busy &&
            find
                .byKey(const Key('quick-sampling-mode-false'))
                .evaluate()
                .isNotEmpty &&
            tester
                    .widget<DropdownButtonFormField<bool>>(
                      find.byKey(const Key('quick-sampling-mode-false')),
                    )
                    .onChanged !=
                null,
      );
      Future<void> enter(String key, String value) async {
        final f = find.byKey(Key(key));
        await tester.ensureVisible(f);
        await tester.enterText(f, value);
        await tester.pump();
      }

      Future<void> click(String key) async {
        FocusManager.instance.primaryFocus?.unfocus();
        final f = find.byKey(Key(key));
        await tester.ensureVisible(f);
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(f);
        await tester.pump(const Duration(milliseconds: 250));
      }

      Future<void> binocular(String key) async {
        final c = tester.getCenter(find.byKey(Key(key)).first);
        final origin = tester.getTopLeft(find.byType(StereoSurface));
        await tester.tapAt(Offset(origin.dx + (c.dx - origin.dx) * 2, c.dy));
        await tester.pump();
      }

      Future<TestScreenState> screenReady() async {
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
        return tester.state<TestScreenState>(find.byType(TestScreen));
      }

      Future<void> answerReady(TestScreenState screen) async {
        await support.until(
          tester,
          () => [
            StudyStage.answer,
            StudyStage.error,
            StudyStage.interrupted,
          ].contains(screen.runner.stage),
        );
        if (screen.runner.stage == StudyStage.error) fail(screen.runner.error!);
        if (screen.runner.stage == StudyStage.interrupted) {
          await screen.runner.begin();
          await answerReady(screen);
        }
      }

      Future<void> backToSetup() => support.until(
        tester,
        () =>
            !bench.busy &&
            find.byType(TestScreen).evaluate().isEmpty &&
            find.byKey(const Key('quick-start-test')).evaluate().isNotEmpty,
      );

      await click('quick-sampling-mode-false');
      await tester.tap(find.text('固定帧和视点（所有人相同）').last);
      await tester.pumpAndSettle();
      await click('quick-fixed-list-Dance_Dunhuang_Pair_1080');
      const bindings = '12,20\n85,0\n7,30\n144,10\n200,50\n249,40';
      await enter('fixed-sampling-input', bindings);
      await support.capture(tester, repo, 'fixed-six-bindings');
      await click('fixed-sampling-apply');
      expect(find.text('固定 6 组，共需答 12 题'), findsOneWidget);
      await click('quick-patch-enabled');
      await enter('quick-patch-height', '320');
      await tester.ensureVisible(find.byKey(const Key('quick-start-test')));
      await tester.pumpAndSettle();
      await support.capture(tester, repo, 'fixed-effective-settings');
      await click('quick-start-test');
      await enter('participant-id', 'FIXED-SIMULATED-1');
      await click('create-session');
      var screen = await screenReady();
      final e = screen.runner.experiment;
      expect(e.definition!.fixedSampling, true);
      final frozen = jsonEncode(
        screen.runner.session.trials.map((t) => t.toJson()).toList(),
      );
      final expected = [
        [12, 20],
        [85, 0],
        [7, 30],
        [144, 10],
        [200, 50],
        [249, 40],
      ];
      expect(
        screen.runner.session.trials.take(6).map((t) {
          final c = e.caseById(t.caseId);
          return [c.frame, c.view];
        }).toList(),
        expected,
      );
      await binocular('begin-phase');
      await answerReady(screen);
      await support.capture(tester, repo, 'fixed-binocular-answer');
      await binocular('answer-1');
      await support.until(
        tester,
        () =>
            screen.runner.session.answers.length == 1 && !screen.runner.saving,
      );
      final firstId = screen.runner.session.id;
      await screen.leave();
      await tester.pumpAndSettle();
      await binocular('confirm-leave');
      await backToSetup();
      await support.until(
        tester,
        () => find.byKey(Key('quick-resume-$firstId')).evaluate().isNotEmpty,
      );
      await click('quick-resume-$firstId');
      screen = await screenReady();
      expect(
        jsonEncode(
          screen.runner.session.trials.map((t) => t.toJson()).toList(),
        ),
        frozen,
      );
      await binocular('begin-phase');
      while (!screen.runner.session.complete) {
        await answerReady(screen);
        final count = screen.runner.session.answers.length;
        await binocular('answer-2');
        await support.until(
          tester,
          () =>
              screen.runner.session.answers.length == count + 1 &&
              !screen.runner.saving,
        );
      }
      final first = screen.runner.session;
      first.validate(e);
      expect(first.answers.length, 12);
      await binocular('finish-session');
      await backToSetup();
      await click('quick-start-test');
      await enter('participant-id', 'FIXED-SIMULATED-2');
      await click('create-session');
      screen = await screenReady();
      final second = screen.runner.session;
      expect(screen.runner.experiment.id, e.id);
      expect(
        second.trials.map((t) => t.caseId).toList(),
        first.trials.map((t) => t.caseId).toList(),
      );
      await binocular('begin-phase');
      await answerReady(screen);
      await binocular('answer-1');
      await support.until(
        tester,
        () => second.answers.length == 1 && !screen.runner.saving,
      );
      await screen.leave();
      await tester.pumpAndSettle();
      await binocular('confirm-leave');
      await backToSetup();
      expect((await repo.sessions(e)).length, 2);
      expect((await repo.experiments()).length, 1);
      support.integrationBinding.reportData!.addAll(<String, dynamic>{
        'fixedBindings': expected,
        'firstAnswers': first.answers.length,
        'secondAnswers': second.answers.length,
        'sameContentAndOrder': true,
        'diskResumeMatches': true,
        'revisionReused': true,
        'patchesDifferAcrossParticipants':
            jsonEncode(first.trials.first.patch) !=
            jsonEncode(second.trials.first.patch),
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
