import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/error_orchestrator.dart';
import '../../core/failure.dart';
import '../../core/logger.dart';
import '../../core/validators.dart';
import '../../imaging/filters.dart';
import '../../imaging/geometry.dart';
import '../db/app_database.dart';
import '../models/models.dart';
import 'storage_service.dart';

/// Punto unico de acceso a documentos, paginas y carpetas.
///
/// Las lecturas nunca lanzan: ante un fallo devuelven vacio y lo dejan
/// registrado, para que un problema puntual no deje la pantalla en blanco.
/// Las escrituras si propagan [AppFailure], porque quien las pide necesita
/// saber que no se guardo.
class DocumentRepository {
  DocumentRepository._();
  static final DocumentRepository instance = DocumentRepository._();

  static const _tag = 'Repositorio';

  final _uuid = const Uuid();
  final _changes = StreamController<void>.broadcast();

  /// Emite cada vez que cambia algo, para refrescar la interfaz.
  Stream<void> get changes => _changes.stream;
  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

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
    final result = await ErrorOrchestrator.attempt<List<ScanDocument>>(
      'Listando documentos',
      () async {
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
          if (ids.isEmpty) return const <ScanDocument>[];
          // SQLite limita el numero de variables por consulta (999 por
          // defecto): si hay demasiados resultados, se recorta.
          final limited = ids.take(400).toList();
          where.add('d.id IN (${List.filled(limited.length, '?').join(',')})');
          args.addAll(limited);
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

        return rows
            .map((r) => ErrorOrchestrator.guardSync(
                  'Leyendo un documento',
                  () => ScanDocument.fromMap(r),
                  tag: _tag,
                ))
            .whereType<ScanDocument>()
            .toList();
      },
      tag: _tag,
      notifyUser: false,
    );
    return result.valueOrNull ?? const [];
  }

  Future<List<String>> _searchIds(String query) async {
    final db = await _db;
    if (AppDatabase.instance.ftsAvailable) {
      // Prefijo en cada termino: busqueda "mientras escribes".
      final terms = query
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .map((t) => t.replaceAll(RegExp(r'["*()]'), ''))
          .where((t) => t.isNotEmpty)
          .map((t) => '"$t"*')
          .join(' ');
      if (terms.isNotEmpty) {
        try {
          final rows = await db.rawQuery(
            'SELECT doc_id FROM docs_fts WHERE docs_fts MATCH ? ORDER BY rank LIMIT 400',
            [terms],
          );
          return rows.map((r) => r['doc_id'] as String).toList();
        } catch (e) {
          Log.w(_tag, 'Consulta FTS rechazada; se busca con LIKE', e);
        }
      }
    }
    final like = '%${query.replaceAll(RegExp(r'[%_]'), '')}%';
    final rows = await db.rawQuery('''
      SELECT DISTINCT d.id FROM documents d
      LEFT JOIN pages p ON p.document_id = d.id
      WHERE d.title LIKE ? OR d.tags LIKE ? OR p.ocr_text LIKE ?
      LIMIT 400
    ''', [like, like, like]);
    return rows.map((r) => r['id'] as String).toList();
  }

  Future<DocumentWithPages?> getDocument(String id) async {
    if (id.isEmpty) return null;
    final result = await ErrorOrchestrator.attempt<DocumentWithPages?>(
      'Abriendo el documento',
      () async {
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
          pages
              .map((r) => ErrorOrchestrator.guardSync(
                    'Leyendo una pagina',
                    () => ScanPage.fromMap(r),
                    tag: _tag,
                  ))
              .whereType<ScanPage>()
              .toList(),
        );
      },
      tag: _tag,
      notifyUser: false,
    );
    return result.valueOrNull;
  }

  Future<ScanDocument> createDocument({String? title, String? folderId}) async {
    final now = DateTime.now();
    final resolved =
        (title == null || title.trim().isEmpty) ? _defaultTitle(now) : title.trim();

    final invalid = Validators.title(resolved);
    if (invalid != null) throw invalid;

    try {
      final db = await _db;
      final doc = ScanDocument(
        id: _uuid.v4(),
        title: resolved,
        folderId: folderId,
        createdAt: now,
        updatedAt: now,
      );
      await db.insert('documents', doc.toMap());
      await AppDatabase.instance.reindex(doc.id, doc.title, '');
      _notify();
      Log.i(_tag, 'Documento creado: ${doc.id}');
      return doc;
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Creando el documento');
    }
  }

  String _defaultTitle(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Escaneo ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)}';
  }

  Future<void> renameDocument(String id, String title) async {
    final invalid = Validators.title(title);
    if (invalid != null) throw invalid;
    try {
      final db = await _db;
      await db.update(
        'documents',
        {'title': title.trim(), 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id],
      );
      await _reindexDocument(id);
      _notify();
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Renombrando el documento');
    }
  }

  Future<void> setFolder(String docId, String? folderId) async {
    try {
      final db = await _db;
      await db.update(
        'documents',
        {'folder_id': folderId, 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [docId],
      );
      _notify();
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Moviendo el documento');
    }
  }

  Future<void> setFavorite(String docId, bool value) async {
    try {
      final db = await _db;
      await db.update('documents', {'favorite': value ? 1 : 0},
          where: 'id = ?', whereArgs: [docId]);
      _notify();
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Marcando como favorito');
    }
  }

  Future<void> setTags(String docId, List<String> tags) async {
    try {
      final clean = tags
          .map((t) => t.trim().replaceAll(',', ' '))
          .where((t) => t.isNotEmpty)
          .take(20)
          .toList();
      final db = await _db;
      await db.update('documents', {'tags': clean.join(',')},
          where: 'id = ?', whereArgs: [docId]);
      await _reindexDocument(docId);
      _notify();
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Guardando las etiquetas');
    }
  }

  Future<void> moveToTrash(String docId) async {
    try {
      final db = await _db;
      await db.update('documents',
          {'deleted_at': DateTime.now().millisecondsSinceEpoch},
          where: 'id = ?', whereArgs: [docId]);
      await AppDatabase.instance.removeFromIndex(docId);
      _notify();
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Moviendo a la papelera');
    }
  }

  Future<void> restore(String docId) async {
    try {
      final db = await _db;
      await db.update('documents', {'deleted_at': null},
          where: 'id = ?', whereArgs: [docId]);
      await _reindexDocument(docId);
      _notify();
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Restaurando el documento');
    }
  }

  /// Borrado definitivo: base de datos + ficheros.
  Future<void> purge(String docId) async {
    try {
      final db = await _db;
      await db.delete('documents', where: 'id = ?', whereArgs: [docId]);
      await AppDatabase.instance.removeFromIndex(docId);
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Eliminando el documento');
    } finally {
      // Aunque falle la base, se intenta liberar el disco.
      await _files.deleteDocumentFiles(docId);
      _notify();
    }
  }

  Future<int> emptyTrash() async {
    final docs = await listDocuments(trash: true);
    var removed = 0;
    for (final d in docs) {
      final ok = await ErrorOrchestrator.guard<bool>(
        'Vaciando la papelera',
        () async {
          await purge(d.id);
          return true;
        },
        tag: _tag,
        notifyUser: false,
      );
      if (ok == true) removed++;
    }
    return removed;
  }

  // ---------------------------------------------------------------- paginas

  /// Anade una pagina nueva escribiendo las tres imagenes en disco.
  ///
  /// Si la insercion en la base falla, se borran las imagenes ya escritas para
  /// no dejar basura ocupando espacio.
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
    if (documentId.isEmpty) {
      throw const AppFailure.validation('Falta el documento de destino.');
    }
    if (processedJpeg.isEmpty || thumbnailJpeg.isEmpty) {
      throw const AppFailure.validation('La pagina procesada esta vacia.');
    }

    final pageId = _uuid.v4();
    final origRel = _files.relativeForPage(documentId, pageId, 'orig');
    final procRel = _files.relativeForPage(documentId, pageId, 'page');
    final thumbRel = _files.relativeForPage(documentId, pageId, 'thumb');
    final written = <String>[];

    try {
      await _files.write(origRel, originalJpeg.isEmpty ? processedJpeg : originalJpeg);
      written.add(origRel);
      await _files.write(procRel, processedJpeg);
      written.add(procRel);
      await _files.write(thumbRel, thumbnailJpeg);
      written.add(thumbRel);

      final db = await _db;
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
    } catch (e, st) {
      // Reversion: sin fila en la base, esas imagenes no le sirven a nadie.
      for (final rel in written) {
        await _files.deleteRelative(rel);
      }
      throw AppFailure.from(e, st, 'Guardando la pagina');
    }
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
    if (processedJpeg.isEmpty) {
      throw const AppFailure.validation('La imagen procesada esta vacia.');
    }
    try {
      await _files.write(page.processedFile, processedJpeg);
      if (thumbnailJpeg.isNotEmpty) {
        await _files.write(page.thumbFile, thumbnailJpeg);
      }
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
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Actualizando la pagina');
    }
  }

  /// Resuelve una ruta relativa guardada en la base de datos.
  Future<File> absoluteFile(String relative) => _files.fileFor(relative);

  /// Fichero en disco con la imagen procesada de una pagina.
  Future<File> pageFile(ScanPage page) => _files.fileFor(page.processedFile);

  /// Fichero de la miniatura de una pagina.
  Future<File> thumbFile(ScanPage page) => _files.fileFor(page.thumbFile);

  Future<void> setOcrText(String pageId, String documentId, String text,
      {String? boxesJson}) async {
    try {
      final db = await _db;
      await db.update(
        'pages',
        {'ocr_text': text, 'ocr_boxes': ?boxesJson},
        where: 'id = ?',
        whereArgs: [pageId],
      );
      await _reindexDocument(documentId);
      _notify();
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Guardando el texto reconocido');
    }
  }

  Future<void> deletePage(ScanPage page) async {
    try {
      final db = await _db;
      await db.delete('pages', where: 'id = ?', whereArgs: [page.id]);
      await _renumber(page.documentId);
      await _touch(page.documentId);
      await _reindexDocument(page.documentId);
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Eliminando la pagina');
    } finally {
      for (final rel in [page.originalFile, page.processedFile, page.thumbFile]) {
        await _files.deleteRelative(rel);
      }
      _notify();
    }
  }

  Future<void> reorderPages(String documentId, List<String> orderedIds) async {
    if (orderedIds.isEmpty) return;
    try {
      final db = await _db;
      await db.transaction((txn) async {
        for (var i = 0; i < orderedIds.length; i++) {
          await txn.update('pages', {'position': i},
              where: 'id = ?', whereArgs: [orderedIds[i]]);
        }
      });
      await _touch(documentId);
      _notify();
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Reordenando las paginas');
    }
  }

  Future<void> _renumber(String documentId) async {
    final db = await _db;
    final rows = await db.query('pages',
        columns: ['id'],
        where: 'document_id = ?',
        whereArgs: [documentId],
        orderBy: 'position ASC');
    await db.transaction((txn) async {
      for (var i = 0; i < rows.length; i++) {
        await txn.update('pages', {'position': i},
            where: 'id = ?', whereArgs: [rows[i]['id']]);
      }
    });
  }

  Future<void> _touch(String documentId) async {
    try {
      final db = await _db;
      await db.update(
          'documents', {'updated_at': DateTime.now().millisecondsSinceEpoch},
          where: 'id = ?', whereArgs: [documentId]);
    } catch (e) {
      Log.w(_tag, 'No se pudo actualizar la fecha de $documentId', e);
    }
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
    final result = await ErrorOrchestrator.attempt<List<Folder>>(
      'Listando carpetas',
      () async {
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
      },
      tag: _tag,
      notifyUser: false,
    );
    return result.valueOrNull ?? const [];
  }

  Future<int> countInFolder(String folderId) async {
    final result = await ErrorOrchestrator.attempt<int>(
      'Contando documentos de la carpeta',
      () async {
        final db = await _db;
        return Sqflite.firstIntValue(await db.rawQuery(
              'SELECT COUNT(*) FROM documents WHERE folder_id = ? AND deleted_at IS NULL',
              [folderId],
            )) ??
            0;
      },
      tag: _tag,
      notifyUser: false,
    );
    return result.valueOrNull ?? 0;
  }

  Future<Folder> createFolder(String name, {String? parentId}) async {
    final invalid = Validators.title(name);
    if (invalid != null) throw invalid;
    try {
      final db = await _db;
      final f = Folder(
        id: _uuid.v4(),
        name: name.trim(),
        parentId: parentId,
        createdAt: DateTime.now(),
      );
      await db.insert('folders', f.toMap());
      _notify();
      return f;
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Creando la carpeta');
    }
  }

  Future<void> renameFolder(String id, String name) async {
    final invalid = Validators.title(name);
    if (invalid != null) throw invalid;
    try {
      final db = await _db;
      await db.update('folders', {'name': name.trim()},
          where: 'id = ?', whereArgs: [id]);
      _notify();
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Renombrando la carpeta');
    }
  }

  /// Borra la carpeta; sus documentos vuelven a la raiz.
  Future<void> deleteFolder(String id) async {
    try {
      final db = await _db;
      await db.transaction((txn) async {
        await txn.update('documents', {'folder_id': null},
            where: 'folder_id = ?', whereArgs: [id]);
        await txn.update('folders', {'parent_id': null},
            where: 'parent_id = ?', whereArgs: [id]);
        await txn.delete('folders', where: 'id = ?', whereArgs: [id]);
      });
      _notify();
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Eliminando la carpeta');
    }
  }

  // ------------------------------------------------------------ mantenimiento

  /// Revisa que cada pagina tenga su imagen en disco y limpia lo que sobra.
  /// Devuelve cuantas incidencias ha encontrado.
  Future<int> verifyIntegrity() async {
    var problems = 0;
    final result = await ErrorOrchestrator.attempt<int>(
      'Revisando la integridad',
      () async {
        final db = await _db;
        final rows = await db.query('pages',
            columns: ['id', 'document_id', 'processed_file']);
        for (final row in rows) {
          final rel = row['processed_file'] as String?;
          if (rel == null || rel.isEmpty) continue;
          final file = await _files.fileFor(rel);
          if (!await file.exists()) {
            problems++;
            Log.w(_tag, 'Pagina sin imagen: ${row['id']}');
            await db.delete('pages', where: 'id = ?', whereArgs: [row['id']]);
          }
        }

        final docIds = (await db.query('documents', columns: ['id']))
            .map((r) => r['id'] as String)
            .toSet();
        problems += await _files.removeOrphanDirectories(docIds);

        if (problems > 0) _notify();
        return problems;
      },
      tag: _tag,
      notifyUser: false,
    );
    return result.valueOrNull ?? problems;
  }
}
