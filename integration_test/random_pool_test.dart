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

const materialPath = String.fromEnvironment('STUDY_RENDER_ROOT');

StudySession participant(Experiment e, int seed) => StudySession(
  id: uuid(),
  schema: 2,
  studyId: e.studyId,
  experimentId: e.id,
  schedulerVersion: e.release!['implementations']['scheduler'] as String,
  participantId: 'SIMULATED-RANDOM-$seed',
  startedAt: DateTime.now().toUtc().toIso8601String(),
  seed: seed,
  participant: {},
  display: {'conditionId': 'windows-pool', 'condition': 'Windows 素材池演练'},
  trials: buildSchedule(e, seed),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows raw pool: independent participants, replay, hashes and material-free packages',
    (tester) async {
      final root = Directory('validation/random-pool-${uuid()}');
      final repo = StudyRepository(root);
      final clock = Stopwatch()..start();
      final draft = await repo.loadRenderDirectory(Directory(materialPath));
      final e = await repo.publishDraft(draft);
      final loadMs = clock.elapsedMilliseconds;
      expect(e.cases.length, 5000);
      final a = participant(e, 117), b = participant(e, 81123);
      expect(
        a.trials.map((t) => t.caseId).toList(),
        isNot(b.trials.map((t) => t.caseId).toList()),
      );
      for (final group in protocolViews.keys) {
        final cases = a.trials
            .map((t) => e.caseById(t.caseId))
            .where((c) => c.sequence == group)
            .toSet();
        expect(cases.length, protocolViews[group]!.length);
        expect(cases.map((c) => c.frame).toSet().length, greaterThan(1));
      }
      await repo.pinSelection(e, a);
      await repo.pinSelection(e, b);
      a.validate(e);
      b.validate(e);
      await repo.save(a);
      await repo.save(b);
      expect(a.materialHashes.length, 40);
      support.integrationBinding.reportData = {
        'purpose': 'workflow-simulation',
        'testTimingMode': 'production image files, 30ms test-only stage timers',
        'loadMs': loadMs,
        'repository': root.absolute.path,
      };
      Future<void> mount(StudySession session) async {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: const Key('capture-root'),
              child: TestScreen(
                repository: repo,
                experiment: e,
                session: session,
                testDurationMs: 30,
              ),
            ),
          ),
        );
        await support.until(
          tester,
          () => support.canPress(tester, const Key('begin-phase')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('begin-phase')));
      }

      await mount(a);
      var screen = tester.state<TestScreenState>(find.byType(TestScreen));
      Future<void> answer() async {
        while (true) {
          await support.until(
            tester,
            () => [
              StudyStage.answer,
              StudyStage.interrupted,
              StudyStage.error,
            ].contains(screen.runner.stage),
          );
          if (screen.runner.stage == StudyStage.error) {
            fail(screen.runner.error!);
          }
          if (screen.runner.stage == StudyStage.answer) break;
          await screen.runner.begin();
        }
        final index = screen.runner.index,
            alternative = screen.runner.trial.repetition == 1 ? 'a' : 'b';
        await screen.runner.answer(
          screen.runner.trial.order.indexOf(alternative) + 1,
        );
        expect(screen.runner.session.answers.length, index + 1);
      }

      await answer();
      await answer();
      final next = a.trials[2].toJson();
      await screen.runner.interrupt('random-pool-restart');
      await support.capture(tester, repo, 'random-pool-paused');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final restored = (await StudyRepository(
        root,
      ).sessions(e)).singleWhere((s) => s.id == a.id);
      expect(restored.trials[2].toJson(), next);
      expect(restored.materialHashes, a.materialHashes);
      await mount(restored);
      screen = tester.state<TestScreenState>(find.byType(TestScreen));
      while (!restored.complete) {
        await answer();
      }
      await support.capture(tester, repo, 'random-pool-complete');
      final package = await repo.exportPackage(e),
          other = StudyRepository(Directory('${root.path}/other'));
      final imported = (await other.importStudyZip(package)).experiment!;
      await expectLater(other.verify(imported), throwsFormatException);
      await other.loadMaterialDirectory(imported, Directory(materialPath));
      await other.verifySelection(
        imported,
        restored.trials,
        hashes: restored.materialHashes,
      );
      final data = repo.resultsJson(e, [restored, b]);
      expect(await other.mergeResults(imported, data), 2);
      expect(await other.mergeResults(imported, data), 0);
      final report = buildReport(e, [restored, b]);
      final condition = records(report['conditions']).single;
      expect(condition['validObservers'], 1);
      for (final row in records(condition['sequences'])) {
        expect(row['rate'], .5);
      }
      expect(
        utf8.decode(repo.resultsCsv(e, [restored])),
        contains('sampling_seed'),
      );
      await File('${root.path}/simulated-results.json').writeAsBytes(data);
      support.integrationBinding.reportData!.addAll({
        'packageBytes': package.length,
        'firstSelection': a.trials.map((t) => t.toJson()).toList(),
        'secondSelection': b.trials.map((t) => t.toJson()).toList(),
        'report': report,
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture-root'),
          child: StudyApp(repository: repo),
        ),
      );
      await support.until(
        tester,
        () => support.canPress(tester, const Key('go-sessions')),
      );
      await support.capture(tester, repo, 'random-pool-library');
      expect(find.textContaining('每人随机 20 对'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    skip: materialPath.isEmpty,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
