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
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        color: (m['color'] as int?) ?? 0,
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
        position: m['position'] as int,
        originalFile: m['original_file'] as String,
        processedFile: m['processed_file'] as String,
        thumbFile: m['thumb_file'] as String,
        quad: m['quad'] == null ? null : Quad.fromJson(_decode(m['quad'] as String)),
        filter: ScanFilter.fromName(m['filter'] as String?),
        adjustments: m['adjustments'] == null
            ? Adjustments.none
            : Adjustments.fromJson(
                Map<String, dynamic>.from(_decode(m['adjustments'] as String) as Map)),
        rotation: (m['rotation'] as int?) ?? 0,
        width: (m['width'] as int?) ?? 0,
        height: (m['height'] as int?) ?? 0,
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
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
        tags: ((m['tags'] as String?) ?? '')
            .split(',')
            .where((e) => e.trim().isNotEmpty)
            .toList(),
        favorite: ((m['favorite'] as int?) ?? 0) == 1,
        deletedAt: m['deleted_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['deleted_at'] as int),
        pageCount: (m['page_count'] as int?) ?? 0,
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
Object? _decode(String s) => jsonDecode(s);
