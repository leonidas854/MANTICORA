import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/page_ranges.dart';

void main() {
  group('parsePageRanges', () {
    test('acepta paginas sueltas y rangos, y devuelve indices desde 0', () {
      expect(parsePageRanges('1-3,5', 10), [0, 1, 2, 4]);
      expect(parsePageRanges('2', 10), [1]);
      expect(parsePageRanges('1 3 5', 10), [0, 2, 4]);
    });

    test('ordena y elimina duplicados', () {
      expect(parsePageRanges('5,1-2,1', 10), [0, 1, 4]);
    });

    test('rechaza paginas fuera del documento', () {
      expect(parsePageRanges('11', 10), isNull);
      expect(parsePageRanges('0', 10), isNull);
      expect(parsePageRanges('8-12', 10), isNull);
    });

    test('rechaza rangos invertidos y basura', () {
      expect(parsePageRanges('5-2', 10), isNull);
      expect(parsePageRanges('abc', 10), isNull);
      expect(parsePageRanges('1-2-3', 10), isNull);
      expect(parsePageRanges('', 10), isNull);
    });
  });
}
