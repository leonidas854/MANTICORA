import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/failure.dart';
import 'package:manticora/export/pdf_builder.dart';
import 'package:manticora/export/pdf_tools.dart';
import 'package:manticora/imaging/ocr_service.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import 'support/document_fixtures.dart';

/// Crea un PDF de [pages] paginas, cada una con una imagen distinta.
Future<Uint8List> makePdf(int pages, {String title = 'Prueba'}) async {
  final inputs = <PdfPageInput>[];
  for (var i = 0; i < pages; i++) {
    final page = DocumentFixtures.renderPage(width: 300, height: 420, withTable: false);
    inputs.add(PdfPageInput(
      jpeg: DocumentFixtures.encodeJpeg(page, quality: 70),
      imageWidth: 300,
      imageHeight: 420,
      ocrLines: [OcrLine('Pagina ${i + 1}', 30, 30, 120, 16)],
    ));
  }
  return PdfBuilder.build(pages: inputs, title: title, pageSize: PdfPageSize.a4);
}

/// Texto extraible de un PDF, para comprobar que las paginas son las esperadas.
///
/// El extractor separa cada palabra con un salto de linea, asi que se
/// normaliza a espacios antes de comparar.
List<String> textOf(Uint8List pdf, {String? password}) => PdfTools
    .extractText(pdf, password: password)
    .map((t) => t.replaceAll(RegExp(r'\s+'), ' ').trim())
    .toList();

