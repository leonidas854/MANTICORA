import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/failure.dart';
import 'package:manticora/data/repositories/storage_service.dart';
import 'package:manticora/features/media/media_source.dart';
import 'package:manticora/features/media/slide_image.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Redirige el almacenamiento de la app a una carpeta temporal de la prueba.
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

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('manticora_media_');
    PathProviderPlatform.instance = _TempPathProvider(temp.path);
    StorageService.instance.resetForTesting();
  });

  tearDown(() async {
    StorageService.instance.resetForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('Texto que se narra de cada pagina', () {
    test('no repite el titulo cuando el cuerpo ya empieza por el', () {
      final narration = MediaSourceLoader.narrationFor(
        title: 'Resumen anual',
        body: 'Resumen anual\nLas ventas crecieron un 12 por ciento.',
      );

      expect(narration.startsWith('Resumen anual\n'), isTrue);
      expect('Resumen anual'.allMatches(narration), hasLength(1));
    });

    test('anuncia el titulo cuando aporta algo que el cuerpo no dice', () {
      final narration = MediaSourceLoader.narrationFor(
        title: 'Conclusiones',
        body: 'Conviene repetir la campana en primavera.',
      );

      expect(narration, 'Conclusiones.\nConviene repetir la campana en primavera.');
    });

    test('una diapositiva solo con titulo si se lee', () {
      expect(
        MediaSourceLoader.narrationFor(title: 'Cierre', body: '   '),
        'Cierre',
      );
      expect(
        MediaSourceLoader.narrationFor(title: '  ', body: 'Solo cuerpo'),
        'Solo cuerpo',
      );
    });
  });

  group('Lectura de un fichero elegido por la persona', () {
    test('un DOCX se convierte en paginas narrables sin necesitar imagenes',
        () async {
      final bytes = _officeZip({
        'word/document.xml': _wordXml([
          '<w:p><w:r><w:t>Informe de campo</w:t></w:r></w:p>',
          '<w:p><w:r><w:br w:type="page"/></w:r></w:p>',
          '<w:p><w:r><w:t>Segunda pagina del informe</w:t></w:r></w:p>',
        ]),
      });

      final content = await MediaSourceLoader.fromBytes(
        bytes,
        fileName: 'informe.docx',
        needImages: false,
      );

      expect(content.kind, MediaSourceKind.word);
      expect(content.pageCount, 2);
      expect(content.pagesWithText, 2);
      expect(content.hasText, isTrue);
      expect(content.hasImages, isFalse,
          reason: 'sin imagenes no se puede montar un video');
      expect(content.pages.first.text, contains('Informe de campo'));
      await content.dispose();
    });

    test('un PPTX genera una lamina por diapositiva para el video', () async {
      final bytes = _officeZip({
        'ppt/presentation.xml': '<p:presentation '
            'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"/>',
        'ppt/slides/slide1.xml': _slideXml('Primera', 'Introduccion al tema'),
        'ppt/slides/slide2.xml': _slideXml('Segunda', 'Datos de ventas'),
      });

      final content = await MediaSourceLoader.fromBytes(
        bytes,
        fileName: 'charla.pptx',
        needImages: true,
      );

      expect(content.kind, MediaSourceKind.presentation);
      expect(content.pageCount, 2);
      expect(content.hasImages, isTrue);
      for (final page in content.pages) {
        expect(await page.imageFile!.exists(), isTrue);
        expect(await page.imageFile!.length(), greaterThan(0));
      }

      final work = content.workDir!;
      await content.dispose();
      expect(await work.exists(), isFalse,
          reason: 'las laminas temporales no deben quedarse en disco');
    });

    test('un fichero que no es documento se rechaza con un motivo claro', () {
      expect(
        () => MediaSourceLoader.fromBytes(
          Uint8List.fromList(utf8.encode('hola, soy texto suelto')),
          fileName: 'notas.txt',
          needImages: false,
        ),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            contains('PDF, Word'),
          ),
        ),
      );
    });

    test('un archivo vacio no llega ni a analizarse', () {
      expect(
        () => MediaSourceLoader.fromBytes(
          Uint8List(0),
          fileName: 'vacio.docx',
          needImages: false,
        ),
        throwsA(isA<AppFailure>()),
      );
    });
  });

  group('Laminas de texto para el video', () {
    test('salen en PNG con el tamano pedido', () async {
      final png = await SlideImage.render(
        title: 'Resultados',
        body: 'Las ventas del trimestre superaron la prevision inicial.',
        number: 1,
        total: 3,
        width: 640,
        height: 360,
      );

      expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10],
          reason: 'firma PNG');

      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 640);
      expect(frame.image.height, 360);
      frame.image.dispose();
      codec.dispose();
    });

    test('un texto larguisimo no revienta la lamina', () async {
      final png = await SlideImage.render(
        title: 'Acta',
        body: List.filled(4000, 'palabra').join(' '),
        number: 12,
        total: 12,
        width: 640,
        height: 360,
      );
      expect(png.length, greaterThan(1000));
    });

    test('un tamano imposible se rechaza en vez de dibujar basura', () {
      expect(
        () => SlideImage.render(
          title: 'x',
          body: 'y',
          number: 1,
          total: 1,
          width: 10,
          height: 10,
        ),
        throwsA(isA<AppFailure>()),
      );
    });
  });
}

Uint8List _officeZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _wordXml(List<String> body) => '''
<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>${body.join()}</w:body>
</w:document>
''';

String _slideXml(String title, String body) => '''
<?xml version="1.0" encoding="UTF-8"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <p:cSld><p:spTree>
    <p:sp><p:txBody><a:p><a:r><a:t>$title</a:t></a:r></a:p></p:txBody></p:sp>
    <p:sp><p:txBody><a:p><a:r><a:t>$body</a:t></a:r></a:p></p:txBody></p:sp>
  </p:spTree></p:cSld>
</p:sld>
''';
