import 'package:flutter/material.dart';
import 'labeled_control.dart';
import 'quick_test_settings.dart';

class QuickTestDialog extends StatefulWidget {
  final QuickTestSettings settings;
  const QuickTestDialog({super.key, required this.settings});
  @override
  State<QuickTestDialog> createState() => _QuickTestDialogState();
}

class _QuickTestDialogState extends State<QuickTestDialog> {
  late final prompt = TextEditingController(
    text: secondsText(widget.settings.promptMs),
  );
  late final image = TextEditingController(
    text: secondsText(widget.settings.imageMs),
  );
  late final question = TextEditingController(text: widget.settings.question);
  late final instructions = TextEditingController(
    text: widget.settings.instructions,
  );
  String? error;
  @override
  void dispose() {
    for (final c in [prompt, image, question, instructions]) {
      c.dispose();
    }
    super.dispose();
  }

  int? milliseconds(String text) {
    if (!RegExp(r'^(?:\d+(?:\.\d{0,3})?|\.\d{1,3})$').hasMatch(text.trim())) {
      return null;
    }
    final seconds = double.tryParse(text.trim());
    if (seconds == null || !seconds.isFinite || seconds > 600) return null;
    return (seconds * 1000).round();
  }

  void apply() {
    final p = milliseconds(prompt.text), i = milliseconds(image.text);
    final failure = p == null || i == null
        ? '时长请填写秒数，最多保留三位小数'
        : widget.settings.timingError(p, i);
    if (failure != null || question.text.trim().isEmpty) {
      setState(() => error = failure ?? '请填写作答问题');
      return;
    }
    widget.settings
      ..promptMs = p!
      ..imageMs = i!
      ..question = question.text.trim()
      ..instructions = instructions.text.trim();
    Navigator.pop(context, true);
  }

  Widget field(
    String label,
    String key,
    TextEditingController controller, {
    bool numeric = false,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: LabeledControl(
      label: label,
      child: TextField(
        key: Key(key),
        controller: controller,
        scrollPadding: const EdgeInsets.all(32),
        minLines: lines,
        maxLines: numeric ? 1 : lines + 2,
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.multiline,
        decoration: const InputDecoration(isDense: false),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('测试设置'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('应用后用于接下来开始的测试；已开始的会话继续使用原设置。'),
            const SizedBox(height: 20),
            field(
              '提示时长（秒，0 表示跳过）',
              'quick-prompt-seconds',
              prompt,
              numeric: true,
            ),
            field('每张图片展示时长（秒）', 'quick-image-seconds', image, numeric: true),
            const Padding(
              padding: EdgeInsets.only(bottom: 18),
              child: Text('每道题按“提示 → 第一幅 → 提示 → 第二幅 → 作答”进行，作答不限时。'),
            ),
            field('作答问题', 'quick-question', question, lines: 2),
            field('开始前说明（选填）', 'quick-instructions', instructions, lines: 3),
            if (error != null)
              Text(
                error!,
                key: const Key('quick-settings-error'),
                style: const TextStyle(color: Color(0xffa04935)),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        key: const Key('quick-settings-cancel'),
        onPressed: () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('quick-settings-apply'),
        onPressed: apply,
        child: const Text('应用设置'),
      ),
    ],
  );
}
