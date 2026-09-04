import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../core/failure.dart';
import '../core/validators.dart';

/// Formatos de documento que se pueden identificar sin confiar en la extension.
enum SourceDocumentType {
  pdf,
  word,
  presentation,
  unknown,
}

/// Una pagina logica del documento importado.
///
/// En DOCX solo se pueden conocer los saltos explicitos sin maquetar el fichero
/// con Word o LibreOffice. En PPTX una pagina corresponde a una diapositiva.
class SourceDocumentPage {
  final int number;
  final String title;
  final String text;

  const SourceDocumentPage({
    required this.number,
    required this.title,
    required this.text,
  });
}

/// Contenido textual neutral que luego puede alimentar voz, video o busqueda.
class SourceDocument {
  final SourceDocumentType type;
  final String fileName;
  final String title;
  final List<SourceDocumentPage> pages;

  const SourceDocument({
    required this.type,
    required this.fileName,
    required this.title,
    required this.pages,
  });

  String get text => pages
      .map((page) => page.text.trim())
      .where((value) => value.isNotEmpty)
      .join('\n\n');
}

/// Detecta y lee documentos Office sin extraer sus ficheros al disco.
///
/// La extension se usa unicamente para dar nombre al resultado. El tipo real
/// sale de la firma PDF o de las partes internas del ZIP OOXML.
class SourceDocumentReader {
  SourceDocumentReader._();

  static const int maxArchiveEntries = 2048;
  static const int maxArchiveExpandedBytes = 192 * 1024 * 1024;
  static const int maxXmlEntryBytes = 8 * 1024 * 1024;
  static const int maxXmlExpandedBytes = 48 * 1024 * 1024;
  static const int maxPresentationSlides = 1000;

  static const int _maxCompressionRatio = 250;
  static const int _ratioCheckFloor = 1024 * 1024;

  /// Identifica el formato por contenido. Un fichero desconocido no lanza una
  /// excepcion; un ZIP malformado o peligroso si, para que nunca se confunda
  /// con un documento simplemente no compatible.
  static SourceDocumentType detectType(
    Uint8List bytes, {
    String? fileName,
  }) {
    _validateInputSize(bytes);
    if (_looksLikePdf(bytes)) return SourceDocumentType.pdf;
    if (!_looksLikeZip(bytes)) return SourceDocumentType.unknown;

    final office = _SafeOfficeArchive.open(bytes, fileName: fileName);
    return _typeOf(office);
  }

  /// Lee texto y estructura basica de DOCX o PPTX.
  static SourceDocument read(
    Uint8List bytes, {
    required String fileName,
  }) {
    _validateInputSize(bytes);
    if (_looksLikePdf(bytes)) {
      throw const AppFailure(
        kind: FailureKind.unsupported,
        message: 'Este lector solo extrae Word y PowerPoint; usa las herramientas PDF para ese fichero.',
        retryable: false,
      );
    }
    if (!_looksLikeZip(bytes)) {
      throw const AppFailure(
        kind: FailureKind.document,
        message: 'El fichero no es un documento de Word ni PowerPoint compatible.',
        retryable: false,
      );
    }

    final office = _SafeOfficeArchive.open(bytes, fileName: fileName);
    final type = _typeOf(office);
    return switch (type) {
      SourceDocumentType.word => _readWord(office, fileName),
      SourceDocumentType.presentation => _readPresentation(office, fileName),
      _ => throw const AppFailure(
          kind: FailureKind.document,
          message: 'El archivo ZIP no es un documento de Word ni PowerPoint compatible.',
          retryable: false,
        ),
    };
  }

  static void _validateInputSize(Uint8List bytes) {
    final failure = Validators.fileSize(bytes.length, what: 'documento');
    if (failure != null) throw failure;
  }

