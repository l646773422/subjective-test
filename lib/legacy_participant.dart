import 'dart:io';
import 'package:flutter/material.dart';

class ParticipantDialog extends StatefulWidget {
  const ParticipantDialog({super.key});
  @override
  State<ParticipantDialog> createState() => _ParticipantDialogState();
}

class _ParticipantDialogState extends State<ParticipantDialog> {
  final id = TextEditingController();
  final age = TextEditingController();
  final condition = TextEditingController(
    text: Platform.isWindows ? 'PC · 实验室显示器' : 'Android · 移动显示设备',
  );
  final distance = TextEditingController(
    text: Platform.isWindows ? '60' : '35',
  );
  final device = TextEditingController();
  final notes = TextEditingController();
  bool vision = false, colorVision = false, independent = false, expert = false;
  String? error;
  @override
  void dispose() {
    for (final c in [id, age, condition, distance, device, notes]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('登记受试者与观看条件'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('使用匿名编号。同一题库、同一观看条件下，每位受试者只建立一条会话。'),
            const SizedBox(height: 18),
            TextField(
              key: const Key('participant-id'),
              controller: id,
              decoration: const InputDecoration(labelText: '受试者编号（必填）'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('participant-age'),
                    controller: age,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '年龄（宜 18～40 岁）',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: distance,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '观看距离 / cm'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: condition,
              decoration: const InputDecoration(labelText: '观看条件分组（用于统计）'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('device-model'),
              controller: device,
              decoration: const InputDecoration(labelText: '显示设备型号（必填）'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notes,
              decoration: const InputDecoration(labelText: '亮度、色彩、环境等设置记录'),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('视力正常（含矫正视力）'),
              value: vision,
              onChanged: (v) => setState(() => vision = v!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('色觉正常'),
              value: colorVision,
              onChanged: (v) => setState(() => colorVision = v!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('非本次评价组织者及算法开发相关人员'),
              value: independent,
              onChanged: (v) => setState(() => independent = v!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('属于相关领域专家'),
              value: expert,
              onChanged: (v) => setState(() => expert = v!),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
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
        key: const Key('create-session'),
        onPressed: () {
          final years = int.tryParse(age.text),
              cm = double.tryParse(distance.text);
          if (id.text.trim().isEmpty ||
              id.text.trim().length > 80 ||
              condition.text.trim().isEmpty ||
              device.text.trim().isEmpty ||
              years == null ||
              years < 1 ||
              years > 120 ||
              cm == null ||
              !cm.isFinite ||
              cm <= 0 ||
              !vision ||
              !colorVision ||
              !independent) {
            setState(() => error = '请填写有效编号、年龄、观看距离、设备，并确认参与条件。');
            return;
          }
          Navigator.pop(context, {
            'participantId': id.text.trim(),
            'age': years,
            'condition': condition.text.trim(),
            'distanceCm': cm,
            'device': device.text.trim(),
            'displayNotes': notes.text.trim(),
            'expert': expert,
          });
        },
        child: const Text('确认并进入测试'),
      ),
    ],
  );
}
