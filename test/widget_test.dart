import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/main.dart';
import 'package:subjective_study/repository.dart';

class EmptyRepository extends StudyRepository {
  EmptyRepository() : super(Directory('unused-widget-fixture'));
  @override
  Future<List<Experiment>> experiments() async => [];
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
      expect(find.byKey(const Key('load-demo')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