  static bool _looksLikePdf(Uint8List bytes) {
    // ISO 32000 permite que la cabecera aparezca dentro de los primeros 1024
    // bytes. No se acepta una extension .pdf como sustituto de la firma.
    final limit = bytes.length < 1024 ? bytes.length : 1024;
    for (var i = 0; i + 4 < limit; i++) {
      if (bytes[i] == 0x25 &&
          bytes[i + 1] == 0x50 &&
          bytes[i + 2] == 0x44 &&
          bytes[i + 3] == 0x46 &&
          bytes[i + 4] == 0x2D) {
        return true;
      }
    }
    return false;
  }

  static bool _looksLikeZip(Uint8List bytes) {
    if (bytes.length < 4) return false;
    return bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        ((bytes[2] == 0x03 && bytes[3] == 0x04) ||
            (bytes[2] == 0x05 && bytes[3] == 0x06) ||
            (bytes[2] == 0x07 && bytes[3] == 0x08));
  }

  static SourceDocumentType _typeOf(_SafeOfficeArchive office) {
    final hasWord = office.contains('word/document.xml');
    final hasPresentation = office.contains('ppt/presentation.xml');

    if (hasWord && hasPresentation) {
      throw const AppFailure(
        kind: FailureKind.document,
        message: 'El ZIP mezcla contenido de Word y PowerPoint y no es un documento valido.',
        retryable: false,
      );
    }
    if (hasWord) return SourceDocumentType.word;
    if (hasPresentation) return SourceDocumentType.presentation;

    // Algunos productores anuncian primero el tipo en [Content_Types].xml.
    // Sirve para dar un diagnostico mejor aunque falte luego la parte principal.
    if (office.contains('[Content_Types].xml')) {
      final xml = office.readXml('[Content_Types].xml', what: 'tipos del documento');
      final contentTypes = xml.toLowerCase();
      if (contentTypes.contains('wordprocessingml.document.main+xml')) {
        throw const AppFailure(
          kind: FailureKind.document,
          message: 'El documento de Word esta incompleto: falta word/document.xml.',
          retryable: false,
        );
      }
      if (contentTypes.contains('presentationml.presentation.main+xml')) {
        throw const AppFailure(
          kind: FailureKind.document,
          message: 'La presentacion esta incompleta: falta ppt/presentation.xml.',
          retryable: false,
        );
      }
    }
    return SourceDocumentType.unknown;
  }

  // ------------------------------------------------------------------ DOCX

  static SourceDocument _readWord(_SafeOfficeArchive office, String fileName) {
    final xml = office.readXml('word/document.xml', what: 'contenido de Word');
    final document = _parseXml(xml, 'El contenido principal de Word esta dañado.');
    final bodies = document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'body')
        .toList();
    if (bodies.length != 1) {
      throw const AppFailure(
        kind: FailureKind.document,
        message: 'El documento de Word no contiene un cuerpo legible.',
        retryable: false,
      );
    }

    final output = _PageAccumulator();
    for (final child in bodies.single.childElements) {
      switch (child.name.local) {
        case 'p':
          _appendWordParagraph(child, output);
        case 'tbl':
          final table = _wordTableText(child);
          if (table.isNotEmpty) output.addBlock(table);
      }
    }

