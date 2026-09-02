import 'dart:convert';

import '../../imaging/filters.dart';
import '../../imaging/geometry.dart';

/// Carpeta para organizar documentos (soporta anidamiento).
class Folder {
  final String id;
  final String name;
  final String? parentId;
  final DateTime createdAt;
  final int color;

  const Folder({
    required this.id,
    required this.name,
    this.parentId,
    required this.createdAt,
    this.color = 0,
  });

  Folder copyWith({String? name, String? parentId, int? color}) => Folder(
        id: id,
        name: name ?? this.name,
        parentId: parentId ?? this.parentId,
        createdAt: createdAt,
        color: color ?? this.color,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'parent_id': parentId,
        'created_at': createdAt.millisecondsSinceEpoch,
        'color': color,
      };

  factory Folder.fromMap(Map<String, Object?> m) => Folder(
        id: m['id'] as String,
        name: m['name'] as String,
        parentId: m['parent_id'] as String?,
        createdAt: _parseDate(m['created_at']),
        color: _parseInt(m['color']),
      );
}

/// Una pagina escaneada.
class ScanPage {
  final String id;
  final String documentId;
  final int position;

  /// Rutas RELATIVAS a la carpeta de datos de la app.
  final String originalFile;
  final String processedFile;
  final String thumbFile;

  final Quad? quad;
  final ScanFilter filter;
  final Adjustments adjustments;
  final int rotation; // cuartos de vuelta
  final int width, height;
  final String? ocrText;

  /// Cajas de texto reconocidas, en JSON, para la capa buscable del PDF.
  final String? ocrBoxes;

  const ScanPage({
    required this.id,
    required this.documentId,
    required this.position,
    required this.originalFile,
    required this.processedFile,
    required this.thumbFile,
    this.quad,
    this.filter = ScanFilter.magic,
    this.adjustments = Adjustments.none,
    this.rotation = 0,
    this.width = 0,
    this.height = 0,
    this.ocrText,
    this.ocrBoxes,
  });

  bool get hasOcr => (ocrText ?? '').trim().isNotEmpty;

  ScanPage copyWith({
    int? position,
    String? processedFile,
    String? thumbFile,
    Quad? quad,
    bool clearQuad = false,
    ScanFilter? filter,
    Adjustments? adjustments,
    int? rotation,
    int? width,
    int? height,
    String? ocrText,
    String? ocrBoxes,
  }) =>
      ScanPage(
        id: id,
        documentId: documentId,
        position: position ?? this.position,
        originalFile: originalFile,
        processedFile: processedFile ?? this.processedFile,
        thumbFile: thumbFile ?? this.thumbFile,
        quad: clearQuad ? null : (quad ?? this.quad),
        filter: filter ?? this.filter,
        adjustments: adjustments ?? this.adjustments,
        rotation: rotation ?? this.rotation,
        width: width ?? this.width,
        height: height ?? this.height,
        ocrText: ocrText ?? this.ocrText,
        ocrBoxes: ocrBoxes ?? this.ocrBoxes,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'document_id': documentId,
        'position': position,
        'original_file': originalFile,
        'processed_file': processedFile,
        'thumb_file': thumbFile,
        'quad': quad == null ? null : _encode(quad!.toJson()),
        'filter': filter.name,
        'adjustments': _encode(adjustments.toJson()),
        'rotation': rotation,
        'width': width,
        'height': height,
        'ocr_text': ocrText,
        'ocr_boxes': ocrBoxes,
      };

  factory ScanPage.fromMap(Map<String, Object?> m) => ScanPage(
        id: m['id'] as String,
        documentId: m['document_id'] as String,
        position: _parseInt(m['position']),
        originalFile: m['original_file'] as String,
        processedFile: m['processed_file'] as String,
        thumbFile: m['thumb_file'] as String,
        quad: _parseQuad(m['quad']),
        filter: ScanFilter.fromName(m['filter'] as String?),
        adjustments: _parseAdjustments(m['adjustments']),
        rotation: _parseInt(m['rotation']),
        width: _parseInt(m['width']),
        height: _parseInt(m['height']),
        ocrText: m['ocr_text'] as String?,
        ocrBoxes: m['ocr_boxes'] as String?,
      );
}

