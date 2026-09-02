import 'dart:math' as math;

import '../imaging/ocr_service.dart';

/// Una pieza del documento reconocido.
sealed class DocBlock {
  const DocBlock();
}

/// Texto corrido.
class ParagraphBlock extends DocBlock {
  final String text;
  const ParagraphBlock(this.text);

  @override
  String toString() => 'Parrafo("$text")';
}

/// Una tabla reconstruida a partir de la posicion de las celdas.
class TableBlock extends DocBlock {
  final List<List<String>> rows;
  const TableBlock(this.rows);

  int get rowCount => rows.length;
  int get columnCount => rows.isEmpty ? 0 : rows.first.length;

  /// Version en texto plano, con tabuladores entre celdas.
  String toPlainText() => rows.map((r) => r.join('\t')).join('\n');

  @override
  String toString() => 'Tabla(${rowCount}x$columnCount)';
}

/// Reconstruye la estructura del documento a partir de las cajas del OCR.
///
/// El reconocedor devuelve lineas sueltas con su posicion; aqui se agrupan en
/// filas y se busca cuando esas filas comparten columnas. Es lo que permite
/// que una factura salga como tabla de verdad en Word y no como un amasijo de
/// parrafos.
class TableExtractor {
  TableExtractor._();

  /// Numero minimo de filas con varias celdas para hablar de tabla.
  static const int _minSeedRows = 2;

  /// Minimo de columnas: con una sola no es una tabla, es una lista.
  static const int _minColumns = 2;

  static List<DocBlock> analyze(List<OcrLine> lines, {required double pageWidth}) {
    final clean = lines.where((l) => l.text.trim().isNotEmpty).toList();
    if (clean.isEmpty) return const [];

    final rows = _groupIntoRows(clean);
    final tolerance = math.max(14.0, pageWidth * 0.025);

    final blocks = <DocBlock>[];
    var index = 0;
    while (index < rows.length) {
      final region = _findTableRegion(rows, index, tolerance);
      if (region == null) {
        blocks.add(_paragraphOf(rows[index]));
        index++;
        continue;
      }
      blocks.add(region.table);
      index = region.endExclusive;
    }
    return blocks;
  }

  // ------------------------------------------------------------------ filas

  /// Agrupa las lineas en filas: dos lineas van juntas si se solapan en
  /// vertical mas de la mitad de la altura de la mas baja.
  static List<List<OcrLine>> _groupIntoRows(List<OcrLine> lines) {
    final sorted = [...lines]..sort((a, b) => a.top.compareTo(b.top));
    final rows = <List<OcrLine>>[];

    for (final line in sorted) {
      var placed = false;
      for (final row in rows) {
        if (_overlapsVertically(row, line)) {
          row.add(line);
          placed = true;
          break;
        }
      }
      if (!placed) rows.add([line]);
    }

    for (final row in rows) {
      row.sort((a, b) => a.left.compareTo(b.left));
    }
    rows.sort((a, b) => _rowTop(a).compareTo(_rowTop(b)));
    return rows;
  }

  static bool _overlapsVertically(List<OcrLine> row, OcrLine line) {
    final top = _rowTop(row), bottom = _rowBottom(row);
    final overlap =
        math.min(bottom, line.top + line.height) - math.max(top, line.top);
    if (overlap <= 0) return false;
    final smallest = math.min(bottom - top, line.height);
    return smallest > 0 && overlap >= smallest * 0.5;
  }

  static double _rowTop(List<OcrLine> row) =>
      row.map((l) => l.top).reduce(math.min);

  static double _rowBottom(List<OcrLine> row) =>
      row.map((l) => l.top + l.height).reduce(math.max);

  static ParagraphBlock _paragraphOf(List<OcrLine> row) =>
      ParagraphBlock(row.map((l) => l.text.trim()).join(' ').trim());

  // ----------------------------------------------------------------- tablas

  /// Busca una tabla que empiece en [start]. Devuelve null si no la hay.
  static ({TableBlock table, int endExclusive})? _findTableRegion(
    List<List<OcrLine>> rows,
    int start,
    double tolerance,
  ) {
    // 1. Semilla: filas consecutivas con varias celdas.
    var seedEnd = start;
    while (seedEnd < rows.length && rows[seedEnd].length >= _minColumns) {
      seedEnd++;
    }
    if (seedEnd - start < _minSeedRows) return null;

    // 2. Columnas deducidas de las filas semilla.
    final columns = _deriveColumns(rows.sublist(start, seedEnd), tolerance);
    if (columns.length < _minColumns) return null;

    // 3. Se extiende hacia abajo mientras las filas encajen en esas columnas.
    var end = seedEnd;
    while (end < rows.length && _rowFitsColumns(rows[end], columns, tolerance)) {
      end++;
    }

    // 4. Se construye la tabla rellenando los huecos.
    final table = <List<String>>[];
    for (var i = start; i < end; i++) {
      final cells = List<String>.filled(columns.length, '');
      for (final line in rows[i]) {
        final column = _columnFor(line, columns, tolerance);
        if (column < 0) continue;
        cells[column] = cells[column].isEmpty
            ? line.text.trim()
            : '${cells[column]} ${line.text.trim()}';
      }
      table.add(cells);
    }

    return (table: TableBlock(table), endExclusive: end);
  }

  /// Agrupa los bordes izquierdos de las celdas en columnas.
  static List<_Column> _deriveColumns(List<List<OcrLine>> rows, double tolerance) {
    final cells = [for (final row in rows) ...row]
      ..sort((a, b) => a.left.compareTo(b.left));

    final columns = <_Column>[];
    for (final cell in cells) {
      _Column? match;
      for (final column in columns) {
        if ((cell.left - column.left).abs() <= tolerance) {
          match = column;
          break;
        }
      }
      if (match == null) {
        columns.add(_Column(cell.left, cell.left + cell.width));
      } else {
        match.absorb(cell);
      }
    }

    columns.sort((a, b) => a.left.compareTo(b.left));
    return columns;
  }

  /// Una fila encaja si todas sus celdas caen en alguna columna y ninguna
  /// invade la siguiente (un parrafo largo cruza varias columnas y se descarta).
  static bool _rowFitsColumns(
    List<OcrLine> row,
    List<_Column> columns,
    double tolerance,
  ) {
    if (row.isEmpty) return false;
    for (final line in row) {
      final index = _columnFor(line, columns, tolerance);
      if (index < 0) return false;
      if (index + 1 < columns.length) {
        // La celda no puede llegar hasta donde empieza la columna siguiente.
        if (line.left + line.width > columns[index + 1].left + tolerance) {
          return false;
        }
      }
    }
    return true;
  }

  static int _columnFor(OcrLine line, List<_Column> columns, double tolerance) {
    for (var i = 0; i < columns.length; i++) {
      if ((line.left - columns[i].left).abs() <= tolerance) return i;
    }
    return -1;
  }
}

class _Column {
  double left;
  double right;
  _Column(this.left, this.right);

  void absorb(OcrLine cell) {
    left = math.min(left, cell.left);
    right = math.max(right, cell.left + cell.width);
  }
}
