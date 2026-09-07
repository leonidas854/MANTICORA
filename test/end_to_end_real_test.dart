import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/data/db/app_database.dart';
import 'package:manticora/data/repositories/document_repository.dart';
import 'package:manticora/data/repositories/storage_service.dart';
import 'package:manticora/export/export_service.dart';
import 'package:manticora/export/docx_builder.dart';
import 'package:manticora/export/pdf_builder.dart';
import 'package:manticora/export/pdf_tools.dart';
import 'package:manticora/features/scan/scan_screen.dart';
import 'package:manticora/imaging/filters.dart';
import 'package:manticora/imaging/ocr_service.dart';
import 'package:manticora/imaging/pipeline.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'support/corpus.dart';

/// Recorrido completo con **fotos reales** de documentos: la misma cadena que
/// recorre una persona al escanear, desde el JPEG que sale de la camara hasta
/// el PDF, el Word, el texto y las imagenes que comparte.
///
/// El OCR no se puede ejecutar aqui (ML Kit solo existe en el movil y este
/// equipo no tiene Tesseract), asi que el texto reconocido se inyecta con
/// cajas creidbles sobre la foto real: lo que se comprueba es que ese texto
/// sobrevive intacto hasta el PDF buscable, el Word y el texto plano.
class _TempPathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _TempPathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late DocumentRepository repo;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('manticora_e2e_');
    PathProviderPlatform.instance = _TempPathProvider(temp.path);
    await AppDatabase.instance.resetForTesting();
    StorageService.instance.resetForTesting();
    repo = DocumentRepository.instance;
  });

  tearDown(() async {
    await AppDatabase.instance.resetForTesting();
    StorageService.instance.resetForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// Escanea una foto real tal y como lo hace la aplicacion y la guarda.
  Future<({String docId, int width, int height})> scanRealPhoto(
    String fileName, {
    ScanFilter filter = ScanFilter.magic,
    String? title,
    String? ocrText,
    bool keepOriginal = true,
    String? appendTo,
  }) async {
    final raw = await File('${Corpus.directory}/$fileName').readAsBytes();

    final normalized = await ImagePipeline.normalizeWithSize(raw);
    expect(normalized, isNotNull, reason: 'la foto real debe poder normalizarse');

    final detected = await ImagePipeline.detectInJpeg(normalized!.jpeg);
    final quad = initialDocumentQuad(
      detected,
      width: normalized.width.toDouble(),
      height: normalized.height.toDouble(),
    );

    final processed = await ImagePipeline.processPage(
      sourceJpeg: normalized.jpeg,
      quad: quad,
      filter: filter,
      adjustments: Adjustments.none,
      rotationQuarterTurns: 0,
    );

    final docId = appendTo ?? (await repo.createDocument(title: title)).id;
    final page = await repo.addPage(
      documentId: docId,
      originalJpeg: normalized.jpeg,
      processedJpeg: processed.jpeg,
      thumbnailJpeg: processed.thumbnail,
      quad: quad,
      filter: filter,
      width: processed.width,
      height: processed.height,
      keepOriginal: keepOriginal,
    );

    if (ocrText != null) {
      await repo.setOcrText(
        page.id,
        docId,
        ocrText,
        boxesJson: _boxesFor(ocrText, processed.width, processed.height),
      );
    }

    return (docId: docId, width: processed.width, height: processed.height);
  }

  group('Escaneo real de principio a fin', () {
    for (final name in Corpus.expected.keys) {
      test(
        '$name: se captura, se procesa y se guarda con imagen valida',
        () async {
          final scan = await scanRealPhoto(name, title: 'Prueba $name');
          final doc = await repo.getDocument(scan.docId);

          expect(doc, isNotNull);
          expect(doc!.pages, hasLength(1));
          final page = doc.pages.single;

          expect(page.width, greaterThan(200));
          expect(page.height, greaterThan(200));

          final processed = await repo.pageFile(page);
          final thumb = await repo.thumbFile(page);
          final original = await repo.absoluteFile(page.originalFile);
          for (final file in [processed, thumb, original]) {
            expect(await file.exists(), isTrue);
            final bytes = await file.readAsBytes();
            expect(_isJpeg(bytes), isTrue, reason: '${file.path} debe ser JPEG');
          }

          // La miniatura tiene que ser mucho mas ligera que la pagina: es lo
          // que hace que la biblioteca no se atragante con cien documentos.
          expect(await thumb.length(), lessThan(await processed.length()));

          final size = await ImagePipeline.readSize(await processed.readAsBytes());
          expect(size, isNotNull);
          expect(size!.width, page.width);
          expect(size.height, page.height);
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: Corpus.isAvailable ? false : Corpus.missingReason,
      );
    }

    test(
      'el PDF de una foto real conserva el texto reconocido y se puede volver a leer',
      () async {
        const texto = 'Manticora reconocio esta linea del documento original';
        final scan = await scanRealPhoto(
          'instrucciones.jpg',
          title: 'Instrucciones escaneadas',
          ocrText: texto,
        );
        final doc = (await repo.getDocument(scan.docId))!;

        final result = await ExportService.instance.toPdf(
          doc,
          pageSize: PdfPageSize.a4,
          quality: PdfQuality.medium,
        );

        expect(await result.file.exists(), isTrue);
        expect(result.skippedPages, isEmpty);
        final bytes = await result.file.readAsBytes();
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(PdfTools.pageCount(bytes), 1);

        // Round trip de verdad: lo escribe el generador de PDF y lo vuelve a
        // leer el extractor de Syncfusion, que es lo que usaria un buscador.
        //
        // El extractor devuelve cada fragmento de texto en su propia linea
        // (asi coloca las palabras el generador de PDF, como cualquier PDF con
        // OCR), por eso se compara sobre el texto con los espacios unificados.
        final extraido = _plano(PdfTools.extractText(bytes).join(' '));
        expect(extraido, contains('Manticora reconocio esta linea'));
        expect(extraido, contains('del documento original'));
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );

    test(
      'sin capa de texto el PDF sale igual de valido pero sin nada que buscar',
      () async {
        final scan = await scanRealPhoto(
          'factura-sichuan.jpg',
          title: 'Factura sin texto',
          ocrText: 'texto que no debe acabar en el PDF',
        );
        final doc = (await repo.getDocument(scan.docId))!;

        final result = await ExportService.instance.toPdf(
          doc,
          searchableText: false,
          quality: PdfQuality.low,
        );
        final bytes = await result.file.readAsBytes();

        expect(PdfTools.pageCount(bytes), 1);
        expect(
          PdfTools.extractText(bytes).join(' '),
          isNot(contains('no debe acabar')),
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );

    test(
      'un documento de varias fotos reales sale con una pagina por foto',
      () async {
        final fotos = Corpus.available();
        var docId = '';
        for (var i = 0; i < fotos.length; i++) {
          final scan = await scanRealPhoto(
            fotos[i],
            title: 'Expediente completo',
            appendTo: i == 0 ? null : docId,
            ocrText: 'Pagina numero ${i + 1} del expediente',
            filter: i.isEven ? ScanFilter.magic : ScanFilter.grayscale,
          );
          docId = scan.docId;
        }

        final doc = (await repo.getDocument(docId))!;
        expect(doc.pages, hasLength(fotos.length));
        expect(doc.pages.map((p) => p.position), List.generate(fotos.length, (i) => i));

        final pdf = await ExportService.instance.toPdf(doc, quality: PdfQuality.low);
        final bytes = await pdf.file.readAsBytes();
        expect(PdfTools.pageCount(bytes), fotos.length);

        final texto = PdfTools.extractText(bytes);
        expect(texto, hasLength(fotos.length));
        for (var i = 0; i < fotos.length; i++) {
          expect(_plano(texto[i]), contains('Pagina numero ${i + 1}'));
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );

    test(
      'el texto en espanol real sobrevive al PDF: tildes, enyes y comillas',
      () async {
        const texto = 'Señor Muñoz: la reunión del 5 de marzo — con el '
            '“presupuesto” anual — quedó aplazada. Coste: 1.250 € más IVA…';
        final scan = await scanRealPhoto(
          'instrucciones.jpg',
          title: 'Acta con acentos',
          ocrText: texto,
        );
        final doc = (await repo.getDocument(scan.docId))!;

        final result = await ExportService.instance.toPdf(doc);
        final extraido = _plano(
          PdfTools.extractText(await result.file.readAsBytes()).join(' '),
        );

        // Las tildes y la enye estan en Latin-1: deben salir intactas.
        expect(extraido, contains('Señor Muñoz'));
        expect(extraido, contains('reunión'));
        expect(extraido, contains('quedó aplazada'));

        // Los signos tipograficos se cambian por su equivalente de siempre en
        // vez de convertirse en interrogantes que romperian la busqueda.
        expect(extraido, contains('"presupuesto"'));
        expect(extraido, contains('1.250 EUR'));
        expect(extraido, isNot(contains('?')));

        // Y el texto guardado en la base sigue siendo el original, con sus
        // comillas curvas: la adaptacion es solo para el PDF.
        expect(doc.pages.single.ocrText, texto);
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );

    test(
      'el Word de una foto real lleva dentro la imagen y el texto',
      () async {
        const texto = 'Tabla de existencias del almacen central';
        final scan = await scanRealPhoto(
          'tabla-sharon-1854.jpg',
          title: 'Tabla historica',
          ocrText: texto,
        );
        final doc = (await repo.getDocument(scan.docId))!;

        final result = await ExportService.instance.toDocx(doc);
        final bytes = await result.file.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        final nombres = archive.files.map((f) => f.name).toSet();

        expect(nombres, contains('[Content_Types].xml'));
        expect(nombres, contains('word/document.xml'));
        expect(
          nombres.any((n) => n.startsWith('word/media/')),
          isTrue,
          reason: 'la foto real debe viajar dentro del .docx',
        );

        final documento = utf8.decode(
          archive.files.firstWhere((f) => f.name == 'word/document.xml').content
              as List<int>,
        );
        expect(documento, contains('Tabla de existencias'));

        final media = archive.files.firstWhere(
          (f) => f.name.startsWith('word/media/'),
        );
        expect(
          _isJpeg(Uint8List.fromList(media.content as List<int>)),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );

    test(
      'el Word de solo imagenes no filtra el texto reconocido',
      () async {
        final scan = await scanRealPhoto(
          'factura-1849.jpg',
          title: 'Solo imagen',
          ocrText: 'texto confidencial del expediente',
        );
        final doc = (await repo.getDocument(scan.docId))!;

        final result = await ExportService.instance.toDocx(
          doc,
          mode: DocxMode.imagesOnly,
        );
        final archive = ZipDecoder().decodeBytes(await result.file.readAsBytes());
        final documento = utf8.decode(
          archive.files.firstWhere((f) => f.name == 'word/document.xml').content
              as List<int>,
        );
        expect(documento, isNot(contains('confidencial')));
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );

    test(
      'el texto plano y las imagenes sueltas salen listos para compartir',
      () async {
        final scan = await scanRealPhoto(
          'instrucciones.jpg',
          title: 'Instrucciones de montaje',
          ocrText: 'Paso uno: apretar los tornillos',
        );
        final doc = (await repo.getDocument(scan.docId))!;

        final texto = await ExportService.instance.toText(doc);
        expect(await texto.file.readAsString(), contains('apretar los tornillos'));

        final imagenes = await ExportService.instance.toImages(doc);
        expect(imagenes, hasLength(1));
        expect(_isJpeg(await imagenes.single.readAsBytes()), isTrue);
        expect(await imagenes.single.length(), greaterThan(1024));
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );

    test(
      'la busqueda encuentra el documento por el texto de la foto',
      () async {
        await scanRealPhoto(
          'instrucciones.jpg',
          title: 'Manual de la lavadora',
          ocrText: 'programa de centrifugado y aclarado',
        );
        await scanRealPhoto(
          'factura-sichuan.jpg',
          title: 'Factura del restaurante',
          ocrText: 'arroz frito y te de jazmin',
        );

        final porTexto = await repo.listDocuments(query: 'centrifugado');
        expect(porTexto, hasLength(1));
        expect(porTexto.single.title, 'Manual de la lavadora');

        final porTitulo = await repo.listDocuments(query: 'restaurante');
        expect(porTitulo, hasLength(1));

        expect(await repo.listDocuments(query: 'inexistente'), isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );
  });

  group('Herramientas PDF sobre un PDF hecho con fotos reales', () {
    late Uint8List pdfReal;

    setUp(() async {
      if (!Corpus.isAvailable) return;
      final fotos = Corpus.available();
      var docId = '';
      for (var i = 0; i < fotos.length; i++) {
        final scan = await scanRealPhoto(
          fotos[i],
          title: 'Origen',
          appendTo: i == 0 ? null : docId,
          ocrText: 'Hoja ${i + 1}',
        );
        docId = scan.docId;
      }
      final doc = (await repo.getDocument(docId))!;
      final result = await ExportService.instance.toPdf(doc, quality: PdfQuality.low);
      pdfReal = await result.file.readAsBytes();
    });

    test(
      'unir, extraer, girar y proteger un escaneo real conserva su contenido',
      () async {
        final paginas = PdfTools.pageCount(pdfReal);
        expect(paginas, greaterThan(1));

        final unido = await PdfTools.merge([pdfReal, pdfReal]);
        expect(PdfTools.pageCount(unido), paginas * 2);

        final extraido = await PdfTools.extractPages(unido, [0, 1]);
        expect(PdfTools.pageCount(extraido), 2);
        expect(_plano(PdfTools.extractText(extraido).join(' ')), contains('Hoja 1'));

        final girado = await PdfTools.rotatePages(extraido, const {}, 1);
        expect(PdfTools.pageCount(girado), 2);

        final protegido = await PdfTools.protect(
          girado,
          userPassword: 'clave-larga-123',
        );
        expect(PdfTools.needsPassword(protegido), isTrue);
        expect(
          _plano(PdfTools.extractText(protegido, password: 'clave-larga-123')
              .join(' ')),
          contains('Hoja'),
        );

        final abierto = await PdfTools.removeProtection(protegido, 'clave-larga-123');
        expect(PdfTools.needsPassword(abierto), isFalse);
        expect(PdfTools.pageCount(abierto), 2);
      },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );

    test(
      'dividir un escaneo real reparte todas las paginas sin perder ninguna',
      () async {
        final paginas = PdfTools.pageCount(pdfReal);
        final partes = await PdfTools.splitEvery(pdfReal, 1);

        expect(partes, hasLength(paginas));
        for (final parte in partes) {
          expect(PdfTools.pageCount(parte), 1);
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );
  });
}

/// Texto con los saltos y espacios unificados, como lo lee una persona.
String _plano(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

bool _isJpeg(Uint8List bytes) =>
    bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;

/// Cajas plausibles para el texto dado, repartidas por la pagina real.
String _boxesFor(String text, int width, int height) {
  final lineas = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
  final alto = height / (lineas.length + 2);
  return OcrResult(
    text,
    [
      for (var i = 0; i < lineas.length; i++)
        OcrLine(
          lineas[i],
          width * 0.08,
          alto * (i + 1),
          width * 0.84,
          alto * 0.7,
        ),
    ],
  ).boxesJson;
}
