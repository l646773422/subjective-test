import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/main.dart';
import 'package:subjective_study/platform_bridge.dart';
import 'package:subjective_study/presentation.dart';
import 'package:subjective_study/repository.dart';

final integrationBinding =
    IntegrationTestWidgetsFlutterBinding.ensureInitialized();
bool canPress(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  return finder.evaluate().isNotEmpty &&
      tester.widget<FilledButton>(finder).onPressed != null;
}

Future<void> until(
  WidgetTester tester,
  bool Function() predicate, {
  int seconds = 50,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for native UI');
    }
    await tester.pump(const Duration(milliseconds: 60));
  }
  await tester.pump();
}

Future<void> capture(
  WidgetTester tester,
  StudyRepository repo,
  String name,
) async {
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('capture-root')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  integrationBinding.reportData ??= <String, dynamic>{};
  final artifacts =
      integrationBinding.reportData!.putIfAbsent(
            'artifacts',
            () => <String, dynamic>{},
          )
          as Map<String, dynamic>;
  artifacts[name] = base64Encode(bytes!.buffer.asUint8List());
  final file = File(p.join(repo.root.path, 'screenshots', '$name.png'));
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
}

Future<StudyRepository> repository(String label) async {
  final root = Directory(
    p.join(
      await PlatformBridge.appDirectory(),
      'native-validation',
      '${label}_${uniqueId()}',
    ),
  );
  await Directory(p.join(root.path, 'experiments')).create(recursive: true);
  await Directory(p.join(root.path, 'sessions')).create();
  return StudyRepository(root);
}

