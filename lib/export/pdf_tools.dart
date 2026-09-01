import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

/// Operaciones sobre PDFs ya existentes.
///
/// La version Flutter de Syncfusion no expone `merge`, asi que copiamos las
/// paginas como plantillas (`createTemplate` + `drawPdfTemplate`), que es el
/// procedimiento admitido y conserva el contenido vectorial y el texto.
class PdfTools {
  /// Numero de paginas de un PDF.
  static int pageCount(Uint8List bytes, {String? password}) {
    final doc = sf.PdfDocument(inputBytes: bytes, password: password);
    final n = doc.pages.count;
    doc.dispose();
    return n;
  }

  /// Comprueba si el PDF esta cifrado y necesita contrasena.
  static bool needsPassword(Uint8List bytes) {
    try {
      final doc = sf.PdfDocument(inputBytes: bytes);
      doc.dispose();
      return false;
    } catch (_) {
      return true;
    }
  }

  // ------------------------------------------------------------------ unir

  /// Une varios PDF en uno solo, respetando el tamano de cada pagina.
  static Future<Uint8List> merge(List<Uint8List> documents,
      {List<String?>? passwords}) async {
    final dest = sf.PdfDocument();
    dest.pageSettings.margins.all = 0;

    for (var i = 0; i < documents.length; i++) {
      final src = sf.PdfDocument(
        inputBytes: documents[i],
        password: passwords != null && i < passwords.length ? passwords[i] : null,
      );
      _copyPages(src, dest);
      src.dispose();
    }
    final out = Uint8List.fromList(await dest.save());
    dest.dispose();
    return out;
  }

  static void _copyPages(sf.PdfDocument src, sf.PdfDocument dest,
      {List<int>? only}) {
    for (var i = 0; i < src.pages.count; i++) {
      if (only != null && !only.contains(i)) continue;
      final page = src.pages[i];
      final template = page.createTemplate();
      dest.pageSettings.size = Size(template.size.width, template.size.height);
      dest.pageSettings.margins.all = 0;
      final newPage = dest.pages.add();
      newPage.graphics.drawPdfTemplate(template, Offset.zero, template.size);
    }
  }

  // -------------------------------------------------------- dividir/extraer

  /// Crea un PDF nuevo solo con las paginas indicadas (indices desde 0).
  static Future<Uint8List> extractPages(
    Uint8List bytes,
    List<int> pageIndices, {
    String? password,
  }) async {
    final src = sf.PdfDocument(inputBytes: bytes, password: password);
    final dest = sf.PdfDocument();
    dest.pageSettings.margins.all = 0;
    final wanted = pageIndices.toSet();
    _copyPages(src, dest, only: wanted.toList());
    final out = Uint8List.fromList(await dest.save());
    src.dispose();
    dest.dispose();
    return out;
  }

  /// Divide el documento en bloques de [pagesPerChunk] paginas.
  static Future<List<Uint8List>> splitEvery(
    Uint8List bytes,
    int pagesPerChunk, {
    String? password,
  }) async {
    final total = pageCount(bytes, password: password);
    final out = <Uint8List>[];
    for (var start = 0; start < total; start += pagesPerChunk) {
      final end = (start + pagesPerChunk).clamp(0, total);
      out.add(await extractPages(
        bytes,
        [for (var i = start; i < end; i++) i],
        password: password,
      ));
    }
    return out;
  }

  /// Elimina las paginas indicadas.
  static Future<Uint8List> deletePages(
    Uint8List bytes,
    Set<int> pageIndices, {
    String? password,
  }) async {
    final total = pageCount(bytes, password: password);
    final keep = [for (var i = 0; i < total; i++) if (!pageIndices.contains(i)) i];
    return extractPages(bytes, keep, password: password);
  }

  /// Reordena las paginas segun la lista de indices dada.
  static Future<Uint8List> reorderPages(
    Uint8List bytes,
    List<int> newOrder, {
    String? password,
  }) async {
    final src = sf.PdfDocument(inputBytes: bytes, password: password);
    final dest = sf.PdfDocument();
    dest.pageSettings.margins.all = 0;
    for (final index in newOrder) {
      if (index < 0 || index >= src.pages.count) continue;
      final template = src.pages[index].createTemplate();
      dest.pageSettings.size = Size(template.size.width, template.size.height);
      dest.pageSettings.margins.all = 0;
      dest.pages.add().graphics.drawPdfTemplate(template, Offset.zero, template.size);
    }
    final out = Uint8List.fromList(await dest.save());
    src.dispose();
    dest.dispose();
    return out;
  }

  // ---------------------------------------------------------------- rotar

