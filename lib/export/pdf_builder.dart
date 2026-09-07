import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/failure.dart';
import '../core/logger.dart';
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

  /// Texto reconocido sin coordenadas. Se usa solo cuando no hay cajas: es
  /// preferible un PDF donde se pueda buscar aunque el texto no este colocado
  /// palabra por palabra, a un PDF en el que no se pueda buscar nada.
  final String plainText;

  const PdfPageInput({
    required this.jpeg,
    required this.imageWidth,
    required this.imageHeight,
    this.ocrLines = const [],
    this.plainText = '',
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
    if (pages.isEmpty) {
      throw const AppFailure.validation('No hay paginas que incluir en el PDF.');
    }
    try {
      return await _build(
        pages: pages,
        title: title,
        pageSize: pageSize,
        margin: margin,
        searchableText: searchableText,
        watermark: watermark,
      );
    } on AppFailure {
      rethrow;
    } catch (e, st) {
      Log.e('PDF', 'Error construyendo el PDF', e, st);
      throw AppFailure.from(e, st, 'Construyendo el PDF');
    }
  }

  static Future<Uint8List> _build({
    required List<PdfPageInput> pages,
    required String title,
    required PdfPageSize pageSize,
    required double margin,
    required bool searchableText,
    String? watermark,
  }) async {
    final doc = pw.Document(
      title: title,
      author: 'Manticora',
      creator: 'Manticora',
      compress: true,
    );

    var added = 0;
    for (final input in pages) {
      if (input.jpeg.isEmpty) continue;
      final image = pw.MemoryImage(input.jpeg);
      final imgW =
          (input.imageWidth > 0 ? input.imageWidth : (image.width ?? 1000)).toDouble();
      final imgH =
          (input.imageHeight > 0 ? input.imageHeight : (image.height ?? 1414)).toDouble();

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
            } else if (searchableText && input.plainText.trim().isNotEmpty) {
              children.add(
                _plainTextLayer(input.plainText, offX, offY, drawW, drawH),
              );
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
      added++;
    }

    if (added == 0) {
      throw const AppFailure(
        kind: FailureKind.pdf,
        message: 'Ninguna de las paginas se ha podido incluir en el PDF.',
        retryable: false,
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
      // El tamano se calcula para que la linea ocupe aproximadamente el ancho
      // de su caja. NO se usa FittedBox ni se limita el ancho: cualquier
      // restriccion hace que la linea se parta y el PDF pierda texto al
      // buscarlo (una linea como "Pagina 1" acababa guardada como "Pagina").
      final byHeight = (h * 0.82).clamp(4.0, 72.0);
      final byWidth = text.isEmpty ? byHeight : (w / (text.length * 0.52));
      final fontSize = math.min(byHeight, byWidth.clamp(4.0, 72.0));

      out.add(
        pw.Positioned(
          left: left,
          top: top,
          child: pw.Opacity(
            opacity: 0,
            child: pw.Text(
              text,
              maxLines: 1,
              softWrap: false,
              overflow: pw.TextOverflow.visible,
              style: pw.TextStyle(fontSize: fontSize),
            ),
          ),
        ),
      );
    }
    return out;
  }

  /// Capa invisible para el texto sin coordenadas: un bloque que ocupa la
  /// pagina. No sirve para seleccionar palabra a palabra, pero deja el
  /// documento buscable, que es lo que se espera de un PDF escaneado.
  static pw.Widget _plainTextLayer(
    String text,
    double offX,
    double offY,
    double drawW,
    double drawH,
  ) {
    return pw.Positioned(
      left: offX,
      top: offY,
      child: pw.Opacity(
        opacity: 0,
        child: pw.SizedBox(
          width: drawW,
          height: drawH,
          child: pw.Text(
            _sanitize(text),
            style: const pw.TextStyle(fontSize: 8),
            overflow: pw.TextOverflow.clip,
          ),
        ),
      ),
    );
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
  /// Adapta el texto a lo que sabe escribir la fuente estandar del PDF.
  ///
  /// Las fuentes base de un PDF (Helvetica y companeras) solo cubren Latin-1,
  /// que incluye las tildes y la enye del espanol. Lo que queda fuera son sobre
  /// todo signos tipograficos —comillas curvas, guiones largos, puntos
  /// suspensivos, el simbolo del euro— que aparecen constantemente en
  /// documentos reales: sustituirlos por su equivalente de toda la vida deja el
  /// texto buscable, mientras que dejarlos como "?" rompe la busqueda.
  static String _sanitize(String s) {
    const equivalences = <int, String>{
      0x2018: "'", // ‘
      0x2019: "'", // ’
      0x201A: "'",
      0x201B: "'",
      0x201C: '"', // “
      0x201D: '"', // ”
      0x201E: '"',
      0x2010: '-', // ‐
      0x2011: '-',
      0x2012: '-',
      0x2013: '-', // –
      0x2014: '-', // —
      0x2015: '-',
      0x2026: '...', // …
      0x2022: '-', // •
      0x00A0: ' ', // espacio duro
      0x202F: ' ',
      0x2007: ' ',
      0x2009: ' ',
      0x20AC: 'EUR', // €
      0x2122: 'TM', // ™
      0x2212: '-', // menos matematico
      0x00AD: '', // guion blando
    };

    final buf = StringBuffer();
    for (final r in s.runes) {
      final replacement = equivalences[r];
      if (replacement != null) {
        buf.write(replacement);
      } else if (r <= 0xFF) {
        buf.writeCharCode(r);
      } else {
        buf.writeCharCode(0x3F); // ?
      }
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
