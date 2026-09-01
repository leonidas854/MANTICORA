import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

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
  const ExportResult(this.file, this.format);

  String get name => p.basename(file.path);
}

/// Convierte documentos escaneados a PDF, Word, texto o imagenes.
class ExportService {
  ExportService._();
  static final ExportService instance = ExportService._();

  StorageService get _files => StorageService.instance;

  /// Nombre de fichero seguro en cualquier sistema de ficheros.
  static String safeName(String raw, String extension) {
    var name = raw.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    if (name.length > 80) name = name.substring(0, 80);
    if (name.isEmpty) name = 'documento';
    return '$name.$extension';
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
    final inputs = <PdfPageInput>[];
    for (var i = 0; i < doc.pages.length; i++) {
      final page = doc.pages[i];
      final file = await _files.fileFor(page.processedFile);
      if (!await file.exists()) continue;

      var bytes = await file.readAsBytes();
      var w = page.width, h = page.height;
      if (quality != PdfQuality.high) {
        bytes = await ImagePipeline.recompress(bytes,
            maxSide: quality.maxSide, quality: quality.jpegQuality);
        // Las cajas OCR estan en coordenadas de la imagen original; al
        // recomprimir cambia la escala, pero la proporcion se mantiene, asi
        // que basta con re-escalar el ancho/alto declarados.
        if (w > 0 && h > 0) {
          final longest = w > h ? w : h;
          if (longest > quality.maxSide) {
            final s = quality.maxSide / longest;
            w = (w * s).round();
            h = (h * s).round();
          }
        }
      }

      final rawLines = OcrResult.parseBoxes(page.ocrBoxes);
      final scale = (page.width > 0 && w > 0) ? w / page.width : 1.0;
      final lines = scale == 1.0
          ? rawLines
          : rawLines
              .map((l) => OcrLine(l.text, l.left * scale, l.top * scale,
                  l.width * scale, l.height * scale))
              .toList();

      inputs.add(PdfPageInput(
        jpeg: bytes,
        imageWidth: w,
        imageHeight: h,
        ocrLines: lines,
      ));
      onProgress?.call(i + 1, doc.pages.length);
    }

    final bytes = await PdfBuilder.build(
      pages: inputs,
      title: doc.document.title,
      pageSize: pageSize,
      margin: margin,
      searchableText: searchableText,
      watermark: watermark,
    );

    final out = File(p.join((await _files.exportsDir).path,
        safeName(doc.document.title, 'pdf')));
    await out.parent.create(recursive: true);
    await out.writeAsBytes(bytes, flush: true);
    return ExportResult(out, ExportFormat.pdf);
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
    final inputs = <DocxPageInput>[];
    for (final page in doc.pages) {
      Uint8List? bytes;
      var w = page.width, h = page.height;
      if (mode != DocxMode.textOnly) {
        final file = await _files.fileFor(page.processedFile);
        if (await file.exists()) {
          bytes = await ImagePipeline.recompress(
            await file.readAsBytes(),
            maxSide: quality.maxSide,
            quality: quality.jpegQuality,
          );
          if (w > 0 && h > 0) {
            final longest = w > h ? w : h;
            if (longest > quality.maxSide) {
              final s = quality.maxSide / longest;
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
    }

    final bytes = DocxBuilder.build(
      pages: inputs,
      title: doc.document.title,
      mode: mode,
    );
    final out = File(p.join((await _files.exportsDir).path,
        safeName(doc.document.title, 'docx')));
    await out.parent.create(recursive: true);
    await out.writeAsBytes(bytes, flush: true);
    return ExportResult(out, ExportFormat.docx);
  }

  // ------------------------------------------------------------------ TEXTO

  Future<ExportResult> toText(DocumentWithPages doc) async {
    final buf = StringBuffer('${doc.document.title}\n\n');
    for (var i = 0; i < doc.pages.length; i++) {
      final t = doc.pages[i].ocrText ?? '';
      if (t.trim().isEmpty) continue;
      if (doc.pages.length > 1) buf.writeln('--- Pagina ${i + 1} ---');
      buf.writeln(t.trim());
      buf.writeln();
    }
    final out = File(p.join((await _files.exportsDir).path,
        safeName(doc.document.title, 'txt')));
    await out.parent.create(recursive: true);
    await out.writeAsString(buf.toString(), flush: true);
    return ExportResult(out, ExportFormat.text);
  }

  // --------------------------------------------------------------- IMAGENES

  /// Copia las paginas como JPEG sueltos a la carpeta de exportacion.
  Future<List<File>> toImages(DocumentWithPages doc) async {
    final dir = Directory(p.join((await _files.exportsDir).path,
        safeName(doc.document.title, 'imgs').replaceAll('.imgs', '')));
    await dir.create(recursive: true);
    final out = <File>[];
    for (var i = 0; i < doc.pages.length; i++) {
      final src = await _files.fileFor(doc.pages[i].processedFile);
      if (!await src.exists()) continue;
      final index = '${i + 1}'.padLeft(3, '0');
      final dst = File(p.join(dir.path, '$index.jpg'));
      await src.copy(dst.path);
      out.add(dst);
    }
    return out;
  }
}
