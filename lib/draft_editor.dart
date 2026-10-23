import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'repository.dart';
import 'domain.dart';
import 'study_templates.dart';
import 'stimulus_view.dart';

class DraftEditor extends StatefulWidget {
  final StudyRepository repository;
  final StudyDraft draft;
  const DraftEditor({super.key, required this.repository, required this.draft});
  @override
  State<DraftEditor> createState() => _DraftEditorState();
}

class _DraftEditorState extends State<DraftEditor> {
  late Map<String, dynamic> source;
  late final TextEditingController name, question, instructions, disparity;
  late final TextEditingController patchWidth, patchHeight;
  Timer? timer;
  bool dirty = false, busy = false, leaving = false;
  String? error;
  int generation = 0;
  StudyRepository get repo => widget.repository;
  List<Map<String, dynamic>> get items => records(source['items']);
  @override
  void initState() {
    super.initState();
    source = widget.draft.definition.toJson();
    final patch = (source['presentation'] as Map)['patch'];
    patchWidth = TextEditingController(text: '${patch?['width'] ?? 512}');
    patchHeight = TextEditingController(text: '${patch?['height'] ?? 512}');
    disparity = TextEditingController(
      text: '${(source['presentation'] as Map)['stereo']?['uiDisparity'] ?? 0}',
    );
    name = TextEditingController(text: source['name'] as String);
    question = TextEditingController(text: source['question'] as String);
    instructions = TextEditingController(
      text: source['instructions'] as String,
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    name.dispose();
    question.dispose();
    instructions.dispose();
    disparity.dispose();
    patchWidth.dispose();
    patchHeight.dispose();
    super.dispose();
  }

  void changed() {
    generation++;
    setState(() {
      dirty = true;
      error = null;
    });
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 500), () {
      save();
    });
  }

  Future<bool> save() async {
    timer?.cancel();
    final version = generation;
    try {
      await repo.saveDraft(source);
      if (mounted) {
        setState(() {
          if (version == generation) dirty = false;
          error = null;
        });
      }
      return true;
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
      return false;
    }
  }

  Future<void> leave() async {
    if (busy || leaving || !await save() || !mounted) return;
    setState(() => leaving = true);
    Navigator.pop(context);
  }

  Future<void> editItem([int? index]) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      Map<String, dynamic> item;
      if (index == null) {
        item = {
          'id': 'pair-${uuid().substring(0, 8)}',
          'role': 'main',
          'metadata': {},
        };
        for (final key in [
          'a',
          'b',
          if ((source['presentation'] as Map)['stereo'] != null) ...[
            'aRight',
            'bRight',
          ],
        ]) {
          final picked = await FilePicker.platform.pickFiles(
            dialogTitle:
                '选择 ${{'a': 'A 左眼 / 2D', 'b': 'B 左眼 / 2D', 'aRight': 'A 右眼', 'bRight': 'B 右眼'}[key]}',
            type: FileType.image,
            withData: true,
          );
          if (picked == null) return;
          item[key] = await repo.addDraftAsset(
            widget.draft,
            picked.files.single.bytes!,
            picked.files.single.name,
          );
        }
      } else {
        item = items[index];
      }
      if (!mounted) return;
      final edited = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => ItemDialog(
          item: item,
          stereo: (source['presentation'] as Map)['stereo'] != null,
        ),
      );
      if (edited == null) return;
      final list = items;
      if (index == null) {
        list.add(edited);
      } else {
        list[index] = edited;
      }
      final updated = {...source, 'items': list};
      StudyDefinition.fromJson(updated, draft: true);
      source = updated;
      changed();
      await save();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> advanced() async {
    final controller = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(source),
    );
    String? failure;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('编辑完整实验描述'),
          content: SizedBox(
            width: 760,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('可编辑题目元数据和高级配置。素材路径相对于已加载的素材目录，实验身份保持不变。'),
                const SizedBox(height: 12),
                SizedBox(
                  height: MediaQuery.sizeOf(ctx).height * .45,
                  child: TextField(
                    controller: controller,
                    maxLines: null,
                    expands: true,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                    ),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                if (failure != null)
                  Text(failure!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final parsed = jsonMap(jsonDecode(controller.text), 'study');
                  check(parsed['studyId'] == widget.draft.id, '请通过复制实验生成新身份');
                  final d = StudyDefinition.fromJson(parsed, draft: true);
                  Navigator.pop(ctx, d.toJson());
                } catch (e) {
                  update(() => failure = e.toString());
                }
              },
              child: const Text('应用并保存'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result != null && mounted) {
      source = result;
      final patch = (source['presentation'] as Map)['patch'];
      patchWidth.text = '${patch?['width'] ?? 512}';
      patchHeight.text = '${patch?['height'] ?? 512}';
      disparity.text =
          '${(source['presentation'] as Map)['stereo']?['uiDisparity'] ?? 0}';
      name.text = source['name'] as String;
      question.text = source['question'] as String;
      instructions.text = source['instructions'] as String;
      changed();
      await save();
    }
  }

  void template(bool photo) {
    final replacement = newStudySource(widget.draft.id, photorealism: photo);
    final normalized = StudyDefinition.fromJson(
      replacement,
      draft: true,
    ).toJson();
    for (final key in [
      'question',
      'instructions',
      'presentation',
      'schedule',
      'quality',
      'analysis',
      'participantFields',
    ]) {
      source[key] = normalized[key];
    }
    if (normalized.containsKey('sampling')) {
      source['sampling'] = normalized['sampling'];
    } else {
      source.remove('sampling');
    }
    question.text = source['question'] as String;
    instructions.text = source['instructions'] as String;
    changed();
  }

  Widget section(String title, Widget child) => Card(
    margin: const EdgeInsets.only(bottom: 20),
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    ),
  );
  Widget choice<T>(
    String label,
    T value,
    List<T> options,
    ValueChanged<T> change, {
    String Function(T)? labelFor,
  }) => SizedBox(
    width: 180,
    child: DropdownButtonFormField<T>(
      key: ValueKey('$label:$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: options
          .map(
            (v) => DropdownMenuItem(
              value: v,
              child: Text(labelFor?.call(v) ?? '$v'),
            ),
          )
          .toList(),
      onChanged: busy ? null : (v) => change(v as T),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final p = source['presentation'] as Map,
        s = source['schedule'] as Map,
        a = source['analysis'] as Map;
    final photo = a['profile'] != null;
    return PopScope(
      canPop: leaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) leave();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: leave,
            icon: const Icon(Icons.arrow_back),
          ),
          title: const Text('实验草稿'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: TextButton.icon(
                key: const Key('save-draft'),
                onPressed: busy ? null : save,
                icon: Icon(dirty ? Icons.edit_outlined : Icons.check),
                label: Text(dirty ? '保存草稿' : '已保存'),
              ),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (busy) const LinearProgressIndicator(),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        error!,
                        style: const TextStyle(color: Color(0xffa04935)),
                      ),
                    ),
                  section(
                    '01  问题与方法',
                    Column(
                      children: [
                        TextField(
                          key: const Key('study-name'),
                          controller: name,
                          decoration: const InputDecoration(labelText: '实验名称'),
                          onChanged: (v) {
                            source['name'] = v;
                            changed();
                          },
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          key: const Key('study-question'),
                          controller: question,
                          decoration: const InputDecoration(labelText: '作答问题'),
                          onChanged: (v) {
                            source['question'] = v;
                            changed();
                          },
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: instructions,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: '补充说明（选填）',
                          ),
                          onChanged: (v) {
                            source['instructions'] = v;
                            changed();
                          },
                        ),
                        const SizedBox(height: 10),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('演示数据'),
                          subtitle: const Text('演示结果始终标记，不用于正式判定'),
                          value: source['isDemo'] as bool,
                          onChanged: (v) {
                            source['isDemo'] = v;
                            changed();
                          },
                        ),
                        Wrap(
                          spacing: 12,
                          children: [
                            TextButton(
                              onPressed: () => template(false),
                              child: const Text('使用通用 2AFC 配置'),
                            ),
                            TextButton(
                              onPressed: () => template(true),
                              child: const Text('应用真实感评测模板'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  section(
                    '02  素材与题目',
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          photo
                              ? '真实感模板要求 a 为真实拍摄图。正式题需填写分组和 metadata 中的 frame/view；保留规定的练习、控制与覆盖要求。'
                              : '每道题引用两张图片，目录和文件名自由。练习、控制及标准答案按实验需要设置。',
                          style: const TextStyle(height: 1.7),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          key: const Key('add-item'),
                          onPressed: busy ? null : () => editItem(),
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: const Text('添加图片对'),
                        ),
                        const SizedBox(height: 16),
                        if (items.length > 24)
                          Text(
                            '共 ${items.length} 对候选素材，下方仅预览前 24 对；会话从完整素材池抽样。',
                          ),
                        for (final (index, item) in items.take(24).indexed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: const Color(0xffdce4da),
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${item['id']} · ${item['role']} ${item['group'] ?? ''}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      for (final alternative in ['a', 'b'])
                                        Expanded(
                                          child: Column(
                                            children: [
                                              Image.file(
                                                File(
                                                  '${repo.bindingAt(repo.draftDir(widget.draft.id))?['root'] ?? repo.draftDir(widget.draft.id).path}/${item[alternative]}',
                                                ),
                                                height: 90,
                                                cacheWidth: 280,
                                                fit: BoxFit.contain,
                                                errorBuilder: (_, _, _) =>
                                                    const SizedBox(
                                                      height: 90,
                                                      child: Center(
                                                        child: Text('素材缺失'),
                                                      ),
                                                    ),
                                              ),
                                              Text(
                                                '$alternative${item['answer'] == alternative ? ' · 标准答案' : ''}',
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      TextButton(
                                        onPressed: busy
                                            ? null
                                            : () => editItem(index),
                                        child: const Text('编辑题目'),
                                      ),
                                      TextButton(
                                        key: Key('preview-${item['id']}'),
                                        onPressed: busy
                                            ? null
                                            : () => Navigator.push(
                                                context,
                                                MaterialPageRoute<void>(
                                                  builder: (_) => DraftPreview(
                                                    read: (relative) =>
                                                        repo.materialBytes(
                                                          repo.draftDir(
                                                            widget.draft.id,
                                                          ),
                                                          relative,
                                                        ),
                                                    directory: repo.draftDir(
                                                      widget.draft.id,
                                                    ),
                                                    item: item,
                                                    question:
                                                        source['question']
                                                            as String,
                                                    promptMs:
                                                        p['promptMs'] as int,
                                                    imageMs:
                                                        p['imageMs'] as int,
                                                    presentation:
                                                        Map<
                                                          String,
                                                          dynamic
                                                        >.from(p),
                                                  ),
                                                ),
                                              ),
                                        child: const Text('预览完整题次'),
                                      ),
                                      TextButton(
                                        onPressed: busy
                                            ? null
                                            : () {
                                                final list = items
                                                  ..removeAt(index);
                                                source['items'] = list;
                                                changed();
                                              },
                                        child: const Text('移除'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  section(
                    '03  呈现与排程',
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          key: const Key('stereo-enabled'),
                          title: const Text('3D 双眼 SBS'),
                          subtitle: const Text(
                            'A、B 仍先后播放；每幅同时显示左右眼。发布前需补齐每题双眼路径。',
                          ),
                          value: p['stereo'] != null,
                          onChanged: busy
                              ? null
                              : (v) {
                                  if (v) {
                                    disparity.text = '0';
                                    p['stereo'] = {
                                      'layout': 'full_sbs',
                                      'uiDisparity': 0,
                                    };
                                  } else {
                                    p.remove('stereo');
                                  }
                                  changed();
                                },
                        ),
                        if (p['stereo'] != null)
                          Wrap(
                            spacing: 14,
                            runSpacing: 14,
                            children: [
                              choice<String>(
                                'SBS 输出格式',
                                (p['stereo'] as Map)['layout'] as String,
                                ['half_sbs', 'full_sbs'],
                                (v) {
                                  (p['stereo'] as Map)['layout'] = v;
                                  changed();
                                },
                                labelFor: (v) => v == 'half_sbs'
                                    ? 'Half SBS（半宽）'
                                    : 'Full SBS（全宽）',
                              ),
                              choice<String>(
                                '鼠标映射',
                                (p['stereo'] as Map)['pointerMapping']
                                        as String? ??
                                    'screen',
                                ['screen', 'per_eye'],
                                (v) {
                                  (p['stereo'] as Map)['pointerMapping'] = v;
                                  changed();
                                },
                                labelFor: (v) =>
                                    v == 'screen' ? '整屏连续' : '按半屏（调试）',
                              ),
                              SizedBox(
                                width: 240,
                                child: TextFormField(
                                  controller: disparity,
                                  decoration: const InputDecoration(
                                    labelText: 'UI 双眼视差 / 逻辑像素',
                                  ),
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        signed: true,
                                        decimal: true,
                                      ),
                                  onChanged: (text) {
                                    (p['stereo'] as Map)['uiDisparity'] =
                                        double.tryParse(text) ?? text;
                                    changed();
                                  },
                                ),
                              ),
                            ],
                          ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          key: const Key('patch-enabled'),
                          title: const Text('随机 Patch 展示'),
                          subtitle: const Text(
                            '每人抽帧和视点后，按中心偏重分布抽取区域。A、B 和双眼共用区域；重复题与恢复保持一致。',
                          ),
                          value: p['patch'] != null,
                          onChanged: busy
                              ? null
                              : (v) {
                                  if (v) {
                                    p['patch'] = {
                                      'width':
                                          int.tryParse(patchWidth.text) ??
                                          patchWidth.text,
                                      'height':
                                          int.tryParse(patchHeight.text) ??
                                          patchHeight.text,
                                      'distribution': 'center_triangular',
                                    };
                                  } else {
                                    p.remove('patch');
                                  }
                                  changed();
                                },
                        ),
                        if (p['patch']?['area'] != null) ...[
                          Text(
                            '沿用旧版面积配置 ${((p['patch']['area'] as num) * 100).toStringAsFixed(1)}%；已有会话保持原裁剪。',
                          ),
                          TextButton(
                            key: const Key('patch-use-pixels'),
                            onPressed: busy
                                ? null
                                : () {
                                    p['patch'] = {
                                      'width': 512,
                                      'height': 512,
                                      'distribution': 'center_triangular',
                                    };
                                    patchWidth.text = patchHeight.text = '512';
                                    changed();
                                  },
                            child: const Text('改用像素宽高'),
                          ),
                        ],
                        if (p['patch'] != null &&
                            p['patch']['area'] == null) ...[
                          Wrap(
                            spacing: 14,
                            runSpacing: 14,
                            children: [
                              for (final (dimension, label, controller) in [
                                ('width', 'Patch 宽 / 像素', patchWidth),
                                ('height', 'Patch 高 / 像素', patchHeight),
                              ])
                                SizedBox(
                                  width: 200,
                                  child: TextField(
                                    key: Key('patch-$dimension'),
                                    controller: controller,
                                    enabled: !busy,
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      labelText: label,
                                    ),
                                    onChanged: (_) {
                                      p['patch']['width'] =
                                          int.tryParse(patchWidth.text) ??
                                          patchWidth.text;
                                      p['patch']['height'] =
                                          int.tryParse(patchHeight.text) ??
                                          patchHeight.text;
                                      changed();
                                    },
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text('按原图像素截取，可设置任意宽高比；区域等比适应显示。宽、高不能超过任一候选图。'),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 14,
                          runSpacing: 14,
                          children: [
                            choice<int>(
                              '提示 / 毫秒',
                              p['promptMs'] as int,
                              {
                                0,
                                500,
                                1000,
                                2000,
                                3000,
                                5000,
                                p['promptMs'] as int,
                              }.toList()..sort(),
                              (v) {
                                p['promptMs'] = v;
                                changed();
                              },
                            ),
                            choice<int>(
                              '图片 / 毫秒',
                              p['imageMs'] as int,
                              {
                                1000,
                                2000,
                                3000,
                                4000,
                                5000,
                                p['imageMs'] as int,
                              }.toList()..sort(),
                              (v) {
                                p['imageMs'] = v;
                                changed();
                              },
                            ),
                            choice<int>(
                              '正式题重复次数',
                              s['repetitions'] as int,
                              {
                                1,
                                2,
                                3,
                                4,
                                6,
                                10,
                                s['repetitions'] as int,
                              }.toList()..sort(),
                              (v) {
                                s['repetitions'] = v;
                                if (v.isOdd) s['pairOrder'] = 'random';
                                changed();
                              },
                            ),
                            choice<String>(
                              '素材先后次序',
                              s['pairOrder'] as String,
                              (s['repetitions'] as int).isEven
                                  ? ['random', 'balanced']
                                  : ['random'],
                              (v) {
                                s['pairOrder'] = v;
                                changed();
                              },
                              labelFor: (v) => v == 'random' ? '随机' : '平衡',
                            ),
                            choice<String>(
                              '题目顺序',
                              s['itemOrder'] as String,
                              ['random', 'listed'],
                              (v) {
                                s['itemOrder'] = v;
                                changed();
                              },
                              labelFor: (v) => v == 'random' ? '每轮随机' : '清单顺序',
                            ),
                            choice<String>(
                              '正式指标',
                              a['metric'] as String,
                              ['selection_rate', 'accuracy'],
                              (v) {
                                a['metric'] = v;
                                if (v != 'accuracy') a.remove('profile');
                                changed();
                              },
                              labelFor: (v) =>
                                  v == 'accuracy' ? '准确率' : '逐题选择比例',
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('按分组完成全部轮次'),
                          value: s['blockByGroup'] as bool,
                          onChanged: (v) {
                            s['blockByGroup'] = v;
                            changed();
                          },
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('避免同一题相邻重复'),
                          value: s['avoidAdjacentRepeats'] as bool,
                          onChanged: (v) {
                            s['avoidAdjacentRepeats'] = v;
                            changed();
                          },
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '练习与控制题各出现一次。配置矛盾会在发布前指出。${photo ? '当前启用真实感统计与参与条件。' : ''}',
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: busy ? null : advanced,
                          icon: const Icon(Icons.data_object),
                          label: const Text('完整描述与高级配置'),
                        ),
                      ],
                    ),
                  ),
                  const Text(
                    '草稿修改自动保存。返回实验页面后发布，新版本不会改动已有采集。',
                    style: TextStyle(color: Color(0xff627368)),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ItemDialog extends StatefulWidget {
  final Map<String, dynamic> item;
  final bool stereo;
  const ItemDialog({super.key, required this.item, this.stereo = false});
  @override
  State<ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<ItemDialog> {
  late final TextEditingController id, group, metadata;
  final paths = <String, TextEditingController>{};
  late String role;
  String? answer, error;
  @override
  void initState() {
    super.initState();
    final i = widget.item;
    for (final key in [
      'a',
      'b',
      if (widget.stereo) ...['aRight', 'bRight'],
    ]) {
      paths[key] = TextEditingController(text: i[key] as String? ?? '');
    }
    id = TextEditingController(text: i['id'] as String);
    group = TextEditingController(text: i['group'] as String? ?? '');
    metadata = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(i['metadata'] ?? {}),
    );
    role = i['role'] as String;
    answer = i['answer'] as String?;
  }

  @override
  void dispose() {
    id.dispose();
    group.dispose();
    metadata.dispose();
    for (final controller in paths.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('题目设置'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: id,
              decoration: const InputDecoration(labelText: '题目编号'),
            ),
            for (final entry in paths.entries)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: TextField(
                  controller: entry.value,
                  decoration: InputDecoration(
                    labelText:
                        '${{'a': 'A 左眼 / 2D', 'b': 'B 左眼 / 2D', 'aRight': 'A 右眼', 'bRight': 'B 右眼'}[entry.key]} · 素材目录相对路径',
                  ),
                ),
              ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: role,
              decoration: const InputDecoration(labelText: '题目角色'),
              items: [
                for (final entry in [
                  ('main', '正式题'),
                  ('practice', '练习题'),
                  ('control', '控制题'),
                ])
                  DropdownMenuItem(value: entry.$1, child: Text(entry.$2)),
              ],
              onChanged: (v) => role = v!,
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: answer ?? 'none',
              decoration: const InputDecoration(labelText: '标准答案'),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('无标准答案')),
                DropdownMenuItem(value: 'a', child: Text('素材 a')),
                DropdownMenuItem(value: 'b', child: Text('素材 b')),
              ],
              onChanged: (v) => answer = v == 'none' ? null : v,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: group,
              decoration: const InputDecoration(labelText: '分组（选填）'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: metadata,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '元数据 JSON（选填）',
                hintText: '{"frame":0,"view":10}',
              ),
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
        onPressed: () {
          try {
            check(validId(id.text.trim()), '题目编号格式无效');
            check(role != 'control' || answer != null, '控制题需要标准答案');
            final result = {
              ...widget.item,
              for (final entry in paths.entries)
                entry.key: assetPath(entry.value.text.trim()),
              'id': id.text.trim(),
              'role': role,
              'metadata': jsonMap(jsonDecode(metadata.text), 'metadata'),
            };
            result.remove('answer');
            result.remove('group');
            if (answer != null) result['answer'] = answer;
            if (group.text.trim().isNotEmpty) {
              result['group'] = group.text.trim();
            }
            Navigator.pop(context, result);
          } catch (e) {
            setState(() => error = e.toString());
          }
        },
        child: const Text('保存题目'),
      ),
    ],
  );
}

class DraftPreview extends StatefulWidget {
  final Future<Uint8List> Function(String)? read;
  final Directory directory;
  final Map<String, dynamic> item;
  final String question;
  final int promptMs, imageMs;
  final Map<String, dynamic> presentation;
  const DraftPreview({
    super.key,
    required this.directory,
    required this.item,
    required this.question,
    required this.promptMs,
    required this.imageMs,
    this.read,
    this.presentation = const {},
  });
  @override
  State<DraftPreview> createState() => _DraftPreviewState();
}

class _DraftPreviewState extends State<DraftPreview> {
  final images = <String, ui.Image>{};
  Map<String, dynamic>? patch;
  Timer? timer;
  int stage = -1;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      for (final key in [
        'a',
        'b',
        if (widget.presentation['stereo'] != null) ...['aRight', 'bRight'],
      ]) {
        check(widget.item[key] is String, '请先补齐左右眼图片路径');
        final codec = await ui.instantiateImageCodec(
          widget.read != null
              ? await widget.read!(widget.item[key] as String)
              : await File(
                  '${widget.directory.path}/${widget.item[key]}',
                ).readAsBytes(),
        );
        late final ui.Image image;
        try {
          image = (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
        if (!mounted) {
          image.dispose();
          return;
        }
        images[key] = image;
      }
      final first = images['a']!;
      if (widget.presentation['patch'] != null ||
          widget.presentation['stereo'] != null) {
        check(
          images.values.every(
            (image) =>
                image.width == first.width && image.height == first.height,
          ),
          'A、B 与双眼图片必须具有相同尺寸',
        );
      }
      if (widget.presentation['patch'] != null) {
        patch = sampleConfiguredPatch(
          first.width,
          first.height,
          Map<String, dynamic>.from(widget.presentation['patch'] as Map),
          StableRandom(DateTime.now().microsecondsSinceEpoch),
        );
      }
      advance(widget.promptMs == 0 ? 1 : 0);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  void advance(int next) {
    if (!mounted) return;
    setState(() => stage = next);
    if (next == 4) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || stage != next) return;
      timer = Timer(
        Duration(milliseconds: next.isEven ? widget.promptMs : widget.imageMs),
        () => advance(next == 1 && widget.promptMs == 0 ? 3 : next + 1),
      );
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    for (final image in images.values) {
      image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff808080),
    body: StereoSurface(
      stereo: widget.presentation['stereo'] == null
          ? null
          : Map<String, dynamic>.from(widget.presentation['stereo'] as Map),
      stimulus: error == null && (stage == 1 || stage == 3),
      builder: (context, eye) => Stack(
        fit: StackFit.expand,
        children: [
          error != null
              ? Center(child: Text(error!))
              : stage < 0
              ? const Center(child: CircularProgressIndicator())
              : stage == 0 || stage == 2
              ? Center(
                  child: Text(
                    stage == 0 ? '第一幅' : '第二幅',
                    style: const TextStyle(fontSize: 50, color: Colors.white),
                  ),
                )
              : stage == 1 || stage == 3
              ? SizedBox.expand(
                  child: StimulusView(
                    image:
                        images[stage == 1
                            ? (eye == 0 ? 'a' : 'aRight')
                            : (eye == 0 ? 'b' : 'bRight')]!,
                    patch: patch,
                  ),
                )
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.question,
                          style: const TextStyle(
                            fontSize: 26,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Wrap(
                          spacing: 16,
                          runSpacing: 12,
                          children: [
                            for (final label in ['第一幅', '第二幅'])
                              FilledButton(
                                onPressed: () => Navigator.pop(context),
                                child: Text(label),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
          if (stage != 1 && stage != 3 || error != null)
            Align(
              alignment: Alignment.topLeft,
              child: SafeArea(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回 · 题次预览（不保存答案）'),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
