import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/quick_test_settings.dart';
import 'package:subjective_study/repository.dart';
import 'package:subjective_study/stimulus_view.dart';
import 'support/stereo_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'new raw-material runs use Half SBS while frozen Full SBS sessions and explicit choices survive',
    () async {
      final temp = await Directory.systemTemp.createTemp('half-sbs-');
      addTearDown(() => temp.delete(recursive: true));
      final repo = StudyRepository(Directory('${temp.path}/repo'));
      final draft = await stereoFixture(
        repo,
        Directory('${temp.path}/source'),
        packed: true,
      );
      final source = draft.definition.toJson();
      (source['metadata'] as Map)['sourceAdapter'] = 'sbs-renders@1';
      final old = await repo.publishDraft(await repo.saveDraft(source));
      final oldDefinition = old.definition!.toJson();
      final session = stereoSession(old);
      await repo.pinSelection(old, session);
      await repo.save(session);
      final model = QuickTestSettings(old.definition!);
      expect(model.layout, 'half_sbs');
      final next = model.definition({'scene': '2'});
      expect(next.stereo!['layout'], 'half_sbs');
      expect(old.definition!.toJson(), oldDefinition);
      final restored = (await repo.sessions(old)).single;
      restored.validate(old);
      expect(
        (await repo.readRelease(
          repo.revisionDir(old.id),
        )).definition!.stereo!['layout'],
        'full_sbs',
      );
      model.layout = 'full_sbs';
      final explicit = model.definition({'scene': '2'});
      expect(QuickTestSettings(explicit).layout, 'full_sbs');
      final plain = source..['presentation'] = {'promptMs': 0, 'imageMs': 100};
      expect(
        QuickTestSettings(StudyDefinition.fromJson(plain)).layout,
        'half_sbs',
      );
    },
  );

  testWidgets(
    'Half SBS squeezes UI and software cursor horizontally without changing height',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final cursorSizes = <String, Size>{};
      for (final layout in ['half_sbs', 'full_sbs']) {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: const Key('capture'),
              child: StereoSurface(
                stereo: {'layout': layout, 'uiDisparity': 0},
                stimulus: false,
                builder: (_, eye) => ColoredBox(
                  color: Colors.black,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 200,
                        top: 100,
                        width: 200,
                        height: 100,
                        child: ColoredBox(
                          key: ValueKey('ui-block-$eye'),
                          color: Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final box = tester.renderObject<RenderBox>(
          find.byKey(const ValueKey('ui-block-0')),
        );
        final physical = MatrixUtils.transformRect(
          box.getTransformTo(null),
          Offset.zero & box.size,
        );
        expect(physical.size, Size(layout == 'half_sbs' ? 100 : 200, 100));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(960, 600));
        await mouse.moveTo(const Offset(961, 600));
        await tester.pump();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          int minX = 1920, maxX = 0, minY = 1080, maxY = 0;
          for (int y = 580; y < 650; y++) {
            for (int x = 440; x < 530; x++) {
              final i = (y * image.width + x) * 4;
              if (data.getUint8(i) > 220 &&
                  data.getUint8(i + 1) > 220 &&
                  data.getUint8(i + 2) > 220) {
                if (x < minX) {
                  minX = x;
                }
                if (x > maxX) {
                  maxX = x;
                }
                if (y < minY) {
                  minY = y;
                }
                if (y > maxY) {
                  maxY = y;
                }
              }
            }
          }
          expect(maxX, greaterThan(minX));
          cursorSizes[layout] = Size(
            (maxX - minX + 1).toDouble(),
            (maxY - minY + 1).toDouble(),
          );
          image.dispose();
        });
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
      }
      expect(
        cursorSizes['half_sbs']!.width * 2,
        closeTo(cursorSizes['full_sbs']!.width, 2),
      );
      // Horizontal resampling can trim one thresholded edge pixel; Y scale is 1.
      expect(
        cursorSizes['half_sbs']!.height,
        closeTo(cursorSizes['full_sbs']!.height, 1),
      );
    },
  );

  testWidgets(
    'Half SBS squeezes each packed eye and its Patch into half width and hides pointers',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 160, 90),
        Paint()..color = Colors.red,
      );
      canvas.drawRect(
        const Rect.fromLTWH(160, 0, 160, 90),
        Paint()..color = Colors.blue,
      );
      final picture = recorder.endRecording();
      final image = (await tester.runAsync(() => picture.toImage(320, 90)))!;
      picture.dispose();
      for (final patch in [
        null,
        {'x': 20, 'y': 10, 'width': 80, 'height': 45},
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: const Key('capture'),
              child: StereoSurface(
                stereo: const {'layout': 'half_sbs', 'uiDisparity': 0},
                stimulus: true,
                builder: (_, eye) =>
                    StimulusView(image: image, packedEye: eye, patch: patch),
              ),
            ),
          ),
        );
        await tester.pump();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('capture')),
        );
        await tester.runAsync(() async {
          final output = await boundary.toImage();
          final bytes = (await output.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          // Top-edge pixels are filled: each full-height eye was squeezed to 960x1080.
          expect(bytes.getUint8((10 * output.width + 100) * 4), 244);
          expect(bytes.getUint8((10 * output.width + 1060) * 4 + 2), 243);
          output.dispose();
        });
        expect(find.byKey(const Key('stereo-cursor-0')), findsNothing);
        expect(find.byKey(const Key('stereo-cursor-1')), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      image.dispose();
    },
  );
}
