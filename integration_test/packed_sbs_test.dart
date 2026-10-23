import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/presentation.dart';
import 'package:subjective_study/quick_test_panel.dart';
import 'package:subjective_study/repository.dart';
import 'package:subjective_study/stimulus_view.dart';
import '../test/support/stereo_fixture.dart' show stereoSession;
import 'flow_test.dart' as support;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows real packed SBS: one-page setup, full eyes, matched patches, answers and resume',
    (tester) async {
      const path = String.fromEnvironment('STUDY_RENDER_ROOT');
      expect(path, isNotEmpty);
      final root = Directory('validation/packed-sbs-${uuid()}');
      final repo = StudyRepository(root);
      await repo.initializeV2();
      final draft = await repo.loadQuickDirectory(Directory(path));
      expect(draft.definition.items.length, 1500);
      expect(draft.definition.packedStereo, true);
      StudyDefinition? selected;
      support.integrationBinding.reportData = {
        'purpose': 'real prepacked Dunhuang SBS workflow simulation',
        'repository': root.absolute.path,
        'testTimingMode': '0ms prompts, 3000ms per image',
        'poolPairs': 1500,
      };
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: const Key('capture-root'),
            child: Scaffold(
              body: SingleChildScrollView(
                child: QuickTestPanel(
                  repository: repo,
                  busy: false,
                  active: null,
                  sessions: const [],
                  onSource: (_) async {},
                  onStart: (_, settings) async {
                    selected = settings;
                  },
                  onResume: (_, _) async {},
                ),
              ),
            ),
          ),
        ),
      );
      await support.until(
        tester,
        () => find
            .byKey(const Key('quick-count-Dance_Dunhuang_Pair_1080'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('素材：已拼 SBS'), findsOneWidget);
      expect(find.textContaining('尚未指定右眼'), findsNothing);
      Future<void> enter(String key, String value) async {
        final f = find.byKey(Key(key));
        await tester.ensureVisible(f);
        await tester.enterText(f, value);
        await tester.pump();
      }

      Future<void> tap(String key) async {
        FocusManager.instance.primaryFocus?.unfocus();
        final f = find.byKey(Key(key));
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        await tester.tap(f);
        await tester.pumpAndSettle();
      }

      await enter('quick-count-Dance_Dunhuang_Pair_1080', '2');
      await tap('quick-patch-enabled');
      await enter('quick-patch-width', '512');
      await enter('quick-patch-height', '320');
      await support.capture(tester, repo, 'packed-setup');
      await tap('quick-start-test');
      expect(selected!.packedStereo, true);
      expect(selected!.trialCount, 4);
      final source = selected!.toJson();
      (source['presentation'] as Map)['promptMs'] = 0;
      final e = await repo.prepareQuickTest(
        draft,
        StudyDefinition.fromJson(source),
      );
      var s = stereoSession(e);
      await repo.pinSelection(e, s);
      await repo.save(s);
      final frozen = jsonEncode(s.trials.map((t) => t.toJson()).toList());
      Future<TestScreenState> mount(
        Experiment experiment,
        StudySession session,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: const Key('capture-root'),
              child: TestScreen(
                repository: repo,
                experiment: experiment,
                session: session,
              ),
            ),
          ),
        );
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
        await tester.pumpAndSettle();
        return tester.state<TestScreenState>(find.byType(TestScreen));
      }

      Offset inputPosition(String key) {
        final center = tester.getCenter(find.byKey(Key(key)).first);
        final origin = tester.getTopLeft(find.byType(StereoSurface));
        return Offset(origin.dx + (center.dx - origin.dx) * 2, center.dy);
      }

      Future<void> click(String key) => tester.tapAt(inputPosition(key));
      late TestScreenState screen;
      Future<void> reach(StudyStage stage) async {
        await support.until(
          tester,
          () => [
            stage,
            StudyStage.interrupted,
            StudyStage.error,
          ].contains(screen.runner.stage),
        );
        if (screen.runner.stage == StudyStage.error) fail(screen.runner.error!);
        if (screen.runner.stage == StudyStage.interrupted) {
          await screen.runner.begin();
          await reach(stage);
        }
      }

      // Whole-image mode must split the existing SBS exactly once.
      final wholeSource = e.definition!.toJson();
      (wholeSource['presentation'] as Map).remove('patch');
      final whole = await repo.prepareQuickTest(
        draft,
        StudyDefinition.fromJson(wholeSource),
      );
      final wholeSession = stereoSession(whole);
      await repo.pinSelection(whole, wholeSession);
      screen = await mount(whole, wholeSession);
      await click('begin-phase');
      await reach(StudyStage.imageA);
      final fullViews = tester
          .widgetList<StimulusView>(find.byType(StimulusView))
          .toList();
      expect(fullViews.length, 2);
      expect(fullViews[0].image, same(fullViews[1].image));
      expect(
        StimulusView.sourceRect(fullViews[0].image, null, packedEye: 0),
        const Rect.fromLTWH(0, 0, 1920, 1080),
      );
      expect(
        StimulusView.sourceRect(fullViews[1].image, null, packedEye: 1),
        const Rect.fromLTWH(1920, 0, 1920, 1080),
      );
      await support.capture(tester, repo, 'packed-whole');
      await screen.runner.interrupt('whole-image-check');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      screen = await mount(e, s);
      await support.capture(tester, repo, 'packed-instructions');
      await click('begin-phase');
      await reach(StudyStage.imageA);
      final views = tester
          .widgetList<StimulusView>(find.byType(StimulusView))
          .toList();
      expect(views[0].image, same(views[1].image));
      expect(screen.runner.imageARight, isNull);
      expect(views.map((v) => v.packedEye).toList(), [0, 1]);
      final left = StimulusView.sourceRect(
        views[0].image,
        views[0].patch,
        packedEye: 0,
      );
      final right = StimulusView.sourceRect(
        views[1].image,
        views[1].patch,
        packedEye: 1,
      );
      expect(left.size, const Size(512, 320));
      expect(left.right, lessThanOrEqualTo(1920));
      expect(right, left.shift(const Offset(1920, 0)));
      expect(find.byKey(const Key('stereo-cursor-0')), findsNothing);
      await support.capture(tester, repo, 'packed-patch');
      await reach(StudyStage.answer);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: inputPosition('answer-1'));
      await mouse.moveTo(inputPosition('answer-1') + const Offset(1, 1));
      await tester.pump();
      expect(find.byKey(const Key('stereo-cursor-0')), findsOneWidget);
      expect(find.byKey(const Key('stereo-cursor-1')), findsOneWidget);
      await support.capture(tester, repo, 'packed-answer');
      await click('answer-1');
      await support.until(
        tester,
        () => s.answers.length == 1 && !screen.runner.saving,
      );
      await screen.runner.interrupt('packed-disk-restart');
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      s = (await repo.sessions(e)).single;
      expect(jsonEncode(s.trials.map((t) => t.toJson()).toList()), frozen);
      screen = await mount(e, s);
      await click('begin-phase');
      while (!s.complete) {
        await reach(StudyStage.answer);
        final count = s.answers.length;
        await click('answer-2');
        await support.until(
          tester,
          () => s.answers.length == count + 1 && !screen.runner.saving,
        );
      }
      s.validate(e);
      final imageEvents = s.events
          .where((ev) => ['imageA', 'imageB'].contains(ev['stage']))
          .toList();
      expect(imageEvents.length, 8);
      for (final event in imageEvents) {
        final rects = event['viewport']['eyeSourceRects'] as List;
        expect(rects[1]['x'] - rects[0]['x'], 1920);
        expect(rects[1]['y'], rects[0]['y']);
        expect(rects[0]['width'], 512);
        expect(rects[1]['height'], 320);
      }
      expect(utf8.decode(repo.resultsCsv(e, [s])), contains('stereo_input'));
      expect(s.materialHashes.length, 4);
      await support.capture(tester, repo, 'packed-completed');
      support.integrationBinding.reportData!.addAll(<String, dynamic>{
        'answers': s.answers.length,
        'imageEvents': imageEvents.length,
        'materialHashes': s.materialHashes.length,
        'cropPerEye': s.trials.first.patch,
        'resumeMatches': true,
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
