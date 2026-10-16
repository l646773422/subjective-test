import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'domain.dart';
import 'platform_bridge.dart';
import 'repository.dart';

enum StudyStage {
  instructions,
  loading,
  promptA,
  imageA,
  promptB,
  imageB,
  answer,
  interrupted,
  completed,
  error,
}

class SessionRunner extends ChangeNotifier {
  final StudyRepository repository;
  final Experiment experiment;
  final StudySession session;
  // Test harnesses may shorten timers; production always reads the frozen manifest.
  final int? testDurationMs;
  StudyStage stage = StudyStage.instructions;
  ui.Image? imageA, imageB;
  String? error;
  bool saving = false, disposed = false, _presented = false, _cancelled = false;
  int generation = 0;
  Timer? _timer;
  final Stopwatch clock = Stopwatch()..start();
  int? _stageStarted;
  Map<String, dynamic>? _stageEvent;
  SessionRunner(
    this.repository,
    this.experiment,
    this.session, {
    this.testDurationMs,
  }) {
    if (session.complete) stage = StudyStage.completed;
  }
  int get index => session.answers.length;
  Trial get trial => session.trials[index];
  StudyCase get currentCase => experiment.caseById(trial.caseId);
  bool get practice =>
      index < session.trials.length && currentCase.kind == 'practice';
  int get token => generation;
  Future<void> begin() async {
    if (saving || session.complete) return;
    _cancelled = false;
    if (practice) {
      session.practiceStarted = true;
    } else {
      session.formalStarted = true;
    }
    try {
      await repository.save(session);
      await loadTrial();
    } catch (e) {
      fail(e);
    }
  }

  void _finishStage() {
    if (_stageEvent != null && _stageStarted != null) {
      _stageEvent!['actualMs'] = clock.elapsedMilliseconds - _stageStarted!;
      session.events.add(_stageEvent!);
    }
    _stageEvent = null;
    _stageStarted = null;
  }

  void setStage(StudyStage next) {
    _timer?.cancel();
    _finishStage();
    stage = next;
    generation++;
    _presented = false;
    if (!disposed) notifyListeners();
  }

  Future<void> loadTrial() async {
    _cancelled = false;
    setStage(StudyStage.loading);
    final loadToken = token;
    imageA?.dispose();
    imageB?.dispose();
    imageA = null;
    imageB = null;
    ui.Image? a, b;
    try {
      final c = currentCase;
      final first = trial.capturedFirst ? c.gt : c.render;
      final second = trial.capturedFirst ? c.render : c.gt;
      a = await _decode(first);
      b = await _decode(second);
      if (disposed || _cancelled || token != loadToken) {
        a.dispose();
        b.dispose();
        return;
      }
      imageA = a;
      imageB = b;
      setStage(StudyStage.promptA);
    } catch (e) {
      a?.dispose();
      b?.dispose();
      if (!disposed && token == loadToken) fail(e);
    }
  }

