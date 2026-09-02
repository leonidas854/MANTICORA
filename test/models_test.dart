import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/data/models/models.dart';
import 'package:manticora/imaging/filters.dart';
import 'package:manticora/imaging/geometry.dart';

Map<String, Object?> _pageRow({
  Object? quad,
  Object? adjustments,
  Object? rotation = 0,
  Object? position = 0,
}) =>
    {
      'id': 'p1',
      'document_id': 'd1',
      'position': position,
      'original_file': 'docs/d1/orig_p1.jpg',
      'processed_file': 'docs/d1/page_p1.jpg',
      'thumb_file': 'docs/d1/thumb_p1.jpg',
      'quad': quad,
      'filter': 'magic',
      'adjustments': adjustments,
      'rotation': rotation,
      'width': 100,
      'height': 200,
      'ocr_text': null,
      'ocr_boxes': null,
    };

void main() {
  group('ScanPage.fromMap resiste datos corruptos', () {
    test('un cuadrilatero ilegible no impide leer la pagina', () {
      final page = ScanPage.fromMap(_pageRow(quad: '{esto no es json'));
      expect(page.quad, isNull);
      expect(page.id, 'p1');
    });

    test('unos ajustes ilegibles caen en los neutros', () {
      final page = ScanPage.fromMap(_pageRow(adjustments: 'basura'));
      expect(page.adjustments.isIdentity, isTrue);
    });

    test('un JSON valido pero con forma inesperada no rompe', () {
      final page = ScanPage.fromMap(_pageRow(quad: '[1,2,3]', adjustments: '[]'));
      expect(page.quad, isNull);
      expect(page.adjustments.isIdentity, isTrue);
    });

    test('acepta numeros guardados como decimales', () {
      final page = ScanPage.fromMap(_pageRow(rotation: 2.0, position: 3.0));
      expect(page.rotation, 2);
      expect(page.position, 3);
    });

    test('lee correctamente un cuadrilatero valido', () {
      final quad = Quad.full(100, 200);
      final page = ScanPage.fromMap(_pageRow(
        quad: ScanPage(
          id: 'x',
          documentId: 'd',
          position: 0,
          originalFile: 'a',
          processedFile: 'b',
          thumbFile: 'c',
          quad: quad,
        ).toMap()['quad'],
      ));
      expect(page.quad, isNotNull);
      expect(page.quad!.br.x, closeTo(100, 1e-9));
    });

    test('conserva el filtro guardado y cae en magic si no lo reconoce', () {
      final row = _pageRow()..['filter'] = 'blackWhite';
      expect(ScanPage.fromMap(row).filter, ScanFilter.blackWhite);
      final bad = _pageRow()..['filter'] = 'inventado';
      expect(ScanPage.fromMap(bad).filter, ScanFilter.magic);
    });
  });

  group('ScanDocument.fromMap', () {
    Map<String, Object?> row() => {
          'id': 'd1',
          'title': 'Factura',
          'folder_id': null,
          'created_at': 1700000000000,
          'updated_at': 1700000001000,
          'tags': 'casa,banco',
          'favorite': 1,
          'deleted_at': null,
          'page_count': 3,
          'cover_thumb': 'docs/d1/thumb_p1.jpg',
        };

    test('lee las etiquetas separadas por comas', () {
      expect(ScanDocument.fromMap(row()).tags, ['casa', 'banco']);
    });

    test('interpreta el favorito y el recuento de paginas', () {
      final doc = ScanDocument.fromMap(row());
      expect(doc.favorite, isTrue);
      expect(doc.pageCount, 3);
      expect(doc.isDeleted, isFalse);
    });

    test('una fecha ausente no revienta la lectura', () {
      final bad = row()..['created_at'] = null;
      expect(() => ScanDocument.fromMap(bad), returnsNormally);
    });

    test('etiquetas vacias no generan entradas fantasma', () {
      final bad = row()..['tags'] = ',, ,';
      expect(ScanDocument.fromMap(bad).tags, isEmpty);
    });
  });

  group('DocumentWithPages', () {
    test('combina el texto de las paginas que tienen OCR', () {
      final doc = DocumentWithPages(
        ScanDocument.fromMap({
          'id': 'd',
          'title': 't',
          'created_at': 0,
          'updated_at': 0,
          'tags': '',
          'favorite': 0,
          'deleted_at': null,
        }),
        [
          ScanPage.fromMap(_pageRow()..['ocr_text'] = 'primera'),
          ScanPage.fromMap(_pageRow()..['ocr_text'] = '   '),
          ScanPage.fromMap(_pageRow()..['ocr_text'] = 'segunda'),
        ],
      );
      expect(doc.combinedText, 'primera\n\nsegunda');
    });
  });
}
