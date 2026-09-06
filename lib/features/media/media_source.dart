import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/error_orchestrator.dart';
import '../../core/failure.dart';
import '../../core/logger.dart';
import '../../data/models/models.dart';
import '../../data/repositories/document_repository.dart';
import '../../data/repositories/storage_service.dart';
import '../../export/media_export_service.dart';
import '../../export/pdf_tools.dart';
import '../../imaging/ocr_service.dart';
import '../../import/source_document.dart';
import 'slide_image.dart';

/// De donde sale el contenido que se va a convertir en audio o video.
enum MediaSourceKind { scan, pdf, word, presentation }

extension MediaSourceKindLabel on MediaSourceKind {
  String get label => switch (this) {
        MediaSourceKind.scan => 'Documento escaneado',
        MediaSourceKind.pdf => 'PDF',
        MediaSourceKind.word => 'Word',
        MediaSourceKind.presentation => 'Diapositivas',
      };
}

/// Paginas ya listas para [MediaExportService], con sus imagenes en disco.
///
/// Las laminas generadas para Word y PowerPoint son temporales: quien pide el
/// contenido debe llamar a [dispose] cuando termine la exportacion.
class MediaSourceContent {
  final String title;
  final MediaSourceKind kind;
  final List<MediaPageInput> pages;
  final Directory? workDir;

  const MediaSourceContent({
    required this.title,
    required this.kind,
    required this.pages,
    this.workDir,
  });

  int get pageCount => pages.length;
  int get pagesWithText =>
      pages.where((page) => page.text.trim().isNotEmpty).length;
  bool get hasImages => pages.every((page) => page.imageFile != null);
  bool get hasText => pagesWithText > 0;

  Future<void> dispose() async {
    final dir = workDir;
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      Log.w('Multimedia', 'No se pudo retirar el material temporal', e);
    }
  }
}

/// Convierte cualquier origen admitido en paginas con texto e imagen.
abstract final class MediaSourceLoader {
  static const _tag = 'Multimedia';

  /// Extensiones que se ofrecen en el selector de ficheros.
  static const List<String> pickableExtensions = ['pdf', 'docx', 'pptx'];

  /// Texto que se narra de una pagina: el titulo solo se lee si aporta algo.
  ///
  /// Repetir el titulo cuando ya encabeza el cuerpo suena a tartamudeo, y una
  /// pagina vacia con titulo si merece leerse para que el oyente sepa por donde
  /// va la presentacion.
  static String narrationFor({required String title, required String body}) {
    final cleanTitle = title.trim();
    final cleanBody = body.trim();
    if (cleanTitle.isEmpty) return cleanBody;
    if (cleanBody.isEmpty) return cleanTitle;
    final start = cleanBody.length <= cleanTitle.length
        ? cleanBody
        : cleanBody.substring(0, cleanTitle.length);
    if (start.toLowerCase() == cleanTitle.toLowerCase()) return cleanBody;
    return '$cleanTitle.\n$cleanBody';
  }

  // ------------------------------------------------------- documento escaneado

  /// Paginas de un documento de la biblioteca.
  ///
  /// Con [runOcrIfMissing] se reconoce el texto que falte y se guarda, para que
  /// la proxima conversion sea inmediata y la busqueda tambien lo encuentre.
  static Future<MediaSourceContent> fromScannedDocument(
    DocumentWithPages doc, {
    required DocumentRepository repository,
    bool runOcrIfMissing = true,
    void Function(String message)? onProgress,
  }) async {
    if (doc.pages.isEmpty) {
      throw const AppFailure.validation('Este documento no tiene paginas.');
    }

    final pages = <MediaPageInput>[];
    for (var i = 0; i < doc.pages.length; i++) {
      var page = doc.pages[i];
      final image = await repository.pageFile(page);

      if (!page.hasOcr && runOcrIfMissing && await image.exists()) {
        onProgress?.call('Leyendo la pagina ${i + 1} de ${doc.pages.length}...');
        final text = await _recognize(image);
        if (text != null && text.text.trim().isNotEmpty) {
          await ErrorOrchestrator.guard(
            'Guardando el texto reconocido',
            () => repository.setOcrText(
              page.id,
              page.documentId,
              text.text,
              boxesJson: text.boxesJson,
            ),
            tag: _tag,
            notifyUser: false,
          );
          page = page.copyWith(ocrText: text.text);
        }
      }

      pages.add(MediaPageInput(
        title: '',
        text: page.ocrText ?? '',
        imageFile: await image.exists() ? image : null,
      ));
    }

    return MediaSourceContent(
      title: doc.document.title,
      kind: MediaSourceKind.scan,
      pages: pages,
    );
  }

  // ------------------------------------------------------------ fichero suelto

