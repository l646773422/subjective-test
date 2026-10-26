import 'package:flutter/material.dart';
import 'quick_test_settings.dart';
import 'labeled_control.dart';

class FixedSamplingDialog extends StatefulWidget {
  final QuickTestSettings settings;
  final String group;
  final int count;
  const FixedSamplingDialog({
    super.key,
    required this.settings,
    required this.group,
    required this.count,
  });
  @override
  State<FixedSamplingDialog> createState() => _FixedSamplingDialogState();
}

class _FixedSamplingDialogState extends State<FixedSamplingDialog> {
  late final input = TextEditingController(
    text: widget.settings.fixedText(widget.group),
  );
  String? error;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void apply() {
    try {
      final ids = widget.settings.resolveFixed(
        widget.group,
        input.text,
        widget.count,
      );
      Navigator.pop(context, ids);
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pool = widget.settings.groupItems(widget.group);
    final frames = {
      for (final i in pool)
        if (i['metadata']['frame'] is int) i['metadata']['frame'] as int,
    }.toList()..sort();
    final views = {
      for (final i in pool)
        if (i['metadata']['view'] is int) i['metadata']['view'] as int,
    }.toList()..sort();
    return AlertDialog(
      title: const Text('按顺序填写帧和视点'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.settings.groupNames[widget.group] ?? widget.group),
              const SizedBox(height: 12),
              Text(
                '需要 ${widget.count} 行，每行是一组“帧号, 视点号”。第一行先测试，依次往下；所有参与者使用同一份列表。',
              ),
              const SizedBox(height: 8),
              Text(
                frames.isEmpty || views.isEmpty
                    ? '当前素材未提供帧号/视点号，请先在素材描述 metadata 中补齐 frame 和 view。'
                    : '帧号范围 ${frames.first}～${frames.last}（共 ${frames.length} 帧）；可用视点 ${views.join('、')}。',
              ),
              const SizedBox(height: 8),
              const Text('填写相机视点号，例如 0、10、20；不是图片文件的导出索引。'),
              const SizedBox(height: 16),
              LabeledControl(
                label: '按测试顺序填写（支持粘贴多行）',
                child: TextField(
                  key: const Key('fixed-sampling-input'),
                  controller: input,
                  minLines: 6,
                  maxLines: 10,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    hintText: '12, 20\n85, 0\n7, 30',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '测 ${widget.settings.repetitions} 遍时，每遍都保持这个顺序；A/B 先后和 Patch 沿用原规则。',
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    key: const Key('fixed-sampling-error'),
                    style: const TextStyle(color: Color(0xffa04935)),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('fixed-sampling-apply'),
          onPressed: apply,
          child: const Text('使用这份列表'),
        ),
      ],
    );
  }
}
