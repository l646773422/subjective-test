import 'domain.dart';

/// Editable run settings stay separate from the frozen settings of old sessions.
class QuickTestSettings {
  final StudyDefinition base;
  final Map<String, int> available = {}, counts = {};
  bool patchEnabled, stereoEnabled;
  Map<String, dynamic>? legacyPatch;
  String patchWidth,
      patchHeight,
      layout,
      pointerMapping,
      disparity,
      stereoInput;
  int repetitions;
  static const ungrouped = '未分组';
  QuickTestSettings(this.base)
    : patchEnabled = base.patch != null,
      stereoEnabled = base.stereo != null,
      legacyPatch = base.patch?.containsKey('area') == true ? base.patch : null,
      patchWidth = '${base.patch?['width'] ?? 512}',
      patchHeight = '${base.patch?['height'] ?? 512}',
      layout = base.stereo?['layout'] as String? ?? 'full_sbs',
      stereoInput = base.stereo?['input'] as String? ?? 'separate',
      pointerMapping = base.stereo?['pointerMapping'] as String? ?? 'screen',
      disparity = '${base.stereo?['uiDisparity'] ?? 0}',
      repetitions = base.schedule['repetitions'] as int {
    for (final item in base.items.where((i) => i['role'] == 'main')) {
      final group = item['group'] as String? ?? ungrouped;
      available[group] = (available[group] ?? 0) + 1;
    }
    for (final group in available.keys) {
      counts[group] =
          (base.sampling?['perGroup'] as Map?)?[group] as int? ??
          available[group]!;
    }
  }
  int get selectedCount => counts.values.fold(0, (a, b) => a + b);
  int get judgments =>
      selectedCount * repetitions +
      base.items.where((i) => i['role'] != 'main').length;
  int get stereoMissing => base.items
      .where((i) => i['aRight'] == null || i['bRight'] == null)
      .length;
  String? error(Map<String, String> inputCounts) {
    for (final entry in available.entries) {
      final value = int.tryParse(inputCounts[entry.key] ?? '');
      if (value == null || value < 1 || value > entry.value) {
        return '${sequenceLabels[entry.key] ?? entry.key}：抽样数量需为 1～${entry.value} 的整数';
      }
    }
    if (stereoEnabled && stereoInput == 'separate' && stereoMissing > 0) {
      return '当前目录有 $stereoMissing 对素材尚未指定右眼图片。如果图片已拼好，请将素材格式选为“左右眼已拼在一张图”；否则需在 study.json 中指定左右眼路径。';
    }
    if (patchEnabled && legacyPatch == null) {
      final w = int.tryParse(patchWidth), h = int.tryParse(patchHeight);
      if (w == null ||
          h == null ||
          w < 1 ||
          h < 1 ||
          w > 40000000 ||
          h > 40000000 ||
          w * h > 40000000) {
        return 'Patch 宽、高须为正整数像素，面积不超过 4000 万像素';
      }
    }
    if (stereoEnabled) {
      final value = double.tryParse(disparity);
      if (value == null || !value.isFinite || value < -64 || value > 64) {
        return 'UI 双眼视差应为 -64～64 逻辑像素';
      }
    }
    return null;
  }

  StudyDefinition definition(Map<String, String> inputCounts) {
    final failure = error(inputCounts);
    check(failure == null, failure ?? '测试参数无效');
    final source = base.toJson();
    source['items'] = [
      for (final item in base.items)
        {...item, 'group': item['group'] ?? ungrouped},
    ];
    final selected = {
      for (final group in available.keys) group: int.parse(inputCounts[group]!),
    };
    source['sampling'] = {'mode': 'per_participant', 'perGroup': selected};
    final schedule = source['schedule'] as Map;
    schedule['repetitions'] = repetitions;
    if (repetitions.isOdd) schedule['pairOrder'] = 'random';
    // A one-pair group cannot separate its two order-balanced repetitions.
    if (base.profile == null &&
        schedule['avoidAdjacentRepeats'] == true &&
        repetitions > 1 &&
        (schedule['blockByGroup'] == true
            ? selected.values.any((n) => n == 1)
            : selected.values.fold(0, (a, b) => a + b) == 1)) {
      schedule['avoidAdjacentRepeats'] = false;
    }
    final presentation = source['presentation'] as Map;
    presentation.remove('patch');
    presentation.remove('stereo');
    if (patchEnabled) {
      presentation['patch'] =
          legacyPatch ??
          {
            'width': int.parse(patchWidth),
            'height': int.parse(patchHeight),
            'distribution': 'center_triangular',
          };
    }
    if (stereoEnabled) {
      presentation['stereo'] = {
        if (stereoInput == 'sbs' || base.stereo?.containsKey('input') == true)
          'input': stereoInput,
        'layout': layout,
        'pointerMapping': pointerMapping,
        'uiDisparity': double.parse(disparity),
      };
    }
    return StudyDefinition.fromJson(source);
  }
}
