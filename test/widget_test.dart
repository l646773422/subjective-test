import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/main.dart';
import 'package:subjective_study/repository.dart';
import 'package:subjective_study/draft_editor.dart';
import 'package:subjective_study/participant_dialog.dart';
import 'package:subjective_study/study_templates.dart';

class EmptyRepository extends StudyRepository {
  EmptyRepository() : super(Directory('unused-widget-fixture'));
  @override
  Future<List<Experiment>> experiments() async => [];
  @override
  Future<List<StudyDraft>> drafts() async => [];
}

class DraftMemoryRepository extends EmptyRepository {
  StudyDraft? saved;
  @override
  Future<StudyDraft> saveDraft(Map<String, dynamic> source) async =>
      saved = StudyDraft(StudyDefinition.fromJson(source, draft: true));
}

void main() {
  for (final size in [const Size(1280, 800), const Size(411, 850)]) {
    testWidgets('empty workbench fits $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(StudyApp(repository: EmptyRepository()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quick-material-directory')), findsOneWidget);
      expect(find.byKey(const Key('quick-load-materials')), findsOneWidget);
      await tester.tap(find.text('高级实验管理'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('load-demo')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'draft editor autosaves a changed question and fits phone layout',
    (tester) async {
      tester.view.physicalSize = const Size(411, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final repo = DraftMemoryRepository();
      final draft = StudyDraft(
        StudyDefinition.fromJson(newStudySource('editor-test'), draft: true),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DraftEditor(repository: repo, draft: draft),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('study-question')),
        '修改后自动保存的问题',
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(repo.saved!.definition.question, '修改后自动保存的问题');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('generic registration requires no fixed demographics', (
    tester,
  ) async {
    Map<String, dynamic>? result;
    final definition = StudyDefinition.fromJson(
      newStudySource('generic'),
      draft: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<Map<String, dynamic>>(
                  context: context,
                  builder: (_) =>
                      GenericParticipantDialog(definition: definition),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('participant-id')), 'P1');
    expect(find.byKey(const Key('participant-age')), findsNothing);
    await tester.tap(find.byKey(const Key('create-session')));
    await tester.pumpAndSettle();
    expect(result!['participant'], isEmpty);
    expect(result!['participantId'], 'P1');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'editor defaults to Full SBS and saves exact pixel patch dimensions',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final repo = DraftMemoryRepository();
      final draft = StudyDraft(
        StudyDefinition.fromJson(newStudySource('pixel-editor'), draft: true),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DraftEditor(repository: repo, draft: draft),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('stereo-enabled')));
      await tester.tap(find.byKey(const Key('stereo-enabled')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('patch-enabled')));
      await tester.tap(find.byKey(const Key('patch-enabled')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('patch-width')));
      await tester.enterText(find.byKey(const Key('patch-width')), '512');
      await tester.enterText(find.byKey(const Key('patch-height')), '320');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(repo.saved!.definition.stereo!['layout'], 'full_sbs');
      expect(repo.saved!.definition.patch, {
        'width': 512,
        'height': 320,
        'distribution': 'center_triangular',
      });
      expect(find.byKey(const Key('patch-area')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
