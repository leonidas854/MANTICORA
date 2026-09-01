import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../imaging/filters.dart';
import '../../imaging/geometry.dart';
import '../db/app_database.dart';
import '../models/models.dart';
import 'storage_service.dart';

/// Punto unico de acceso a documentos, paginas y carpetas.
class DocumentRepository {
  DocumentRepository._();
  static final DocumentRepository instance = DocumentRepository._();

  final _uuid = const Uuid();
  final _changes = StreamController<void>.broadcast();

  /// Emite cada vez que cambia algo, para refrescar la interfaz.
  Stream<void> get changes => _changes.stream;
  void _notify() => _changes.add(null);

  Future<Database> get _db async => AppDatabase.instance.database;
  StorageService get _files => StorageService.instance;

  // ------------------------------------------------------------- documentos

  Future<List<ScanDocument>> listDocuments({
    String? folderId,
    bool rootOnly = false,
    String query = '',
    bool trash = false,
    bool favoritesOnly = false,
  }) async {
    final db = await _db;
    final where = <String>[];
    final args = <Object?>[];

    where.add(trash ? 'd.deleted_at IS NOT NULL' : 'd.deleted_at IS NULL');
    if (!trash) {
      if (folderId != null) {
        where.add('d.folder_id = ?');
        args.add(folderId);
      } else if (rootOnly) {
        where.add('d.folder_id IS NULL');
      }
      if (favoritesOnly) where.add('d.favorite = 1');
    }

    final q = query.trim();
    if (q.isNotEmpty) {
      final ids = await _searchIds(q);
      if (ids.isEmpty) return const [];
      where.add('d.id IN (${List.filled(ids.length, '?').join(',')})');
      args.addAll(ids);
    }

    final rows = await db.rawQuery('''
      SELECT d.*,
             (SELECT COUNT(*) FROM pages p WHERE p.document_id = d.id) AS page_count,
             (SELECT p.thumb_file FROM pages p WHERE p.document_id = d.id
                ORDER BY p.position LIMIT 1) AS cover_thumb
      FROM documents d
      WHERE ${where.join(' AND ')}
      ORDER BY d.updated_at DESC
    ''', args);
    return rows.map(ScanDocument.fromMap).toList();
  }

  Future<List<String>> _searchIds(String query) async {
    final db = await _db;
    if (AppDatabase.instance.ftsAvailable) {
      // Prefijo en cada termino: busqueda "mientras escribes".
      final terms = query
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .map((t) => '"${t.replaceAll('"', '')}"*')
          .join(' ');
      if (terms.isEmpty) return const [];
      try {
        final rows = await db.rawQuery(
            'SELECT doc_id FROM docs_fts WHERE docs_fts MATCH ? ORDER BY rank', [terms]);
        return rows.map((r) => r['doc_id'] as String).toList();
      } catch (_) {
        // Consulta FTS malformada: caemos a LIKE.
      }
    }
    final like = '%${query.replaceAll('%', '')}%';
    final rows = await db.rawQuery('''
      SELECT DISTINCT d.id FROM documents d
      LEFT JOIN pages p ON p.document_id = d.id
      WHERE d.title LIKE ? OR d.tags LIKE ? OR p.ocr_text LIKE ?
    ''', [like, like, like]);
    return rows.map((r) => r['id'] as String).toList();
  }

  Future<DocumentWithPages?> getDocument(String id) async {
    final db = await _db;
    final docs = await db.rawQuery('''
      SELECT d.*,
             (SELECT COUNT(*) FROM pages p WHERE p.document_id = d.id) AS page_count
      FROM documents d WHERE d.id = ?''', [id]);
    if (docs.isEmpty) return null;
    final pages = await db.query('pages',
        where: 'document_id = ?', whereArgs: [id], orderBy: 'position ASC');
    return DocumentWithPages(
      ScanDocument.fromMap(docs.first),
      pages.map(ScanPage.fromMap).toList(),
    );
  }

  Future<ScanDocument> createDocument({String? title, String? folderId}) async {
    final db = await _db;
    final now = DateTime.now();
    final doc = ScanDocument(
      id: _uuid.v4(),
      title: (title == null || title.trim().isEmpty) ? _defaultTitle(now) : title.trim(),
      folderId: folderId,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('documents', doc.toMap());
    await AppDatabase.instance.reindex(doc.id, doc.title, '');
    _notify();
    return doc;
  }

  String _defaultTitle(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Escaneo ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)}';
  }

