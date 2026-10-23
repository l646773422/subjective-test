import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/presentation.dart';
import 'package:subjective_study/repository.dart';
import 'flow_test.dart' as support;
import 'random_pool_test.dart' show participant;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows original render pool displays and restores real 4K patches',
    (tester) async {
      const sourcePath = String.fromEnvironment('STUDY_RENDER_ROOT');
      expect(
        sourcePath,
        isNotEmpty,
        reason: 'Pass the read-only material root with --dart-define',
      );
      final root = Directory('validation/real-patch-${uuid()}');
      final repo = StudyRepository(root);
      final d = await repo.loadRenderDirectory(Directory(sourcePath));
      final source = d.definition.toJson();
      (source['presentation'] as Map)['patch'] = {'width': 512, 'height': 512};
      (source['presentation'] as Map)['promptMs'] = 0;
      final e = await repo.publishDraft(await repo.saveDraft(source));
      int seed = 117;
      while (e.caseById(buildSchedule(e, seed).first.caseId).width != 3840) {
        seed++;
      }
      final s = participant(e, seed);
      await repo.pinSelection(e, s);
      await repo.save(s);
      final frozen = jsonEncode(s.trials.map((t) => t.toJson()).toList());
      support.integrationBinding.reportData = {
        'purpose': 'real-material patch workflow simulation',
        'testTimingMode': 'configured 0ms prompts, default 3000ms images',
        'repository': root.absolute.path,
        'seed': seed,
      };
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: const Key('capture-root'),
            child: TestScreen(repository: repo, experiment: e, session: s),
          ),
        ),
      );
      await support.until(
        tester,
        () => support.canPress(tester, const Key('begin-phase')),
      );
      await tester.tap(find.byKey(const Key('begin-phase')));
      final screen = tester.state<TestScreenState>(find.byType(TestScreen));
      Future<void> reach(StudyStage target) async {
        await support.until(
          tester,
          () => [
            target,
            StudyStage.interrupted,
            StudyStage.error,
          ].contains(screen.runner.stage),
        );
        if (screen.runner.stage == StudyStage.error) {
          fail(screen.runner.error!);
        }
        if (screen.runner.stage == StudyStage.interrupted) {
          await screen.runner.begin();
          await reach(target);
        }
      }

      await reach(StudyStage.imageA);
      expect(screen.runner.imageA!.width, 3840);
      expect(screen.runner.trial.patch!['width'], 512);
      expect(screen.runner.trial.patch!['height'], 512);
      for (final trial in s.trials) {
        expect(trial.patch!['width'], 512);
        expect(trial.patch!['height'], 512);
      }
      await support.capture(tester, repo, 'real-4k-patch');
      await reach(StudyStage.answer);
      await tester.tap(find.byKey(const Key('answer-1')));
      await support.until(
        tester,
        () => s.answers.length == 1 && !screen.runner.saving,
      );
      await screen.runner.interrupt('real-patch-restart');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final restored = (await repo.sessions(e)).single;
      restored.validate(e);
      expect(
        jsonEncode(restored.trials.map((t) => t.toJson()).toList()),
        frozen,
      );
      expect(restored.materialHashes, s.materialHashes);
      expect(e.cases.length, 5000);
      expect(s.materialHashes.length, 40);
      support.integrationBinding.reportData!.addAll(<String, dynamic>{
        'answers': restored.answers.length,
        'poolPairs': e.cases.length,
        'selectedPairs': s.trials.map((t) => t.caseId).toSet().length,
        'materialHashes': s.materialHashes.length,
        'crop': s.trials.first.patch,
        'resumeMatches': true,
      });
    },
  );
}
