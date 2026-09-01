import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../imaging/geometry.dart';

/// Calcula el rectangulo que ocupa una imagen dentro de un area, con
/// BoxFit.contain, y permite convertir coordenadas en ambos sentidos.
class FittedImage {
  final Size imageSize;
  final Size boxSize;
  late final double scale;
  late final Offset origin;

  FittedImage(this.imageSize, this.boxSize) {
    if (imageSize.width <= 0 || imageSize.height <= 0) {
      scale = 1;
      origin = Offset.zero;
      return;
    }
    scale = math.min(boxSize.width / imageSize.width, boxSize.height / imageSize.height);
    origin = Offset(
      (boxSize.width - imageSize.width * scale) / 2,
      (boxSize.height - imageSize.height * scale) / 2,
    );
  }

  Rect get rect => Rect.fromLTWH(
      origin.dx, origin.dy, imageSize.width * scale, imageSize.height * scale);

  Offset toView(Pt p) => Offset(origin.dx + p.x * scale, origin.dy + p.y * scale);

  Pt toImage(Offset o) => Pt(
        ((o.dx - origin.dx) / scale).clamp(0, imageSize.width),
        ((o.dy - origin.dy) / scale).clamp(0, imageSize.height),
      );
}

/// Dibuja el cuadrilatero detectado sobre la vista previa de la camara.
class QuadPainter extends CustomPainter {
  final Quad? quad;
  final Size sourceSize;
  final Color color;
  final bool showHandles;
  final bool cover;

  QuadPainter({
    required this.quad,
    required this.sourceSize,
    this.color = const Color(0xFF2E6BE6),
    this.showHandles = false,
    this.cover = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final q = quad;
    if (q == null || sourceSize.width <= 0 || sourceSize.height <= 0) return;

    // La vista previa de la camara usa BoxFit.cover; la de recorte, contain.
    final scale = cover
        ? math.max(size.width / sourceSize.width, size.height / sourceSize.height)
        : math.min(size.width / sourceSize.width, size.height / sourceSize.height);
    final dx = (size.width - sourceSize.width * scale) / 2;
    final dy = (size.height - sourceSize.height * scale) / 2;
    Offset map(Pt p) => Offset(dx + p.x * scale, dy + p.y * scale);

    final pts = q.points.map(map).toList();
    final path = Path()..addPolygon(pts, true);

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: 0.18),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );

    if (showHandles) {
      final fill = Paint()..color = Colors.white;
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = color;
      for (final p in pts) {
        canvas.drawCircle(p, 9, fill);
        canvas.drawCircle(p, 9, ring);
      }
    }
  }

  @override
  bool shouldRepaint(QuadPainter old) =>
      old.quad != quad || old.sourceSize != sourceSize || old.color != color;
}

/// Editor interactivo de las 4 esquinas del documento.
class QuadEditor extends StatefulWidget {
  final ui.Image image;
  final Quad quad;
  final ValueChanged<Quad> onChanged;

  const QuadEditor({
    super.key,
    required this.image,
    required this.quad,
    required this.onChanged,
  });

  @override
  State<QuadEditor> createState() => _QuadEditorState();
}

class _QuadEditorState extends State<QuadEditor> {
  int? _dragging;
  Offset? _magnifierAt;

  @override
  Widget build(BuildContext context) {
    final imageSize =
        Size(widget.image.width.toDouble(), widget.image.height.toDouble());

    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final fit = FittedImage(imageSize, box);
        final corners = widget.quad.points.map(fit.toView).toList();

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            var best = -1;
            var bestDist = 44.0;
            for (var i = 0; i < corners.length; i++) {
              final dist = (corners[i] - d.localPosition).distance;
              if (dist < bestDist) {
                bestDist = dist;
                best = i;
              }
            }
            if (best >= 0) {
              setState(() {
                _dragging = best;
                _magnifierAt = d.localPosition;
              });
            }
          },
          onPanUpdate: (d) {
            final i = _dragging;
            if (i == null) return;
            final pts = [...widget.quad.points];
            pts[i] = fit.toImage(d.localPosition);
            setState(() => _magnifierAt = d.localPosition);
            widget.onChanged(Quad(pts[0], pts[1], pts[2], pts[3]));
          },
          onPanEnd: (_) => setState(() {
            _dragging = null;
            _magnifierAt = null;
          }),
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(painter: _ImagePainter(widget.image, fit)),
              CustomPaint(
                painter: QuadPainter(
                  quad: widget.quad,
                  sourceSize: imageSize,
                  showHandles: true,
                  cover: false,
                ),
              ),
              // Lupa: imprescindible para ajustar la esquina bajo el dedo.
              if (_magnifierAt != null)
                Positioned(
                  left: _magnifierAt!.dx - 60,
                  top: _magnifierAt!.dy - 150,
                  child: IgnorePointer(
                    child: RawMagnifier(
                      decoration: MagnifierDecoration(
                        shape: CircleBorder(
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 3,
                          ),
                        ),
                      ),
                      size: const Size(120, 120),
                      magnificationScale: 2.2,
                      focalPointOffset: const Offset(0, 90),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ImagePainter extends CustomPainter {
  final ui.Image image;
  final FittedImage fit;
  _ImagePainter(this.image, this.fit);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      fit.rect,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_ImagePainter old) => old.image != image || old.fit.rect != fit.rect;
}
