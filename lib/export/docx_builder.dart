import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Que se vuelca en el documento de Word.
enum DocxMode {
  textAndImages('Texto e imagenes'),
  textOnly('Solo texto (OCR)'),
  imagesOnly('Solo imagenes');

  final String label;
  const DocxMode(this.label);
}

/// Una pagina de entrada para el .docx.
class DocxPageInput {
  final Uint8List? jpeg;
  final int imageWidth, imageHeight;
  final String text;

  const DocxPageInput({
    this.jpeg,
    this.imageWidth = 0,
    this.imageHeight = 0,
    this.text = '',
  });
}

/// Genera un .docx (OOXML) valido sin dependencias externas ni conexion.
///
/// Un .docx es un ZIP con un conjunto de partes XML relacionadas entre si.
/// Aqui se escriben a mano las minimas necesarias para que Word, LibreOffice
/// y Google Docs lo abran correctamente.
class DocxBuilder {
  /// 914400 EMU por pulgada; a 96 ppp cada pixel son 9525 EMU.
  static const int _emuPerPixel = 9525;

  /// Ancho util de una A4 con margenes de 2 cm, en EMU.
  static const int _contentWidthEmu = 5943600;

  static Uint8List build({
    required List<DocxPageInput> pages,
    String title = 'Documento',
    DocxMode mode = DocxMode.textAndImages,
    bool pageBreakBetweenPages = true,
  }) {
    final archive = Archive();
    final body = StringBuffer();
    final imageRels = StringBuffer();
    final imageTypes = <String>{};
    var imageIndex = 0;

    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];

      if (mode != DocxMode.textOnly && page.jpeg != null) {
        imageIndex++;
        final name = 'image$imageIndex.jpeg';
        final rid = 'rIdImg$imageIndex';
        archive.addFile(
          ArchiveFile('word/media/$name', page.jpeg!.length, page.jpeg!),
        );
        imageTypes.add('jpeg');
        imageRels.writeln(
          '<Relationship Id="$rid" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/$name"/>',
        );

        var w = page.imageWidth > 0 ? page.imageWidth : 1200;
        var h = page.imageHeight > 0 ? page.imageHeight : 1600;
        var cx = w * _emuPerPixel, cy = h * _emuPerPixel;
        if (cx > _contentWidthEmu) {
          cy = (cy * _contentWidthEmu / cx).round();
          cx = _contentWidthEmu;
        }
        body.write(_imageParagraph(imageIndex, rid, cx, cy));
      }

      if (mode != DocxMode.imagesOnly && page.text.trim().isNotEmpty) {
        if (mode == DocxMode.textAndImages) {
          body.write(_heading('Pagina ${i + 1}'));
        }
        for (final line in const LineSplitter().convert(page.text)) {
          body.write(_paragraph(line));
        }
      }

      if (pageBreakBetweenPages && i < pages.length - 1) {
        body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
      }
    }

    if (body.isEmpty) body.write(_paragraph(''));

    _addString(archive, '[Content_Types].xml', _contentTypes(imageTypes));
    _addString(archive, '_rels/.rels', _rootRels());
    _addString(
      archive,
      'word/_rels/document.xml.rels',
      _documentRels(imageRels.toString()),
    );
    _addString(archive, 'word/document.xml', _document(body.toString()));
    _addString(archive, 'word/styles.xml', _styles());
    _addString(archive, 'docProps/core.xml', _coreProps(title));
    _addString(archive, 'docProps/app.xml', _appProps());

    final encoded = ZipEncoder().encode(archive);
    return Uint8List.fromList(encoded);
  }

  static void _addString(Archive a, String path, String content) {
    final bytes = utf8.encode(content);
    a.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  // -------------------------------------------------------------- fragmentos

  static String _imageParagraph(int id, String rid, int cx, int cy) =>
      '''
<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing>
<wp:inline distT="0" distB="0" distL="0" distR="0">
<wp:extent cx="$cx" cy="$cy"/>
<wp:effectExtent l="0" t="0" r="0" b="0"/>
<wp:docPr id="$id" name="Imagen $id"/>
<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>
<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
<pic:pic>
<pic:nvPicPr><pic:cNvPr id="$id" name="Imagen $id"/><pic:cNvPicPr/></pic:nvPicPr>
<pic:blipFill><a:blip r:embed="$rid"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>
<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
</pic:pic>
</a:graphicData></a:graphic>
</wp:inline>
</w:drawing></w:r></w:p>''';

  static String _paragraph(String text) =>
      '<w:p><w:r><w:t xml:space="preserve">${_esc(text)}</w:t></w:r></w:p>';

  static String _heading(String text) =>
      '<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t xml:space="preserve">${_esc(text)}</w:t></w:r></w:p>';

  static String _esc(String s) {
    final buf = StringBuffer();
    for (final rune in s.runes) {
      // XML 1.0 prohibe la mayoria de caracteres de control.
      if (rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D) continue;
      switch (rune) {
        case 0x26:
          buf.write('&amp;');
        case 0x3C:
          buf.write('&lt;');
        case 0x3E:
          buf.write('&gt;');
        case 0x22:
          buf.write('&quot;');
        case 0x27:
          buf.write('&apos;');
        default:
          buf.writeCharCode(rune);
      }
    }
    return buf.toString();
  }

  static String _contentTypes(Set<String> imageExts) {
    final defaults = StringBuffer()
      ..write(
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
      )
      ..write('<Default Extension="xml" ContentType="application/xml"/>');
    for (final e in imageExts) {
      defaults.write('<Default Extension="$e" ContentType="image/$e"/>');
    }
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
$defaults
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>''';
  }

  static String _rootRels() =>
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>''';

  static String _documentRels(String imageRels) =>
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
$imageRels
</Relationships>''';

  static String _document(String body) =>
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document
  xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
  xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
  xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
<w:body>
$body
<w:sectPr>
<w:pgSz w:w="11906" w:h="16838"/>
<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="709" w:footer="709" w:gutter="0"/>
</w:sectPr>
</w:body>
</w:document>''';

  static String _styles() =>
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:docDefaults>
<w:rPrDefault><w:rPr>
<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>
<w:sz w:val="22"/><w:szCs w:val="22"/>
</w:rPr></w:rPrDefault>
<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>
</w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal">
<w:name w:val="Normal"/><w:qFormat/>
</w:style>
<w:style w:type="paragraph" w:styleId="Heading2">
<w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:qFormat/>
<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="1"/></w:pPr>
<w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr>
</w:style>
</w:styles>''';

  static String _coreProps(String title) {
    final now = '${DateTime.now().toUtc().toIso8601String().split('.').first}Z';
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties
  xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
  xmlns:dc="http://purl.org/dc/elements/1.1/"
  xmlns:dcterms="http://purl.org/dc/terms/"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<dc:title>${_esc(title)}</dc:title>
<dc:creator>Manticora</dc:creator>
<cp:lastModifiedBy>Manticora</cp:lastModifiedBy>
<dcterms:created xsi:type="dcterms:W3CDTF">$now</dcterms:created>
<dcterms:modified xsi:type="dcterms:W3CDTF">$now</dcterms:modified>
</cp:coreProperties>''';
  }

  static String _appProps() =>
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties
  xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
  xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
<Application>Manticora</Application>
</Properties>''';
}
