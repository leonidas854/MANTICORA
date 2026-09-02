import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/device_profile.dart';
import '../../core/failure.dart';
import '../../core/logger.dart';
import '../../data/repositories/storage_service.dart';
import '../../imaging/filters.dart';
import '../../imaging/geometry.dart';

/// Una captura pendiente de procesar y guardar.
///
/// El JPEG original **no se guarda en memoria**: se vuelca a un fichero
/// temporal en cuanto llega. Mantener veinte fotos de 12 MP en RAM cierra la
/// aplicacion en cualquier movil modesto.
class CapturedShot {
  /// Ruta absoluta del original en la carpeta temporal de la sesion.
  final String originalPath;

  /// Tamano de la imagen original en pixeles.
  final int width, height;

  Quad? quad;
  int rotation;
  ScanFilter filter;
  Adjustments adjustments;

  /// Vista previa ya procesada (pequena) para mostrar en el editor.
  /// Es lo unico que se conserva en memoria por pagina.
  Uint8List? preview;

  CapturedShot({
    required this.originalPath,
    required this.width,
    required this.height,
    this.quad,
    this.rotation = 0,
    this.filter = ScanFilter.magic,
    this.adjustments = Adjustments.none,
    this.preview,
  });

  File get file => File(originalPath);

  /// Lee el original de disco. Lanza [AppFailure] si ya no esta.
  Future<Uint8List> readOriginal() async {
    try {
      final f = file;
      if (!await f.exists()) {
        throw const AppFailure.notFound(
          'La imagen capturada ya no esta disponible.',
        );
      }
      return await f.readAsBytes();
    } on AppFailure {
      rethrow;
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Leyendo la captura');
    }
  }

  Future<void> deleteFile() async {
    try {
      final f = file;
      if (await f.exists()) await f.delete();
    } catch (e) {
      Log.w('Escaneo', 'No se pudo borrar el temporal $originalPath', e);
    }
  }
}

/// Agrupa las capturas de una tanda y gestiona sus ficheros temporales.
class ScanSession {
  final List<CapturedShot> shots = [];
  Directory? _dir;

  /// Tope de paginas por tanda, para no agotar el disco ni la paciencia.
  int get maxShots => DeviceProfile.current.maxPagesPerExport;

  bool get isFull => shots.length >= maxShots;

  Future<Directory> _sessionDir() async {
    if (_dir != null) return _dir!;
    final tmp = await StorageService.instance.tmpDir;
    final dir = Directory(
      p.join(tmp.path, 'scan_${DateTime.now().millisecondsSinceEpoch}'),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  /// Guarda una captura en disco y la anade a la tanda.
  Future<CapturedShot> add(
    Uint8List jpeg, {
    required int width,
    required int height,
    Quad? quad,
    ScanFilter filter = ScanFilter.magic,
  }) async {
    if (isFull) {
      throw AppFailure.validation(
        'Has alcanzado el maximo de $maxShots paginas por tanda. '
        'Guarda estas y sigue en un documento nuevo.',
      );
    }
    final dir = await _sessionDir();
    final path = p.join(dir.path, 'shot_${shots.length}_'
        '${DateTime.now().microsecondsSinceEpoch}.jpg');
    final file = File(path);
    await file.writeAsBytes(jpeg, flush: true);

    final shot = CapturedShot(
      originalPath: path,
      width: width,
      height: height,
      quad: quad,
      filter: filter,
    );
    shots.add(shot);
    Log.d('Escaneo', 'Captura ${shots.length} guardada (${jpeg.length} bytes)');
    return shot;
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= shots.length) return;
    final shot = shots.removeAt(index);
    await shot.deleteFile();
  }

  /// Borra todos los temporales de la tanda.
  Future<void> dispose() async {
    for (final shot in shots) {
      await shot.deleteFile();
    }
    shots.clear();
    try {
      final dir = _dir;
      if (dir != null && await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      Log.w('Escaneo', 'No se pudo borrar la carpeta temporal de la tanda', e);
    }
    _dir = null;
  }
}
