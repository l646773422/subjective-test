import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:subjective_study/presentation.dart';
import 'package:subjective_study/repository.dart';
import 'package:subjective_study/stimulus_view.dart';
import '../test/support/stereo_fixture.dart';
import 'flow_test.dart' as support;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows SBS eyes, patch, both-half input, pause and disk resume',
    (tester) async {
      support.integrationBinding.reportData = {
        'purpose': 'synthetic stereo workflow validation',
        'testTimingMode':
            'synthetic images; configured prompt 80ms and image 1200ms',
        'layouts': <Map<String, dynamic>>[],
      };
      for (final layout in ['half_sbs', 'full_sbs']) {
        final root = Directory('validation/stereo-$layout-${uuid()}');
        final repo = StudyRepository(Directory('${root.path}/repo'));
        final d = await stereoFixture(
          repo,
          Directory('${root.path}/source'),
          layout: layout,
        );
        final source = d.definition.toJson();
        (source['presentation'] as Map)['promptMs'] = 80;
        (source['presentation'] as Map)['imageMs'] = 1200;
        final e = await repo.publishDraft(await repo.saveDraft(source));
        var s = stereoSession(e);
        await repo.pinSelection(e, s);
        await repo.save(s);
        final frozen = jsonEncode(s.trials.map((t) => t.toJson()).toList());
        Future<TestScreenState> mount() async {
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

        var screen = await mount();
        Offset inputPosition(Key key) {
          final center = tester.getCenter(find.byKey(key).first);
          final origin = tester.getTopLeft(find.byType(StereoSurface));
          final shift = layout == 'half_sbs' ? 3.0 : 6.0;
          return Offset(
            origin.dx + (center.dx - origin.dx - shift) * 2,
            center.dy,
          );
        }

        Future<void> click(Key key) => tester.tapAt(inputPosition(key));
        await support.capture(tester, repo, '$layout-instructions');
        await screen.leave();
        await tester.pump();
        expect(find.byKey(const Key('confirm-leave')), findsNWidgets(2));
        await support.capture(tester, repo, '$layout-exit');
        await click(const Key('continue-test'));
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
        final views = tester
            .widgetList<StimulusView>(find.byType(StimulusView))
            .toList();
        expect(views.length, 2);
        expect(views[0].image, same(screen.runner.imageA));
        expect(views[1].image, same(screen.runner.imageARight));
        expect(views[0].image, isNot(same(views[1].image)));
        await support.capture(tester, repo, '$layout-patch');
        expect(find.byKey(const Key('stereo-cursor-0')), findsNothing);
        expect(views[0].patch, views[1].patch);
        await reach(StudyStage.answer);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        final target = inputPosition(const Key('answer-1'));
        await mouse.addPointer(location: target);
        await mouse.moveTo(target + const Offset(1, 1));
        await tester.pump();
        expect(find.byKey(const Key('stereo-cursor-0')), findsOneWidget);
        expect(find.byKey(const Key('stereo-cursor-1')), findsOneWidget);
        await support.capture(tester, repo, '$layout-answer');
        await click(const Key('answer-1'));
        await support.until(
          tester,
          () => s.answers.length == 1 && !screen.runner.saving,
        );
        expect(s.answers.length, 1);
        await screen.runner.interrupt('stereo-disk-restart');
        await tester.pump();
        await support.capture(tester, repo, '$layout-paused');
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        s = (await repo.sessions(e)).single;
        expect(jsonEncode(s.trials.map((t) => t.toJson()).toList()), frozen);
        screen = await mount();
        await click(const Key('begin-phase'));
        while (!s.complete) {
          await reach(StudyStage.answer);
          final count = s.answers.length;
          await click(const Key('answer-2'));
          await support.until(
            tester,
            () => s.answers.length == count + 1 && !screen.runner.saving,
          );
        }
        await tester.pump();
        s.validate(e);
        await support.capture(tester, repo, '$layout-completed');
        final images = s.events
            .where((ev) => ['imageA', 'imageB'].contains(ev['stage']))
            .toList();
        expect(images.length, 8);
        for (final event in images) {
          final trial = s.trials.firstWhere((t) => t.id == event['trialId']);
          expect(event['viewport']['patch'], trial.patch);
          expect(event['viewport']['stereo']['layout'], layout);
        }
        final csv = utf8.decode(repo.resultsCsv(e, [s]));
        expect(csv, contains('patch_width'));
        expect(csv, contains('a_right_sha256'));
        (support.integrationBinding.reportData!['layouts'] as List).add({
          'layout': layout,
          'answers': s.answers.length,
          'imageEvents': images.length,
          'materialHashes': s.materialHashes.length,
          'resumedTrialMatches': true,
          'repository': root.absolute.path,
        });
        await File(
          '${root.path}/session.json',
        ).writeAsString(jsonEncode(s.toJson()));
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    },
  );
}
