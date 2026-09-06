import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../core/failure.dart';

/// Dibuja una pagina de texto como imagen para poder montar un video.
///
/// Un DOCX o un PPTX no traen pixeles que mostrar, solo texto. En vez de
/// renunciar al video, se compone una lamina legible con el titulo, el cuerpo y
/// el numero de pagina. El texto que se narra es el completo; aqui solo se
/// muestra lo que cabe, con puntos suspensivos si sobra.
abstract final class SlideImage {
  static const Color _background = Color(0xFFF6F5F2);
  static const Color _ink = Color(0xFF1B1D22);
  static const Color _muted = Color(0xFF6B7280);
  static const Color _accent = Color(0xFF2F6FED);

  /// Devuelve un PNG de [width] x [height] pixeles.
  static Future<Uint8List> render({
    required String title,
    required String body,
    required int number,
    required int total,
    int width = 1280,
    int height = 720,
  }) async {
    if (width < 320 || height < 240) {
      throw const AppFailure.validation('El tamano de la lamina es demasiado pequeno.');
    }

    final w = width.toDouble();
    final h = height.toDouble();
    final margin = w * 0.07;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w, h));

    canvas.drawRect(ui.Rect.fromLTWH(0, 0, w, h), Paint()..color = _background);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, w, h * 0.012),
      Paint()..color = _accent,
    );

    var cursor = margin;
    final cleanTitle = _collapse(title);
    if (cleanTitle.isNotEmpty) {
      final painter = _painter(
        cleanTitle,
        size: h * 0.062,
        weight: FontWeight.w700,
        color: _ink,
        maxLines: 2,
        maxWidth: w - margin * 2,
      );
      painter.paint(canvas, Offset(margin, cursor));
      cursor += painter.height + h * 0.045;
      painter.dispose();
    }

    final cleanBody = _collapse(body);
    if (cleanBody.isNotEmpty) {
      final fontSize = h * 0.036;
      final available = h - cursor - margin;
      final lines = (available / (fontSize * 1.42)).floor().clamp(1, 40);
      final painter = _painter(
        cleanBody,
        size: fontSize,
        weight: FontWeight.w400,
        color: _ink.withValues(alpha: 0.88),
        maxLines: lines,
        maxWidth: w - margin * 2,
        height: 1.42,
      );
      painter.paint(canvas, Offset(margin, cursor));
      painter.dispose();
    }

    final footer = _painter(
      total > 0 ? '$number / $total' : '$number',
      size: h * 0.028,
      weight: FontWeight.w500,
      color: _muted,
      maxLines: 1,
      maxWidth: w - margin * 2,
    );
    footer.paint(canvas, Offset(margin, h - margin * 0.75));
    footer.dispose();

    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) {
          throw const AppFailure(
            kind: FailureKind.document,
            message: 'No se ha podido dibujar la pagina para el video.',
          );
        }
        return data.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  static TextPainter _painter(
    String text, {
    required double size,
    required FontWeight weight,
    required Color color,
    required int maxLines,
    required double maxWidth,
    double height = 1.2,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: weight,
          height: height,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '...',
    )..layout(maxWidth: maxWidth);
    return painter;
  }

  static String _collapse(String value) =>
      value.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
