import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Gestiona la estructura de ficheros en disco.
///
/// En la base de datos SOLO se guardan rutas relativas: la carpeta raiz de la
/// app puede cambiar entre versiones del sistema, asi que se resuelve siempre
/// en tiempo de ejecucion.
class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  Directory? _root;

  Future<Directory> get root async {
    if (_root != null) return _root!;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'manticora'));
    if (!await dir.exists()) await dir.create(recursive: true);
    for (final sub in ['docs', 'exports', 'tmp']) {
      final d = Directory(p.join(dir.path, sub));
      if (!await d.exists()) await d.create(recursive: true);
    }
    return _root = dir;
  }

  Future<String> absolutePath(String relative) async =>
      p.join((await root).path, relative);

  Future<File> fileFor(String relative) async => File(await absolutePath(relative));

  Future<Directory> documentDir(String docId) async {
    final dir = Directory(p.join((await root).path, 'docs', docId));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String relativeForPage(String docId, String pageId, String kind) =>
      p.join('docs', docId, '${kind}_$pageId.jpg');

  Future<Directory> get exportsDir async =>
      Directory(p.join((await root).path, 'exports'));

  Future<Directory> get tmpDir async => Directory(p.join((await root).path, 'tmp'));

  /// Escribe bytes en una ruta relativa, creando los directorios necesarios.
  Future<File> write(String relative, List<int> bytes) async {
    final f = await fileFor(relative);
    await f.parent.create(recursive: true);
    return f.writeAsBytes(bytes, flush: true);
  }

  Future<void> deleteDocumentFiles(String docId) async {
    final dir = Directory(p.join((await root).path, 'docs', docId));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> deleteRelative(String relative) async {
    final f = await fileFor(relative);
    if (await f.exists()) await f.delete();
  }

  /// Espacio ocupado por los escaneos, en bytes.
  Future<int> usedBytes() async {
    final dir = Directory(p.join((await root).path, 'docs'));
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        total += await e.length();
      }
    }
    return total;
  }

  /// Vacia la carpeta temporal (ficheros intermedios de exportacion).
  Future<void> clearTmp() async {
    final dir = await tmpDir;
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      try {
        await e.delete(recursive: true);
      } catch (_) {}
    }
  }
}
