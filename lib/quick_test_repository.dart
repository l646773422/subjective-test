part of 'repository.dart';

/// The common Windows flow keeps immutable revisions internally; operators only
/// choose materials and run settings. Existing sessions always retain their rules.
extension QuickTestRepository on StudyRepository {
  Future<StudyDraft?> lastQuickDraft() async {
    final all = await drafts();
    final preference = File(p.join(root.path, 'quick-test.json'));
    if (await preference.exists()) {
      try {
        final selected = jsonDecode(await preference.readAsString())['studyId'];
        final found = all.where((d) => d.id == selected).firstOrNull;
        if (found != null && found.definition.items.isNotEmpty) return found;
      } catch (e) {
        noteIssue('快速测试设置无法读取：$e');
      }
    }
    final versions = await experiments();
    for (final version in versions.where((e) => e.isV2)) {
      final found = all.where((d) => d.id == version.studyId).firstOrNull;
      if (found != null &&
          found.definition.items.isNotEmpty &&
          bindingAt(draftDir(found.id)) != null) {
        return found;
      }
    }
    return all
        .where(
          (d) =>
              d.definition.items.isNotEmpty &&
              bindingAt(draftDir(d.id)) != null,
        )
        .firstOrNull;
  }

  Future<void> rememberQuickDraft(StudyDraft draft) async {
    await initializeV2();
    await File(p.join(root.path, 'quick-test.json')).writeAsString(
      jsonEncode({'schema': 1, 'studyId': draft.id}),
      flush: true,
    );
  }

  Future<StudyDraft> loadQuickDirectory(Directory directory) async {
    check(await directory.exists(), '素材目录不存在，请重新选择');
    final file = File(p.join(directory.path, 'study.json'));
    if (!await file.exists()) {
      final hasRenders = await directory
          .list(followLinks: false)
          .any(
            (entry) =>
                entry is Directory &&
                p.basename(entry.path).endsWith('_renders'),
          );
      check(hasRenders, '未找到 *_renders 子目录或 study.json。请选择四个序列共同的上一级目录。');
      final draft = await loadRenderDirectory(directory);
      await rememberQuickDraft(draft);
      return draft;
    }
    check(
      !await File(p.join(directory.path, 'release.json')).exists(),
      '此目录是旧发布包，请在高级实验管理中导入；这里选择原素材目录或含 study.json 的源目录',
    );
    final definition = StudyDefinition.fromJson(
      jsonMap(jsonDecode(await file.readAsString()), 'study'),
    );
    final existing = (await drafts())
        .where((d) => d.id == definition.studyId)
        .firstOrNull;
    StudyDraft draft;
    if (existing == null) {
      draft = await importSourceDirectory(directory);
    } else {
      final binding = await readMaterialBinding(directory);
      final materials = binding == null
          ? directory
          : Directory(binding['root'] as String);
      for (final path in definition.assets) {
        await sourceFile(materials, path);
      }
      // A selected source file supplies the current source, including changed refs.
      // Remove a previous index so publishing cannot trust stale image metadata.
      final catalog = File(p.join(draftDir(existing.id).path, 'catalog.json'));
      if (await catalog.exists()) await catalog.delete();
      draft = await saveDraft(definition.toJson());
      await bindMaterialRoot(draftDir(draft.id), materials);
    }
    await rememberQuickDraft(draft);
    return draft;
  }

  Future<Experiment> prepareQuickTest(
    StudyDraft base,
    StudyDefinition settings,
  ) async {
    await initializeV2();
    check(base.id == settings.studyId, '素材与测试配置不匹配，请重新读取目录');
    final binding = bindingAt(draftDir(base.id));
    if (binding == null) throw const FormatException('请先选择并读取测试素材目录');
    final draft = await saveDraft(settings.toJson());
    final matching = (await experiments())
        .where(
          (e) =>
              e.isV2 &&
              e.studyId == settings.studyId &&
              digestJson(bindingAt(revisionDir(e.id)) ?? {}) ==
                  digestJson(binding) &&
              digestJson(e.definition!.toJson()) ==
                  digestJson(settings.toJson()),
        )
        .firstOrNull;
    final experiment = matching ?? await publishDraft(draft);
    await bindMaterialSource(revisionDir(experiment.id), binding);
    await rememberQuickDraft(draft);
    return experiment;
  }
}
