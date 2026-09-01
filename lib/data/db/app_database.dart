import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Acceso a la base de datos SQLite local.
///
/// Usa FTS5 para la busqueda de texto completo (titulo + texto OCR). Algunos
/// dispositivos compilan SQLite sin FTS5; en ese caso se detecta al abrir y se
/// cae con elegancia a una busqueda LIKE.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static const _dbName = 'manticora.db';
  static const _version = 1;

  Database? _db;
  bool _ftsAvailable = false;
  bool get ftsAvailable => _ftsAvailable;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, _dbName);
    final db = await openDatabase(
      path,
      version: _version,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, v) async => _createSchema(db),
      onOpen: (db) async {
        _ftsAvailable = await _ensureFts(db);
      },
    );
    return db;
  }

  Future<void> _createSchema(Database db) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE folders(
        id         TEXT PRIMARY KEY,
        name       TEXT NOT NULL,
        parent_id  TEXT REFERENCES folders(id) ON DELETE SET NULL,
        created_at INTEGER NOT NULL,
        color      INTEGER NOT NULL DEFAULT 0
      )''');
    batch.execute('''
      CREATE TABLE documents(
        id         TEXT PRIMARY KEY,
        title      TEXT NOT NULL,
        folder_id  TEXT REFERENCES folders(id) ON DELETE SET NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        tags       TEXT NOT NULL DEFAULT '',
        favorite   INTEGER NOT NULL DEFAULT 0,
        deleted_at INTEGER
      )''');
    batch.execute('''
      CREATE TABLE pages(
        id             TEXT PRIMARY KEY,
        document_id    TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        position       INTEGER NOT NULL,
        original_file  TEXT NOT NULL,
        processed_file TEXT NOT NULL,
        thumb_file     TEXT NOT NULL,
        quad           TEXT,
        filter         TEXT NOT NULL DEFAULT 'magic',
        adjustments    TEXT,
        rotation       INTEGER NOT NULL DEFAULT 0,
        width          INTEGER NOT NULL DEFAULT 0,
        height         INTEGER NOT NULL DEFAULT 0,
        ocr_text       TEXT,
        ocr_boxes      TEXT
      )''');
    batch.execute('CREATE INDEX idx_pages_doc ON pages(document_id, position)');
    batch.execute('CREATE INDEX idx_docs_folder ON documents(folder_id, deleted_at)');
    batch.execute('CREATE INDEX idx_docs_updated ON documents(updated_at DESC)');
    await batch.commit(noResult: true);
  }

  Future<bool> _ensureFts(Database db) async {
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS docs_fts USING fts5(
          doc_id UNINDEXED,
          title,
          body,
          tokenize = "unicode61 remove_diacritics 2"
        )''');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Reindexa un documento en la tabla FTS.
  Future<void> reindex(String docId, String title, String body) async {
    if (!_ftsAvailable) return;
    final db = await database;
    await db.delete('docs_fts', where: 'doc_id = ?', whereArgs: [docId]);
    await db.insert('docs_fts', {'doc_id': docId, 'title': title, 'body': body});
  }

  Future<void> removeFromIndex(String docId) async {
    if (!_ftsAvailable) return;
    final db = await database;
    await db.delete('docs_fts', where: 'doc_id = ?', whereArgs: [docId]);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