  /// Gira paginas. [quarterTurns] en sentido horario (1 = 90 grados).
  static Future<Uint8List> rotatePages(
    Uint8List bytes,
    Set<int> pageIndices,
    int quarterTurns, {
    String? password,
  }) async {
    final doc = sf.PdfDocument(inputBytes: bytes, password: password);
    final angle = switch (((quarterTurns % 4) + 4) % 4) {
      1 => sf.PdfPageRotateAngle.rotateAngle90,
      2 => sf.PdfPageRotateAngle.rotateAngle180,
      3 => sf.PdfPageRotateAngle.rotateAngle270,
      _ => sf.PdfPageRotateAngle.rotateAngle0,
    };
    for (var i = 0; i < doc.pages.count; i++) {
      if (pageIndices.isEmpty || pageIndices.contains(i)) {
        doc.pages[i].rotation = angle;
      }
    }
    final out = Uint8List.fromList(await doc.save());
    doc.dispose();
    return out;
  }

  // ------------------------------------------------------------ seguridad

  /// Protege el PDF con contrasena (AES-256).
  static Future<Uint8List> protect(
    Uint8List bytes, {
    required String userPassword,
    String? ownerPassword,
    String? currentPassword,
  }) async {
    final doc = sf.PdfDocument(inputBytes: bytes, password: currentPassword);
    doc.security.algorithm = sf.PdfEncryptionAlgorithm.aesx256Bit;
    doc.security.userPassword = userPassword;
    doc.security.ownerPassword =
        (ownerPassword == null || ownerPassword.isEmpty) ? userPassword : ownerPassword;
    final out = Uint8List.fromList(await doc.save());
    doc.dispose();
    return out;
  }

  /// Quita la proteccion (hay que conocer la contrasena actual).
  static Future<Uint8List> removeProtection(
    Uint8List bytes,
    String currentPassword,
  ) async {
    final doc = sf.PdfDocument(inputBytes: bytes, password: currentPassword);
    doc.security.userPassword = '';
    doc.security.ownerPassword = '';
    final out = Uint8List.fromList(await doc.save());
    doc.dispose();
    return out;
  }

  // ------------------------------------------------------------- contenido

  /// Extrae el texto de cada pagina (util para convertir un PDF a Word).
  static List<String> extractText(Uint8List bytes, {String? password}) {
    final doc = sf.PdfDocument(inputBytes: bytes, password: password);
    final extractor = sf.PdfTextExtractor(doc);
    final out = <String>[];
    for (var i = 0; i < doc.pages.count; i++) {
      out.add(extractor.extractText(startPageIndex: i, endPageIndex: i));
    }
    doc.dispose();
    return out;
  }

  /// Rasteriza el PDF a JPEG, una imagen por pagina.
  ///
  /// Usa el motor nativo (pdfium) a traves del paquete `printing`, asi que
  /// debe llamarse desde el isolate principal.
  static Future<List<RasterPage>> rasterize(
    Uint8List bytes, {
    double dpi = 150,
    int jpegQuality = 82,
    List<int>? pages,
    void Function(int done)? onPage,
  }) async {
    final out = <RasterPage>[];
    var index = 0;
    await for (final page in Printing.raster(bytes, dpi: dpi, pages: pages)) {
      final rgba = page.pixels;
      final w = page.width, h = page.height;
      final jpeg = await Isolate.run(() {
        final image = img.Image.fromBytes(
          width: w,
          height: h,
          bytes: rgba.buffer,
          bytesOffset: rgba.offsetInBytes,
          numChannels: 4,
          order: img.ChannelOrder.rgba,
        );
        return Uint8List.fromList(img.encodeJpg(image, quality: jpegQuality));
      });
      out.add(RasterPage(jpeg, w, h));
      onPage?.call(++index);
    }
    return out;
  }

  /// Comprime un PDF rasterizandolo a la resolucion indicada.
  /// Es la unica forma fiable de reducir de verdad un PDF lleno de escaneos.
  static Future<Uint8List> compress(
    Uint8List bytes, {
    double dpi = 120,
    int jpegQuality = 70,
    void Function(int done)? onPage,
  }) async {
    final rasters = await rasterize(bytes,
        dpi: dpi, jpegQuality: jpegQuality, onPage: onPage);
    final dest = sf.PdfDocument();
    dest.pageSettings.margins.all = 0;
    for (final r in rasters) {
      // 72 pt por pulgada: mantenemos el tamano fisico original.
      final wPt = r.width * 72 / dpi;
      final hPt = r.height * 72 / dpi;
      dest.pageSettings.size = Size(wPt, hPt);
      dest.pageSettings.margins.all = 0;
      final page = dest.pages.add();
      page.graphics.drawImage(
        sf.PdfBitmap(r.jpeg),
        Rect.fromLTWH(0, 0, wPt, hPt),
      );
    }
    dest.compressionLevel = sf.PdfCompressionLevel.best;
    final out = Uint8List.fromList(await dest.save());
    dest.dispose();
    return out;
  }
}

class RasterPage {
  final Uint8List jpeg;
  final int width, height;
  const RasterPage(this.jpeg, this.width, this.height);
}
