import 'domain.dart';

Map<String, dynamic> newStudySource(
  String id, {
  bool photorealism = false,
  bool legacyPhotorealism = false,
}) {
  final source = <String, dynamic>{
    'schema': 2,
    'studyId': id,
    'name': photorealism ? '照片级真实感评测' : '新的图片评价实验',
    'method': '2afc',
    'question': photorealism ? '哪一幅是真实拍摄图像？' : '哪一幅看起来更自然？',
    'items': <dynamic>[],
  };
  if (photorealism) {
    if (!legacyPhotorealism) {
      source['sampling'] = {
        'mode': 'per_participant',
        'perGroup': {
          for (final e in protocolViews.entries) e.key: e.value.length,
        },
      };
    }
    source.addAll({
      'instructions': '请依据记忆与整体印象作答，不必刻意寻找细小差别。测试期间保持观看距离，不切换应用。',
      'schedule': {
        'repetitions': 2,
        'pairOrder': 'balanced',
        'blockByGroup': true,
        'avoidAdjacentRepeats': true,
        'practicePairOrder': 'alternating',
        'controlPairOrder': 'balanced',
      },
      'quality': {
        'minControlAccuracy': 1.0,
        'requiredTrue': ['normalVision', 'normalColorVision', 'independent'],
      },
      'participantFields': [
        {
          'id': 'age',
          'label': '年龄（宜 18～40 岁）',
          'type': 'integer',
          'required': true,
          'min': 1,
          'max': 120,
        },
        {
          'id': 'normalVision',
          'label': '视力正常（含矫正视力）',
          'type': 'boolean',
          'required': true,
        },
        {
          'id': 'normalColorVision',
          'label': '色觉正常',
          'type': 'boolean',
          'required': true,
        },
        {
          'id': 'independent',
          'label': '非本次评价组织者及算法开发相关人员',
          'type': 'boolean',
          'required': true,
        },
        {
          'id': 'expert',
          'label': '属于相关领域专家',
          'type': 'boolean',
          'required': true,
        },
      ],
      'analysis': {
        'metric': 'accuracy',
        'profile': {
          'type': 'photorealism',
          'version': legacyPhotorealism ? 1 : 2,
          (legacyPhotorealism
                  ? 'minObserversPerItem'
                  : 'minObserversPerSequence'):
              15,
          'expertNumerator': 1,
          'expertDenominator': 3,
          'maxSequenceAccuracy': .75,
          'equalCoverage': true,
          'sequenceViews': protocolViews,
          'resolutions': {
            for (final key in protocolViews.keys)
              key: key == 'Show_Groups_4K' ? [3840, 2160] : [1920, 1080],
          },
          'practiceMin': 3,
          'practiceMax': 5,
          'controlCount': 2,
        },
      },
    });
  }
  return source;
}
