import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import '../../core/failure.dart';
import '../../core/logger.dart';
import '../repositories/storage_service.dart';

/// Acceso a la base de datos SQLite local.
///
/// Usa FTS5 para la busqueda de texto completo (titulo + texto OCR). Algunos
/// dispositivos compilan SQLite sin FTS5; en ese caso se detecta al abrir y la
/// busqueda cae con elegancia a `LIKE`.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static const _tag = 'BaseDatos';
  static const _dbName = 'manticora.db';
  static const _version = 1;

  Database? _db;
  Completer<Database>? _opening;
  bool _ftsAvailable = false;
  static bool _ffiReady = false;

  bool get ftsAvailable => _ftsAvailable;
  bool get isOpen => _db != null;

  /// Devuelve la base abierta. Varias llamadas simultaneas comparten la misma
  /// apertura en lugar de abrirla dos veces.
  Future<Database> get database async {
    final open = _db;
    if (open != null) return open;
    final pending = _opening;
    if (pending != null) return pending.future;

    final completer = Completer<Database>();
    _opening = completer;
    try {
      final db = await _open();
      _db = db;
      completer.complete(db);
      return db;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _opening = null;
    }
  }

  /// En escritorio (Linux, Windows, macOS) `sqflite` no trae implementacion
  /// nativa: hay que enchufar la de FFI. En Android y iOS no se toca nada.
  static void _ensureDesktopFactory() {
    if (_ffiReady) return;
    if (Platform.isAndroid || Platform.isIOS) {
      _ffiReady = true;
      return;
    }
    try {
      ffi.sqfliteFfiInit();
      databaseFactory = ffi.databaseFactoryFfi;
      _ffiReady = true;
      Log.i(_tag, 'Motor SQLite de escritorio (FFI) activado');
    } catch (e, st) {
      Log.e(_tag, 'No se pudo activar SQLite en escritorio', e, st);
    }
  }

  Future<Database> _open() async {
    _ensureDesktopFactory();

    late final String path;
    try {
      path = p.join(await _databaseDirectory(), _dbName);
      Log.d(_tag, 'Base de datos en $path');
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Localizando la base de datos');
    }

    try {
      return await _openAt(path);
    } catch (e, st) {
      // Una base corrupta dejaria la app inservible para siempre. Se hace copia
      // del fichero dañado y se empieza de cero: se pierden los metadatos, pero
      // las imagenes siguen en disco y la app vuelve a arrancar.
      Log.e(_tag, 'No se pudo abrir la base de datos', e, st);
      final recovered = await _recover(path);
      if (!recovered) {
        throw AppFailure(
          kind: FailureKind.database,
          message: 'No se ha podido abrir la base de datos de la aplicacion.',
          cause: e,
          stackTrace: st,
          retryable: false,
        );
      }
      return _openAt(path);
    }
  }

  /// Carpeta donde vive el fichero de la base de datos.
  Future<String> _databaseDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return getDatabasesPath();
    }
    // En escritorio la guardamos junto al resto de datos de la aplicacion.
    final root = await StorageService.instance.root;
    final dir = Directory(p.join(root.path, 'db'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<Database> _openAt(String path) => openDatabase(
        path,
        version: _version,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          // WAL reduce los bloqueos y aguanta mejor un cierre inesperado.
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, v) async {
          Log.i(_tag, 'Creando el esquema (version $v)');
          await _createSchema(db);
        },
        onUpgrade: (db, from, to) async {
          Log.i(_tag, 'Migrando de la version $from a la $to');
        },
        onOpen: (db) async {
          _ftsAvailable = await _ensureFts(db);
          Log.i(_tag, 'Base de datos abierta. FTS5: $_ftsAvailable');
        },
      );

  Future<bool> _recover(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        final backup = File('$path.corrupta');
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
        Log.w(_tag, 'Base de datos dañada movida a ${backup.path}');
      }
      // Los ficheros auxiliares de WAL tambien estorban.
      for (final suffix in ['-wal', '-shm']) {
        final aux = File('$path$suffix');
        if (await aux.exists()) await aux.delete();
      }
      return true;
    } catch (e, st) {
      Log.e(_tag, 'Fallo la recuperacion de la base de datos', e, st);
      return false;
    }
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
    batch.execute('CREATE INDEX idx_docs_deleted ON documents(deleted_at)');
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
    } catch (e) {
      Log.w(_tag, 'Este dispositivo no tiene FTS5; se buscara con LIKE', e);
      return false;
    }
  }

  /// Reindexa un documento en la tabla FTS. Nunca lanza: la busqueda es una
  /// comodidad, no debe impedir guardar.
  Future<void> reindex(String docId, String title, String body) async {
    if (!_ftsAvailable) return;
    try {
      final db = await database;
      await db.delete('docs_fts', where: 'doc_id = ?', whereArgs: [docId]);
      await db.insert('docs_fts', {'doc_id': docId, 'title': title, 'body': body});
    } catch (e) {
      Log.w(_tag, 'No se pudo reindexar el documento $docId', e);
    }
  }

  Future<void> removeFromIndex(String docId) async {
    if (!_ftsAvailable) return;
    try {
      final db = await database;
      await db.delete('docs_fts', where: 'doc_id = ?', whereArgs: [docId]);
    } catch (e) {
      Log.w(_tag, 'No se pudo quitar del indice el documento $docId', e);
    }
  }

  /// Compacta la base y reconstruye los indices.
  Future<void> vacuum() async {
    try {
      final db = await database;
      await db.execute('VACUUM');
      Log.i(_tag, 'Base de datos compactada');
    } catch (e) {
      Log.w(_tag, 'No se pudo compactar la base de datos', e);
    }
  }

  /// Cierra y olvida el estado. Solo para pruebas.
  @visibleForTesting
  Future<void> resetForTesting() async {
    await close();
    _ftsAvailable = false;
  }

  Future<void> close() async {
    try {
      await _db?.close();
    } catch (e) {
      Log.w(_tag, 'Error cerrando la base de datos', e);
    }
    _db = null;
  }
}