/// Documento = conjunto ordenado de paginas.
class ScanDocument {
  final String id;
  final String title;
  final String? folderId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> tags;
  final bool favorite;
  final DateTime? deletedAt;

  /// Solo se rellena en los listados (no se persiste).
  final int pageCount;
  final String? coverThumb;

  const ScanDocument({
    required this.id,
    required this.title,
    this.folderId,
    required this.createdAt,
    required this.updatedAt,
    this.tags = const [],
    this.favorite = false,
    this.deletedAt,
    this.pageCount = 0,
    this.coverThumb,
  });

  bool get isDeleted => deletedAt != null;

  ScanDocument copyWith({
    String? title,
    String? folderId,
    bool clearFolder = false,
    DateTime? updatedAt,
    List<String>? tags,
    bool? favorite,
    DateTime? deletedAt,
    bool clearDeleted = false,
    int? pageCount,
    String? coverThumb,
  }) =>
      ScanDocument(
        id: id,
        title: title ?? this.title,
        folderId: clearFolder ? null : (folderId ?? this.folderId),
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        tags: tags ?? this.tags,
        favorite: favorite ?? this.favorite,
        deletedAt: clearDeleted ? null : (deletedAt ?? this.deletedAt),
        pageCount: pageCount ?? this.pageCount,
        coverThumb: coverThumb ?? this.coverThumb,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'folder_id': folderId,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'tags': tags.join(','),
        'favorite': favorite ? 1 : 0,
        'deleted_at': deletedAt?.millisecondsSinceEpoch,
      };

  factory ScanDocument.fromMap(Map<String, Object?> m) => ScanDocument(
        id: m['id'] as String,
        title: m['title'] as String,
        folderId: m['folder_id'] as String?,
        createdAt: _parseDate(m['created_at']),
        updatedAt: _parseDate(m['updated_at']),
        tags: ((m['tags'] as String?) ?? '')
            .split(',')
            .where((e) => e.trim().isNotEmpty)
            .toList(),
        favorite: _parseInt(m['favorite']) == 1,
        deletedAt: m['deleted_at'] == null ? null : _parseDate(m['deleted_at']),
        pageCount: _parseInt(m['page_count']),
        coverThumb: m['cover_thumb'] as String?,
      );
}

/// Documento con sus paginas ya cargadas.
class DocumentWithPages {
  final ScanDocument document;
  final List<ScanPage> pages;
  const DocumentWithPages(this.document, this.pages);

  String get combinedText =>
      pages.map((p) => p.ocrText ?? '').where((t) => t.trim().isNotEmpty).join('\n\n');
}

String _encode(Object? v) => jsonEncode(v);

/// Lecturas defensivas de los campos JSON guardados en la base de datos.
///
/// Un valor corrupto (por un cierre a medias, por ejemplo) devuelve el valor
/// por defecto en lugar de impedir que se abra el documento entero.
Quad? _parseQuad(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return Quad.fromJson(jsonDecode(raw));
  } catch (_) {
    return null;
  }
}

Adjustments _parseAdjustments(Object? raw) {
  if (raw is! String || raw.isEmpty) return Adjustments.none;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return Adjustments.none;
    return Adjustments.fromJson(Map<String, dynamic>.from(decoded));
  } catch (_) {
    return Adjustments.none;
  }
}

int _parseInt(Object? raw, [int fallback = 0]) =>
    raw is int ? raw : (raw is num ? raw.toInt() : fallback);

DateTime _parseDate(Object? raw) => DateTime.fromMillisecondsSinceEpoch(
      raw is int ? raw : (raw is num ? raw.toInt() : 0),
    );
