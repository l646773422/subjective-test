import 'dart:convert';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:subjective_study/repository.dart';
import 'package:subjective_study/domain.dart';

/// Synthetic eye pairs only; no camera pairing is inferred from real materials.
Future<StudyDraft> stereoFixture(
  StudyRepository repo,
  Directory source, {
  bool stereo = true,
  bool patch = true,
  bool legacyArea = false,
  bool packed = false,
  String layout = 'full_sbs',
}) async {
  await source.create(recursive: true);
  final items = <Map<String, dynamic>>[];
  for (int frame = 0; frame < 4; frame++) {
    for (int view = 0; view < 3; view++) {
      final item = <String, dynamic>{
        'id': 'f$frame-v$view',
        'group': 'scene',
        'metadata': {'frame': frame, 'view': view},
        'answer': 'a',
      };
      for (final key in [
        'a',
        'b',
        if (stereo && !packed) ...['aRight', 'bRight'],
      ]) {
        final image = img.Image(width: packed ? 640 : 320, height: 180);
        for (int y = 0; y < 180; y++) {
          for (int x = 0; x < image.width; x++) {
            final right = key.endsWith('Right') || (packed && x >= 320);
            final px = x % 320 + (right ? 6 : 0);
            final square = px >= 100 && px < 220 && y >= 40 && y < 140;
            image.setPixelRgba(
              x,
              y,
              square
                  ? 220
                  : (px ~/ 20 + y ~/ 20).isEven
                  ? 35
                  : 65,
              square ? 100 + frame * 20 : 50 + view * 10,
              square ? (key.startsWith('a') ? 80 : 180) : y,
              255,
            );
          }
        }
        final path = 'f$frame-v$view-$key.png';
        await File('${source.path}/$path').writeAsBytes(img.encodePng(image));
        item[key] = path;
      }
      items.add(item);
    }
  }
  await File('${source.path}/study.json').writeAsString(
    jsonEncode({
      'schema': 2,
      'studyId': 'stereo-fixture',
      'name': '双眼与 Patch 演练',
      'method': '2afc',
      'question': '请选择第一幅或第二幅',
      'isDemo': true,
      'presentation': {
        'promptMs': 50,
        'imageMs': 150,
        if (stereo)
          'stereo': {
            if (packed) 'input': 'sbs',
            'layout': layout,
            'uiDisparity': 12,
          },
        if (patch)
          'patch': legacyArea ? {'area': 0.25} : {'width': 128, 'height': 96},
      },
      'schedule': {
        'repetitions': 2,
        'pairOrder': 'balanced',
        'avoidAdjacentRepeats': true,
      },
      'sampling': {
        'mode': 'per_participant',
        'perGroup': {'scene': 2},
      },
      'items': items,
    }),
  );
  return repo.importSourceDirectory(source);
}

StudySession stereoSession(Experiment e, {int seed = 117}) => StudySession(
  id: uuid(),
  schema: 2,
  studyId: e.studyId,
  experimentId: e.id,
  schedulerVersion: e.release!['implementations']['scheduler'] as String,
  participantId: 'SIMULATED-$seed',
  startedAt: DateTime.now().toUtc().toIso8601String(),
  seed: seed,
  participant: {},
  display: {'conditionId': 'windows', 'condition': 'Windows SBS 演练'},
  trials: buildSchedule(e, seed),
);