StudySession session(Experiment e, String id) => StudySession(
  id: id,
  experimentId: e.id,
  participantId: id,
  startedAt: DateTime.now().toUtc().toIso8601String(),
  seed: 117,
  participant: {
    'age': 26,
    'expert': false,
    'normalVision': true,
    'normalColorVision': true,
    'organizerOrDeveloper': false,
  },
  display: {
    'condition': '${Platform.operatingSystem} integration',
    'platform': Platform.operatingSystem,
    'device': 'native validation',
    'distanceCm': 60,
  },
  trials: buildSchedule(e, 117),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native real timing, no answer timeout and interruption recovery',
    (tester) async {
      final repo = await repository('timing'), e = await repo.loadDemo();
      final s = session(e, 'timing');
      await repo.save(s);
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: const Key('capture-root'),
            child: TestScreen(repository: repo, experiment: e, session: s),
          ),
        ),
      );
      await until(tester, () => canPress(tester, const Key('begin-phase')));
      await tester.ensureVisible(find.byKey(const Key('begin-phase')));
      await tester.tap(find.byKey(const Key('begin-phase')));
      await until(tester, () => find.byType(TestScreen).evaluate().isNotEmpty);
      final screen = tester.state<TestScreenState>(find.byType(TestScreen));
      await until(tester, () => screen.runner.stage == StudyStage.imageA);
      await capture(tester, repo, 'stimulus');
      await until(tester, () => screen.runner.stage == StudyStage.answer);
      final answerToken = screen.runner.token;
      await tester.pump(const Duration(seconds: 6));
      expect(screen.runner.token, answerToken);
      expect(s.answers, isEmpty);
      await capture(tester, repo, 'answer');
      await screen.runner.interrupt('integration-interruption');
      await tester.pump();
      expect(screen.runner.stage, StudyStage.interrupted);
      expect(s.answers, isEmpty);
      expect(
        s.events.where((event) => event['type'] == 'interruption').length,
        1,
      );
      final saved = (await repo.sessions(e)).single;
      expect(saved.answers, isEmpty);
      final events = s.events
          .where(
            (event) =>
                event['type'] == 'presentation' && event['stage'] != 'answer',
          )
          .toList();
      expect(events.length, 4);
      for (final event in events) {
        final planned = event['plannedMs'] as int,
            actual = event['actualMs'] as int;
        expect(actual, greaterThanOrEqualTo(planned - 20));
        expect(actual, lessThan(planned + 1200));
      }
      await File(
        p.join(repo.root.path, 'timing.json'),
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()));
      // Logged path contains only app-owned validation artifacts.
      integrationBinding.reportData!['timing'] = s.toJson();
      debugPrint('NATIVE_TIMING_ARTIFACT=${repo.root.path}');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 300));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'native UI completes all 46 demo trials and persists exportable results',
    (tester) async {
      final repo = await repository('full-flow');
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture-root'),
          child: StudyApp(repository: repo, testDurationMs: 30),
        ),
      );
      await until(tester, () => canPress(tester, const Key('load-demo')));
      await tester.tap(find.byKey(const Key('load-demo')));
      await until(tester, () => canPress(tester, const Key('go-sessions')));
      await capture(tester, repo, 'preparation');
      await tester.ensureVisible(find.byKey(const Key('go-sessions')));
      await tester.tap(find.byKey(const Key('go-sessions')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-session')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('participant-id')),
        'DEMO-001',
      );
      await tester.ensureVisible(find.byKey(const Key('participant-age')));
      await tester.enterText(find.byKey(const Key('participant-age')), '26');
      await tester.ensureVisible(find.byKey(const Key('device-model')));
      await tester.enterText(
        find.byKey(const Key('device-model')),
        'Native integration device',
      );
      for (final label in ['视力正常（含矫正视力）', '色觉正常', '非本次评价组织者及算法开发相关人员']) {
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pump();
      }
      await tester.ensureVisible(find.byKey(const Key('create-session')));
      await tester.tap(find.byKey(const Key('create-session')));
      await until(tester, () => find.byType(TestScreen).evaluate().isNotEmpty);
      final screen = tester.state<TestScreenState>(find.byType(TestScreen));
      int answers = 0;
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (screen.runner.stage != StudyStage.completed) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Full flow did not complete');
        }
        if (screen.runner.stage == StudyStage.error) fail(screen.runner.error!);
        if (screen.runner.stage == StudyStage.instructions &&
            canPress(tester, const Key('begin-phase'))) {
          await tester.ensureVisible(find.byKey(const Key('begin-phase')));
          await tester.tap(find.byKey(const Key('begin-phase')));
        } else if (screen.runner.stage == StudyStage.answer &&
            !screen.runner.saving) {
          // Formal judgments always choose A (therefore 50%); controls use the fixture oracle.
          final choice = screen.runner.currentCase.kind == 'control'
              ? screen.runner.trial.correctChoice
              : 1;
          await tester.tap(find.byKey(Key('answer-$choice')));
          answers++;
        }
        await tester.pump(const Duration(milliseconds: 70));
      }
      expect(answers, 46);
      final e = (await repo.experiments()).single;
      final loaded = (await repo.sessions(e)).single;
      expect(loaded.answers.length, 46);
      expect(loaded.controlCorrect(e), 2);
      expect(loaded.valid(e), true);
      final group = records(buildReport(e, [loaded])['conditions']).single;
      expect(group['validObservers'], 1);
      expect(records(group['sequences']).every((r) => r['rate'] == .5), true);
      final data = repo.resultsJson(e, [loaded]);
      await File(
        p.join(repo.root.path, 'validation-results.json'),
      ).writeAsBytes(data);
      await File(
        p.join(repo.root.path, 'validation-results.csv'),
      ).writeAsBytes(repo.resultsCsv(e, [loaded]));
      expect(await repo.mergeResults(e, data), 0);
      await tester.tap(find.byKey(const Key('finish-session')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('结果汇总').last);
      await tester.pumpAndSettle();
      await capture(tester, repo, 'results');
      integrationBinding.reportData!['results'] = jsonDecode(utf8.decode(data));
      debugPrint('NATIVE_FLOW_ARTIFACT=${repo.root.path}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
