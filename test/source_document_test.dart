import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/failure.dart';
import 'package:manticora/import/source_document.dart';

void main() {
  group('SourceDocumentReader', () {
    test('detecta DOCX por su contenido aunque la extension sea incorrecta', () {
      final bytes = _officeZip({
        'word/document.xml': _wordXml([
          '<w:p><w:r><w:t>Informe trimestral</w:t></w:r></w:p>',
        ]),
      });

      expect(
        SourceDocumentReader.detectType(bytes, fileName: 'engaño.bin'),
        SourceDocumentType.word,
      );
    });

    test('lee parrafos, saltos de pagina y tablas de un DOCX real', () {
      final bytes = _officeZip({
        'word/document.xml': _wordXml([
          '<w:p><w:r><w:t>Resumen anual</w:t></w:r></w:p>',
          '<w:tbl>'
              '<w:tr><w:tc><w:p><w:r><w:t>Producto</w:t></w:r></w:p></w:tc>'
              '<w:tc><w:p><w:r><w:t>Cantidad</w:t></w:r></w:p></w:tc></w:tr>'
              '<w:tr><w:tc><w:p><w:r><w:t>Cuadernos</w:t></w:r></w:p></w:tc>'
              '<w:tc><w:p><w:r><w:t>25</w:t></w:r></w:p></w:tc></w:tr>'
              '</w:tbl>',
          '<w:p><w:r><w:br w:type="page"/></w:r></w:p>',
          '<w:p><w:r><w:t>Conclusiones &amp; acciones</w:t></w:r></w:p>',
        ]),
      });

      final document = SourceDocumentReader.read(
        bytes,
        fileName: 'informe.docx',
      );

      expect(document.type, SourceDocumentType.word);
      expect(document.pages, hasLength(2));
      expect(document.pages.first.text, contains('Resumen anual'));
      expect(document.pages.first.text, contains('Producto\tCantidad'));
      expect(document.pages.first.text, contains('Cuadernos\t25'));
      expect(document.pages.last.text, contains('Conclusiones & acciones'));
    });

    test('ordena numericamente y conserva el texto de las diapositivas PPTX', () {
      final bytes = _officeZip({
        'ppt/presentation.xml': '<p:presentation '
            'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"/>',
        'ppt/slides/slide10.xml': _slideXml('Decima', 'Cierre'),
        'ppt/slides/slide2.xml': _slideXml('Segunda', 'Datos y tabla'),
        'ppt/slides/slide1.xml': _slideXml('Primera', 'Introduccion'),
      });

      final document = SourceDocumentReader.read(
        bytes,
        fileName: 'presentacion.pptx',
      );

      expect(document.type, SourceDocumentType.presentation);
      expect(document.pages.map((p) => p.title), ['Primera', 'Segunda', 'Decima']);
      expect(document.pages[1].text, contains('Datos y tabla'));
    });

    test('rechaza un ZIP que no sea Word ni PowerPoint con mensaje claro', () {
      final bytes = _officeZip({'datos.txt': 'no es un documento'});

      expect(
        () => SourceDocumentReader.read(bytes, fileName: 'archivo.zip'),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            contains('Word ni PowerPoint'),
          ),
        ),
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
