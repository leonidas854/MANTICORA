import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/export/docx_builder.dart';

/// JPEG minimo valido (1x1 pixel) para comprobar el empaquetado de imagenes.
final _tinyJpeg = Uint8List.fromList(base64Decode(
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a'
    'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA'
    'AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=='));

Archive _open(Uint8List docx) => ZipDecoder().decodeBytes(docx);

String _text(Archive a, String path) {
  final file = a.files.firstWhere((f) => f.name == path);
  return utf8.decode(file.content as List<int>);
}

void main() {
  group('DocxBuilder', () {
    test('genera un paquete OOXML con todas las partes obligatorias', () {
      final docx = DocxBuilder.build(
        pages: const [DocxPageInput(text: 'Hola mundo')],
        title: 'Prueba',
      );
      final names = _open(docx).files.map((f) => f.name).toSet();

      expect(names, containsAll(<String>[
        '[Content_Types].xml',
        '_rels/.rels',
        'word/document.xml',
        'word/_rels/document.xml.rels',
        'word/styles.xml',
        'docProps/core.xml',
        'docProps/app.xml',
      ]));
    });

    test('escribe el texto en parrafos', () {
      final docx = DocxBuilder.build(
        pages: const [DocxPageInput(text: 'Primera linea\nSegunda linea')],
        mode: DocxMode.textOnly,
      );
      final document = _text(_open(docx), 'word/document.xml');
      expect(document, contains('Primera linea'));
      expect(document, contains('Segunda linea'));
      // Dos lineas, dos parrafos con texto.
      expect('<w:t '.allMatches(document).length, greaterThanOrEqualTo(2));
    });

    test('escapa los caracteres reservados de XML', () {
      final docx = DocxBuilder.build(
        pages: const [DocxPageInput(text: 'a < b & c > d "cita"')],
        mode: DocxMode.textOnly,
      );
      final document = _text(_open(docx), 'word/document.xml');
      expect(document, contains('a &lt; b &amp; c &gt; d'));
      // El texto crudo no debe aparecer sin escapar.
      expect(document.contains('a < b & c'), isFalse);
    });

    test('incrusta la imagen y su relacion cuando hay pagina con foto', () {
      final docx = DocxBuilder.build(
        pages: [
          DocxPageInput(
            jpeg: _tinyJpeg,
            imageWidth: 800,
            imageHeight: 600,
            text: 'Texto reconocido',
          ),
        ],
      );
      final archive = _open(docx);
      final names = archive.files.map((f) => f.name).toSet();

      expect(names, contains('word/media/image1.jpeg'));
      expect(_text(archive, 'word/_rels/document.xml.rels'),
          contains('media/image1.jpeg'));
      expect(_text(archive, '[Content_Types].xml'), contains('image/jpeg'));
      expect(_text(archive, 'word/document.xml'), contains('r:embed="rIdImg1"'));
    });

    test('el modo "solo imagenes" omite el texto', () {
      final docx = DocxBuilder.build(
        pages: [DocxPageInput(jpeg: _tinyJpeg, text: 'NO DEBE APARECER')],
        mode: DocxMode.imagesOnly,
      );
      expect(_text(_open(docx), 'word/document.xml'),
          isNot(contains('NO DEBE APARECER')));
    });

    test('el modo "solo texto" no incrusta imagenes', () {
      final docx = DocxBuilder.build(
        pages: [DocxPageInput(jpeg: _tinyJpeg, text: 'Solo texto')],
        mode: DocxMode.textOnly,
      );
      final names = _open(docx).files.map((f) => f.name);
      expect(names.any((n) => n.startsWith('word/media/')), isFalse);
    });

    test('inserta salto de pagina entre paginas', () {
      final docx = DocxBuilder.build(
        pages: const [
          DocxPageInput(text: 'Uno'),
          DocxPageInput(text: 'Dos'),
        ],
        mode: DocxMode.textOnly,
      );
      final document = _text(_open(docx), 'word/document.xml');
      expect('w:type="page"'.allMatches(document).length, 1);
    });

    test('la imagen se limita al ancho util de la pagina', () {
      // 4000 px de ancho superan con creces el ancho util de una A4.
      final docx = DocxBuilder.build(
        pages: [DocxPageInput(jpeg: _tinyJpeg, imageWidth: 4000, imageHeight: 2000)],
        mode: DocxMode.imagesOnly,
      );
      final document = _text(_open(docx), 'word/document.xml');
      final match = RegExp(r'<wp:extent cx="(\d+)" cy="(\d+)"/>').firstMatch(document);
      expect(match, isNotNull);
      final cx = int.parse(match!.group(1)!);
      final cy = int.parse(match.group(2)!);
      expect(cx, 5943600); // ancho util exacto
      // Se conserva la proporcion 2:1.
      expect(cy, closeTo(cx / 2, 2));
    });
  });
}
