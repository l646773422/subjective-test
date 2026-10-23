import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/repository.dart';
import 'package:subjective_study/quick_test_settings.dart';
import 'package:subjective_study/stimulus_view.dart';
import 'material_pool_test.dart' show tree;
import 'support/stereo_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'packed eyes sample within one eye, preserve order and freeze on disk',
    () async {
      final temp = await Directory.systemTemp.createTemp('packed-sbs-');
      addTearDown(() => temp.delete(recursive: true));
      final repo = StudyRepository(Directory('${temp.path}/repo'));
      final draft = await stereoFixture(
        repo,
        Directory('${temp.path}/source'),
        packed: true,
      );
      final e = await repo.publishDraft(draft);
      expect(e.definition!.packedStereo, true);
      expect(e.definition!.methodVersion, '2afc-sbs@1');
      expect(e.definition!.schedulerVersion, '2afc-schedule@5');
      for (final input in [null, 'guess']) {
        final invalid = e.definition!.toJson();
        (invalid['presentation'] as Map)['stereo']['input'] = input;
        expect(() => StudyDefinition.fromJson(invalid), throwsFormatException);
      }
      expect(e.cases.first.width, 640);
      expect(e.cases.first.aRight, isNull);
      final settings = QuickTestSettings(e.definition!);
      expect(settings.stereoInput, 'sbs');
      expect(settings.error({'scene': '2'}), isNull);
      final noPatch = draft.definition.toJson();
      (noPatch['presentation'] as Map).remove('patch');
      final full = await repo.publishDraft(await repo.saveDraft(noPatch));
      for (int seed = 0; seed < 100; seed++) {
        final trials = buildSchedule(e, seed),
            fullTrials = buildSchedule(full, seed);
        expect(trials.map((t) => t.caseId), fullTrials.map((t) => t.caseId));
        expect(trials.map((t) => t.order), fullTrials.map((t) => t.order));
        for (final trial in trials) {
          final p = trial.patch!;
          expect(p['width'], 128);
          expect(p['height'], 96);
          expect((p['x'] as int) + 128, lessThanOrEqualTo(320));
          expect((p['y'] as int) + 96, lessThanOrEqualTo(180));
          expect(trials.firstWhere((t) => t.caseId == trial.caseId).patch, p);
        }
      }
      final s = stereoSession(e);
      await repo.pinSelection(e, s);
      await repo.save(s);
      final restored = (await repo.sessions(e)).single;
      restored.validate(e);
      expect(
        restored.trials.map((t) => t.toJson()),
        s.trials.map((t) => t.toJson()),
      );
      expect(restored.materialHashes.length, 4);
      final tooWide = draft.definition.toJson();
      (tooWide['presentation'] as Map)['patch'] = {'width': 321, 'height': 96};
      await expectLater(
        repo.publishDraft(await repo.saveDraft(tooWide)),
        throwsFormatException,
      );
      final badRelease = Map<String, dynamic>.from(e.release!);
      badRelease['assets'] = [
        for (final a in records(e.release!['assets'])) {...a, 'width': 639},
      ];
      expect(
        () => Experiment.fromRelease(e.definition!.toJson(), badRelease),
        throwsFormatException,
      );
    },
  );

  test(
    'a single direct renders sequence loads as packed SBS and keeps old pools unchanged',
    () async {
      final temp = await Directory.systemTemp.createTemp('packed-pool-');
      addTearDown(() => temp.delete(recursive: true));
      final repo = StudyRepository(temp);
      final packedTree = tree();
      packedTree['entries'] = [
        for (final entry in records(
          packedTree['entries'],
        ).where((a) => (a['path'] as String).startsWith('Dance_')))
          {
            ...entry,
            'path': (entry['path'] as String).replaceFirst('/primitive/', '/'),
            'width': 3840,
            'height': 1080,
          },
      ];
      final draft = await repo.createRenderPool(packedTree);
      final e = await repo.publishDraft(draft);
      expect(e.cases.length, 180);
      expect(e.definition!.packedStereo, true);
      expect(e.definition!.selectedMainCount, 6);
      expect(e.definition!.trialCount, 12);
      expect((await repo.createRenderPool(packedTree)).id, draft.id);
      final old = await repo.createRenderPool(tree());
      expect(old.definition.stereo, isNull);
      expect(old.definition.selectedMainCount, 20);
    },
  );

  testWidgets(
    'packed full images and patches draw each eye once with the same local crop',
    (tester) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 200, 100),
        Paint()..color = Colors.red,
      );
      canvas.drawRect(
        const Rect.fromLTWH(200, 0, 200, 100),
        Paint()..color = Colors.blue,
      );
      final picture = recorder.endRecording();
      final image = await tester.runAsync(() => picture.toImage(400, 100));
      picture.dispose();
      for (final patch in [
        null,
        {'x': 120, 'y': 30, 'width': 60, 'height': 40},
      ]) {
        final left = StimulusView.sourceRect(image!, patch, packedEye: 0);
        final right = StimulusView.sourceRect(image, patch, packedEye: 1);
        expect(right, left.shift(const Offset(200, 0)));
        expect(left.right, lessThanOrEqualTo(200));
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: const Key('pixels'),
              child: StereoSurface(
                stereo: const {
                  'input': 'sbs',
                  'layout': 'full_sbs',
                  'uiDisparity': 0,
                },
                stimulus: true,
                builder: (_, eye) =>
                    StimulusView(image: image, patch: patch, packedEye: eye),
              ),
            ),
          ),
        );
        await tester.pump();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('pixels')),
        );
        await tester.runAsync(() async {
          final screenshot = await boundary.toImage();
          final data = (await screenshot.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final y = screenshot.height ~/ 2;
          final leftPixel = (y * screenshot.width + screenshot.width ~/ 4) * 4;
          final rightPixel =
              (y * screenshot.width + screenshot.width * 3 ~/ 4) * 4;
          expect(data.getUint8(leftPixel), 244);
          expect(data.getUint8(rightPixel + 2), 243);
          screenshot.dispose();
        });
        expect(find.byKey(const Key('stereo-cursor-0')), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      image!.dispose();
    },
  );
}
