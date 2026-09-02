import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/device_profile.dart';
import '../core/error_orchestrator.dart';
import '../core/failure.dart';
import '../core/logger.dart';
import '../core/validators.dart';
import '../data/models/models.dart';
import '../data/repositories/storage_service.dart';
import '../imaging/ocr_service.dart';
import '../imaging/pipeline.dart';
import 'docx_builder.dart';
import 'pdf_builder.dart';

/// Formatos de salida ofrecidos al usuario.
enum ExportFormat { pdf, docx, text, jpeg }

class ExportResult {
  final File file;
  final ExportFormat format;

  /// Paginas que no se pudieron incluir (por fichero perdido o dañado).
  final List<int> skippedPages;

  const ExportResult(this.file, this.format, {this.skippedPages = const []});

  String get name => p.basename(file.path);
  bool get isPartial => skippedPages.isNotEmpty;
}

/// Convierte documentos escaneados a PDF, Word, texto o imagenes.
class ExportService {
  ExportService._();
  static final ExportService instance = ExportService._();

  static const _tag = 'Exportacion';

  StorageService get _files => StorageService.instance;

  static String safeName(String raw, String extension) =>
      Validators.safeFileName(raw, extension);

  /// Comprobaciones comunes antes de empezar cualquier exportacion.
  Future<void> _preflight(DocumentWithPages doc, {int bytesPerPage = 400 * 1024}) async {
    final empty = Validators.nonEmptyPages(doc.pages.length);
    if (empty != null) throw empty;

    final profile = DeviceProfile.current;
    final tooMany = Validators.pageLimit(doc.pages.length, profile.maxPagesPerExport);
    if (tooMany != null) throw tooMany;

    final space = await Validators.freeSpaceFor(
      await _files.exportsDir,
      doc.pages.length * bytesPerPage,
    );
    if (space != null) throw space;
  }

  // ------------------------------------------------------------------- PDF

