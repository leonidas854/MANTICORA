import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/failure.dart';
import '../../core/logger.dart';

/// Gestiona la estructura de ficheros en disco.
///
/// En la base de datos SOLO se guardan rutas relativas: la carpeta raiz de la
/// app puede cambiar entre versiones del sistema, asi que se resuelve siempre
/// en tiempo de ejecucion.
class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  static const _tag = 'Almacenamiento';

  Directory? _root;
  Completer<Directory>? _preparing;

  Future<Directory> get root async {
    final ready = _root;
    if (ready != null) return ready;
    final pending = _preparing;
    if (pending != null) return pending.future;

    final completer = Completer<Directory>();
    _preparing = completer;
    try {
      final dir = await _prepare();
      _root = dir;
      completer.complete(dir);
      return dir;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _preparing = null;
    }
  }

  /// Olvida la carpeta cacheada. Solo para pruebas: permite apuntar el
  /// almacenamiento a un directorio temporal distinto en cada caso.
  @visibleForTesting
  void resetForTesting() {
    _root = null;
    _preparing = null;
  }

  Future<Directory> _prepare() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(base.path, 'manticora'));
      if (!await dir.exists()) await dir.create(recursive: true);
      for (final sub in ['docs', 'exports', 'tmp', 'logs']) {
        final d = Directory(p.join(dir.path, sub));
        if (!await d.exists()) await d.create(recursive: true);
      }
      return dir;
    } catch (e, st) {
      throw AppFailure(
        kind: FailureKind.storage,
        message: 'No se ha podido preparar el almacenamiento de la aplicacion.',
        cause: e,
        stackTrace: st,
        context: 'Preparando carpetas',
      );
    }
  }

  Future<String> absolutePath(String relative) async {
    _assertSafe(relative);
    return p.join((await root).path, relative);
  }

  Future<File> fileFor(String relative) async => File(await absolutePath(relative));

  /// Impide que una ruta guardada apunte fuera de la carpeta de la app.
  void _assertSafe(String relative) {
    final normalized = p.normalize(relative);
    if (p.isAbsolute(normalized) || normalized.startsWith('..')) {
      throw AppFailure.validation('Ruta de fichero no permitida: $relative');
    }
  }

  Future<Directory> documentDir(String docId) async {
    final dir = Directory(p.join((await root).path, 'docs', docId));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String relativeForPage(String docId, String pageId, String kind) =>
      p.join('docs', docId, '${kind}_$pageId.jpg');

  Future<Directory> get exportsDir async {
    final dir = Directory(p.join((await root).path, 'exports'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> get tmpDir async {
    final dir = Directory(p.join((await root).path, 'tmp'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Escribe bytes de forma **atomica**: primero a un temporal y luego se
  /// renombra. Asi un corte de corriente no deja una imagen a medias que
  /// luego no se pueda abrir.
  Future<File> write(String relative, List<int> bytes) async {
    if (bytes.isEmpty) {
      throw AppFailure.validation('Se intento guardar un fichero vacio.');
    }
    final target = await fileFor(relative);
    final temp = File('${target.path}.tmp');
    try {
      await target.parent.create(recursive: true);
      await temp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
      return target;
    } catch (e, st) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      throw AppFailure.from(e, st, 'Guardando $relative');
    }
  }

  Future<void> deleteDocumentFiles(String docId) async {
    try {
      final dir = Directory(p.join((await root).path, 'docs', docId));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      Log.w(_tag, 'No se pudieron borrar los ficheros de $docId', e);
    }
  }

  Future<void> deleteRelative(String relative) async {
    try {
      final f = await fileFor(relative);
      if (await f.exists()) await f.delete();
    } catch (e) {
      Log.w(_tag, 'No se pudo borrar $relative', e);
    }
  }

  /// Espacio ocupado por los escaneos, en bytes.
  Future<int> usedBytes() async {
    try {
      final dir = Directory(p.join((await root).path, 'docs'));
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {
            // Un fichero que desaparece a mitad del recuento no es un problema.
          }
        }
      }
      return total;
    } catch (e) {
      Log.w(_tag, 'No se pudo calcular el espacio usado', e);
      return 0;
    }
  }

  /// Vacia la carpeta temporal (ficheros intermedios de exportacion).
  Future<void> clearTmp() async {
    try {
      final dir = await tmpDir;
      if (!await dir.exists()) return;
      var removed = 0;
      await for (final e in dir.list()) {
        try {
          await e.delete(recursive: true);
          removed++;
        } catch (_) {}
      }
      if (removed > 0) Log.i(_tag, 'Temporales eliminados: $removed');
    } catch (e) {
      Log.w(_tag, 'No se pudo limpiar la carpeta temporal', e);
    }
  }

  /// Borra exportaciones antiguas para que la carpeta no crezca sin control.
  Future<void> pruneExports({Duration olderThan = const Duration(days: 7)}) async {
    try {
      final dir = await exportsDir;
      if (!await dir.exists()) return;
      final limit = DateTime.now().subtract(olderThan);
      await for (final e in dir.list()) {
        try {
          final stat = await e.stat();
          if (stat.modified.isBefore(limit)) await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (e) {
      Log.w(_tag, 'No se pudieron limpiar las exportaciones antiguas', e);
    }
  }

  /// Elimina carpetas de documentos que ya no existen en la base de datos.
  Future<int> removeOrphanDirectories(Set<String> knownDocumentIds) async {
    var removed = 0;
    try {
      final docs = Directory(p.join((await root).path, 'docs'));
      if (!await docs.exists()) return 0;
      await for (final e in docs.list()) {
        if (e is! Directory) continue;
        final id = p.basename(e.path);
        if (knownDocumentIds.contains(id)) continue;
        try {
          await e.delete(recursive: true);
          removed++;
        } catch (_) {}
      }
      if (removed > 0) Log.i(_tag, 'Carpetas huerfanas eliminadas: $removed');
    } catch (e) {
      Log.w(_tag, 'No se pudieron buscar carpetas huerfanas', e);
    }
    return removed;
  }
}
