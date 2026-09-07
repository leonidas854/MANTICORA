import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/data/db/app_database.dart';
import 'package:manticora/data/repositories/document_repository.dart';
import 'package:manticora/data/repositories/storage_service.dart';
import 'package:manticora/export/media_export_service.dart';
import 'package:manticora/features/media/media_source.dart';
import 'package:manticora/imaging/filters.dart';
import 'package:manticora/imaging/pipeline.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'support/corpus.dart';

/// Conversion de verdad: voz real de `espeak-ng` y codificacion real con
/// FFmpeg, sin simulacros. Si el escritorio no tiene esas dos herramientas la
/// prueba se salta con un motivo visible en vez de fingir que paso.
///
/// Comprueba lo que de verdad importa al compartir: que el fichero exista, que
/// sea un MP4/M4A legible por el sistema, que dure algo y que quepa en
/// WhatsApp.
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

  final missing = _missingTools();
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('manticora_media_real_');
    PathProviderPlatform.instance = _TempPathProvider(temp.path);
    await AppDatabase.instance.resetForTesting();
    StorageService.instance.resetForTesting();
  });

  tearDown(() async {
    await AppDatabase.instance.resetForTesting();
    StorageService.instance.resetForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// Guarda fotos reales como documento escaneado, con su texto reconocido.
  Future<String> escanearReal(Map<String, String> fotosYTexto) async {
    final repo = DocumentRepository.instance;
    final doc = await repo.createDocument(title: 'Expediente narrado');
    for (final entrada in fotosYTexto.entries) {
      final raw = await File('${Corpus.directory}/${entrada.key}').readAsBytes();
      final normalizada = await ImagePipeline.normalizeWithSize(raw);
      final procesada = await ImagePipeline.processPage(
        sourceJpeg: normalizada!.jpeg,
        quad: await ImagePipeline.detectInJpeg(normalizada.jpeg),
        filter: ScanFilter.magic,
        adjustments: Adjustments.none,
        rotationQuarterTurns: 0,
      );
      final page = await repo.addPage(
        documentId: doc.id,
        originalJpeg: normalizada.jpeg,
        processedJpeg: procesada.jpeg,
        thumbnailJpeg: procesada.thumbnail,
        width: procesada.width,
        height: procesada.height,
      );
      await repo.setOcrText(page.id, doc.id, entrada.value);
    }
    return doc.id;
  }

  group('Conversion real de un escaneo de la biblioteca', () {
    test(
      'una foto real escaneada se convierte en el audio que se manda por WhatsApp',
      () async {
        final id = await escanearReal({
          'instrucciones.jpg': 'Instrucciones de montaje. Primero se colocan '
              'las patas y despues se aprietan los tornillos.',
        });
        final doc = (await DocumentRepository.instance.getDocument(id))!;

        final contenido = await MediaSourceLoader.fromScannedDocument(
          doc,
          repository: DocumentRepository.instance,
          runOcrIfMissing: false,
        );
        addTearDown(contenido.dispose);
        expect(contenido.hasText, isTrue);
        expect(contenido.hasImages, isTrue);

        final audio = await MediaExportService.instance.toAudio(
          contenido.pages,
          title: doc.document.title,
        );

        expect(_isIsoMedia(await audio.file.readAsBytes()), isTrue);
        final duracion = await _duration(audio.file.path);
        expect(duracion, isNotNull);
        expect(duracion!, greaterThan(2), reason: 'dos frases duran mas de 2 s');
        expect(await audio.file.length(), lessThan(2 * 1024 * 1024),
            reason: 'un audio de dos frases tiene que ser diminuto');
      },
      timeout: const Timeout(Duration(minutes: 4)),
      skip: Corpus.isAvailable ? (missing == false ? false : missing) : Corpus.missingReason,
    );

    test(
      'varias fotos reales se convierten en un video narrado con sus paginas',
      () async {
        final id = await escanearReal({
          'instrucciones.jpg': 'Primera hoja del manual.',
          'factura-sichuan.jpg': 'Segunda hoja con el importe.',
        });
        final doc = (await DocumentRepository.instance.getDocument(id))!;

        final contenido = await MediaSourceLoader.fromScannedDocument(
          doc,
          repository: DocumentRepository.instance,
          runOcrIfMissing: false,
        );
        addTearDown(contenido.dispose);

        final video = await MediaExportService.instance.toVideo(
          contenido.pages,
          title: 'manual narrado',
          options: const MediaExportOptions(videoWidth: 480),
        );

        expect(_isIsoMedia(await video.file.readAsBytes()), isTrue);
        final flujos = await _streamKinds(video.file.path);
        expect(flujos, containsAll(['video', 'audio']));

        final duracion = await _duration(video.file.path);
        expect(duracion, isNotNull);
        expect(duracion!, greaterThan(2));
      },
      timeout: const Timeout(Duration(minutes: 6)),
      skip: Corpus.isAvailable ? (missing == false ? false : missing) : Corpus.missingReason,
    );
  });

  group('Conversion real de documentos', () {
    test(
      'un DOCX acaba en un M4A que suena y pesa poco',
      () async {
        final content = await MediaSourceLoader.fromBytes(
          _wordDocx([
            'Acta de la reunion del martes.',
            'Se aprueba el presupuesto de mantenimiento.',
          ]),
          fileName: 'acta.docx',
          needImages: false,
        );
        addTearDown(content.dispose);

        final result = await MediaExportService.instance.toAudio(
          content.pages,
          title: 'acta de la reunion',
          options: const MediaExportOptions(audioBitrateKbps: 32),
        );

        expect(await result.file.exists(), isTrue);
        final bytes = await result.file.readAsBytes();
        expect(_isIsoMedia(bytes), isTrue,
            reason: 'debe ser un MP4/M4A que reconozca el sistema');
        expect(result.duration.inMilliseconds, greaterThan(500),
            reason: 'un audio de duracion cero no se puede escuchar');
        expect(bytes.length, lessThan(16 * 1024 * 1024),
            reason: 'tiene que caber holgadamente en un envio de WhatsApp');

        final probed = await _duration(result.file.path);
        expect(probed, isNotNull, reason: 'FFmpeg debe poder volver a abrirlo');
        expect(probed!, greaterThan(0.5));
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: missing,
    );

    test(
      'un PPTX acaba en un MP4 narrado con una lamina por diapositiva',
      () async {
        final content = await MediaSourceLoader.fromBytes(
          _presentationPptx({
            'Primera': 'Presentamos los resultados del trimestre.',
            'Segunda': 'Las ventas suben respecto al ano pasado.',
          }),
          fileName: 'charla.pptx',
          needImages: true,
        );
        addTearDown(content.dispose);
        expect(content.hasImages, isTrue);

        final result = await MediaExportService.instance.toVideo(
          content.pages,
          title: 'charla del trimestre',
          options: const MediaExportOptions(videoWidth: 480),
        );

        expect(await result.file.exists(), isTrue);
        final bytes = await result.file.readAsBytes();
        expect(_isIsoMedia(bytes), isTrue);
        expect(result.narrated, isTrue);

        final probed = await _duration(result.file.path);
        expect(probed, isNotNull);
        expect(probed!, greaterThan(1),
            reason: 'dos diapositivas narradas duran mas de un segundo');

        final streams = await _streamKinds(result.file.path);
        expect(streams, contains('video'));
        expect(streams, contains('audio'),
            reason: 'se pidio narracion: el MP4 debe llevar voz');
      },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: missing,
    );

    test(
      'un video sin narracion sale mudo y respeta los segundos por pagina',
      () async {
        final content = await MediaSourceLoader.fromBytes(
          _presentationPptx({'Unica': 'Una sola lamina.'}),
          fileName: 'breve.pptx',
          needImages: true,
        );
        addTearDown(content.dispose);

        final result = await MediaExportService.instance.toVideo(
          content.pages,
          title: 'lamina muda',
          options: const MediaExportOptions(
            narrated: false,
            secondsPerPage: 3,
            videoWidth: 480,
          ),
        );

        expect(result.narrated, isFalse);
        final streams = await _streamKinds(result.file.path);
        expect(streams, contains('video'));
        expect(streams, isNot(contains('audio')));

        final probed = await _duration(result.file.path);
        expect(probed, isNotNull);
        expect(probed!, closeTo(3, 1.2),
            reason: 'se pidieron 3 segundos para la unica lamina');
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: missing,
    );
  });
}

/// Motivo por el que saltarse las pruebas, o `false` si se pueden ejecutar.
Object _missingTools() {
  final faltan = <String>[
    // FFmpeg no entiende `--version`, solo `-version`.
    if (!_hasTool('ffmpeg', versionFlag: const ['-version'])) 'ffmpeg',
    if (!_hasTool('ffprobe', versionFlag: const ['-version'])) 'ffprobe',
    if (!_hasTool('espeak-ng') && !_hasTool('espeak')) 'espeak-ng',
  ];
  if (faltan.isEmpty) return false;
  return 'Falta ${faltan.join(' y ')} en este equipo; instalalos para probar '
      'la conversion real.';
}

bool _hasTool(String name, {List<String> versionFlag = const ['--version']}) {
  try {
    return Process.runSync(name, versionFlag).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Cabecera ISO-BMFF: `ftyp` en el segundo bloque de cuatro bytes.
bool _isIsoMedia(Uint8List bytes) =>
    bytes.length > 12 && String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp';

Future<double?> _duration(String path) async {
  final probe = await Process.run('ffprobe', [
    '-v', 'error',
    '-show_entries', 'format=duration',
    '-of', 'default=noprint_wrappers=1:nokey=1',
    path,
  ]);
  if (probe.exitCode != 0) return null;
  return double.tryParse('${probe.stdout}'.trim());
}

Future<Set<String>> _streamKinds(String path) async {
  final probe = await Process.run('ffprobe', [
    '-v', 'error',
    '-show_entries', 'stream=codec_type',
    '-of', 'default=noprint_wrappers=1:nokey=1',
    path,
  ]);
  if (probe.exitCode != 0) return {};
  return '${probe.stdout}'
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toSet();
}

Uint8List _officeZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _wordDocx(List<String> paragraphs) => _officeZip({
      'word/document.xml': '''
<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>${paragraphs.map((t) => '<w:p><w:r><w:t>$t</w:t></w:r></w:p>').join()}</w:body>
</w:document>
''',
    });

Uint8List _presentationPptx(Map<String, String> slides) {
  final files = <String, String>{
    'ppt/presentation.xml': '<p:presentation '
        'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"/>',
  };
  var index = 1;
  for (final slide in slides.entries) {
    files['ppt/slides/slide$index.xml'] = '''
<?xml version="1.0" encoding="UTF-8"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <p:cSld><p:spTree>
    <p:sp><p:txBody><a:p><a:r><a:t>${slide.key}</a:t></a:r></a:p></p:txBody></p:sp>
    <p:sp><p:txBody><a:p><a:r><a:t>${slide.value}</a:t></a:r></a:p></p:txBody></p:sp>
  </p:spTree></p:cSld>
</p:sld>
''';
    index++;
  }
  return _officeZip(files);
}
