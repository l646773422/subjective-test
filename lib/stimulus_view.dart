import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// One source rectangle is shared by A/B and both eyes. No material files change.
class StimulusView extends StatelessWidget {
  final ui.Image image;
  final Map<String, dynamic>? patch;

  /// For packed SBS, 0/1 selects a half. Patch coordinates are local to one eye.
  final int? packedEye;
  const StimulusView({
    super.key,
    required this.image,
    this.patch,
    this.packedEye,
  });
  static Rect sourceRect(
    ui.Image image,
    Map<String, dynamic>? patch, {
    int? packedEye,
  }) {
    final width = packedEye == null ? image.width.toDouble() : image.width / 2;
    final offset = (packedEye ?? 0) * width;
    return patch == null
        ? Rect.fromLTWH(offset, 0, width, image.height.toDouble())
        : Rect.fromLTWH(
            offset + (patch['x'] as num).toDouble(),
            (patch['y'] as num).toDouble(),
            (patch['width'] as num).toDouble(),
            (patch['height'] as num).toDouble(),
          );
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const Key('stimulus-image'),
    size: Size.infinite,
    painter: _StimulusPainter(
      image,
      sourceRect(image, patch, packedEye: packedEye),
    ),
  );
}

class _StimulusPainter extends CustomPainter {
  final ui.Image image;
  final Rect source;
  _StimulusPainter(this.image, this.source);
  @override
  void paint(Canvas canvas, Size size) {
    final fitted = applyBoxFit(BoxFit.contain, source.size, size).destination;
    canvas.drawImageRect(
      image,
      source,
      Alignment.center.inscribe(fitted, Offset.zero & size),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_StimulusPainter old) =>
      image != old.image || source != old.source;
}

/// Both eye trees have the same state/callbacks. Flutter transforms hit testing,
/// so clicking either eye produces exactly one normal UI action.
class StereoSurface extends StatefulWidget {
  final Map<String, dynamic>? stereo;
  final bool stimulus;
  final Widget Function(BuildContext context, int eye) builder;
  const StereoSurface({
    super.key,
    required this.stereo,
    required this.stimulus,
    required this.builder,
  });
  @override
  State<StereoSurface> createState() => _StereoSurfaceState();
}

class _StereoSurfaceState extends State<StereoSurface> {
  final cursor = ValueNotifier<Offset?>(null);
  final scroll = [
    ScrollController(keepScrollOffset: false),
    ScrollController(keepScrollOffset: false),
  ];
  bool syncingScroll = false;
  @override
  void dispose() {
    cursor.dispose();
    for (final controller in scroll) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.stereo == null) {
      return MouseRegion(
        cursor: widget.stimulus ? SystemMouseCursors.none : MouseCursor.defer,
        child: SizedBox.expand(child: widget.builder(context, 0)),
      );
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        final half = bounds.maxWidth / 2;
        // Half SBS first lays out a full-width eye, then squeezes the entire
        // tree to half width: stimuli, UI, software pointer and hit transforms.
        final logicalWidth = widget.stereo!['layout'] == 'half_sbs'
            ? bounds.maxWidth
            : half;
        final scale = half / logicalWidth;
        final disparity = (widget.stereo!['uiDisparity'] as num).toDouble();
        final screenPointer = widget.stereo!['pointerMapping'] != 'per_eye';
        double shift(int eye) => (eye == 0 ? 1 : -1) * disparity / 2;
        void track(Offset p) {
          if (screenPointer) {
            cursor.value = Offset(p.dx / bounds.maxWidth * logicalWidth, p.dy);
            return;
          }
          final eye = p.dx < half ? 0 : 1;
          cursor.value = Offset((p.dx - eye * half) / scale - shift(eye), p.dy);
        }

        // Button hover/press overlays are disabled so the two eyes remain identical.
        final theme = Theme.of(context);
        final noOverlay = WidgetStatePropertyAll<Color>(Colors.transparent);
        final binocularTheme = theme.copyWith(
          filledButtonTheme: FilledButtonThemeData(
            style: (theme.filledButtonTheme.style ?? const ButtonStyle())
                .copyWith(
                  overlayColor: noOverlay,
                  mouseCursor: const WidgetStatePropertyAll(
                    SystemMouseCursors.none,
                  ),
                ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: (theme.textButtonTheme.style ?? const ButtonStyle())
                .copyWith(
                  overlayColor: noOverlay,
                  mouseCursor: const WidgetStatePropertyAll(
                    SystemMouseCursors.none,
                  ),
                ),
          ),
        );
        return MouseRegion(
          cursor: SystemMouseCursors.none,
          onHover: (e) => track(e.localPosition),
          onExit: (_) => cursor.value = null,
          child: Listener(
            onPointerMove: (e) => track(e.localPosition),
            onPointerDown: (e) => track(e.localPosition),
            child: Theme(
              data: binocularTheme,
              child: _StereoInput(
                screenMapping: screenPointer,
                leftShift: widget.stimulus ? 0 : shift(0) * scale,
                child: Row(
                  children: [
                    for (final eye in [0, 1])
                      SizedBox(
                        width: half,
                        height: bounds.maxHeight,
                        child: ClipRect(
                          child: FittedBox(
                            fit: BoxFit.fill,
                            child: SizedBox(
                              width: logicalWidth,
                              height: bounds.maxHeight,
                              child: ExcludeSemantics(
                                excluding: eye == 1,
                                child: Transform.translate(
                                  offset: Offset(
                                    widget.stimulus ? 0 : shift(eye),
                                    0,
                                  ),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      KeyedSubtree(
                                        key: ValueKey('stereo-eye-$eye'),
                                        child: PrimaryScrollController(
                                          controller: scroll[eye],
                                          child:
                                              NotificationListener<
                                                ScrollUpdateNotification
                                              >(
                                                onNotification: (_) {
                                                  final other = scroll[1 - eye];
                                                  if (!syncingScroll &&
                                                      scroll[eye].hasClients &&
                                                      other.hasClients) {
                                                    syncingScroll = true;
                                                    other.jumpTo(
                                                      scroll[eye].offset.clamp(
                                                        other
                                                            .position
                                                            .minScrollExtent,
                                                        other
                                                            .position
                                                            .maxScrollExtent,
                                                      ),
                                                    );
                                                    syncingScroll = false;
                                                  }
                                                  return false;
                                                },
                                                child: ScrollConfiguration(
                                                  behavior:
                                                      ScrollConfiguration.of(
                                                        context,
                                                      ).copyWith(
                                                        scrollbars: false,
                                                      ),
                                                  child: widget.builder(
                                                    context,
                                                    eye,
                                                  ),
                                                ),
                                              ),
                                        ),
                                      ),
                                      if (!widget.stimulus)
                                        IgnorePointer(
                                          child: CustomPaint(
                                            key: ValueKey('stereo-cursor-$eye'),
                                            painter: _CursorPainter(cursor),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A physical full-screen pointer addresses the logical binocular UI once.
/// Reproject its hit coordinates into the left eye tree; events never duplicate.
class _StereoInput extends SingleChildRenderObjectWidget {
  final bool screenMapping;
  final double leftShift;
  const _StereoInput({
    required this.screenMapping,
    required this.leftShift,
    required super.child,
  });
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderStereoInput(screenMapping, leftShift);
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderStereoInput renderObject,
  ) {
    renderObject.screenMapping = screenMapping;
    renderObject.leftShift = leftShift;
  }
}

class _RenderStereoInput extends RenderProxyBox {
  bool screenMapping;
  double leftShift;
  _RenderStereoInput(this.screenMapping, this.leftShift);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (!screenMapping) {
      return super.hitTestChildren(result, position: position);
    }
    final transform = Matrix4.identity()
      ..setEntry(0, 0, 0.5)
      ..setEntry(0, 3, leftShift);
    return result.addWithRawTransform(
      transform: transform,
      position: position,
      hitTest: (result, p) => super.hitTestChildren(result, position: p),
    );
  }
}

class _CursorPainter extends CustomPainter {
  final ValueNotifier<Offset?> position;
  _CursorPainter(this.position) : super(repaint: position);
  @override
  void paint(Canvas canvas, Size size) {
    final p = position.value;
    if (p == null) return;
    final path = Path()
      ..moveTo(p.dx, p.dy)
      ..relativeLineTo(0, 25)
      ..relativeLineTo(6, -6)
      ..relativeLineTo(5, 11)
      ..relativeLineTo(5, -2)
      ..relativeLineTo(-5, -11)
      ..relativeLineTo(9, 0)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_CursorPainter old) => old.position != position;
}
