import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/failure.dart';
import 'package:manticora/core/validators.dart';

void main() {
  group('titulos', () {
    test('rechaza vacios y solo espacios', () {
      expect(Validators.title(null), isNotNull);
      expect(Validators.title(''), isNotNull);
      expect(Validators.title('   '), isNotNull);
    });

    test('acepta uno normal', () {
      expect(Validators.title('Factura de marzo'), isNull);
    });

    test('rechaza los demasiado largos', () {
      expect(Validators.title('a' * 200), isNotNull);
    });
  });

  group('contrasenas', () {
    test('rechaza vacia y demasiado corta', () {
      expect(Validators.password(''), isNotNull);
      expect(Validators.password('abc'), isNotNull);
    });

    test('acepta una razonable', () {
      expect(Validators.password('secreta'), isNull);
    });

    test('rechaza las que superan el limite del formato PDF', () {
      expect(Validators.password('x' * 200), isNotNull);
    });
  });

  group('nombres de fichero', () {
    test('sustituye los caracteres prohibidos', () {
      final name = Validators.safeFileName('a/b:c*d?e"f<g>h|i', 'pdf');
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains(':')));
      expect(name, isNot(contains('*')));
      expect(name.endsWith('.pdf'), isTrue);
    });

    test('nunca devuelve un nombre vacio', () {
      expect(Validators.safeFileName('   ', 'pdf'), 'documento.pdf');
      expect(Validators.safeFileName('...', 'pdf'), 'documento.pdf');
    });

    test('recorta los nombres larguisimos', () {
      final name = Validators.safeFileName('n' * 300, 'docx');
      expect(name.length, lessThanOrEqualTo(86));
      expect(name.endsWith('.docx'), isTrue);
    });

    test('escapa los nombres reservados del sistema', () {
      expect(Validators.safeFileName('con', 'pdf'), '_con.pdf');
    });
  });

  group('bytes de PDF', () {
    test('rechaza vacios', () {
      expect(Validators.pdfBytes(null), isNotNull);
      expect(Validators.pdfBytes(Uint8List(0)), isNotNull);
    });

    test('rechaza lo que no empieza por %PDF', () {
      final fake = Uint8List.fromList('esto no es un pdf'.codeUnits);
      final failure = Validators.pdfBytes(fake);
      expect(failure, isNotNull);
      expect(failure!.kind, FailureKind.validation);
    });

    test('acepta una cabecera valida', () {
      final good = Uint8List.fromList([0x25, 0x50, 0x44, 0x46, ...List.filled(64, 0)]);
      expect(Validators.pdfBytes(good), isNull);
    });
  });

  group('bytes de imagen', () {
    test('rechaza vacios', () {
      expect(Validators.imageBytes(Uint8List(0)), isNotNull);
    });

    test('acepta una cabecera JPEG', () {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(64, 0)]);
      expect(Validators.imageBytes(jpeg), isNull);
    });

    test('acepta una cabecera PNG', () {
      final png = Uint8List.fromList(
          [0x89, 0x50, 0x4E, 0x47, ...List.filled(64, 0)]);
      expect(Validators.imageBytes(png), isNull);
    });

    test('rechaza lo demasiado pequeno para ser una imagen', () {
      expect(Validators.imageBytes(Uint8List.fromList([1, 2, 3])), isNotNull);
    });
  });

  group('limites', () {
    test('avisa cuando hay mas paginas de las que caben', () {
      expect(Validators.pageLimit(10, 60), isNull);
      final failure = Validators.pageLimit(200, 60);
      expect(failure, isNotNull);
      expect(failure!.message, contains('60'));
    });

    test('exige un minimo de ficheros', () {
      expect(Validators.minimumFiles(2, 2, 'unir'), isNull);
      expect(Validators.minimumFiles(1, 2, 'unir'), isNotNull);
    });

    test('rechaza documentos sin paginas', () {
      expect(Validators.nonEmptyPages(0), isNotNull);
      expect(Validators.nonEmptyPages(3), isNull);
    });

    test('rechaza ficheros vacios o desmesurados', () {
      expect(Validators.fileSize(0), isNotNull);
      expect(Validators.fileSize(1024), isNull);
      expect(Validators.fileSize(300 * 1024 * 1024), isNotNull);
    });
  });
}
