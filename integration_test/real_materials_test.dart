// Opt-in local test. Real images and simulated answers stay in ignored validation/.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:subjective_study/main.dart';
import 'package:subjective_study/presentation.dart';
import 'package:subjective_study/repository.dart';
import 'flow_test.dart' as harness;

const sourcePath = String.fromEnvironment('STUDY_REAL_SOURCE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real images: import, publish, 40 real-timed answers, disk recovery and results',
    (tester) async {
      harness.integrationBinding.reportData = {
        'testTimingMode':
            'production 2s prompts / 3s images; 40 synthetic answers on real images',
        'purpose': 'workflow-simulation',
      };
      final source = Directory(sourcePath);
      final repo = StudyRepository(
        Directory(p.join(source.parent.path, 'native-${uuid()}')),
      );
      final publishClock = Stopwatch()..start();
      final imported = await repo.importStudyDirectory(source);
      final e = await repo.publishDraft(imported.draft!);
      final publishMs = publishClock.elapsedMilliseconds;
      expect(e.isDemo, true);
      expect(e.definition!.profile, isNull);
      expect(e.cases.length, 20);
      expect(e.cases.map((c) => c.sequence).toSet().length, 4);
      expect(e.cases.where((c) => c.width == 3840).length, 6);
      await repo.verify(e);
      debugPrint('Real study published in ${publishMs}ms: ${repo.root.path}');

      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture-root'),
          child: StudyApp(repository: repo),
        ),
      );
      await harness.until(
        tester,
        () =>
            find.text('高级实验管理').evaluate().isNotEmpty &&
            !tester.state<WorkbenchState>(find.byType(Workbench)).busy,
      );
      await tester.tap(find.text('高级实验管理'));
      await tester.pump();
      await harness.until(
        tester,
        () => harness.canPress(tester, const Key('go-sessions')),
      );
      await harness.capture(tester, repo, 'real-library');
      await tester.ensureVisible(find.byKey(const Key('go-sessions')));
      await tester.tap(find.byKey(const Key('go-sessions')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-session')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('participant-id')),
        'SIMULATED-WORKFLOW-001',
      );
      await tester.enterText(
        find.byKey(const Key('condition-id')),
        'simulated-windows',
      );
      await tester.tap(find.byKey(const Key('create-session')));
      await harness.until(
        tester,
        () => find.byType(TestScreen).evaluate().isNotEmpty,
      );
      var screen = tester.state<TestScreenState>(find.byType(TestScreen));
      expect(screen.runner.testDurationMs, isNull);
      expect(screen.runner.session.trials.length, 40);

      Future<void> begin() async {
        await harness.until(
          tester,
          () => harness.canPress(tester, const Key('begin-phase')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('begin-phase')));
      }

      final captured = <String>{};
      var externalInterruptions = 0;
      Future<void> respond() async {
        while (true) {
          await harness.until(
            tester,
            () => [
              StudyStage.imageA,
              StudyStage.interrupted,
              StudyStage.error,
            ].contains(screen.runner.stage),
          );
          if (screen.runner.stage == StudyStage.error) {
            fail('Presentation failed: ${screen.runner.error}');
          }
          if (screen.runner.stage == StudyStage.imageA) {
            final c = screen.runner.currentCase;
            if (captured.add(c.sequence)) {
              await harness.capture(tester, repo, 'real-${c.sequence}');
            }
            await harness.until(
              tester,
              () => [
                StudyStage.answer,
                StudyStage.interrupted,
                StudyStage.error,
              ].contains(screen.runner.stage),
            );
          }
          if (screen.runner.stage == StudyStage.answer) break;
          if (screen.runner.stage == StudyStage.error) {
            fail('Presentation failed: ${screen.runner.error}');
          }
          // Follow the same replay path as an operator after a focus interruption.
          // Interrupted partial presentations remain recorded and are not answered.
          externalInterruptions++;
          expect(externalInterruptions, lessThan(20));
          // A lifecycle callback may arrive between widget lookup and tap on the
          // live desktop. Invoke the button's action after checking current state.
          if (screen.runner.stage == StudyStage.interrupted) {
            await screen.runner.begin();
          }
        }
        final index = screen.runner.index;
        // Deliberately synthetic 50% accuracy, independent of image content.
        // Correct on the first repetition, incorrect on the second.
        final alternative = screen.runner.trial.repetition == 1 ? 'a' : 'b';
        final choice = screen.runner.trial.order.indexOf(alternative) + 1;
        await tester.tap(find.byKey(Key('answer-$choice')));
        await harness.until(
          tester,
          () =>
              screen.runner.session.answers.length == index + 1 &&
              !screen.runner.saving,
        );
        debugPrint('Real-material workflow ${index + 1}/40');
      }

      await begin();
      await respond();
      await respond();
      await harness.until(
        tester,
        () => screen.runner.stage == StudyStage.imageA,
      );
      final nextTrial = screen.runner.trial.id;
      final sessionId = screen.runner.session.id;
      await screen.runner.interrupt('workflow-simulation-disk-reload');
      await harness.capture(tester, repo, 'real-interrupted');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final restarted = StudyRepository(repo.root);
      final restored = (await restarted.sessions(e)).single;
      expect(restored.id, sessionId);
      expect(restored.answers.length, 2);
      expect(restored.trials[2].id, nextTrial);
      restored.validate(e);
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: const Key('capture-root'),
            child: TestScreen(
              repository: restarted,
              experiment: e,
              session: restored,
            ),
          ),
        ),
      );
      screen = tester.state<TestScreenState>(find.byType(TestScreen));
      await begin();
      expect(screen.runner.trial.id, nextTrial);
      while (!screen.runner.session.complete) {
        await respond();
      }
      await harness.until(
        tester,
        () => screen.runner.stage == StudyStage.completed,
      );
      await harness.capture(tester, repo, 'real-completed');
      final saved = (await restarted.sessions(e)).single;
      saved.validate(e);
      final results = restarted.resultsJson(e, [saved]);
      final body = jsonDecode(utf8.decode(results)) as Map<String, dynamic>;
      final verificationRepo = StudyRepository(
        Directory(p.join(repo.root.path, 'verification')),
      );
      // Exchange through an existing release directory, without making a delivery ZIP.
      await verificationRepo.importStudyDirectory(repo.revisionDir(e.id));
      expect(await verificationRepo.mergeResults(e, results), 1);
      expect(await verificationRepo.mergeResults(e, results), 0);
      final output = Directory(p.join(repo.root.path, 'evidence'));
      await output.create();
      await File(
        p.join(output.path, 'simulated-results.json'),
      ).writeAsBytes(results);
      await File(
        p.join(output.path, 'simulated-results.csv'),
      ).writeAsBytes(restarted.resultsCsv(e, [saved]));
      final presentationEvents = saved.trials.expand((trial) {
        final events = saved.events
            .where(
              (event) =>
                  event['type'] == 'presentation' &&
                  event['plannedMs'] != null &&
                  event['trialId'] == trial.id,
            )
            .toList();
        // The last four stages are the full replay which led to this answer.
        expect(events.length, greaterThanOrEqualTo(4));
        return events.skip(events.length - 4);
      }).toList();
      expect(captured.length, 4);
      expect(saved.answers.length, 40);
      expect(presentationEvents.length, 160);
      for (final event in presentationEvents) {
        expect(
          event['plannedMs'],
          event['stage'].toString().startsWith('image') ? 3000 : 2000,
        );
        expect(
          event['actualMs'] as int,
          greaterThanOrEqualTo((event['plannedMs'] as int) - 100),
        );
      }
      harness.integrationBinding.reportData ??= <String, dynamic>{};
      harness.integrationBinding.reportData!.addAll({
        'testTimingMode':
            'production 2s prompts / 3s images; 40 synthetic answers on real images',
        'purpose': 'workflow-simulation',
        'repository': repo.root.path,
        'publishMs': publishMs,
        'externalInterruptions': externalInterruptions,
        'results': body,
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    skip: sourcePath.isEmpty,
    timeout: const Timeout(Duration(minutes: 18)),
  );
}