  Future<ui.Image> _decode(String relative) async {
    final data = await repository.imageFile(experiment, relative).readAsBytes();
    final codec = await ui.instantiateImageCodec(data);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  void presented(int expectedToken, Map<String, dynamic> viewport) {
    if (disposed ||
        _presented ||
        expectedToken != token ||
        ![
          StudyStage.promptA,
          StudyStage.imageA,
          StudyStage.promptB,
          StudyStage.imageB,
          StudyStage.answer,
        ].contains(stage)) {
      return;
    }
    _presented = true;
    _stageStarted = clock.elapsedMilliseconds;
    final image = stage == StudyStage.imageA || stage == StudyStage.imageB;
    final duration = stage == StudyStage.answer
        ? null
        : testDurationMs ?? (image ? experiment.imageMs : experiment.promptMs);
    _stageEvent = {
      'type': 'presentation',
      'trialId': trial.id,
      'stage': stage.name,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'plannedMs': duration,
      'viewport': viewport,
    };
    if (duration != null) {
      _timer = Timer(Duration(milliseconds: duration), () {
        final next = switch (stage) {
          StudyStage.promptA => StudyStage.imageA,
          StudyStage.imageA => StudyStage.promptB,
          StudyStage.promptB => StudyStage.imageB,
          StudyStage.imageB => StudyStage.answer,
          _ => stage,
        };
        setStage(next);
      });
    }
  }

  Future<void> answer(int choice) async {
    if (stage != StudyStage.answer ||
        !_presented ||
        saving ||
        ![1, 2].contains(choice)) {
      return;
    }
    saving = true;
    notifyListeners();
    final oldEventCount = session.events.length;
    final response =
        clock.elapsedMilliseconds -
        (_stageStarted ?? clock.elapsedMilliseconds);
    final answer = {
      'trialId': trial.id,
      'choice': choice,
      'responseMs': response,
      'answeredAt': DateTime.now().toUtc().toIso8601String(),
    };
    _finishStage();
    session.answers.add(answer);
    final done = index == session.trials.length;
    if (done) session.completedAt = DateTime.now().toUtc().toIso8601String();
    try {
      await repository.save(session);
      saving = false;
      if (disposed) return;
      if (done) {
        imageA?.dispose();
        imageB?.dispose();
        imageA = null;
        imageB = null;
        setStage(StudyStage.completed);
      } else if (!practice && !session.formalStarted) {
        setStage(StudyStage.instructions);
      } else if (stage == StudyStage.interrupted) {
        notifyListeners();
      } else {
        await loadTrial();
      }
    } catch (e) {
      session.answers.removeLast();
      session.completedAt = null;
      session.events.removeRange(oldEventCount, session.events.length);
      saving = false;
      fail(e);
    }
  }

  void fail(Object e) {
    error = e.toString();
    setStage(StudyStage.error);
  }

  Future<void> interrupt(String reason) async {
    if (disposed ||
        session.complete ||
        [StudyStage.instructions, StudyStage.interrupted].contains(stage)) {
      return;
    }
    _cancelled = true;
    final interruptedTrial = index < session.trials.length ? trial.id : null;
    setStage(StudyStage.interrupted);
    session.events.add({
      'type': 'interruption',
      'trialId': interruptedTrial,
      'reason': reason,
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    try {
      await repository.save(session);
    } catch (e) {
      fail(e);
    }
  }

  @override
  void dispose() {
    disposed = true;
    generation++;
    _timer?.cancel();
    imageA?.dispose();
    imageB?.dispose();
    super.dispose();
  }
}

class TestScreen extends StatefulWidget {
  final StudyRepository repository;
  final Experiment experiment;
  final StudySession session;
  final int? testDurationMs;
  const TestScreen({
    super.key,
    required this.repository,
    required this.experiment,
    required this.session,
    this.testDurationMs,
  });
  @override
  State<TestScreen> createState() => TestScreenState();
}

class TestScreenState extends State<TestScreen> with WidgetsBindingObserver {
  late final SessionRunner runner;
  bool _platformReady = false;
  bool get displayReady =>
      _platformReady &&
      (!Platform.isAndroid ||
          (MediaQuery.sizeOf(context).width >
                  MediaQuery.sizeOf(context).height &&
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed));
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    runner = SessionRunner(
      widget.repository,
      widget.experiment,
      widget.session,
      testDurationMs: widget.testDurationMs,
    )..addListener(_changed);
    PlatformBridge.presentation(true)
        .then((_) {
          if (mounted) setState(() => _platformReady = true);
        })
        .catchError((Object e) {
          if (mounted) runner.fail('无法进入正式呈现模式：$e');
        });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) setState(() {});
    if (state != AppLifecycleState.resumed) {
      unawaited(runner.interrupt(state.name));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    runner.removeListener(_changed);
    runner.dispose();
    _focus.dispose();
    unawaited(PlatformBridge.presentation(false));
    super.dispose();
  }

  Future<void> leave() async {
    if (!runner.session.complete) await runner.interrupt('leave');
    if (!mounted) return;
    final exit =
        runner.session.complete ||
        await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('保存并退出本次会话？'),
                content: const Text('已答内容已保存在本机。恢复时，未完成的当前题会重新完整展示。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('继续测试'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('保存退出'),
                  ),
                ],
              ),
            ) ==
            true;
    if (exit && mounted) Navigator.pop(context);
  }

  Widget panel(
    String title,
    String body,
    String button,
    VoidCallback action, {
    Key? buttonKey,
  }) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 640),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
            Text(body, style: const TextStyle(fontSize: 17, height: 1.8)),
            const SizedBox(height: 28),
            FilledButton(
              onPressed:
                  (buttonKey == const Key('begin-phase') ||
                          buttonKey == const Key('resume-trial')) &&
                      !displayReady
                  ? null
                  : action,
              key: buttonKey,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  (buttonKey == const Key('begin-phase') ||
                              buttonKey == const Key('resume-trial')) &&
                          !displayReady
                      ? '正在准备横屏显示…'
                      : button,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: leave, child: const Text('保存并返回')),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final stage = runner.stage;
    final token = runner.token;
    return PopScope(
      canPop: runner.session.complete,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(leave());
      },
      child: KeyboardListener(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (event) {
          if (event is! KeyDownEvent) return;
          if (event.logicalKey == LogicalKeyboardKey.digit1 ||
              event.logicalKey == LogicalKeyboardKey.numpad1) {
            unawaited(runner.answer(1));
          } else if (event.logicalKey == LogicalKeyboardKey.digit2 ||
              event.logicalKey == LogicalKeyboardKey.numpad2) {
            unawaited(runner.answer(2));
          } else if (event.logicalKey == LogicalKeyboardKey.escape) {
            unawaited(leave());
          }
        },
        child: Scaffold(
          backgroundColor: const Color(0xff808080),
          body: LayoutBuilder(
            builder: (context, bounds) {
              final ratio = MediaQuery.devicePixelRatioOf(context);
              final c = runner.index < runner.session.trials.length
                  ? runner.currentCase
                  : null;
              final size = c == null
                  ? Size.zero
                  : applyBoxFit(
                      BoxFit.contain,
                      Size(c.width.toDouble(), c.height.toDouble()),
                      bounds.biggest,
                    ).destination;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                runner.presented(token, {
                  'logicalWidth': bounds.maxWidth,
                  'logicalHeight': bounds.maxHeight,
                  'dpr': ratio,
                  'imageWidthPx': size.width * ratio,
                  'imageHeightPx': size.height * ratio,
                });
              });
              return switch (stage) {
                StudyStage.instructions => panel(
                  runner.practice ? '观看说明与练习' : '练习结束，开始正式测试',
                  runner.practice
                      ? '接下来每次会先后显示两幅图片。\n请判断哪一幅是真实拍摄图像。\n即使不确定，也必须选择第一幅或第二幅。\n图片显示后不能回看，答题不设时限。\n先完成练习，练习结果不计入正式统计。'
                      : '正式阶段不显示答案或正确率。\n请依据记忆与整体印象作答，不必刻意寻找细小差别。\n作答后自动进入下一题。测试期间请保持观看距离，不切换应用。',
                  runner.practice ? '开始练习' : '开始正式测试',
                  () => unawaited(runner.begin()),
                  buttonKey: const Key('begin-phase'),
                ),
                StudyStage.loading => const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
                StudyStage.promptA || StudyStage.promptB => Center(
                  child: Text(
                    stage == StudyStage.promptA ? 'A' : 'B',
                    style: const TextStyle(
                      fontSize: 64,
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                StudyStage.imageA || StudyStage.imageB => SizedBox.expand(
                  child: RawImage(
                    key: const Key('stimulus-image'),
                    image: stage == StudyStage.imageA
                        ? runner.imageA
                        : runner.imageB,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                StudyStage.answer => Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          runner.practice ? '练习' : '请选择',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '哪一幅是真实拍摄图像？',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          '即使不确定，也请选择一幅。答题不限时。',
                          style: TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 30),
                        Wrap(
                          spacing: 24,
                          runSpacing: 16,
                          alignment: WrapAlignment.center,
                          children: [
                            for (final choice in [1, 2])
                              SizedBox(
                                width: 250,
                                height: 76,
                                child: FilledButton(
                                  key: Key('answer-$choice'),
                                  onPressed: runner.saving
                                      ? null
                                      : () => unawaited(runner.answer(choice)),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: const Color(0xff173e3a),
                                  ),
                                  child: Text(
                                    choice == 1
                                        ? '第一幅  A  /  1'
                                        : '第二幅  B  /  2',
                                    style: const TextStyle(fontSize: 21),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                StudyStage.interrupted => panel(
                  '测试已暂停',
                  '本题展示被中断，未计为有效作答。\n继续后将从当前题的第一幅重新完整展示。\n中断记录会保留在结果中。',
                  '重新展示当前题',
                  () => unawaited(runner.begin()),
                  buttonKey: const Key('resume-trial'),
                ),
                StudyStage.error => panel(
                  '暂时无法继续',
                  runner.error ?? '读取或保存失败，请检查素材和存储空间。',
                  '重试当前题',
                  () => unawaited(runner.begin()),
                ),
                StudyStage.completed => panel(
                  '测试已完成',
                  '感谢参与。\n本次答案已保存在本机，请将设备交回组织者。',
                  '返回管理页面',
                  () => Navigator.pop(context),
                  buttonKey: const Key('finish-session'),
                ),
              };
            },
          ),
        ),
      ),
    );
  }

  final FocusNode _focus = FocusNode();
}
