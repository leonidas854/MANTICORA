import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/export/table_extractor.dart';
import 'package:manticora/imaging/ocr_service.dart';

/// Construye una linea de OCR como la que devolveria ML Kit.
OcrLine line(String text, double x, double y, {double w = 90, double h = 18}) =>
    OcrLine(text, x, y, w, h);

/// Tabla de 4 columnas y 4 filas, con las columnas bien alineadas.
List<OcrLine> _invoiceTable() {
  const colX = [60.0, 240.0, 420.0, 560.0];
  const rows = [
    ['Concepto', 'Cantidad', 'Precio', 'Total'],
    ['Teclado', '2', '25,00', '50,00'],
    ['Monitor', '1', '150,00', '150,00'],
    ['Raton', '3', '12,50', '37,50'],
  ];
  final out = <OcrLine>[];
  for (var r = 0; r < rows.length; r++) {
    for (var c = 0; c < rows[r].length; c++) {
      out.add(line(rows[r][c], colX[c], 200.0 + r * 40, w: 110));
    }
  }
  return out;
}

void main() {
  group('Deteccion de tablas en el texto reconocido', () {
    test('reconoce una tabla de 4x4 con las columnas alineadas', () {
      final blocks = TableExtractor.analyze(_invoiceTable(), pageWidth: 700);
      final tables = blocks.whereType<TableBlock>().toList();

      expect(tables, hasLength(1), reason: 'deberia encontrar una tabla');
      final table = tables.first;
      expect(table.rowCount, 4);
      expect(table.columnCount, 4);
      expect(table.rows.first, ['Concepto', 'Cantidad', 'Precio', 'Total']);
      expect(table.rows[1], ['Teclado', '2', '25,00', '50,00']);
      expect(table.rows.last, ['Raton', '3', '12,50', '37,50']);
    });

    test('el texto suelto se queda como parrafos, no como tabla', () {
      final lines = [
        line('Estimado cliente:', 60, 100, w: 300),
        line('Le enviamos el detalle de su pedido del mes.', 60, 130, w: 460),
        line('Un saludo cordial.', 60, 160, w: 240),
      ];
      final blocks = TableExtractor.analyze(lines, pageWidth: 700);

      expect(blocks.whereType<TableBlock>(), isEmpty);
      final paragraphs = blocks.whereType<ParagraphBlock>().toList();
      expect(paragraphs, hasLength(3));
      expect(paragraphs.first.text, 'Estimado cliente:');
    });

    test('conserva el orden entre parrafos y tabla', () {
      final blocks = TableExtractor.analyze([
        line('FACTURA 2026-04', 60, 60, w: 280),
        line('Cliente: Ana Perez', 60, 110, w: 300),
        ..._invoiceTable(),
        line('Gracias por su confianza.', 60, 420, w: 320),
      ], pageWidth: 700);

      expect(blocks.length, greaterThanOrEqualTo(4));
      expect(blocks.first, isA<ParagraphBlock>());
      expect((blocks.first as ParagraphBlock).text, 'FACTURA 2026-04');
      expect(blocks.any((b) => b is TableBlock), isTrue);
      expect(blocks.last, isA<ParagraphBlock>());
      expect((blocks.last as ParagraphBlock).text, contains('Gracias'));
    });

    test('rellena las celdas que faltan en una fila incompleta', () {
      final lines = <OcrLine>[
        line('Producto', 60, 200, w: 110),
        line('Precio', 300, 200, w: 110),
        line('Mesa', 60, 240, w: 110),
        line('80,00', 300, 240, w: 110),
        line('Silla', 60, 280, w: 110),
        // Sin precio en la ultima fila.
        line('Banco', 60, 320, w: 110),
        line('45,00', 300, 320, w: 110),
      ];
      final table = TableExtractor.analyze(lines, pageWidth: 700)
          .whereType<TableBlock>()
          .single;

      expect(table.columnCount, 2);
      expect(table.rowCount, 4);
      // La fila incompleta se rellena con una celda vacia, no descuadra.
      for (final row in table.rows) {
        expect(row.length, 2);
      }
      expect(table.rows[2], ['Silla', '']);
    });

    test('dos columnas de texto no se confunden con una tabla de datos', () {
      // Dos parrafos largos uno al lado del otro: no es una tabla.
      final lines = <OcrLine>[
        line('un texto bastante largo aqui', 60, 200, w: 260),
        line('otro texto largo a la derecha', 360, 200, w: 260),
      ];
      final blocks = TableExtractor.analyze(lines, pageWidth: 700);
      // Con una sola fila no hay estructura suficiente para hablar de tabla.
      expect(blocks.whereType<TableBlock>(), isEmpty);
    });

    test('una lista de texto no genera tabla', () {
      final blocks = TableExtractor.analyze([
        for (var i = 0; i < 6; i++) line('Punto numero $i del listado', 60, 100.0 + i * 30, w: 400),
      ], pageWidth: 700);
      expect(blocks.whereType<TableBlock>(), isEmpty);
    });

    test('sin lineas devuelve una lista vacia', () {
      expect(TableExtractor.analyze(const [], pageWidth: 700), isEmpty);
    });

    test('el texto plano de la tabla conserva las celdas separadas', () {
      final table = TableExtractor.analyze(_invoiceTable(), pageWidth: 700)
          .whereType<TableBlock>()
          .single;
      expect(table.toPlainText(), contains('Concepto'));
      expect(table.toPlainText(), contains('Teclado'));
      // Las celdas de una fila no deben quedar pegadas.
      expect(table.toPlainText().split('\n').first.split('\t').length, 4);
    });
  });
}