    final texts = output.finish();
    final pages = <SourceDocumentPage>[
      for (var i = 0; i < texts.length; i++)
        SourceDocumentPage(
          number: i + 1,
          title: _firstUsefulLine(texts[i], fallback: 'Pagina ${i + 1}'),
          text: texts[i],
        ),
    ];
    return SourceDocument(
      type: SourceDocumentType.word,
      fileName: fileName,
      title: _documentTitle(fileName, pages),
      pages: List.unmodifiable(pages),
    );
  }

  static void _appendWordParagraph(XmlElement paragraph, _PageAccumulator output) {
    if (_wordPageBreakBefore(paragraph) && output.hasContent) output.pageBreak();

    final buffer = StringBuffer();
    void flushText() {
      final value = buffer.toString().trim();
      buffer.clear();
      if (value.isNotEmpty) output.addBlock(value);
    }

    for (final element in paragraph.descendants.whereType<XmlElement>()) {
      switch (element.name.local) {
        case 't':
        case 'instrText':
          buffer.write(element.innerText);
        case 'tab':
          buffer.write('\t');
        case 'cr':
          buffer.write('\n');
        case 'br':
          if ((_attribute(element, 'type') ?? '').toLowerCase() == 'page') {
            flushText();
            output.pageBreak();
          } else {
            buffer.write('\n');
          }
        case 'lastRenderedPageBreak':
          flushText();
          output.pageBreak();
        case 'noBreakHyphen':
          buffer.write('-');
      }
    }
    flushText();

    if (_wordSectionBreakAfter(paragraph) && output.hasContent) output.pageBreak();
  }

  static bool _wordPageBreakBefore(XmlElement paragraph) {
    for (final element in paragraph.descendants.whereType<XmlElement>()) {
      if (element.name.local != 'pageBreakBefore') continue;
      final value = (_attribute(element, 'val') ?? 'true').toLowerCase();
      return value != 'false' && value != '0' && value != 'off';
    }
    return false;
  }

  static bool _wordSectionBreakAfter(XmlElement paragraph) {
    for (final section in paragraph.descendants.whereType<XmlElement>()) {
      if (section.name.local != 'sectPr') continue;
      final type = section.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'type')
          .firstOrNull;
      final value = (_attribute(type, 'val') ?? 'nextPage').toLowerCase();
      if (value == 'nextpage' || value == 'oddpage' || value == 'evenpage') {
        return true;
      }
    }
    return false;
  }

  static String _wordTableText(XmlElement table) {
    final rows = <String>[];
    for (final row in table.childElements.where((element) => element.name.local == 'tr')) {
      final cells = <String>[];
      for (final cell in row.childElements.where((element) => element.name.local == 'tc')) {
        final blocks = <String>[];
        for (final child in cell.childElements) {
          if (child.name.local == 'p') {
            final text = _wordParagraphPlainText(child);
            if (text.isNotEmpty) blocks.add(text);
          } else if (child.name.local == 'tbl') {
            final nested = _wordTableText(child);
            if (nested.isNotEmpty) blocks.add(nested);
          }
        }
        cells.add(blocks.join(' / ').trim());
      }
      if (cells.isNotEmpty) rows.add(cells.join('\t'));
    }
    return rows.join('\n').trim();
  }

  static String _wordParagraphPlainText(XmlElement paragraph) {
    final out = StringBuffer();
    for (final element in paragraph.descendants.whereType<XmlElement>()) {
      switch (element.name.local) {
        case 't':
        case 'instrText':
          out.write(element.innerText);
        case 'tab':
          out.write('\t');
        case 'br':
        case 'cr':
        case 'lastRenderedPageBreak':
          out.write(' ');
        case 'noBreakHyphen':
          out.write('-');
      }
    }
    return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ------------------------------------------------------------------ PPTX

  static SourceDocument _readPresentation(
    _SafeOfficeArchive office,
    String fileName,
  ) {
    final orderedPaths = _orderedSlidePaths(office);
    if (orderedPaths.length > maxPresentationSlides) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'La presentacion tiene ${orderedPaths.length} diapositivas y supera el limite de $maxPresentationSlides.',
        retryable: false,
      );
    }

    final pages = <SourceDocumentPage>[];
    for (final path in orderedPaths) {
      final xml = office.readXml(path, what: 'diapositiva');
      final slide = _parseXml(xml, 'Una diapositiva de PowerPoint esta dañada.');
      final extracted = _slideText(slide);
      pages.add(SourceDocumentPage(
        number: pages.length + 1,
        title: extracted.title.isEmpty
            ? 'Diapositiva ${pages.length + 1}'
            : extracted.title,
        text: extracted.text,
      ));
    }

    return SourceDocument(
      type: SourceDocumentType.presentation,
      fileName: fileName,
      title: _documentTitle(fileName, pages),
      pages: List.unmodifiable(pages),
    );
  }

  static List<String> _orderedSlidePaths(_SafeOfficeArchive office) {
    final available = office.names
        .where((name) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(name))
        .toList()
      ..sort((a, b) => _slideNumber(a).compareTo(_slideNumber(b)));
    if (available.isEmpty) return const [];

    if (!office.contains('ppt/_rels/presentation.xml.rels')) return available;
    final presentation = _parseXml(
      office.readXml('ppt/presentation.xml', what: 'orden de diapositivas'),
      'El orden de la presentacion esta dañado.',
    );
    final relationships = _parseXml(
      office.readXml(
        'ppt/_rels/presentation.xml.rels',
        what: 'relaciones de diapositivas',
      ),
      'Las relaciones de la presentacion estan dañadas.',
    );

    final targetById = <String, String>{};
    for (final relation in relationships.descendants.whereType<XmlElement>()) {
      if (relation.name.local != 'Relationship') continue;
      if ((_attribute(relation, 'TargetMode') ?? '').toLowerCase() == 'external') {
        continue;
      }
      final id = _attribute(relation, 'Id');
      final target = _attribute(relation, 'Target');
      if (id == null || target == null) continue;
      final resolved = _resolvePresentationTarget(target);
      if (resolved != null && available.contains(resolved)) targetById[id] = resolved;
    }

    final ordered = <String>[];
    for (final slideId in presentation.descendants.whereType<XmlElement>()) {
      if (slideId.name.local != 'sldId') continue;
      String? relationshipId;
      for (final attribute in slideId.attributes) {
        if (attribute.name.local == 'id' && attribute.name.prefix == 'r') {
          relationshipId = attribute.value;
          break;
        }
      }
      final target = targetById[relationshipId];
      if (target != null && !ordered.contains(target)) ordered.add(target);
    }
    return ordered.isEmpty ? available : ordered;
  }

  static String? _resolvePresentationTarget(String raw) {
    final target = raw.replaceAll('\\', '/');
    final resolved = target.startsWith('/')
        ? p.posix.normalize(target.substring(1))
        : p.posix.normalize(p.posix.join('ppt', target));
    if (resolved == '..' || resolved.startsWith('../') || p.posix.isAbsolute(resolved)) {
      return null;
    }
    return resolved;
  }

  static int _slideNumber(String path) =>
      int.tryParse(RegExp(r'slide(\d+)\.xml$').firstMatch(path)?.group(1) ?? '') ??
      0;

  static ({String title, String text}) _slideText(XmlDocument slide) {
    final blocks = <String>[];
    String? declaredTitle;

    final trees = slide.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'spTree');
    for (final tree in trees) {
      void visit(XmlElement element) {
        if (element.name.local == 'sp') {
          final values = _drawingParagraphs(element);
          if (values.isEmpty) return;
          if (_isTitleShape(element)) declaredTitle ??= values.first;
          blocks.addAll(values);
          return;
        }
        if (element.name.local == 'graphicFrame') {
          final tables = element.descendants
              .whereType<XmlElement>()
              .where((child) => child.name.local == 'tbl')
              .toList();
          if (tables.isNotEmpty) {
            final table = _presentationTableText(tables.first);
            if (table.isNotEmpty) blocks.add(table);
          } else {
            blocks.addAll(_drawingParagraphs(element));
          }
          return;
        }
        if (element.name.local == 'grpSp') {
          for (final child in element.childElements) {
            visit(child);
          }
        }
      }

      for (final child in tree.childElements) {
        visit(child);
      }
    }

    final clean = blocks.map(_cleanBlock).where((value) => value.isNotEmpty).toList();
    final title = _cleanBlock(declaredTitle ?? (clean.isEmpty ? '' : clean.first));
    return (title: _shortTitle(title), text: clean.join('\n'));
  }

  static bool _isTitleShape(XmlElement shape) {
    for (final placeholder in shape.descendants.whereType<XmlElement>()) {
      if (placeholder.name.local != 'ph') continue;
      final type = (_attribute(placeholder, 'type') ?? '').toLowerCase();
      if (type == 'title' || type == 'ctrtitle') return true;
    }
    return false;
  }

  static List<String> _drawingParagraphs(XmlElement root) {
    final out = <String>[];
    for (final paragraph in root.descendants.whereType<XmlElement>()) {
      if (paragraph.name.local != 'p') continue;
      final text = StringBuffer();
      for (final element in paragraph.descendants.whereType<XmlElement>()) {
        switch (element.name.local) {
          case 't':
            text.write(element.innerText);
          case 'br':
            text.write('\n');
          case 'tab':
            text.write('\t');
        }
      }
      final value = _cleanBlock(text.toString());
      if (value.isNotEmpty) out.add(value);
    }
    return out;
  }

  static String _presentationTableText(XmlElement table) {
    final rows = <String>[];
    for (final row in table.childElements.where((element) => element.name.local == 'tr')) {
      final cells = <String>[];
      for (final cell in row.childElements.where((element) => element.name.local == 'tc')) {
        cells.add(_drawingParagraphs(cell).join(' / '));
      }
      if (cells.isNotEmpty) rows.add(cells.join('\t'));
    }
    return rows.join('\n');
  }

  // --------------------------------------------------------------- helpers

  static XmlDocument _parseXml(String value, String message) {
    final lower = value.toLowerCase();
    if (lower.contains('<!doctype') || lower.contains('<!entity')) {
      throw AppFailure(
        kind: FailureKind.document,
        message: '$message No se permiten entidades XML externas.',
        retryable: false,
      );
    }
    try {
      return XmlDocument.parse(value);
    } catch (error, stackTrace) {
      throw AppFailure(
        kind: FailureKind.document,
        message: message,
        cause: error,
        stackTrace: stackTrace,
        retryable: false,
      );
    }
  }

  static String? _attribute(XmlElement? element, String localName) {
    if (element == null) return null;
    for (final attribute in element.attributes) {
      if (attribute.name.local == localName) return attribute.value;
    }
    return null;
  }

  static String _documentTitle(String fileName, List<SourceDocumentPage> pages) {
    final fromName = p.basenameWithoutExtension(fileName).trim();
    if (fromName.isNotEmpty) return fromName;
    if (pages.isNotEmpty && pages.first.title.trim().isNotEmpty) {
      return pages.first.title.trim();
    }
    return 'Documento';
  }

  static String _firstUsefulLine(String text, {required String fallback}) {
    for (final line in text.split('\n')) {
      final value = _cleanBlock(line);
      if (value.isNotEmpty) return _shortTitle(value);
    }
    return fallback;
  }

  static String _shortTitle(String value) =>
      value.length <= 160 ? value : '${value.substring(0, 157)}...';

  static String _cleanBlock(String value) => value
      .replaceAll('\u0000', '')
      .replaceAll(RegExp(r'[ \f\v]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .trim();
}

class _SafeOfficeArchive {
  final Map<String, ArchiveFile> _files;
  int _xmlBytesRead = 0;

  _SafeOfficeArchive._(this._files);

  Iterable<String> get names => _files.keys;
  bool contains(String name) => _files.containsKey(name);

  static _SafeOfficeArchive open(Uint8List bytes, {String? fileName}) {
    try {
      _preflightCentralDirectory(bytes);
      final decoder = ZipDecoder();
      final archive = decoder.decodeBytes(bytes);
      final headers = decoder.directory.fileHeaders;
      if (headers.length != decoder.directory.totalCentralDirectoryEntries) {
        throw const _UnsafeArchive('El directorio ZIP esta incompleto.');
      }

      var expanded = 0;
      final seen = <String>{};
      for (final header in headers) {
        final name = header.filename;
        _validatePartName(name);
        if (!seen.add(name.toLowerCase())) {
          throw const _UnsafeArchive('El ZIP contiene nombres de partes duplicados.');
        }
        if ((header.generalPurposeBitFlag & 0x1) != 0) {
          throw const _ProtectedOfficeArchive();
        }
        if (header.uncompressedSize < 0 || header.compressedSize < 0) {
          throw const _UnsafeArchive('El ZIP declara tamaños no validos.');
        }
        expanded += header.uncompressedSize;
        if (expanded > SourceDocumentReader.maxArchiveExpandedBytes) {
          throw const _UnsafeArchive('El contenido expandido del ZIP es demasiado grande.');
        }
        if (header.uncompressedSize >= SourceDocumentReader._ratioCheckFloor) {
          final compressed = header.compressedSize;
          if (compressed == 0 ||
              header.uncompressedSize ~/ compressed >
                  SourceDocumentReader._maxCompressionRatio) {
            throw const _UnsafeArchive('El ZIP tiene una relacion de compresion peligrosa.');
          }
        }
        if (header.compressionMethod != 0 &&
            header.compressionMethod != 8 &&
            header.compressionMethod != 12) {
          throw const _UnsafeArchive('El ZIP usa una compresion no compatible.');
        }
      }

      final files = <String, ArchiveFile>{};
      for (final file in archive.files) {
        if (file.isFile) files[file.name] = file;
      }
      return _SafeOfficeArchive._(files);
    } on AppFailure {
      rethrow;
    } on _ProtectedOfficeArchive catch (error, stackTrace) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'El documento de Office esta protegido con contraseña y no se puede leer.',
        cause: error,
        stackTrace: stackTrace,
        retryable: false,
      );
    } on _UnsafeArchive catch (error, stackTrace) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'No se puede abrir el documento: ${error.message}',
        cause: error,
        stackTrace: stackTrace,
        retryable: false,
      );
    } catch (error, stackTrace) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'No se puede abrir el documento de Word o PowerPoint: el ZIP esta dañado.',
        context: fileName,
        cause: error,
        stackTrace: stackTrace,
        retryable: false,
      );
    }
  }

  String readXml(String name, {required String what}) {
    final file = _files[name];
    if (file == null) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'El documento esta incompleto: falta $what.',
        retryable: false,
      );
    }
    if (file.size > SourceDocumentReader.maxXmlEntryBytes) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'No se puede leer $what: supera el limite de seguridad.',
        retryable: false,
      );
    }

    try {
      final output = _LimitedOutputStream(SourceDocumentReader.maxXmlEntryBytes);
      final raw = file.rawContent;
      if (raw == null) throw const _UnsafeArchive('Una parte del ZIP no tiene contenido.');
      final input = raw.getStream(decompress: false);
      switch (file.compression) {
        case CompressionType.none:
        case null:
          output.writeStream(input);
        case CompressionType.deflate:
          ZLibDecoder().decodeStream(input, output, raw: true);
        case CompressionType.bzip2:
          BZip2Decoder().decodeStream(input, output);
      }
      final decoded = output.getBytes();
      if (file.crc32 != null && getCrc32(decoded) != file.crc32) {
        throw const _UnsafeArchive('Una parte del ZIP no supera la comprobacion de integridad.');
      }
      _xmlBytesRead += decoded.length;
      if (_xmlBytesRead > SourceDocumentReader.maxXmlExpandedBytes) {
        throw const _UnsafeArchive('El XML expandido del documento es demasiado grande.');
      }
      return utf8.decode(decoded);
    } on AppFailure {
      rethrow;
    } on _UnsafeArchive catch (error, stackTrace) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'No se puede leer $what: ${error.message}',
        cause: error,
        stackTrace: stackTrace,
        retryable: false,
      );
    } catch (error, stackTrace) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'No se puede leer $what: esta dañado o usa una codificacion no compatible.',
        cause: error,
        stackTrace: stackTrace,
        retryable: false,
      );
    }
  }

  static void _preflightCentralDirectory(Uint8List bytes) {
    if (bytes.length < 22) throw const _UnsafeArchive('El ZIP esta incompleto.');
    final first = bytes.length > 65557 ? bytes.length - 65557 : 0;
    var offset = -1;
    for (var i = bytes.length - 22; i >= first; i--) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4B &&
          bytes[i + 2] == 0x05 &&
          bytes[i + 3] == 0x06) {
        offset = i;
        break;
      }
    }
    if (offset < 0) throw const _UnsafeArchive('Falta el directorio central del ZIP.');

    final data = ByteData.sublistView(bytes);
    final disk = data.getUint16(offset + 4, Endian.little);
    final startDisk = data.getUint16(offset + 6, Endian.little);
    final entriesOnDisk = data.getUint16(offset + 8, Endian.little);
    final entries = data.getUint16(offset + 10, Endian.little);
    final directorySize = data.getUint32(offset + 12, Endian.little);
    final directoryOffset = data.getUint32(offset + 16, Endian.little);
    final commentLength = data.getUint16(offset + 20, Endian.little);

    if (disk != 0 || startDisk != 0 || entriesOnDisk != entries) {
      throw const _UnsafeArchive('Los ZIP divididos en varios volumenes no son compatibles.');
    }
    if (entries == 0xFFFF) {
      throw const _UnsafeArchive('El ZIP64 supera los limites admitidos.');
    }
    if (entries > SourceDocumentReader.maxArchiveEntries) {
      throw _UnsafeArchive('El ZIP contiene $entries partes y supera el limite de ${SourceDocumentReader.maxArchiveEntries}.');
    }
    if (directoryOffset + directorySize > offset ||
        offset + 22 + commentLength > bytes.length) {
      throw const _UnsafeArchive('El directorio central del ZIP no es valido.');
    }
  }

  static void _validatePartName(String name) {
    if (name.isEmpty || name.contains('\u0000') || name.contains('\\')) {
      throw const _UnsafeArchive('El ZIP contiene un nombre de parte no valido.');
    }
    final normalized = p.posix.normalize(name);
    if (p.posix.isAbsolute(name) ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        normalized != name.replaceAll(RegExp(r'/+$'), '')) {
      if (!name.endsWith('/') || '$normalized/' != name) {
        throw const _UnsafeArchive('El ZIP contiene una ruta de parte no segura.');
      }
    }
  }
}