  Future<void> renameDocument(String id, String title) async {
    final db = await _db;
    await db.update(
      'documents',
      {'title': title.trim(), 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _reindexDocument(id);
    _notify();
  }

  Future<void> setFolder(String docId, String? folderId) async {
    final db = await _db;
    await db.update(
      'documents',
      {'folder_id': folderId, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [docId],
    );
    _notify();
  }

  Future<void> setFavorite(String docId, bool value) async {
    final db = await _db;
    await db.update('documents', {'favorite': value ? 1 : 0},
        where: 'id = ?', whereArgs: [docId]);
    _notify();
  }

  Future<void> setTags(String docId, List<String> tags) async {
    final db = await _db;
    await db.update('documents', {'tags': tags.join(',')},
        where: 'id = ?', whereArgs: [docId]);
    await _reindexDocument(docId);
    _notify();
  }

  Future<void> moveToTrash(String docId) async {
    final db = await _db;
    await db.update('documents',
        {'deleted_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [docId]);
    await AppDatabase.instance.removeFromIndex(docId);
    _notify();
  }

  Future<void> restore(String docId) async {
    final db = await _db;
    await db.update('documents', {'deleted_at': null},
        where: 'id = ?', whereArgs: [docId]);
    await _reindexDocument(docId);
    _notify();
  }

  /// Borrado definitivo: base de datos + ficheros.
  Future<void> purge(String docId) async {
    final db = await _db;
    await db.delete('documents', where: 'id = ?', whereArgs: [docId]);
    await AppDatabase.instance.removeFromIndex(docId);
    await _files.deleteDocumentFiles(docId);
    _notify();
  }

  Future<void> emptyTrash() async {
    final docs = await listDocuments(trash: true);
    for (final d in docs) {
      await purge(d.id);
    }
  }

  // ---------------------------------------------------------------- paginas

  /// Anade una pagina nueva escribiendo las tres imagenes en disco.
  Future<ScanPage> addPage({
    required String documentId,
    required Uint8List originalJpeg,
    required Uint8List processedJpeg,
    required Uint8List thumbnailJpeg,
    Quad? quad,
    ScanFilter filter = ScanFilter.magic,
    Adjustments adjustments = Adjustments.none,
    int rotation = 0,
    int width = 0,
    int height = 0,
  }) async {
    final db = await _db;
    final pageId = _uuid.v4();

    final origRel = _files.relativeForPage(documentId, pageId, 'orig');
    final procRel = _files.relativeForPage(documentId, pageId, 'page');
    final thumbRel = _files.relativeForPage(documentId, pageId, 'thumb');

    await _files.write(origRel, originalJpeg);
    await _files.write(procRel, processedJpeg);
    await _files.write(thumbRel, thumbnailJpeg);

    final next = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COALESCE(MAX(position), -1) + 1 FROM pages WHERE document_id = ?',
            [documentId])) ??
        0;

    final page = ScanPage(
      id: pageId,
      documentId: documentId,
      position: next,
      originalFile: origRel,
      processedFile: procRel,
      thumbFile: thumbRel,
      quad: quad,
      filter: filter,
      adjustments: adjustments,
      rotation: rotation,
      width: width,
      height: height,
    );
    await db.insert('pages', page.toMap());
    await _touch(documentId);
    _notify();
    return page;
  }

  /// Sustituye las imagenes procesadas de una pagina (tras reeditarla).
  Future<ScanPage> replacePageImage(
    ScanPage page, {
    required Uint8List processedJpeg,
    required Uint8List thumbnailJpeg,
    Quad? quad,
    ScanFilter? filter,
    Adjustments? adjustments,
    int? rotation,
    int? width,
    int? height,
  }) async {
    await _files.write(page.processedFile, processedJpeg);
    await _files.write(page.thumbFile, thumbnailJpeg);
    final updated = page.copyWith(
      quad: quad,
      filter: filter,
      adjustments: adjustments,
      rotation: rotation,
      width: width,
      height: height,
    );
    final db = await _db;
    await db.update('pages', updated.toMap(), where: 'id = ?', whereArgs: [page.id]);
    await _touch(page.documentId);
    _notify();
    return updated;
  }

  /// Resuelve una ruta relativa guardada en la base de datos.
  Future<File> absoluteFile(String relative) => _files.fileFor(relative);

  /// Fichero en disco con la imagen procesada de una pagina.
  Future<File> pageFile(ScanPage page) => _files.fileFor(page.processedFile);

  /// Fichero de la miniatura de una pagina.
  Future<File> thumbFile(ScanPage page) => _files.fileFor(page.thumbFile);

  Future<void> setOcrText(String pageId, String documentId, String text,
      {String? boxesJson}) async {
    final db = await _db;
    await db.update(
      'pages',
      {'ocr_text': text, if (boxesJson != null) 'ocr_boxes': boxesJson},
      where: 'id = ?',
      whereArgs: [pageId],
    );
    await _reindexDocument(documentId);
    _notify();
  }

  Future<void> deletePage(ScanPage page) async {
    final db = await _db;
    await db.delete('pages', where: 'id = ?', whereArgs: [page.id]);
    for (final rel in [page.originalFile, page.processedFile, page.thumbFile]) {
      await _files.deleteRelative(rel);
    }
    await _renumber(page.documentId);
    await _touch(page.documentId);
    await _reindexDocument(page.documentId);
    _notify();
  }

  Future<void> reorderPages(String documentId, List<String> orderedIds) async {
    final db = await _db;
    final batch = db.batch();
    for (var i = 0; i < orderedIds.length; i++) {
      batch.update('pages', {'position': i},
          where: 'id = ?', whereArgs: [orderedIds[i]]);
    }
    await batch.commit(noResult: true);
    await _touch(documentId);
    _notify();
  }

  Future<void> _renumber(String documentId) async {
    final db = await _db;
    final rows = await db.query('pages',
        columns: ['id'],
        where: 'document_id = ?',
        whereArgs: [documentId],
        orderBy: 'position ASC');
    final batch = db.batch();
    for (var i = 0; i < rows.length; i++) {
      batch.update('pages', {'position': i},
          where: 'id = ?', whereArgs: [rows[i]['id']]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> _touch(String documentId) async {
    final db = await _db;
    await db.update(
        'documents', {'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [documentId]);
  }

  Future<void> _reindexDocument(String docId) async {
    final doc = await getDocument(docId);
    if (doc == null) return;
    await AppDatabase.instance.reindex(
      docId,
      '${doc.document.title} ${doc.document.tags.join(' ')}',
      doc.combinedText,
    );
  }

  // --------------------------------------------------------------- carpetas

  Future<List<Folder>> listFolders({String? parentId, bool rootOnly = true}) async {
    final db = await _db;
    final rows = await db.query(
      'folders',
      where: parentId != null
          ? 'parent_id = ?'
          : (rootOnly ? 'parent_id IS NULL' : null),
      whereArgs: parentId != null ? [parentId] : null,
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map(Folder.fromMap).toList();
  }

  Future<int> countInFolder(String folderId) async {
    final db = await _db;
    return Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM documents WHERE folder_id = ? AND deleted_at IS NULL',
          [folderId],
        )) ??
        0;
  }

  Future<Folder> createFolder(String name, {String? parentId}) async {
    final db = await _db;
    final f = Folder(
      id: _uuid.v4(),
      name: name.trim().isEmpty ? 'Carpeta' : name.trim(),
      parentId: parentId,
      createdAt: DateTime.now(),
    );
    await db.insert('folders', f.toMap());
    _notify();
    return f;
  }

  Future<void> renameFolder(String id, String name) async {
    final db = await _db;
    await db.update('folders', {'name': name.trim()}, where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  /// Borra la carpeta; sus documentos vuelven a la raiz.
  Future<void> deleteFolder(String id) async {
    final db = await _db;
    await db.update('documents', {'folder_id': null},
        where: 'folder_id = ?', whereArgs: [id]);
    await db.delete('folders', where: 'id = ?', whereArgs: [id]);
    _notify();
  }
}
