import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/repository.dart';
import 'package:subjective_study/presentation.dart';
import 'package:subjective_study/stimulus_view.dart';
import 'support/stereo_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'mono stimulus hides a stationary pointer and restores it afterward',
    (tester) async {
      final showing = ValueNotifier(false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: showing,
              builder: (context, value, _) => StereoSurface(
                stereo: null,
                stimulus: value,
                builder: (context, eye) => value
                    ? const ColoredBox(color: Colors.blue)
                    : Center(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            enabledMouseCursor: SystemMouseCursors.click,
                          ),
                          onPressed: () {},
                          child: const Text('选择'),
                        ),
                      ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(find.byType(FilledButton)),
      );
      await mouse.moveTo(
        tester.getCenter(find.byType(FilledButton)) + const Offset(1, 1),
      );
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      showing.value = true;
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.none,
      );
      showing.value = false;
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      showing.dispose();
    },
  );
  testWidgets('binocular instruction scrolling remains synchronized', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StereoSurface(
            stereo: const {'layout': 'half_sbs', 'uiDisparity': 0},
            stimulus: false,
            builder: (context, eye) => SingleChildScrollView(
              primary: true,
              child: SizedBox(
                height: 2000,
                child: Column(
                  children: List.generate(
                    20,
                    (i) => SizedBox(height: 100, child: Text('说明 $i')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(200, 400), const Offset(0, -200));
    await tester.pumpAndSettle();
    final positions = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .map((s) => s.position.pixels)
        .toList();
    expect(positions.length, 2);
    expect(positions.first, greaterThan(100));
    expect(positions.first, positions.last);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
  test(
    'patch area, center density, frame/view independence and frozen resume',
    () async {
      final temp = await Directory.systemTemp.createTemp('stereo-patch-');
      addTearDown(() => temp.delete(recursive: true));
      final repo = StudyRepository(Directory('${temp.path}/repo'));
      final d = await stereoFixture(
        repo,
        Directory('${temp.path}/source'),
        legacyArea: true,
      );
      final e = await repo.publishDraft(d);
      final noPatch = d.definition.toJson();
      (noPatch['presentation'] as Map).remove('patch');
      final full = await repo.publishDraft(await repo.saveDraft(noPatch));
      for (int seed = 0; seed < 50; seed++) {
        final trials = buildSchedule(e, seed),
            originals = buildSchedule(full, seed);
        expect(trials.map((t) => t.caseId), originals.map((t) => t.caseId));
        expect(trials.map((t) => t.order), originals.map((t) => t.order));
        for (final t in trials) {
          expect(t.patch!['width'], 160);
          expect(t.patch!['height'], 90);
          expect(
            trials.firstWhere((other) => other.caseId == t.caseId).patch,
            t.patch,
          );
        }
      }
      final s = stereoSession(e);
      await repo.pinSelection(e, s);
      await repo.save(s);
      expect(s.materialHashes.length, 8);
      final restored = (await repo.sessions(e)).single;
      expect(
        restored.trials.map((t) => t.toJson()),
        s.trials.map((t) => t.toJson()),
      );
      expect(e.release!['implementations']['scheduler'], '2afc-schedule@3');
      expect(e.release!['implementations']['method'], '2afc-stereo@1');
      restored.validate(e);
      final raw = jsonMap(jsonDecode(jsonEncode(restored.toJson())), 'session');
      (((raw['trials'] as List).first as Map)['patch'] as Map)['x'] = 0;
      expect(
        () => StudySession.fromJson(raw).validate(e),
        throwsFormatException,
      );
      final zip = ZipDecoder().decodeBytes(await repo.exportPackage(e));
      expect(zip.files.map((f) => f.name).toSet(), {
        'study.json',
        'release.json',
      });
      final random = StableRandom(999);
      int center = 0, edge = 0;
      for (int i = 0; i < 20000; i++) {
        final r = samplePatch(1000, 500, 0.25, random);
        final x = (r['x'] as int) / 500;
        if (x >= 0.4 && x < 0.6) center++;
        if (x < 0.1 || x >= 0.9) edge++;
        expect(r['x'], inInclusiveRange(0, 500));
        expect(r['y'], inInclusiveRange(0, 250));
      }
      expect(center, greaterThan(edge * 5));
      expect(samplePatch(1, 1, 0.001, random), {
        'x': 0,
        'y': 0,
        'width': 1,
        'height': 1,
      });
      expect(samplePatch(100, 50, 1, random), {
        'x': 0,
        'y': 0,
        'width': 100,
        'height': 50,
      });
    },
  );

  test(
    'stereo requires both eyes and rejects unequal dimensions; old mono still accepts them',
    () async {
      final temp = await Directory.systemTemp.createTemp('stereo-validation-');
      addTearDown(() => temp.delete(recursive: true));
      final repo = StudyRepository(Directory('${temp.path}/repo'));
      final d = await stereoFixture(repo, Directory('${temp.path}/source'));
      final broken = d.definition.toJson();
      (broken['items'] as List).first.remove('aRight');
      StudyDefinition.fromJson(broken, draft: true);
      expect(() => StudyDefinition.fromJson(broken), throwsFormatException);
      final e = await repo.publishDraft(d);
      final release = jsonMap(jsonDecode(jsonEncode(e.release)), 'release');
      (release['assets'] as List).first['width'] = 321;
      expect(
        () => Experiment.fromRelease(d.definition.toJson(), release),
        throwsFormatException,
      );
      for (final p in [
        {
          'patch': {'area': 0},
        },
        {
          'patch': {'area': 1.1},
        },
        {
          'stereo': {'layout': 'anaglyph'},
        },
        {
          'stereo': {'uiDisparity': 65},
        },
        {'stereo': null},
        {'patch': null},
      ]) {
        final bad = d.definition.toJson()..['presentation'] = p;
        expect(() => StudyDefinition.fromJson(bad), throwsFormatException);
      }
      // A changed right-eye file is verified before any partial eye pair is presented.
      final s = stereoSession(e);
      await repo.pinSelection(e, s);
      final path = e.caseById(s.trials.first.caseId).aRight!;
      await File('${temp.path}/source/$path').writeAsBytes([1, 2, 3]);
      final runner = SessionRunner(repo, e, s);
      await runner.loadTrial();
      expect(runner.stage, StudyStage.error);
      expect(runner.imageA, isNull);
      expect(runner.imageARight, isNull);
      runner.dispose();
    },
  );

  test(
    'pixel patches keep exact independent dimensions, freeze sessions and reject oversized candidates',
    () async {
      final temp = await Directory.systemTemp.createTemp('pixel-patch-');
      addTearDown(() => temp.delete(recursive: true));
      final repo = StudyRepository(Directory('${temp.path}/repo'));
      final d = await stereoFixture(repo, Directory('${temp.path}/source'));
      final e = await repo.publishDraft(d);
      expect(e.definition!.schedulerVersion, '2afc-schedule@4');
      expect(e.definition!.stereo!['layout'], 'full_sbs');
      final s = stereoSession(e);
      await repo.pinSelection(e, s);
      await repo.save(s);
      final restored = (await repo.sessions(e)).single;
      restored.validate(e);
      expect(
        restored.trials.map((t) => t.toJson()),
        s.trials.map((t) => t.toJson()),
      );
      for (final trial in s.trials) {
        expect(trial.patch!['width'], 128);
        expect(trial.patch!['height'], 96);
        expect(trial.patch!['x'], inInclusiveRange(0, 320 - 128));
        expect(trial.patch!['y'], inInclusiveRange(0, 180 - 96));
        expect(
          s.trials.firstWhere((t) => t.caseId == trial.caseId).patch,
          trial.patch,
        );
      }
      // A fixed pixel region has the same dimensions on 1080p and 4K.
      final random = StableRandom(117);
      for (final (width, height) in [(1920, 1080), (3840, 2160)]) {
        final patch = samplePixelPatch(width, height, 512, 320, random);
        expect(patch['width'], 512);
        expect(patch['height'], 320);
      }
      expect(samplePixelPatch(320, 180, 320, 180, random), {
        'x': 0,
        'y': 0,
        'width': 320,
        'height': 180,
      });
      for (final (width, height) in [(321, 90), (160, 181)]) {
        final source = d.definition.toJson();
        (source['presentation'] as Map)['patch'] = {
          'width': width,
          'height': height,
        };
        final draft = await repo.saveDraft(source);
        await expectLater(repo.publishDraft(draft), throwsFormatException);
      }
      for (final patch in [
        <String, dynamic>{},
        {'width': 1},
        {'height': 1},
        {'width': 0, 'height': 1},
        {'width': true, 'height': 2},
        {'width': 1.5, 'height': 2},
        {'width': 40000000, 'height': 2},
        {'width': 128, 'height': 96, 'area': 0.25},
      ]) {
        final source = d.definition.toJson();
        (source['presentation'] as Map)['patch'] = patch;
        expect(() => StudyDefinition.fromJson(source), throwsFormatException);
      }
      final source = d.definition.toJson();
      (source['presentation'] as Map)['stereo'] = {};
      expect(StudyDefinition.fromJson(source).stereo!['layout'], 'full_sbs');
      expect(
        d.definition.toJson()['presentation']['patch'].containsKey('area'),
        false,
      );
    },
  );

  for (final layout in ['half_sbs', 'full_sbs']) {
    testWidgets(
      '$layout maps clicks and cursor from both eyes, hides cursors on stimulus',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        int count = 0;
        final stimulus = ValueNotifier(false);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder(
                valueListenable: stimulus,
                builder: (context, value, child) => StereoSurface(
                  stereo: {
                    'layout': layout,
                    'uiDisparity': 12,
                    'pointerMapping': 'per_eye',
                  },
                  stimulus: value,
                  builder: (context, eye) => Center(
                    child: FilledButton(
                      key: Key('click-$eye'),
                      onPressed: () => count++,
                      child: const Text('选择'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final eye0 = find.byKey(const Key('stereo-eye-0'));
        final eye1 = find.byKey(const Key('stereo-eye-1'));
        final bounds0 = tester.getSize(eye0), bounds1 = tester.getSize(eye1);
        expect(bounds0, bounds1);
        expect(bounds0.width, layout == 'half_sbs' ? 1280 : 640);
        await tester.tap(find.byKey(const Key('click-0')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('click-1')));
        await tester.pump();
        expect(count, 2);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(900, 300));
        await mouse.moveTo(const Offset(950, 310));
        await tester.pump();
        expect(find.byKey(const ValueKey('stereo-cursor-0')), findsOneWidget);
        expect(find.byKey(const ValueKey('stereo-cursor-1')), findsOneWidget);
        final regions = tester.renderObjectList<RenderMouseRegion>(
          find.byType(MouseRegion),
        );
        expect(regions.any((r) => r.cursor == SystemMouseCursors.none), true);
        stimulus.value = true;
        await tester.pump();
        expect(find.byKey(const ValueKey('stereo-cursor-0')), findsNothing);
        expect(find.byKey(const ValueKey('stereo-cursor-1')), findsNothing);
        await mouse.moveTo(const Offset(960, 320));
        await tester.pump();
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.none,
        );
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
        stimulus.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final layout in ['half_sbs', 'full_sbs']) {
    testWidgets(
      '$layout continuous full-screen mouse hits the fused UI without midpoint wrapping',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final choices = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StereoSurface(
                stereo: {
                  'layout': layout,
                  'uiDisparity': 12,
                  'pointerMapping': 'screen',
                },
                stimulus: false,
                builder: (context, eye) => Row(
                  children: [
                    for (final choice in [1, 2])
                      Expanded(
                        child: Center(
                          child: FilledButton(
                            onPressed: () => choices.add(choice),
                            child: Text('选 $choice'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // Logical buttons lie at 25% and 75% of the binocular screen.
        await tester.tapAt(const Offset(320, 360));
        await tester.pump();
        await tester.tapAt(const Offset(960, 360));
        await tester.pump();
        expect(choices, [1, 2]);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
}