class _PageAccumulator {
  final List<String> _pages = [];
  StringBuffer _current = StringBuffer();

  bool get hasContent => _current.toString().trim().isNotEmpty;

  void addBlock(String value) {
    final clean = value.trim();
    if (clean.isEmpty) return;
    if (_current.isNotEmpty) _current.writeln();
    _current.write(clean);
  }

  void pageBreak() {
    _pages.add(_normalizePage(_current.toString()));
    _current = StringBuffer();
  }

  List<String> finish() {
    final tail = _normalizePage(_current.toString());
    if (tail.isNotEmpty || _pages.isEmpty) _pages.add(tail);
    return List.unmodifiable(_pages);
  }

  static String _normalizePage(String value) => value
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .split('\n')
      .map((line) => line.trimRight())
      .join('\n')
      .trim();
}

class _LimitedOutputStream extends OutputStream {
  final int maximum;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _length = 0;
  bool _open = true;

  _LimitedOutputStream(this.maximum) : super(byteOrder: ByteOrder.littleEndian);

  @override
  int get length => _length;

  @override
  bool get isOpen => _open;

  void _reserve(int count) {
    if (!_open) throw StateError('El flujo esta cerrado.');
    if (count < 0 || _length + count > maximum) {
      throw const _UnsafeArchive('Una parte XML se expande por encima del limite de seguridad.');
    }
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    _builder.addByte(value);
    _length++;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw RangeError.range(count, 0, bytes.length, 'length');
    }
    _reserve(count);
    _builder.add(count == bytes.length ? bytes : bytes.sublist(0, count));
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      final count = stream.length < 8192 ? stream.length : 8192;
      if (count <= 0) break;
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) {
    final bytes = _builder.toBytes();
    final stop = end ?? bytes.length;
    RangeError.checkValidRange(start, stop, bytes.length);
    return Uint8List.sublistView(bytes, start, stop);
  }

  @override
  void clear() {
    _builder.clear();
    _length = 0;
  }

  @override
  void flush() {}

  @override
  Future<void> close() async => _open = false;

  @override
  void closeSync() => _open = false;
}

class _UnsafeArchive implements Exception {
  final String message;
  const _UnsafeArchive(this.message);
}

class _ProtectedOfficeArchive implements Exception {
  const _ProtectedOfficeArchive();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
