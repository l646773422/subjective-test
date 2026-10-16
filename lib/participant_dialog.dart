import 'dart:io';
import 'package:flutter/material.dart';
import 'study_v2.dart';

class GenericParticipantDialog extends StatefulWidget {
  final StudyDefinition definition;
  const GenericParticipantDialog({super.key, required this.definition});
  @override
  State<GenericParticipantDialog> createState() =>
      _GenericParticipantDialogState();
}

class _GenericParticipantDialogState extends State<GenericParticipantDialog> {
  final id = TextEditingController();
  final conditionId = TextEditingController(
    text: Platform.isWindows ? 'pc-lab' : 'android',
  );
  final condition = TextEditingController(
    text: Platform.isWindows ? 'PC · 实验室显示器' : 'Android · 移动显示设备',
  );
  final device = TextEditingController();
  final distance = TextEditingController();
  final notes = TextEditingController();
  final fields = <String, TextEditingController>{};
  final booleans = <String, bool>{};
  String? error;
  @override
  void initState() {
    super.initState();
    if (widget.definition.profile != null) {
      distance.text = Platform.isWindows ? '60' : '35';
    }
    for (final field in widget.definition.participantFields) {
      final key = field['id'] as String;
      if (field['type'] == 'boolean') {
        booleans[key] = false;
      } else {
        fields[key] = TextEditingController();
      }
    }
  }

  @override
  void dispose() {
    for (final c in [
      id,
      conditionId,
      condition,
      device,
      distance,
      notes,
      ...fields.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget input(
    TextEditingController controller,
    String label, {
    Key? key,
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      key: key,
      controller: controller,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(labelText: label),
    ),
  );
  void submit() {
    try {
      check(
        id.text.trim().isNotEmpty && id.text.trim().length <= 80,
        '请填写 1～80 位匿名参与者编号',
      );
      check(
        validId(conditionId.text.trim()) && nonEmpty(condition.text),
        '请填写稳定的观看条件编号和名称',
      );
      final participant = <String, dynamic>{};
      for (final f in widget.definition.participantFields) {
        final key = f['id'] as String;
        if (f['type'] == 'boolean') {
          participant[key] = booleans[key];
          continue;
        }
        final text = fields[key]!.text.trim();
        if (text.isEmpty && f['required'] != true) continue;
        participant[key] = switch (f['type']) {
          'integer' => int.tryParse(text),
          'number' => double.tryParse(text),
          _ => text,
        };
      }
      widget.definition.validateParticipant(participant);
      check(
        (widget.definition.quality['requiredTrue'] as List).every(
          (key) => participant[key] == true,
        ),
        '请确认本实验要求的参与条件',
      );
      final cm = distance.text.trim().isEmpty
          ? null
          : double.tryParse(distance.text);
      check(
        distance.text.trim().isEmpty || cm != null && cm.isFinite && cm > 0,
        '观看距离必须为正数',
      );
      check(
        widget.definition.profile == null ||
            nonEmpty(device.text) && cm != null,
        '真实感模板需要设备型号和观看距离',
      );
      Navigator.pop(context, {
        'participantId': id.text.trim(),
        'conditionId': conditionId.text.trim(),
        'condition': condition.text.trim(),
        'participant': participant,
        'device': device.text.trim(),
        'distanceCm': cm,
        'displayNotes': notes.text.trim(),
      });
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('登记参与者与观看条件'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('使用匿名编号。同一发布版本和观看条件下，优先恢复已有会话。'),
            const SizedBox(height: 20),
            input(id, '参与者编号（必填）', key: const Key('participant-id')),
            input(
              conditionId,
              '观看条件编号（必填，如 pc-lab）',
              key: const Key('condition-id'),
            ),
            input(condition, '观看条件名称（必填）'),
            input(
              device,
              widget.definition.profile == null ? '显示设备型号（选填）' : '显示设备型号（必填）',
              key: const Key('device-model'),
            ),
            input(
              distance,
              '观看距离 / cm${widget.definition.profile == null ? '（选填）' : '（必填）'}',
              number: true,
            ),
            input(notes, '亮度、环境等备注（选填）'),
            for (final f in widget.definition.participantFields)
              if (f['type'] == 'boolean')
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(f['label'] as String),
                  value: booleans[f['id']],
                  onChanged: (v) =>
                      setState(() => booleans[f['id'] as String] = v!),
                )
              else
                input(
                  fields[f['id']]!,
                  '${f['label']}${f['required'] == true ? '（必填）' : '（选填）'}',
                  key: Key('participant-${f['id']}'),
                  number: f['type'] != 'text',
                ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Color(0xffa04935))),
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
        onPressed: submit,
        child: const Text('确认并进入测试'),
      ),
    ],
  );
}