  Future<ExportResult> toPdf(
    DocumentWithPages doc, {
    PdfPageSize pageSize = PdfPageSize.a4,
    PdfQuality quality = PdfQuality.high,
    bool searchableText = true,
    String? watermark,
    double margin = 0,
    void Function(int done, int total)? onProgress,
  }) async {
    await _preflight(doc);
    final profile = DeviceProfile.current;

    // En gama baja se recorta la calidad pedida: 2400 px por pagina no caben
    // en memoria cuando hay treinta paginas.
    final effectiveMaxSide = quality.maxSide.clamp(600, profile.maxImageSide);

    final inputs = <PdfPageInput>[];
    final skipped = <int>[];

    for (var i = 0; i < doc.pages.length; i++) {
      final page = doc.pages[i];
      final built = await ErrorOrchestrator.guard<PdfPageInput>(
        'Preparando la pagina ${i + 1} del PDF',
        () async {
          final file = await _files.fileFor(page.processedFile);
          final missing = await Validators.readableFile(file, what: 'imagen de la pagina');
          if (missing != null) throw missing;

          var bytes = await file.readAsBytes();
          var w = page.width, h = page.height;

          final needsResize = quality != PdfQuality.high ||
              (w > 0 && h > 0 && (w > effectiveMaxSide || h > effectiveMaxSide));
          if (needsResize) {
            bytes = await ImagePipeline.recompress(
              bytes,
              maxSide: effectiveMaxSide,
              quality: quality.jpegQuality,
            );
            if (w > 0 && h > 0) {
              final longest = w > h ? w : h;
              if (longest > effectiveMaxSide) {
                final s = effectiveMaxSide / longest;
                w = (w * s).round();
                h = (h * s).round();
              }
            }
          }

          // Las cajas del OCR estan en coordenadas de la imagen guardada; si
          // se ha reescalado, hay que moverlas en la misma proporcion.
          final rawLines = OcrResult.parseBoxes(page.ocrBoxes);
          final scale = (page.width > 0 && w > 0) ? w / page.width : 1.0;
          final lines = (scale - 1.0).abs() < 0.001
              ? rawLines
              : rawLines
                  .map((l) => OcrLine(l.text, l.left * scale, l.top * scale,
                      l.width * scale, l.height * scale))
                  .toList();

          return PdfPageInput(
            jpeg: bytes,
            imageWidth: w,
            imageHeight: h,
            ocrLines: lines,
          );
        },
        tag: _tag,
        notifyUser: false,
      );

      if (built == null) {
        skipped.add(i + 1);
        Log.w(_tag, 'Pagina ${i + 1} omitida del PDF');
      } else {
        inputs.add(built);
      }

      onProgress?.call(i + 1, doc.pages.length);
      if ((i + 1) % profile.pagesBeforeYield == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
    }

    if (inputs.isEmpty) {
      throw const AppFailure(
        kind: FailureKind.document,
        message: 'No se ha podido leer ninguna pagina del documento.',
        retryable: false,
      );
    }

    final bytes = await PdfBuilder.build(
      pages: inputs,
      title: doc.document.title,
      pageSize: pageSize,
      margin: margin,
      searchableText: searchableText,
      watermark: watermark,
    );

    final out = await _writeExport(safeName(doc.document.title, 'pdf'), bytes);
    Log.i(_tag, 'PDF creado: ${out.path} (${bytes.length} bytes)');
    return ExportResult(out, ExportFormat.pdf, skippedPages: skipped);
  }

  /// Genera solo los bytes del PDF (para vista previa o impresion).
  Future<Uint8List> pdfBytes(
    DocumentWithPages doc, {
    PdfPageSize pageSize = PdfPageSize.a4,
    PdfQuality quality = PdfQuality.medium,
    bool searchableText = true,
  }) async {
    final result = await toPdf(doc,
        pageSize: pageSize, quality: quality, searchableText: searchableText);
    return result.file.readAsBytes();
  }

  // ------------------------------------------------------------------ WORD

  Future<ExportResult> toDocx(
    DocumentWithPages doc, {
    DocxMode mode = DocxMode.textAndImages,
    PdfQuality quality = PdfQuality.medium,
  }) async {
    await _preflight(doc);
    final profile = DeviceProfile.current;
    final maxSide = quality.maxSide.clamp(600, profile.maxImageSide);

    if (mode != DocxMode.imagesOnly && doc.combinedText.trim().isEmpty) {
      Log.w(_tag, 'Word sin texto: el documento no tiene OCR');
    }

    final inputs = <DocxPageInput>[];
    final skipped = <int>[];

    for (var i = 0; i < doc.pages.length; i++) {
      final page = doc.pages[i];
      Uint8List? bytes;
      var w = page.width, h = page.height;

      if (mode != DocxMode.textOnly) {
        final built = await ErrorOrchestrator.guard<Uint8List>(
          'Preparando la imagen ${i + 1} para Word',
          () async {
            final file = await _files.fileFor(page.processedFile);
            final missing = await Validators.readableFile(file, what: 'imagen');
            if (missing != null) throw missing;
            return ImagePipeline.recompress(
              await file.readAsBytes(),
              maxSide: maxSide,
              quality: quality.jpegQuality,
            );
          },
          tag: _tag,
          notifyUser: false,
        );
        if (built == null) {
          skipped.add(i + 1);
        } else {
          bytes = built;
          if (w > 0 && h > 0) {
            final longest = w > h ? w : h;
            if (longest > maxSide) {
              final s = maxSide / longest;
              w = (w * s).round();
              h = (h * s).round();
            }
          }
        }
      }

      inputs.add(DocxPageInput(
        jpeg: bytes,
        imageWidth: w,
        imageHeight: h,
        text: page.ocrText ?? '',
      ));

      if ((i + 1) % profile.pagesBeforeYield == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
    }

    final bytes = DocxBuilder.build(
      pages: inputs,
      title: doc.document.title,
      mode: mode,
    );
    final out = await _writeExport(safeName(doc.document.title, 'docx'), bytes);
    Log.i(_tag, 'Word creado: ${out.path} (${bytes.length} bytes)');
    return ExportResult(out, ExportFormat.docx, skippedPages: skipped);
  }

  // ------------------------------------------------------------------ TEXTO

  Future<ExportResult> toText(DocumentWithPages doc) async {
    final empty = Validators.nonEmptyPages(doc.pages.length);
    if (empty != null) throw empty;

    final buf = StringBuffer('${doc.document.title}\n\n');
    var withText = 0;
    for (var i = 0; i < doc.pages.length; i++) {
      final t = doc.pages[i].ocrText ?? '';
      if (t.trim().isEmpty) continue;
      withText++;
      if (doc.pages.length > 1) buf.writeln('--- Pagina ${i + 1} ---');
      buf.writeln(t.trim());
      buf.writeln();
    }

    if (withText == 0) {
      throw const AppFailure(
        kind: FailureKind.document,
        message: 'No hay texto reconocido. Ejecuta primero el OCR.',
        retryable: false,
      );
    }

    final out = await _writeExportString(
      safeName(doc.document.title, 'txt'),
      buf.toString(),
    );
    return ExportResult(out, ExportFormat.text);
  }

  // --------------------------------------------------------------- IMAGENES

  /// Copia las paginas como JPEG sueltos a la carpeta de exportacion.
  Future<List<File>> toImages(DocumentWithPages doc) async {
    await _preflight(doc, bytesPerPage: 700 * 1024);

    final baseName = safeName(doc.document.title, 'dir').replaceAll('.dir', '');
    final dir = Directory(p.join((await _files.exportsDir).path, baseName));
    await dir.create(recursive: true);

    final out = <File>[];
    for (var i = 0; i < doc.pages.length; i++) {
      final copied = await ErrorOrchestrator.guard<File>(
        'Exportando la imagen ${i + 1}',
        () async {
          final src = await _files.fileFor(doc.pages[i].processedFile);
          final missing = await Validators.readableFile(src, what: 'imagen');
          if (missing != null) throw missing;
          final index = '${i + 1}'.padLeft(3, '0');
          return src.copy(p.join(dir.path, '$index.jpg'));
        },
        tag: _tag,
        notifyUser: false,
      );
      if (copied != null) out.add(copied);
    }

    if (out.isEmpty) {
      throw const AppFailure(
        kind: FailureKind.document,
        message: 'No se ha podido exportar ninguna imagen.',
        retryable: false,
      );
    }
    return out;
  }

  // ------------------------------------------------------------- utilidades

  Future<File> _writeExport(String fileName, Uint8List bytes) async {
    if (bytes.isEmpty) {
      throw const AppFailure(
        kind: FailureKind.document,
        message: 'El fichero generado ha salido vacio.',
      );
    }
    try {
      final out = File(p.join((await _files.exportsDir).path, fileName));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(bytes, flush: true);
      return out;
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Guardando $fileName');
    }
  }

  Future<File> _writeExportString(String fileName, String content) async {
    try {
      final out = File(p.join((await _files.exportsDir).path, fileName));
      await out.parent.create(recursive: true);
      await out.writeAsString(content, flush: true);
      return out;
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Guardando $fileName');
    }
  }
}
