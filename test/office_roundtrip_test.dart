import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/data/db/app_database.dart';
import 'package:manticora/data/repositories/document_repository.dart';
import 'package:manticora/data/repositories/storage_service.dart';
import 'package:manticora/export/docx_builder.dart';
import 'package:manticora/export/export_service.dart';
import 'package:manticora/export/pdf_builder.dart';
import 'package:manticora/features/media/media_source.dart';
import 'package:manticora/import/source_document.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'support/corpus.dart';

/// Ida y vuelta entre lo que la aplicacion escribe y lo que sabe leer.
///
/// Es la prueba mas parecida a lo que hace una persona de verdad: exporta un
/// escaneo a Word, cierra, y mas tarde vuelve a abrir ese mismo fichero para
/// convertirlo en audio. Si el lector y el escritor se desentienden, aqui se
/// nota; con ficheros de juguete, no.
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
    temp = await Directory.systemTemp.createTemp('manticora_round_');
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

  Future<String> documentoConTexto(
    List<String> paginas, {
    String title = 'Documento de prueba',
    String foto = 'instrucciones.jpg',
  }) async {
    final raw = await File('${Corpus.directory}/$foto').readAsBytes();
    final doc = await repo.createDocument(title: title);
    for (final texto in paginas) {
      final page = await repo.addPage(
        documentId: doc.id,
        originalJpeg: raw,
        processedJpeg: raw,
        thumbnailJpeg: raw,
        width: 1000,
        height: 1400,
      );
      await repo.setOcrText(page.id, doc.id, texto);
    }
    return doc.id;
  }

  group('El Word que exporta la app lo vuelve a leer la propia app', () {
    test(
      'texto e imagenes: el .docx exportado se relee con todas sus paginas',
      () async {
        final id = await documentoConTexto([
          'Primera pagina del expediente municipal.',
          'Segunda pagina con el resumen de gastos.',
        ], title: 'Expediente municipal');
        final doc = (await repo.getDocument(id))!;

        final exportado = await ExportService.instance.toDocx(doc);
        final bytes = await exportado.file.readAsBytes();

        // Lo importante: el lector de importacion reconoce lo que escribio el
        // exportador, sin fiarse de la extension.
        expect(
          SourceDocumentReader.detectType(bytes, fileName: exportado.name),
          SourceDocumentType.word,
        );

        final leido = SourceDocumentReader.read(bytes, fileName: exportado.name);
        expect(leido.pages, hasLength(2));
        expect(leido.pages.first.text, contains('expediente municipal'));
        expect(leido.pages.last.text, contains('resumen de gastos'));
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );

    test(
      'ese mismo .docx se convierte en paginas narrables sin tocar disco',
      () async {
        final id = await documentoConTexto([
          'El acta recoge los acuerdos de la sesion ordinaria.',
        ], title: 'Acta de la sesion');
        final doc = (await repo.getDocument(id))!;

        final exportado = await ExportService.instance.toDocx(doc);
        final contenido = await MediaSourceLoader.fromBytes(
          await exportado.file.readAsBytes(),
          fileName: exportado.name,
          needImages: false,
        );
        addTearDown(contenido.dispose);

        expect(contenido.kind, MediaSourceKind.word);
        expect(contenido.hasText, isTrue);
        expect(contenido.pages.first.text, contains('acuerdos de la sesion'));
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );

    test(
      'el Word de solo imagenes se reconoce como Word aunque no tenga texto',
      () async {
        final id = await documentoConTexto(['texto que no se exporta']);
        final doc = (await repo.getDocument(id))!;

        final exportado = await ExportService.instance.toDocx(
          doc,
          mode: DocxMode.imagesOnly,
        );
        final bytes = await exportado.file.readAsBytes();

        expect(
          SourceDocumentReader.detectType(bytes, fileName: 'x.bin'),
          SourceDocumentType.word,
        );
        final leido = SourceDocumentReader.read(bytes, fileName: exportado.name);
        expect(leido.text.trim(), isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );
  });

  group('El PDF que exporta la app se puede volver a convertir', () {
    test(
      'un PDF buscable exportado vuelve a entrar como origen de audio',
      () async {
        final id = await documentoConTexto([
          'Instrucciones de uso del aparato y garantia de dos anos.',
        ], title: 'Manual de instrucciones');
        final doc = (await repo.getDocument(id))!;

        final pdf = await ExportService.instance.toPdf(
          doc,
          quality: PdfQuality.low,
        );
        final bytes = await pdf.file.readAsBytes();

        expect(
          SourceDocumentReader.detectType(bytes, fileName: pdf.name),
          SourceDocumentType.pdf,
        );

        // Sin imagenes no hace falta rasterizar (eso pide motor nativo), pero
        // el texto del PDF si se lee y es el que se narraria.
        final contenido = await MediaSourceLoader.fromBytes(
          bytes,
          fileName: pdf.name,
          needImages: false,
        );
        addTearDown(contenido.dispose);

        expect(contenido.kind, MediaSourceKind.pdf);
        expect(contenido.pageCount, 1);
        expect(
          contenido.pages.single.text.replaceAll(RegExp(r'\s+'), ' '),
          contains('garantia de dos anos'),
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );

    test(
      'el lector de Office no se traga un PDF: manda a las herramientas PDF',
      () async {
        final id = await documentoConTexto(['una pagina cualquiera']);
        final doc = (await repo.getDocument(id))!;
        final pdf = await ExportService.instance.toPdf(doc, quality: PdfQuality.low);
        final bytes = await pdf.file.readAsBytes();

        expect(
          () => SourceDocumentReader.read(bytes, fileName: pdf.name),
          throwsA(predicate(
            (e) => '$e'.contains('herramientas PDF'),
            'explica que use las herramientas PDF',
          )),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: Corpus.isAvailable ? false : Corpus.missingReason,
    );
  });

  group('Ficheros hostiles y casos raros', () {
    test('un ZIP con un nombre de fichero que se sale de la carpeta se rechaza', () {
      // Un "zip slip": el nombre de la parte apunta fuera del paquete.
      final bytes = _zipCrudo({'../../fuera.xml': 'contenido'});
      expect(
        () => SourceDocumentReader.detectType(bytes, fileName: 'malo.docx'),
        throwsA(anything),
      );
    });

    test('un fichero que solo tiene la extension no engana al lector', () {
      final bytes = Uint8List.fromList('esto no es un docx'.codeUnits);
      expect(
        SourceDocumentReader.detectType(bytes, fileName: 'trampa.docx'),
        SourceDocumentType.unknown,
      );
    });

    test('un PDF vacio o truncado da un fallo entendible, no un cuelgue', () {
      final truncado = Uint8List.fromList('%PDF-1.7\n%%EOF'.codeUnits);
      expect(
        SourceDocumentReader.detectType(truncado, fileName: 'roto.pdf'),
        SourceDocumentType.pdf,
        reason: 'la firma es de PDF; el fallo debe darlo el lector de PDF',
      );
    });
  });
}

Uint8List _zipCrudo(Map<String, String> files) {
  // Un ZIP minimo escrito a mano para poder colar un nombre ilegal que las
  // librerias de empaquetado normales no dejarian escribir.
  final salida = <int>[];
  final central = <int>[];
  var offset = 0;

  void write16(List<int> out, int v) => out.addAll([v & 0xFF, (v >> 8) & 0xFF]);
  void write32(List<int> out, int v) => out.addAll([
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ]);

  files.forEach((name, content) {
    final nameBytes = name.codeUnits;
    final data = content.codeUnits;
    final local = <int>[];
    write32(local, 0x04034b50);
    write16(local, 20);
    write16(local, 0);
    write16(local, 0); // sin compresion
    write16(local, 0);
    write16(local, 0);
    write32(local, 0); // crc sin calcular: el lector debe rechazarlo antes
    write32(local, data.length);
    write32(local, data.length);
    write16(local, nameBytes.length);
    write16(local, 0);
    local
      ..addAll(nameBytes)
      ..addAll(data);

    write32(central, 0x02014b50);
    write16(central, 20);
    write16(central, 20);
    write16(central, 0);
    write16(central, 0);
    write16(central, 0);
    write16(central, 0);
    write32(central, 0);
    write32(central, data.length);
    write32(central, data.length);
    write16(central, nameBytes.length);
    write16(central, 0);
    write16(central, 0);
    write16(central, 0);
    write16(central, 0);
    write32(central, 0);
    write32(central, offset);
    central.addAll(nameBytes);

    salida.addAll(local);
    offset += local.length;
  });

  final centralOffset = salida.length;
  salida.addAll(central);
  final fin = <int>[];
  write32(fin, 0x06054b50);
  write16(fin, 0);
  write16(fin, 0);
  write16(fin, files.length);
  write16(fin, files.length);
  write32(fin, central.length);
  write32(fin, centralOffset);
  write16(fin, 0);
  salida.addAll(fin);

  return Uint8List.fromList(salida);
}
