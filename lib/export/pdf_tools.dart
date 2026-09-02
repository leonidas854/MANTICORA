import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../core/device_profile.dart';
import '../core/failure.dart';
import '../core/logger.dart';
import '../core/validators.dart';

class RasterPage {
  final Uint8List jpeg;
  final int width, height;
  const RasterPage(this.jpeg, this.width, this.height);
}

/// Operaciones sobre PDFs ya existentes.
///
/// La version Flutter de Syncfusion no expone `merge`, asi que copiamos las
/// paginas como plantillas (`createTemplate` + `drawPdfTemplate`), que es el
/// procedimiento admitido y conserva el contenido vectorial y el texto.
///
/// Todos los documentos se cierran en `finally`: un `PdfDocument` sin liberar
/// se lleva por delante varios megas por cada operacion.
class PdfTools {
  PdfTools._();

  static const _tag = 'PDF';

  /// Abre un PDF validando antes los bytes y traduciendo el fallo.
  static sf.PdfDocument _open(Uint8List bytes, {String? password}) {
    final invalid = Validators.pdfBytes(bytes);
    if (invalid != null) throw invalid;
    try {
      return sf.PdfDocument(inputBytes: bytes, password: password);
    } catch (e, st) {
      final text = e.toString().toLowerCase();
      if (text.contains('password') || text.contains('encrypt')) {
        throw AppFailure(
          kind: FailureKind.pdf,
          message: password == null
              ? 'Este PDF esta protegido con contrasena.'
              : 'La contrasena del PDF no es correcta.',
          cause: e,
          stackTrace: st,
          retryable: false,
        );
      }
      throw AppFailure(
        kind: FailureKind.pdf,
        message: 'No se ha podido abrir el PDF: puede estar dañado.',
        cause: e,
        stackTrace: st,
        retryable: false,
      );
    }
  }

  static void _dispose(sf.PdfDocument? doc) {
    try {
      doc?.dispose();
    } catch (_) {}
  }

  /// Numero de paginas de un PDF.
  static int pageCount(Uint8List bytes, {String? password}) {
    sf.PdfDocument? doc;
    try {
      doc = _open(bytes, password: password);
      return doc.pages.count;
    } finally {
      _dispose(doc);
    }
  }

  /// Comprueba si el PDF esta cifrado y necesita contrasena.
  static bool needsPassword(Uint8List bytes) {
    sf.PdfDocument? doc;
    try {
      doc = sf.PdfDocument(inputBytes: bytes);
      return false;
    } catch (_) {
      return true;
    } finally {
      _dispose(doc);
    }
  }

  /// Rechaza documentos con mas paginas de las que aguanta el dispositivo.
  static void _checkPageBudget(int pages) {
    final limit = DeviceProfile.current.maxPagesPerExport;
    final tooMany = Validators.pageLimit(pages, limit);
    if (tooMany != null) throw tooMany;
  }

  // ------------------------------------------------------------------ unir

  /// Une varios PDF en uno solo, respetando el tamano de cada pagina.
  static Future<Uint8List> merge(List<Uint8List> documents,
      {List<String?>? passwords}) async {
    final few = Validators.minimumFiles(documents.length, 2, 'unir');
    if (few != null) throw few;

    final dest = sf.PdfDocument();
    try {
      dest.pageSettings.margins.all = 0;
      var total = 0;

      for (var i = 0; i < documents.length; i++) {
        sf.PdfDocument? src;
        try {
          src = _open(
            documents[i],
            password:
                (passwords != null && i < passwords.length) ? passwords[i] : null,
          );
          total += src.pages.count;
          _checkPageBudget(total);
          _copyPages(src, dest);
        } finally {
          _dispose(src);
        }
      }
      Log.i(_tag, 'Unidos ${documents.length} PDF ($total paginas)');
      return Uint8List.fromList(await dest.save());
    } finally {
      _dispose(dest);
    }
  }

  static void _copyPages(sf.PdfDocument src, sf.PdfDocument dest, {Set<int>? only}) {
    for (var i = 0; i < src.pages.count; i++) {
      if (only != null && !only.contains(i)) continue;
      try {
        final template = src.pages[i].createTemplate();
        dest.pageSettings.size = Size(template.size.width, template.size.height);
        dest.pageSettings.margins.all = 0;
        dest.pages.add().graphics.drawPdfTemplate(template, Offset.zero, template.size);
      } catch (e) {
        // Una pagina rota no debe abortar la operacion entera.
        Log.w(_tag, 'No se pudo copiar la pagina ${i + 1}', e);
      }
    }
  }

