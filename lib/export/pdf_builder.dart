import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../imaging/ocr_service.dart';

/// Tamano de pagina del PDF resultante.
enum PdfPageSize {
  auto('Ajustar a la imagen'),
  a4('A4'),
  letter('Carta'),
  legal('Oficio'),
  a5('A5');

  final String label;
  const PdfPageSize(this.label);

  PdfPageFormat? get format => switch (this) {
        PdfPageSize.auto => null,
        PdfPageSize.a4 => PdfPageFormat.a4,
        PdfPageSize.letter => PdfPageFormat.letter,
        PdfPageSize.legal => PdfPageFormat.legal,
        PdfPageSize.a5 => PdfPageFormat.a5,
      };
}

/// Calidad (resolucion y compresion) de las imagenes incrustadas.
enum PdfQuality {
  high('Alta', 2400, 90),
  medium('Media', 1700, 80),
  low('Baja (menor tamano)', 1200, 68);

  final String label;
  final int maxSide;
  final int jpegQuality;
  const PdfQuality(this.label, this.maxSide, this.jpegQuality);
}

/// Una pagina de entrada para el PDF.
class PdfPageInput {
  final Uint8List jpeg;
  final int imageWidth, imageHeight;
  final List<OcrLine> ocrLines;

  const PdfPageInput({
    required this.jpeg,
    required this.imageWidth,
    required this.imageHeight,
    this.ocrLines = const [],
  });
}

/// Construye PDFs a partir de las paginas escaneadas.
class PdfBuilder {
  /// Margen en puntos (1 pt = 1/72 pulgada).
  static const double defaultMargin = 0;

  static Future<Uint8List> build({
    required List<PdfPageInput> pages,
    String title = 'Manticora',
    PdfPageSize pageSize = PdfPageSize.auto,
    double margin = defaultMargin,
    bool searchableText = true,
    String? watermark,
  }) async {
    final doc = pw.Document(
      title: title,
      author: 'Manticora',
      creator: 'Manticora',
      compress: true,
    );

    for (final input in pages) {
      final image = pw.MemoryImage(input.jpeg);
      final imgW = input.imageWidth > 0 ? input.imageWidth.toDouble() : image.width.toDouble();
      final imgH = input.imageHeight > 0 ? input.imageHeight.toDouble() : image.height.toDouble();

      final format = _formatFor(pageSize, imgW, imgH, margin);
      final availW = format.width - format.marginLeft - format.marginRight;
      final availH = format.height - format.marginTop - format.marginBottom;

      // Encaje "contain" calculado a mano: necesitamos el rectangulo exacto
      // para colocar encima la capa de texto invisible.
      final scale = (availW / imgW) < (availH / imgH) ? availW / imgW : availH / imgH;
      final drawW = imgW * scale, drawH = imgH * scale;
      final offX = (availW - drawW) / 2, offY = (availH - drawH) / 2;

      doc.addPage(
        pw.Page(
          pageFormat: format,
          build: (context) {
            final children = <pw.Widget>[
              pw.Positioned(
                left: offX,
                top: offY,
                child: pw.SizedBox(
                  width: drawW,
                  height: drawH,
                  child: pw.Image(image, fit: pw.BoxFit.fill),
                ),
              ),
            ];

            if (searchableText && input.ocrLines.isNotEmpty) {
              children.addAll(_textLayer(input.ocrLines, scale, offX, offY, drawW, drawH));
            }

            if (watermark != null && watermark.trim().isNotEmpty) {
              children.add(
                pw.Positioned(
                  left: 0,
                  top: availH / 2 - 40,
                  child: pw.SizedBox(
                    width: availW,
                    child: pw.Transform.rotateBox(
                      angle: 0.5,
                      child: pw.Center(
                        child: pw.Opacity(
                          opacity: 0.14,
                          child: pw.Text(
                            _sanitize(watermark),
                            style: pw.TextStyle(
                              fontSize: 48,
                              fontWeight: pw.FontWeight.bold,
                              color: PdfColors.grey700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            return pw.Stack(children: children);
          },
        ),
      );
    }

    return doc.save();
  }

  /// Capa de texto con opacidad 0: invisible pero seleccionable y buscable.
  static List<pw.Widget> _textLayer(
    List<OcrLine> lines,
    double scale,
    double offX,
    double offY,
    double drawW,
    double drawH,
  ) {
    final out = <pw.Widget>[];
    for (final line in lines) {
      final text = _sanitize(line.text);
      if (text.trim().isEmpty) continue;
      final left = offX + line.left * scale;
      final top = offY + line.top * scale;
      final w = line.width * scale;
      final h = line.height * scale;
      if (w <= 0 || h <= 0) continue;
      if (left < -8 || top < -8 || left > offX + drawW + 8 || top > offY + drawH + 8) {
        continue;
      }
      out.add(
        pw.Positioned(
          left: left,
          top: top,
          child: pw.Opacity(
            opacity: 0,
            child: pw.SizedBox(
              width: w,
              height: h,
              child: pw.FittedBox(
                fit: pw.BoxFit.fill,
                child: pw.Text(text, style: pw.TextStyle(fontSize: h.clamp(4, 72))),
              ),
            ),
          ),
        ),
      );
    }
    return out;
  }

  static PdfPageFormat _formatFor(PdfPageSize size, double imgW, double imgH, double margin) {
    final base = size.format;
    if (base == null) {
      // Ajustar a la imagen: 1 pixel = 1/200 pulgada (200 ppp).
      const dpi = 200.0;
      return PdfPageFormat(imgW * 72 / dpi, imgH * 72 / dpi, marginAll: margin);
    }
    // Respetamos la orientacion de la imagen.
    final landscape = imgW > imgH;
    final fmt = landscape ? base.landscape : base.portrait;
    return fmt.copyWith(
      marginLeft: margin,
      marginRight: margin,
      marginTop: margin,
      marginBottom: margin,
    );
  }

  /// Las fuentes estandar del PDF cubren Latin-1; sustituimos lo que no entra
  /// para que nunca falle la generacion por un glifo raro del OCR.
  static String _sanitize(String s) {
    final buf = StringBuffer();
    for (final r in s.runes) {
      buf.writeCharCode(r <= 0xFF ? r : 0x3F);
    }
    return buf.toString();
  }

  /// Guarda el PDF en disco y devuelve el fichero.
  static Future<File> saveTo(String path, Uint8List bytes) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    return f.writeAsBytes(bytes, flush: true);
  }
}
