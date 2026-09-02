import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/export/docx_builder.dart';
import 'package:manticora/export/table_extractor.dart';

String _document(Uint8List docx) {
  final archive = ZipDecoder().decodeBytes(docx);
  final file = archive.files.firstWhere((f) => f.name == 'word/document.xml');
  return utf8.decode(file.content as List<int>);
}

const _table = TableBlock([
  ['Concepto', 'Cantidad', 'Precio'],
  ['Teclado', '2', '25,00'],
  ['Monitor', '1', '150,00'],
]);

void main() {
  group('Tablas en el documento de Word', () {
    test('una tabla se escribe como <w:tbl>, no como parrafos', () {
      final docx = DocxBuilder.build(
        pages: const [DocxPageInput(blocks: [_table])],
        mode: DocxMode.textOnly,
      );
      final xml = _document(docx);

      expect(xml, contains('<w:tbl>'));
      expect(xml, contains('</w:tbl>'));
      // Tres filas de datos.
      expect('<w:tr>'.allMatches(xml).length, 3);
      // Nueve celdas.
      expect('<w:tc>'.allMatches(xml).length, 9);
    });

    test('declara la rejilla con una columna por cada campo', () {
      final xml = _document(DocxBuilder.build(
        pages: const [DocxPageInput(blocks: [_table])],
        mode: DocxMode.textOnly,
      ));
      expect('<w:gridCol'.allMatches(xml).length, 3);
    });

    test('la tabla lleva bordes visibles', () {
      final xml = _document(DocxBuilder.build(
        pages: const [DocxPageInput(blocks: [_table])],
        mode: DocxMode.textOnly,
      ));
      expect(xml, contains('<w:tblBorders>'));
      expect(xml, contains('w:insideH'));
      expect(xml, contains('w:insideV'));
    });

    test('el contenido de cada celda esta en su sitio', () {
      final xml = _document(DocxBuilder.build(
        pages: const [DocxPageInput(blocks: [_table])],
        mode: DocxMode.textOnly,
      ));
      for (final value in ['Concepto', 'Cantidad', 'Precio', 'Teclado', '150,00']) {
        expect(xml, contains('>$value</w:t>'), reason: 'falta la celda "$value"');
      }
    });

    test('escapa los caracteres reservados dentro de las celdas', () {
      final xml = _document(DocxBuilder.build(
        pages: const [
          DocxPageInput(blocks: [
            TableBlock([
              ['a < b', 'x & y'],
              ['"cita"', "apostrofe'"],
            ])
          ])
        ],
        mode: DocxMode.textOnly,
      ));
      expect(xml, contains('a &lt; b'));
      expect(xml, contains('x &amp; y'));
      expect(xml.contains('a < b'), isFalse);
    });

    test('tras la tabla queda un parrafo, como exige Word', () {
      final xml = _document(DocxBuilder.build(
        pages: const [DocxPageInput(blocks: [_table])],
        mode: DocxMode.textOnly,
      ));
      final tableEnd = xml.indexOf('</w:tbl>');
      final rest = xml.substring(tableEnd);
      expect(rest.indexOf('<w:p>'), lessThan(rest.indexOf('<w:sectPr>')),
          reason: 'Word necesita un parrafo despues de la tabla');
    });

    test('mezcla parrafos y tablas conservando el orden', () {
      final xml = _document(DocxBuilder.build(
        pages: const [
          DocxPageInput(blocks: [
            ParagraphBlock('FACTURA 2026-04'),
            _table,
            ParagraphBlock('Gracias por su confianza.'),
          ])
        ],
        mode: DocxMode.textOnly,
      ));

      final titulo = xml.indexOf('FACTURA 2026-04');
      final tabla = xml.indexOf('<w:tbl>');
      final cierre = xml.indexOf('Gracias por su confianza');
      expect(titulo, greaterThan(0));
      expect(tabla, greaterThan(titulo));
      expect(cierre, greaterThan(tabla));
    });

    test('sin bloques sigue funcionando con el texto plano de siempre', () {
      final xml = _document(DocxBuilder.build(
        pages: const [DocxPageInput(text: 'Primera linea\nSegunda linea')],
        mode: DocxMode.textOnly,
      ));
      expect(xml, contains('Primera linea'));
      expect(xml, contains('Segunda linea'));
      expect(xml, isNot(contains('<w:tbl>')));
    });

    test('el paquete sigue siendo un .docx valido con tablas dentro', () {
      final docx = DocxBuilder.build(
        pages: const [DocxPageInput(blocks: [_table])],
        mode: DocxMode.textOnly,
      );
      final names = ZipDecoder().decodeBytes(docx).files.map((f) => f.name).toSet();
      expect(names, containsAll(<String>[
        '[Content_Types].xml',
        '_rels/.rels',
        'word/document.xml',
        'word/styles.xml',
      ]));
      // El estilo de tabla debe estar declarado.
      final styles = utf8.decode(ZipDecoder()
          .decodeBytes(docx)
          .files
          .firstWhere((f) => f.name == 'word/styles.xml')
          .content as List<int>);
      expect(styles, contains('TableGrid'));
    });
  });
}