  // -------------------------------------------------------- dividir/extraer

  /// Crea un PDF nuevo solo con las paginas indicadas (indices desde 0).
  static Future<Uint8List> extractPages(
    Uint8List bytes,
    List<int> pageIndices, {
    String? password,
  }) async {
    if (pageIndices.isEmpty) {
      throw const AppFailure.validation('No has indicado ninguna pagina.');
    }
    _checkPageBudget(pageIndices.length);

    sf.PdfDocument? src;
    final dest = sf.PdfDocument();
    try {
      src = _open(bytes, password: password);
      final valid = pageIndices.where((i) => i >= 0 && i < src!.pages.count).toSet();
      if (valid.isEmpty) {
        throw const AppFailure.validation(
          'Ninguna de las paginas indicadas existe en el documento.',
        );
      }
      dest.pageSettings.margins.all = 0;
      _copyPages(src, dest, only: valid);
      return Uint8List.fromList(await dest.save());
    } finally {
      _dispose(src);
      _dispose(dest);
    }
  }

  /// Divide el documento en bloques de [pagesPerChunk] paginas.
  static Future<List<Uint8List>> splitEvery(
    Uint8List bytes,
    int pagesPerChunk, {
    String? password,
  }) async {
    if (pagesPerChunk < 1) {
      throw const AppFailure.validation(
        'El numero de paginas por fichero debe ser al menos 1.',
      );
    }
    final total = pageCount(bytes, password: password);
    if (total <= pagesPerChunk) {
      throw AppFailure.validation(
        'El documento solo tiene $total paginas: no hay nada que dividir.',
      );
    }

    final out = <Uint8List>[];
    for (var start = 0; start < total; start += pagesPerChunk) {
      final end = (start + pagesPerChunk).clamp(0, total);
      out.add(await extractPages(
        bytes,
        [for (var i = start; i < end; i++) i],
        password: password,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    Log.i(_tag, 'Documento dividido en ${out.length} ficheros');
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
    if (keep.isEmpty) {
      throw const AppFailure.validation(
        'No puedes eliminar todas las paginas del documento.',
      );
    }
    return extractPages(bytes, keep, password: password);
  }

  /// Reordena las paginas segun la lista de indices dada.
  static Future<Uint8List> reorderPages(
    Uint8List bytes,
    List<int> newOrder, {
    String? password,
  }) async {
    if (newOrder.isEmpty) {
      throw const AppFailure.validation('El nuevo orden esta vacio.');
    }
    sf.PdfDocument? src;
    final dest = sf.PdfDocument();
    try {
      src = _open(bytes, password: password);
      dest.pageSettings.margins.all = 0;
      for (final index in newOrder) {
        if (index < 0 || index >= src.pages.count) continue;
        try {
          final template = src.pages[index].createTemplate();
          dest.pageSettings.size = Size(template.size.width, template.size.height);
          dest.pageSettings.margins.all = 0;
          dest.pages.add().graphics.drawPdfTemplate(
                template,
                Offset.zero,
                template.size,
              );
        } catch (e) {
          Log.w(_tag, 'No se pudo reubicar la pagina ${index + 1}', e);
        }
      }
      return Uint8List.fromList(await dest.save());
    } finally {
      _dispose(src);
      _dispose(dest);
    }
  }

  // ---------------------------------------------------------------- rotar

  /// Gira paginas. [quarterTurns] en sentido horario (1 = 90 grados).
  static Future<Uint8List> rotatePages(
    Uint8List bytes,
    Set<int> pageIndices,
    int quarterTurns, {
    String? password,
  }) async {
    sf.PdfDocument? doc;
    try {
      doc = _open(bytes, password: password);
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
      return Uint8List.fromList(await doc.save());
    } finally {
      _dispose(doc);
    }
  }

  // ------------------------------------------------------------ seguridad

  /// Protege el PDF con contrasena (AES-256).
  static Future<Uint8List> protect(
    Uint8List bytes, {
    required String userPassword,
    String? ownerPassword,
    String? currentPassword,
  }) async {
    final invalid = Validators.password(userPassword);
    if (invalid != null) throw invalid;

    sf.PdfDocument? doc;
    try {
      doc = _open(bytes, password: currentPassword);
      doc.security.algorithm = sf.PdfEncryptionAlgorithm.aesx256Bit;
      doc.security.userPassword = userPassword;
      doc.security.ownerPassword =
          (ownerPassword == null || ownerPassword.isEmpty) ? userPassword : ownerPassword;
      Log.i(_tag, 'PDF protegido con AES-256');
      return Uint8List.fromList(await doc.save());
    } finally {
      _dispose(doc);
    }
  }

  /// Quita la proteccion (hay que conocer la contrasena actual).
  static Future<Uint8List> removeProtection(
    Uint8List bytes,
    String currentPassword,
  ) async {
    if (currentPassword.isEmpty) {
      throw const AppFailure.validation('Indica la contrasena actual del PDF.');
    }
    sf.PdfDocument? doc;
    try {
      doc = _open(bytes, password: currentPassword);
      doc.security.userPassword = '';
      doc.security.ownerPassword = '';
      return Uint8List.fromList(await doc.save());
    } finally {
      _dispose(doc);
    }
  }

  // ------------------------------------------------------------- contenido

  /// Extrae el texto de cada pagina (util para convertir un PDF a Word).
  static List<String> extractText(Uint8List bytes, {String? password}) {
    sf.PdfDocument? doc;
    try {
      doc = _open(bytes, password: password);
      final extractor = sf.PdfTextExtractor(doc);
      final out = <String>[];
      for (var i = 0; i < doc.pages.count; i++) {
        try {
          out.add(extractor.extractText(startPageIndex: i, endPageIndex: i));
        } catch (e) {
          Log.w(_tag, 'No se pudo extraer el texto de la pagina ${i + 1}', e);
          out.add('');
        }
      }
      return out;
    } finally {
      _dispose(doc);
    }
  }

  /// Rasteriza el PDF a JPEG, una imagen por pagina.
  ///
  /// Usa el motor nativo (pdfium) a traves del paquete `printing`, asi que
  /// debe llamarse desde el isolate principal.
  static Future<List<RasterPage>> rasterize(
    Uint8List bytes, {
    double? dpi,
    int jpegQuality = 82,
    List<int>? pages,
    void Function(int done)? onPage,
  }) async {
    final invalid = Validators.pdfBytes(bytes);
    if (invalid != null) throw invalid;

    final resolution = dpi ?? DeviceProfile.current.rasterDpi;
    final out = <RasterPage>[];
    var index = 0;

    try {
      await for (final page in Printing.raster(bytes, dpi: resolution, pages: pages)) {
        final rgba = page.pixels;
        final w = page.width, h = page.height;
        if (w <= 0 || h <= 0 || rgba.isEmpty) continue;

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
        _checkPageBudget(out.length);
      }
    } on AppFailure {
      rethrow;
    } catch (e, st) {
      if (out.isEmpty) throw AppFailure.from(e, st, 'Convirtiendo el PDF a imagenes');
      Log.w(_tag, 'Rasterizado incompleto tras ${out.length} paginas', e, st);
    }

    if (out.isEmpty) {
      throw const AppFailure(
        kind: FailureKind.pdf,
        message: 'No se ha podido leer ninguna pagina del PDF.',
        retryable: false,
      );
    }
    return out;
  }

  /// Comprime un PDF rasterizandolo a la resolucion indicada.
  /// Es la unica forma fiable de reducir de verdad un PDF lleno de escaneos.
  static Future<Uint8List> compress(
    Uint8List bytes, {
    double? dpi,
    int jpegQuality = 70,
    void Function(int done)? onPage,
  }) async {
    final resolution = dpi ?? DeviceProfile.current.rasterDpi;
    final rasters = await rasterize(
      bytes,
      dpi: resolution,
      jpegQuality: jpegQuality,
      onPage: onPage,
    );

    final dest = sf.PdfDocument();
    try {
      dest.pageSettings.margins.all = 0;
      for (final r in rasters) {
        try {
          // 72 pt por pulgada: mantenemos el tamano fisico original.
          final wPt = r.width * 72 / resolution;
          final hPt = r.height * 72 / resolution;
          dest.pageSettings.size = Size(wPt, hPt);
          dest.pageSettings.margins.all = 0;
          dest.pages.add().graphics.drawImage(
                sf.PdfBitmap(r.jpeg),
                Rect.fromLTWH(0, 0, wPt, hPt),
              );
        } catch (e) {
          Log.w(_tag, 'No se pudo incluir una pagina comprimida', e);
        }
      }
      dest.compressionLevel = sf.PdfCompressionLevel.best;
      final result = Uint8List.fromList(await dest.save());
      Log.i(
        _tag,
        'Comprimido: ${bytes.length} -> ${result.length} bytes '
        '(${(100 - result.length * 100 / bytes.length).toStringAsFixed(0)}% menos)',
      );
      return result;
    } finally {
      _dispose(dest);
    }
  }
}
