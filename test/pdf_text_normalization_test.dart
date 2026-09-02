import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/export/pdf_tools.dart';

void main() {
  group('Normalizacion del texto extraido de un PDF', () {
    test('rehace las frases cuando viene una palabra por linea', () {
      // Asi es como sale de muchos PDF: cada palabra en su propia linea.
      const fragmented = 'Estimado\ncliente\nle\nenviamos\nel\ndetalle\n'
          'de\nsu\npedido\nde\neste\nmes\n';
      final result = PdfTools.normalizeExtractedText(fragmented);

      expect(result, contains('Estimado cliente le enviamos'));
      expect(result.split('\n').length, lessThan(4),
          reason: 'no deberia quedar una palabra por linea');
    });

    test('respeta un texto que ya viene en parrafos', () {
      const normal = 'Estimado cliente:\n'
          'Le enviamos el detalle de su pedido.\n'
          'Un saludo cordial.';
      expect(PdfTools.normalizeExtractedText(normal), normal);
    });

    test('no toca un texto corto aunque tenga lineas de una palabra', () {
      // Un titulo suelto no es texto fragmentado.
      const short = 'FACTURA\n2026';
      expect(PdfTools.normalizeExtractedText(short), short);
    });

    test('el texto vacio se queda vacio', () {
      expect(PdfTools.normalizeExtractedText(''), '');
      expect(PdfTools.normalizeExtractedText('   \n  \n'), '');
    });

    test('quita los saltos de carro de Windows', () {
      final result = PdfTools.normalizeExtractedText('uno\r\ndos\r\ntres');
      expect(result, isNot(contains('\r')));
    });

    test('conserva todas las palabras', () {
      const fragmented = 'importe\ntotal\nde\nla\nfactura\ncon\nimpuestos\n'
          'incluidos\nsegun\nel\ndetalle\nadjunto\n';
      final result = PdfTools.normalizeExtractedText(fragmented);
      for (final word in fragmented.trim().split('\n')) {
        expect(result, contains(word), reason: 'se ha perdido "$word"');
      }
    });

    test('un texto mixto no pierde el contenido', () {
      const mixed = 'CAPITULO\nPRIMERO\n'
          'En un lugar de la Mancha de cuyo nombre no quiero acordarme.\n';
      final result = PdfTools.normalizeExtractedText(mixed);
      expect(result, contains('CAPITULO'));
      expect(result, contains('En un lugar de la Mancha'));
    });
  });
}