  /// Lee un PDF, un DOCX o un PPTX elegido por la persona.
  ///
  /// Se trabaja con los bytes y no con la ruta porque el selector de Android
  /// entrega contenido de otras aplicaciones que no siempre tiene fichero
  /// propio. El tipo se decide por el contenido, no por la extension: un `.pdf`
  /// que en realidad es un PPTX se trata como lo que es.
  static Future<MediaSourceContent> fromBytes(
    Uint8List bytes, {
    required String fileName,
    required bool needImages,
    void Function(String message)? onProgress,
  }) async {
    if (bytes.isEmpty) {
      throw const AppFailure.validation('El archivo esta vacio.');
    }
    final name = p.basename(fileName);

    final type = SourceDocumentReader.detectType(bytes, fileName: name);
    return switch (type) {
      SourceDocumentType.pdf => _fromPdf(
          bytes,
          name,
          needImages: needImages,
          onProgress: onProgress,
        ),
      SourceDocumentType.word || SourceDocumentType.presentation => _fromOffice(
          bytes,
          name,
          needImages: needImages,
          onProgress: onProgress,
        ),
      SourceDocumentType.unknown => throw const AppFailure(
          kind: FailureKind.document,
          message: 'Solo se pueden convertir PDF, Word (.docx) y '
              'PowerPoint (.pptx).',
          retryable: false,
        ),
    };
  }

  static Future<MediaSourceContent> _fromPdf(
    Uint8List bytes,
    String fileName, {
    required bool needImages,
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('Leyendo el PDF...');
    final extracted = PdfTools.extractText(bytes)
        .map(PdfTools.normalizeExtractedText)
        .toList();

    List<File> images = const [];
    Directory? work;
    if (needImages) {
      work = await _newWorkDirectory();
      onProgress?.call('Preparando las paginas...');
      final rasters = await PdfTools.rasterize(
        bytes,
        onPage: (done) => onProgress?.call('Pagina $done del PDF...'),
      );
      images = await _writeAll(
        work,
        [for (final raster in rasters) raster.jpeg],
        extension: 'jpg',
      );
    }

    // Un PDF escaneado no tiene texto que extraer: si ya se han rasterizado
    // las paginas para el video, se aprovechan para reconocerlo.
    final total = extracted.fold(0, (sum, text) => sum + text.trim().length);
    if (total < 16 && images.isNotEmpty) {
      for (var i = 0; i < images.length; i++) {
        onProgress?.call('Reconociendo el texto ${i + 1} de ${images.length}...');
        final result = await _recognize(images[i]);
        if (result == null) break;
        while (extracted.length <= i) {
          extracted.add('');
        }
        extracted[i] = result.text;
      }
    }

    final count = needImages ? images.length : extracted.length;
    if (count == 0) {
      throw const AppFailure(
        kind: FailureKind.pdf,
        message: 'No se ha podido leer ninguna pagina de ese PDF.',
        retryable: false,
      );
    }

    return MediaSourceContent(
      title: p.basenameWithoutExtension(fileName),
      kind: MediaSourceKind.pdf,
      workDir: work,
      pages: [
        for (var i = 0; i < count; i++)
          MediaPageInput(
            text: i < extracted.length ? extracted[i] : '',
            imageFile: i < images.length ? images[i] : null,
          ),
      ],
    );
  }

  static Future<MediaSourceContent> _fromOffice(
    Uint8List bytes,
    String fileName, {
    required bool needImages,
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('Leyendo el documento...');
    final document = SourceDocumentReader.read(bytes, fileName: fileName);
    if (document.pages.isEmpty) {
      throw const AppFailure(
        kind: FailureKind.document,
        message: 'Ese documento no tiene contenido que convertir.',
        retryable: false,
      );
    }

    Directory? work;
    final images = <File>[];
    if (needImages) {
      work = await _newWorkDirectory();
      for (var i = 0; i < document.pages.length; i++) {
        final page = document.pages[i];
        onProgress?.call(
          'Componiendo la lamina ${i + 1} de ${document.pages.length}...',
        );
        final png = await SlideImage.render(
          title: page.title,
          body: page.text,
          number: page.number,
          total: document.pages.length,
        );
        final file = File(
          p.join(work.path, 'lamina-${i.toString().padLeft(3, '0')}.png'),
        );
        await file.writeAsBytes(png, flush: true);
        images.add(file);
      }
    }

    return MediaSourceContent(
      title: document.title,
      kind: document.type == SourceDocumentType.presentation
          ? MediaSourceKind.presentation
          : MediaSourceKind.word,
      workDir: work,
      pages: [
        for (var i = 0; i < document.pages.length; i++)
          MediaPageInput(
            title: document.pages[i].title,
            text: narrationFor(
              title: document.pages[i].title,
              body: document.pages[i].text,
            ),
            imageFile: i < images.length ? images[i] : null,
          ),
      ],
    );
  }

  // ------------------------------------------------------------------ apoyos

  static Future<OcrResult?> _recognize(File image) => ErrorOrchestrator.guard(
        'Reconociendo el texto',
        () => OcrService.instance.recognizeFile(image.path),
        tag: _tag,
        notifyUser: false,
      );

  static Future<Directory> _newWorkDirectory() async {
    final base = await StorageService.instance.tmpDir;
    final dir = Directory(p.join(base.path, 'origen-${const Uuid().v4()}'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<List<File>> _writeAll(
    Directory dir,
    List<Uint8List> pages, {
    required String extension,
  }) async {
    final files = <File>[];
    for (var i = 0; i < pages.length; i++) {
      final file = File(
        p.join(dir.path, 'pagina-${i.toString().padLeft(3, '0')}.$extension'),
      );
      await file.writeAsBytes(pages[i], flush: true);
      files.add(file);
    }
    return files;
  }
}