void main() {
  group('Creacion de PDF', () {
    test('genera un PDF valido con el numero de paginas pedido', () async {
      final pdf = await makePdf(3);
      expect(pdf.length, greaterThan(1000));
      expect(String.fromCharCodes(pdf.take(4)), '%PDF');
      expect(PdfTools.pageCount(pdf), 3);
    });

    test('la capa de texto invisible queda incrustada y es buscable', () async {
      final pdf = await makePdf(2);
      final text = textOf(pdf).join(' ');
      expect(text, contains('Pagina 1'));
      expect(text, contains('Pagina 2'));
    });

    test('rechaza una lista de paginas vacia', () async {
      expect(
        () => PdfBuilder.build(pages: const []),
        throwsA(isA<AppFailure>()),
      );
    });
  });

  group('Unir', () {
    test('une dos documentos y conserva todas las paginas', () async {
      final a = await makePdf(2, title: 'A');
      final b = await makePdf(3, title: 'B');
      final merged = await PdfTools.merge([a, b]);

      expect(PdfTools.pageCount(merged), 5);
    });

    test('une tres documentos', () async {
      final merged = await PdfTools.merge([
        await makePdf(1),
        await makePdf(2),
        await makePdf(1),
      ]);
      expect(PdfTools.pageCount(merged), 4);
    });

    test('exige al menos dos ficheros', () async {
      expect(
        () => PdfTools.merge([Uint8List.fromList([0x25, 0x50, 0x44, 0x46])]),
        throwsA(isA<AppFailure>()),
      );
    });

    test('rechaza bytes que no son un PDF', () async {
      final basura = Uint8List.fromList(List.filled(2048, 65));
      expect(
        () => PdfTools.merge([basura, basura]),
        throwsA(isA<AppFailure>()),
      );
    });
  });

  group('Extraer y dividir', () {
    test('extrae solo las paginas pedidas', () async {
      final pdf = await makePdf(5);
      final extracted = await PdfTools.extractPages(pdf, [0, 2, 4]);

      expect(PdfTools.pageCount(extracted), 3);
      final text = textOf(extracted).join(' ');
      expect(text, contains('Pagina 1'));
      expect(text, contains('Pagina 3'));
      expect(text, contains('Pagina 5'));
      expect(text, isNot(contains('Pagina 2')));
    });

    test('ignora indices fuera de rango pero conserva los validos', () async {
      final pdf = await makePdf(3);
      final extracted = await PdfTools.extractPages(pdf, [0, 99]);
      expect(PdfTools.pageCount(extracted), 1);
    });

    test('sin paginas validas avisa en vez de crear un PDF vacio', () async {
      final pdf = await makePdf(2);
      expect(
        () => PdfTools.extractPages(pdf, [50, 60]),
        throwsA(isA<AppFailure>()),
      );
    });

    test('divide en bloques del tamano indicado', () async {
      final pdf = await makePdf(5);
      final parts = await PdfTools.splitEvery(pdf, 2);

      expect(parts, hasLength(3));
      expect(PdfTools.pageCount(parts[0]), 2);
      expect(PdfTools.pageCount(parts[1]), 2);
      expect(PdfTools.pageCount(parts[2]), 1);
    });

    test('no divide si el bloque abarca todo el documento', () async {
      final pdf = await makePdf(3);
      expect(() => PdfTools.splitEvery(pdf, 5), throwsA(isA<AppFailure>()));
    });

    test('rechaza un tamano de bloque absurdo', () async {
      final pdf = await makePdf(3);
      expect(() => PdfTools.splitEvery(pdf, 0), throwsA(isA<AppFailure>()));
    });
  });

  group('Eliminar y reordenar', () {
    test('elimina las paginas indicadas', () async {
      final pdf = await makePdf(4);
      final result = await PdfTools.deletePages(pdf, {1, 2});

      expect(PdfTools.pageCount(result), 2);
      final text = textOf(result).join(' ');
      expect(text, contains('Pagina 1'));
      expect(text, contains('Pagina 4'));
      expect(text, isNot(contains('Pagina 2')));
    });

    test('no deja borrar todas las paginas', () async {
      final pdf = await makePdf(2);
      expect(
        () => PdfTools.deletePages(pdf, {0, 1}),
        throwsA(isA<AppFailure>()),
      );
    });

    test('reordena las paginas segun la lista dada', () async {
      final pdf = await makePdf(3);
      final result = await PdfTools.reorderPages(pdf, [2, 0, 1]);

      expect(PdfTools.pageCount(result), 3);
      final pages = textOf(result);
      expect(pages[0], contains('Pagina 3'));
      expect(pages[1], contains('Pagina 1'));
      expect(pages[2], contains('Pagina 2'));
    });

    test('un orden vacio se rechaza', () async {
      final pdf = await makePdf(2);
      expect(() => PdfTools.reorderPages(pdf, const []), throwsA(isA<AppFailure>()));
    });
  });

  group('Girar', () {
    Future<sf.PdfPageRotateAngle> rotationOf(Uint8List pdf, int index) async {
      final doc = sf.PdfDocument(inputBytes: pdf);
      final angle = doc.pages[index].rotation;
      doc.dispose();
      return angle;
    }

    test('gira todas las paginas 90 grados', () async {
      final pdf = await makePdf(2);
      final rotated = await PdfTools.rotatePages(pdf, const {}, 1);

      expect(await rotationOf(rotated, 0), sf.PdfPageRotateAngle.rotateAngle90);
      expect(await rotationOf(rotated, 1), sf.PdfPageRotateAngle.rotateAngle90);
    });

    test('gira solo las paginas seleccionadas', () async {
      final pdf = await makePdf(3);
      final rotated = await PdfTools.rotatePages(pdf, {1}, 2);

      expect(await rotationOf(rotated, 0), sf.PdfPageRotateAngle.rotateAngle0);
      expect(await rotationOf(rotated, 1), sf.PdfPageRotateAngle.rotateAngle180);
      expect(await rotationOf(rotated, 2), sf.PdfPageRotateAngle.rotateAngle0);
    });

    test('un giro completo deja el documento como estaba', () async {
      final pdf = await makePdf(1);
      final rotated = await PdfTools.rotatePages(pdf, const {}, 4);
      expect(await rotationOf(rotated, 0), sf.PdfPageRotateAngle.rotateAngle0);
    });
  });

  group('Contrasena', () {
    test('protege el PDF y deja de abrirse sin la clave', () async {
      final pdf = await makePdf(2);
      final protected = await PdfTools.protect(pdf, userPassword: 'secreta');

      expect(PdfTools.needsPassword(protected), isTrue);
      expect(PdfTools.pageCount(protected, password: 'secreta'), 2);
    });

    test('con la contrasena correcta se lee el contenido', () async {
      final protected =
          await PdfTools.protect(await makePdf(1), userPassword: 'clave1234');
      expect(textOf(protected, password: 'clave1234').join(), contains('Pagina 1'));
    });

    test('una contrasena incorrecta da un error claro', () async {
      final protected =
          await PdfTools.protect(await makePdf(1), userPassword: 'buena');
      expect(
        () => PdfTools.pageCount(protected, password: 'mala'),
        throwsA(isA<AppFailure>()
            .having((f) => f.kind, 'tipo', FailureKind.pdf)
            .having((f) => f.retryable, 'reintentable', isFalse)),
      );
    });

    test('quitar la proteccion devuelve un PDF abierto', () async {
      final protected =
          await PdfTools.protect(await makePdf(2), userPassword: 'abrir');
      final open = await PdfTools.removeProtection(protected, 'abrir');

      expect(PdfTools.needsPassword(open), isFalse);
      expect(PdfTools.pageCount(open), 2);
    });

    test('rechaza contrasenas demasiado cortas', () async {
      final pdf = await makePdf(1);
      expect(
        () => PdfTools.protect(pdf, userPassword: 'ab'),
        throwsA(isA<AppFailure>()),
      );
    });

    test('quitar proteccion sin contrasena se rechaza', () async {
      final pdf = await makePdf(1);
      expect(
        () => PdfTools.removeProtection(pdf, ''),
        throwsA(isA<AppFailure>()),
      );
    });
  });

  group('Lectura', () {
    test('cuenta las paginas', () async {
      expect(PdfTools.pageCount(await makePdf(7)), 7);
    });

    test('detecta si hace falta contrasena', () async {
      expect(PdfTools.needsPassword(await makePdf(1)), isFalse);
    });

    test('extrae una entrada de texto por pagina', () async {
      final text = textOf(await makePdf(4));
      expect(text, hasLength(4));
    });

    test('un fichero corrupto da un fallo entendible', () {
      final basura = Uint8List.fromList(List.filled(1024, 7));
      expect(
        () => PdfTools.pageCount(basura),
        throwsA(isA<AppFailure>().having((f) => f.message, 'mensaje',
            contains('PDF'))),
      );
    });
  });

  group('Cadena completa de operaciones', () {
    test('unir, extraer, girar y proteger encadenados', () async {
      // Es el recorrido real de alguien montando un expediente.
      final merged = await PdfTools.merge([await makePdf(2), await makePdf(3)]);
      expect(PdfTools.pageCount(merged), 5);

      final selection = await PdfTools.extractPages(merged, [0, 1, 4]);
      expect(PdfTools.pageCount(selection), 3);

      final rotated = await PdfTools.rotatePages(selection, const {}, 1);
      expect(PdfTools.pageCount(rotated), 3);

      final protected = await PdfTools.protect(rotated, userPassword: 'final123');
      expect(PdfTools.needsPassword(protected), isTrue);
      expect(PdfTools.pageCount(protected, password: 'final123'), 3);
    });

    test('el texto sobrevive a toda la cadena', () async {
      final merged = await PdfTools.merge([await makePdf(2), await makePdf(2)]);
      final reordered = await PdfTools.reorderPages(merged, [3, 2, 1, 0]);
      final text = textOf(reordered);
      expect(text.first, contains('Pagina 2'));
      expect(text.last, contains('Pagina 1'));
    });
  });
}
