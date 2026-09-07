import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/device_layout.dart';
import 'package:manticora/core/failure.dart';
import 'package:manticora/export/file_saver.dart';
import 'package:manticora/export/share_service.dart';
import 'package:manticora/export/tts_service.dart';
import 'package:manticora/imaging/desktop_ocr.dart';
import 'package:share_plus/share_plus.dart';

/// Lo que cambia de una plataforma a otra, comprobado sin depender de estar
/// ejecutandose en ella: entrega de ficheros, motor de voz, OCR de escritorio y
/// reparto de la interfaz en movil, tablet y escritorio.
class _FakeShare {
  _FakeShare({this.failWith});

  final Object? failWith;
  ShareParams? received;

  Future<ShareResult> share(ShareParams params) async {
    received = params;
    if (failWith != null) throw failWith!;
    return const ShareResult('ok', ShareResultStatus.success);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('manticora_plat_');
  });

  tearDown(() async {
    ShareService.resetSaverForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<XFile> fileWith(String name, String content) async {
    final file = File('${temp.path}${Platform.pathSeparator}$name');
    await file.writeAsString(content, flush: true);
    return XFile(file.path);
  }

  group('Entrega de ficheros segun la plataforma', () {
    test('Android y Windows usan el panel del sistema', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
        expect(
          ShareService.strategyFor(platform, fileCount: 1),
          FileDeliveryStrategy.platformShare,
          reason: '$platform tiene panel de compartir con adjuntos',
        );
        expect(
          ShareService.strategyFor(platform, fileCount: 5),
          FileDeliveryStrategy.platformShare,
        );
      }
    });

    test('Linux guarda: uno tal cual, varios en un ZIP', () {
      expect(
        ShareService.strategyFor(TargetPlatform.linux, fileCount: 1),
        FileDeliveryStrategy.saveAs,
      );
      expect(
        ShareService.strategyFor(TargetPlatform.linux, fileCount: 3),
        FileDeliveryStrategy.bundleAndSave,
      );
    });

    test('la web siempre usa Web Share, tambien sobre Linux', () {
      expect(
        ShareService.strategyFor(TargetPlatform.linux, fileCount: 2, isWeb: true),
        FileDeliveryStrategy.platformShare,
      );
    });

    test('en Windows el fichero llega al panel con su asunto', () async {
      final fake = _FakeShare();
      ShareService.shareWithSystem = fake.share;

      final result = await ShareService.deliverFiles(
        files: [await fileWith('informe.pdf', 'contenido del informe')],
        subject: 'Informe de marzo',
        platform: TargetPlatform.windows,
        isWeb: false,
      );

      expect(result.strategy, FileDeliveryStrategy.platformShare);
      expect(fake.received?.files, hasLength(1));
      expect(fake.received?.subject, 'Informe de marzo');
    });

    test(
      'un Windows antiguo sin panel para adjuntos guarda el fichero en vez de fallar',
      () async {
        ShareService.shareWithSystem = _FakeShare(
          failWith: UnimplementedError('sharing files is only available for...'),
        ).share;
        String? guardado;
        ShareService.saveFile = (name, bytes) async {
          guardado = name;
          return 'C:/Users/prueba/Downloads/$name';
        };

        final result = await ShareService.deliverFiles(
          files: [await fileWith('acta.pdf', 'acta de la reunion')],
          platform: TargetPlatform.windows,
          isWeb: false,
        );

        expect(result.strategy, FileDeliveryStrategy.saveAs);
        expect(result.wasCancelled, isFalse);
        expect(guardado, 'acta.pdf');
      },
    );

    test('varios ficheros en Linux acaban en un ZIP con todos dentro', () async {
      Uint8List? zip;
      ShareService.saveFile = (name, bytes) async {
        zip = bytes;
        return '/home/prueba/Descargas/$name';
      };

      final result = await ShareService.deliverFiles(
        files: [
          await fileWith('pagina-1.jpg', 'primera'),
          await fileWith('pagina-2.jpg', 'segunda'),
        ],
        bundleName: 'escaneo',
        platform: TargetPlatform.linux,
        isWeb: false,
      );

      expect(result.strategy, FileDeliveryStrategy.bundleAndSave);
      expect(result.savedLocation, endsWith('escaneo.zip'));

      final archive = ZipDecoder().decodeBytes(zip!);
      expect(archive.files.map((f) => f.name).toSet(),
          {'pagina-1.jpg', 'pagina-2.jpg'});
      expect(
        utf8.decode(archive.files.first.content as List<int>),
        'primera',
      );
    });

    test('dos ficheros con el mismo nombre no se pisan dentro del ZIP', () async {
      Uint8List? zip;
      ShareService.saveFile = (name, bytes) async {
        zip = bytes;
        return name;
      };

      final subdir = Directory('${temp.path}${Platform.pathSeparator}otra')
        ..createSync();
      final repetido = File('${subdir.path}${Platform.pathSeparator}pagina.jpg')
        ..writeAsStringSync('la de la otra carpeta');

      await ShareService.deliverFiles(
        files: [
          await fileWith('pagina.jpg', 'la primera'),
          XFile(repetido.path),
        ],
        platform: TargetPlatform.linux,
        isWeb: false,
      );

      final nombres =
          ZipDecoder().decodeBytes(zip!).files.map((f) => f.name).toList();
      expect(nombres, hasLength(2));
      expect(nombres.toSet(), hasLength(2), reason: 'ninguno puede sobrescribir al otro');
    });

    test('un fichero vacio se rechaza con un motivo entendible', () async {
      ShareService.shareWithSystem = _FakeShare().share;
      final vacio = await fileWith('vacio.pdf', '');
      expect(
        () => ShareService.deliverFiles(
          files: [vacio],
          platform: TargetPlatform.android,
          isWeb: false,
        ),
        throwsA(isA<AppFailure>().having(
          (e) => e.message,
          'message',
          contains('vacio'),
        )),
      );
    });

    test('los tipos MIME cubren lo que la app llega a generar', () {
      expect(FileSaver.mimeFor('documento.pdf'), 'application/pdf');
      expect(FileSaver.mimeFor('acta.m4a'), 'audio/mp4');
      expect(FileSaver.mimeFor('charla.mp4'), 'video/mp4');
      expect(FileSaver.mimeFor('paginas.zip'), 'application/zip');
      expect(
        FileSaver.mimeFor('informe.docx'),
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
      expect(FileSaver.mimeFor('desconocido.xyz'), 'application/octet-stream');
    });
  });

  group('Motor de voz de Windows', () {
    test('el guion sintetiza a WAV con la voz del idioma pedido', () {
      final script = TtsService.windowsSpeechScript(
        textPath: r'C:\temp\pagina.txt',
        wavPath: r'C:\temp\pagina.wav',
        language: 'es-ES',
        rate: 1,
      );

      expect(script, contains('System.Speech'));
      expect(script, contains('SetOutputToWaveFile'));
      expect(script, contains("CultureInfo('es-ES')"));
      expect(script, contains(r'C:\temp\pagina.wav'));
      expect(script, contains(r'$voz.Rate = 0'));
    });

    test('la velocidad se traduce a la escala de System.Speech', () {
      String rateLine(double rate) => TtsService.windowsSpeechScript(
            textPath: 'a.txt',
            wavPath: 'a.wav',
            language: 'es-ES',
            rate: rate,
          ).split('\n').firstWhere((l) => l.contains(r'$voz.Rate'));

      expect(rateLine(1), contains('= 0'));
      expect(rateLine(1.4), contains('= 4'));
      expect(rateLine(0.8), contains('= -2'));
      // Fuera de rango se recorta en vez de pedir algo imposible.
      expect(rateLine(9), contains('= 6'));
      expect(rateLine(0.1), contains('= -5'));
    });

    test('una ruta con comilla no puede colar ordenes en PowerShell', () {
      final script = TtsService.windowsSpeechScript(
        textPath: r"C:\temp\it's; Remove-Item C:\ -Recurse.txt",
        wavPath: 'salida.wav',
        language: 'es-ES',
        rate: 1,
      );

      // La comilla se duplica, que es como PowerShell escapa dentro de '...':
      // la orden inyectada queda dentro de la cadena, no fuera.
      expect(script, contains("it''s; Remove-Item"));
      expect(script, isNot(contains("'C:\\temp\\it's;")));
    });
  });

  group('OCR de escritorio (Tesseract)', () {
    test('agrupa las palabras del TSV en lineas con su caja', () {
      const tsv = 'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\t'
          'left\ttop\twidth\theight\tconf\ttext\n'
          '5\t1\t1\t1\t1\t1\t100\t50\t60\t20\t96.4\tFactura\n'
          '5\t1\t1\t1\t1\t2\t170\t52\t30\t18\t95.1\tnum\n'
          '5\t1\t1\t1\t2\t1\t100\t90\t120\t22\t93.7\tTotal:\n'
          '5\t1\t1\t1\t2\t2\t230\t92\t70\t20\t90.0\t1.250\n';

      final result = DesktopOcr.parseTsv(tsv);

      expect(result.lines, hasLength(2));
      expect(result.lines.first.text, 'Factura num');
      expect(result.lines.first.left, 100);
      expect(result.lines.first.top, 50);
      expect(result.lines.first.width, 100, reason: '170 + 30 - 100');
      expect(result.lines.last.text, 'Total: 1.250');
      expect(result.text, 'Factura num\nTotal: 1.250');
    });

    test('descarta las palabras que Tesseract no llego a leer', () {
      const tsv = 'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\t'
          'left\ttop\twidth\theight\tconf\ttext\n'
          '4\t1\t1\t1\t1\t0\t100\t50\t200\t20\t-1\t\n'
          '5\t1\t1\t1\t1\t1\t100\t50\t60\t20\t-1\tbasura\n'
          '5\t1\t1\t1\t1\t2\t170\t52\t30\t18\t95.1\tvalido\n';

      final result = DesktopOcr.parseTsv(tsv);
      expect(result.lines, hasLength(1));
      expect(result.lines.single.text, 'valido');
    });

    test('un TSV vacio o con otras columnas no revienta', () {
      expect(DesktopOcr.parseTsv('').lines, isEmpty);
      expect(DesktopOcr.parseTsv('otra\tcosa\n1\t2').lines, isEmpty);
      expect(DesktopOcr.parseTsv('').isEmpty, isTrue);
    });

    test('elige el idioma mas completo de los instalados', () {
      expect(DesktopOcr.bestLanguage(['eng', 'spa', 'osd']), 'spa+eng');
      expect(DesktopOcr.bestLanguage(['spa', 'osd']), 'spa');
      expect(DesktopOcr.bestLanguage(['eng']), 'eng');
      expect(DesktopOcr.bestLanguage(['deu']), 'deu');
      expect(DesktopOcr.bestLanguage([]), isNull);
    });

    test('sin Tesseract el mensaje dice como instalarlo', () {
      final failure = DesktopOcr.missingEngineFailure();
      expect(failure.kind, FailureKind.unsupported);
      expect(failure.retryable, isFalse);
      expect(
        failure.message.toLowerCase(),
        contains('tesseract'),
      );
    });
  });

  group('Reparto de la interfaz en las tres plataformas', () {
    test('un telefono es compacto y un escritorio no', () {
      expect(
        DeviceLayout.classify(
          platform: TargetPlatform.android,
          logicalSize: const Size(392, 850),
        ),
        AppDeviceKind.phone,
      );
      expect(
        DeviceLayout.classify(
          platform: TargetPlatform.windows,
          logicalSize: const Size(392, 850),
        ),
        AppDeviceKind.desktop,
        reason: 'una ventana estrecha en Windows sigue teniendo raton y teclado',
      );
      expect(
        DeviceLayout.classify(
          platform: TargetPlatform.linux,
          logicalSize: const Size(1600, 900),
        ),
        AppDeviceKind.desktop,
      );
      expect(
        DeviceLayout.classify(
          platform: TargetPlatform.android,
          logicalSize: const Size(800, 1280),
        ),
        AppDeviceKind.tablet,
      );
    });

    test('los anchos se clasifican igual en cualquier sistema', () {
      expect(DeviceLayout.widthClassFor(360), AppWidthClass.compact);
      expect(DeviceLayout.widthClassFor(700), AppWidthClass.medium);
      expect(DeviceLayout.widthClassFor(1400), AppWidthClass.expanded);
    });
  });
}
