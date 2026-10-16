import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subjective_study/domain.dart';
import 'package:subjective_study/repository.dart';
import 'domain_test.dart' show completed;

void main() {
  late Directory temp;
  late StudyRepository repo;
  late Uint8List zip;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pcnl-study-tests-');
    await Directory(p.join(temp.path, 'experiments')).create();
    await Directory(p.join(temp.path, 'sessions')).create();
    repo = StudyRepository(temp);
    zip = await File('assets/demo.study.zip').readAsBytes();
  });
  tearDown(() async {
    if (temp.absolute.path.contains('pcnl-study-tests-')) {
      await temp.delete(recursive: true);
    }
  });
  test('portable package validates images and survives a round trip', () async {
    final e = await repo.importZip(zip);
    await repo.verify(e);
    final bytes = await repo.exportPackage(e);
    final again = await repo.importZip(bytes);
    expect(again.id, e.id);
    expect((await repo.experiments()).length, 1);
  });
  test(
    'tampered picture is rejected without changing the frozen study',
    () async {
      final e = await repo.importZip(zip);
      await repo.imageFile(e, e.cases.first.gt).writeAsBytes([0, 1, 2]);
      await expectLater(repo.verify(e), throwsFormatException);
    },
  );
  test('zip traversal is rejected before any extraction', () async {
    final archive = Archive()..addFile(ArchiveFile('../outside.txt', 1, [1]));
    await expectLater(
      repo.importZip(Uint8List.fromList(ZipEncoder().encode(archive))),
      throwsFormatException,
    );
  });
  test(
    'source scan picks largest iteration and correctly pairs all six views',
    () async {
      final scan = await scanSource(
        p.join(
          'demo-data',
          'raw-sequences',
          'Dance_Dunhuang_Pair_1080',
          'demo',
        ),
        'Dance_Dunhuang_Pair_1080',
      );
      expect(scan.frames.length, 1);
      expect(scan.frames.single.length, 6);
      expect(scan.frames.single.every((c) => c.iteration == 30000), true);
      expect(scan.frames.single.map((c) => c.view).toList(), [
        0,
        10,
        20,
        30,
        40,
        50,
      ]);
      expect(scan.isDemo, true);
    },
  );
  test(
    'invalid newest iteration never silently falls back to older images',
    () async {
      final root = Directory(p.join(temp.path, 'source'));
      final original = Directory(
        p.join(
          'demo-data',
          'raw-sequences',
          'VRU_gz',
          'demo',
          'frame000000',
          'test',
          'ours_30000',
        ),
      );
      await for (final file in original.list(recursive: true)) {
        if (file is! File) continue;
        final dest = File(
          p.join(
            root.path,
            'frame000000',
            'test',
            'ours_30000',
            p.relative(file.path, from: original.path),
          ),
        );
        await dest.parent.create(recursive: true);
        await file.copy(dest.path);
      }
      await Directory(
        p.join(root.path, 'frame000000', 'test', 'ours_99999'),
      ).create(recursive: true);
      final scan = await scanSource(root.path, 'VRU_gz');
      expect(scan.frames, isEmpty);
      expect(scan.issues.single, contains('最大迭代'));
    },
  );
  test(
    'four raw sources and auxiliary pairs freeze into a portable fixed demo',
    () async {
      final demo = await repo.importZip(zip);
      final sources = <SourceScan>[];
      for (final key in protocolViews.keys) {
        sources.add(
          await scanSource(
            p.join('demo-data', 'raw-sequences', key, 'demo'),
            key,
          ),
        );
      }
      final aux = demo.cases
          .where((c) => c.kind != 'main')
          .map(
            (c) => StudyCase.fromJson({
              ...c.toJson(),
              'gt': repo.imageFile(demo, c.gt).path,
              'render': repo.imageFile(demo, c.render).path,
            }),
          )
          .toList();
      final fixed = await repo.freezeSources(
        name: 'Raw fixture roundtrip',
        seed: 42,
        sources: sources,
        auxiliary: aux,
      );
      expect(fixed.isDemo, true);
      expect(fixed.cases.where((c) => c.kind == 'main').length, 20);
      await repo.verify(fixed);
      expect(fixed.id, isNot(demo.id));
    },
  );
  test(
    'per-answer persistence can resume and concurrent checkpoints serialize',
    () async {
      final e = await repo.importZip(zip),
          s = completed(await repo.importZip(zip), 1);
      s.completedAt = null;
      final removed = s.answers.removeLast();
      final a = repo.save(s);
      s.answers.add(removed);
      s.completedAt = '2026-10-16T01:15:00Z';
      final b = repo.save(s);
      await Future.wait([a, b]);
      final loaded = (await repo.sessions(e)).single;
      expect(loaded.complete, true);
      expect(loaded.answers.length, 46);
    },
  );
  test('merge is idempotent and rejects conflicting observers', () async {
    final e = await repo.importZip(zip);
    final a = completed(e, 1);
    final data = repo.resultsJson(e, [a]);
    expect(await repo.mergeResults(e, data), 1);
    expect(await repo.mergeResults(e, data), 0);
    final conflict = StudySession.fromJson({
      ...a.toJson(),
      'id': 'different_session',
    });
    await expectLater(
      repo.mergeResults(e, repo.resultsJson(e, [conflict])),
      throwsFormatException,
    );
    expect((await repo.sessions(e)).length, 1);
  });
  test(
    'CSV and JSON include raw invalid sessions and exclude practice from rates',
    () async {
      final e = await repo.importZip(zip);
      final sessions = [completed(e, 1), completed(e, 2, fail: true)];
      final csv = utf8.decode(repo.resultsCsv(e, sessions));
      expect(csv.split('\r\n').length, 93);
      expect(csv, contains('控制题未通过'));
      final data = jsonDecode(utf8.decode(repo.resultsJson(e, sessions)));
      expect(data['sessions'].length, 2);
      expect(records(data['report']['conditions']).single['validObservers'], 1);
    },
  );
}
