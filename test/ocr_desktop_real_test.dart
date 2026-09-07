import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/data/db/app_database.dart';
import 'package:manticora/data/repositories/document_repository.dart';
import 'package:manticora/data/repositories/storage_service.dart';
import 'package:manticora/export/export_service.dart';
import 'package:manticora/export/pdf_builder.dart';
import 'package:manticora/export/pdf_tools.dart';
import 'package:manticora/features/media/media_source.dart';
import 'package:manticora/imaging/desktop_ocr.dart';
import 'package:manticora/imaging/filters.dart';
import 'package:manticora/imaging/pipeline.dart';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'support/corpus.dart';

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

/// OCR de escritorio ejecutado de verdad sobre las fotos reales del corpus.
///
/// Necesita Tesseract instalado en el sistema; si no esta, las pruebas se
/// saltan diciendo como instalarlo, igual que hace la propia aplicacion.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final motivo = _motivoParaSaltar();

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('manticora_ocr_');
    PathProviderPlatform.instance = _TempPathProvider(temp.path);
    await AppDatabase.instance.resetForTesting();
    StorageService.instance.resetForTesting();
  });

  tearDown(() async {
    await AppDatabase.instance.resetForTesting();
    StorageService.instance.resetForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// Prepara la foto igual que la aplicacion antes de reconocerla.
  Future<File> paginaProcesada(String name, {ScanFilter filter = ScanFilter.magic}) async {
    final raw = await File('${Corpus.directory}/$name').readAsBytes();
    final normalizada = await ImagePipeline.normalizeWithSize(raw);
    final quad = await ImagePipeline.detectInJpeg(normalizada!.jpeg);
    final procesada = await ImagePipeline.processPage(
      sourceJpeg: normalizada.jpeg,
      quad: quad,
      filter: filter,
      adjustments: Adjustments.none,
      rotationQuarterTurns: 0,
    );
    final file = File('${temp.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(procesada.jpeg, flush: true);
    return file;
  }

  group('De la foto al PDF buscable sin inventar nada', () {
    test(
      'lo que reconoce el OCR de la foto real se puede volver a buscar en el PDF',
      () async {
        final raw = await File('${Corpus.directory}/instrucciones.jpg').readAsBytes();
        final normalizada = await ImagePipeline.normalizeWithSize(raw);
        final procesada = await ImagePipeline.processPage(
          sourceJpeg: normalizada!.jpeg,
          quad: await ImagePipeline.detectInJpeg(normalizada.jpeg),
          filter: ScanFilter.magic,
          adjustments: Adjustments.none,
          rotationQuarterTurns: 0,
        );

        // 1. Se guarda la pagina como haria la aplicacion.
        final repo = DocumentRepository.instance;
        final doc = await repo.createDocument(title: 'Instrucciones reales');
        final page = await repo.addPage(
          documentId: doc.id,
          originalJpeg: normalizada.jpeg,
          processedJpeg: procesada.jpeg,
          thumbnailJpeg: procesada.thumbnail,
          width: procesada.width,
          height: procesada.height,
        );

        // 2. OCR de verdad sobre la imagen ya procesada, sin texto inventado.
        final archivo = await repo.pageFile(page);
        final ocr = await DesktopOcr.recognizeFile(archivo.path);
        expect(ocr.isEmpty, isFalse);
        await repo.setOcrText(page.id, doc.id, ocr.text, boxesJson: ocr.boxesJson);

        // 3. PDF buscable con esas cajas reales.
        final completo = (await repo.getDocument(doc.id))!;
        final pdf = await ExportService.instance.toPdf(
          completo,
          quality: PdfQuality.medium,
        );
        final extraido = PdfTools.extractText(await pdf.file.readAsBytes())
            .join(' ')
            .replaceAll(RegExp(r'\s+'), ' ');

        // 4. Las palabras largas que reconocio el OCR deben poder buscarse.
        final palabras = ocr.text
            .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
            .where((w) => w.length >= 6)
            .toSet()
            .toList();
        expect(palabras, isNotEmpty, reason: 'el OCR real dio solo palabras cortas');

        final encontradas =
            palabras.where((w) => extraido.contains(w)).length;
        expect(
          encontradas / palabras.length,
          greaterThan(0.8),
          reason: 'el PDF debe conservar casi todas las palabras reconocidas',
        );

        // 5. Y la busqueda de la biblioteca tambien las encuentra.
        final resultados = await repo.listDocuments(query: palabras.first);
        expect(resultados.map((d) => d.id), contains(doc.id));
      },
      timeout: const Timeout(Duration(minutes: 6)),
      skip: motivo,
    );

    test(
      'ese mismo texto reconocido alimenta la conversion a audio',
      () async {
        final raw = await File('${Corpus.directory}/instrucciones.jpg').readAsBytes();
        final normalizada = await ImagePipeline.normalizeWithSize(raw);
        final procesada = await ImagePipeline.processPage(
          sourceJpeg: normalizada!.jpeg,
          quad: await ImagePipeline.detectInJpeg(normalizada.jpeg),
          filter: ScanFilter.magic,
          adjustments: Adjustments.none,
          rotationQuarterTurns: 0,
        );

        final repo = DocumentRepository.instance;
        final doc = await repo.createDocument(title: 'Para narrar');
        await repo.addPage(
          documentId: doc.id,
          originalJpeg: normalizada.jpeg,
          processedJpeg: procesada.jpeg,
          thumbnailJpeg: procesada.thumbnail,
          width: procesada.width,
          height: procesada.height,
        );

        // Sin texto guardado: el cargador debe reconocerlo el mismo.
        final contenido = await MediaSourceLoader.fromScannedDocument(
          (await repo.getDocument(doc.id))!,
          repository: repo,
        );
        addTearDown(contenido.dispose);

        expect(contenido.hasText, isTrue,
            reason: 'el OCR automatico debe rellenar el texto que faltaba');
        expect(
          (await repo.getDocument(doc.id))!.pages.single.hasOcr,
          isTrue,
          reason: 'y quedar guardado para la proxima vez',
        );
      },
      timeout: const Timeout(Duration(minutes: 6)),
      skip: motivo,
    );
  });

  group('Tesseract sobre documentos reales', () {
    test(
      'una pagina impresa moderna devuelve texto y cajas dentro de la imagen',
      () async {
        final file = await paginaProcesada('instrucciones.jpg');
        final resultado = await DesktopOcr.recognizeFile(file.path);

        expect(resultado.isEmpty, isFalse,
            reason: 'una pagina impresa debe dar texto');
        expect(resultado.lines.length, greaterThan(3));

        final tamano = await ImagePipeline.readSize(await file.readAsBytes());
        for (final linea in resultado.lines) {
          expect(linea.left, greaterThanOrEqualTo(0));
          expect(linea.top, greaterThanOrEqualTo(0));
          expect(linea.left + linea.width, lessThanOrEqualTo(tamano!.width + 2));
          expect(linea.top + linea.height, lessThanOrEqualTo(tamano.height + 2));
          expect(linea.text.trim(), isNotEmpty);
        }

        // Las cajas van de arriba abajo: es lo que espera la capa del PDF.
        final tops = resultado.lines.map((l) => l.top).toList();
        final ordenadas = [...tops]..sort();
        expect(tops.first, ordenadas.first);
      },
      timeout: const Timeout(Duration(minutes: 4)),
      skip: motivo,
    );

    test(
      'el filtro de blanco y negro no deja la pagina sin texto reconocible',
      () async {
        final color = await paginaProcesada('instrucciones.jpg');
        final bn = await paginaProcesada(
          'instrucciones.jpg',
          filter: ScanFilter.blackWhite,
        );

        final conColor = await DesktopOcr.recognizeFile(color.path);
        final conBn = await DesktopOcr.recognizeFile(bn.path);

        expect(conBn.isEmpty, isFalse);
        // Binarizar no deberia costar mas de la mitad de las lineas.
        expect(
          conBn.lines.length,
          greaterThanOrEqualTo((conColor.lines.length * 0.5).floor()),
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: motivo,
    );

    test(
      'una factura impresa deja numeros reconocibles',
      () async {
        final file = await paginaProcesada('factura-sichuan.jpg');
        final resultado = await DesktopOcr.recognizeFile(file.path);

        expect(resultado.isEmpty, isFalse);
        expect(
          RegExp(r'\d').hasMatch(resultado.text),
          isTrue,
          reason: 'una factura sin ninguna cifra reconocida no sirve',
        );
      },
      timeout: const Timeout(Duration(minutes: 4)),
      skip: motivo,
    );
  });
}

/// Motivo por el que no se puede ejecutar el OCR real, o `false` si si se puede.
Object _motivoParaSaltar() {
  if (!Corpus.isAvailable) return Corpus.missingReason;
  try {
    if (Process.runSync(DesktopOcr.executable, const ['--version']).exitCode == 0) {
      return false;
    }
  } on ProcessException {
    // Sin binario: se dice como instalarlo.
  }
  return 'Falta Tesseract. Instalalo con: sudo pacman -S tesseract '
      'tesseract-data-spa tesseract-data-eng (Arch) o sudo apt install '
      'tesseract-ocr tesseract-ocr-spa (Debian/Ubuntu).';
}
