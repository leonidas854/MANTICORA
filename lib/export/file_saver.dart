import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../core/failure.dart';
import '../core/logger.dart';

/// Guarda un fichero generado en la ubicacion que elija el usuario.
///
/// En Android se usa el selector del sistema (Storage Access Framework), por
/// lo que no hace falta ningun permiso de almacenamiento.
class FileSaver {
  static const _mimeTypes = {
    'pdf': 'application/pdf',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'txt': 'text/plain',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'mp3': 'audio/mpeg',
    'ogg': 'audio/ogg',
    'opus': 'audio/ogg',
    'wav': 'audio/wav',
    'mp4': 'video/mp4',
    'webm': 'video/webm',
    'zip': 'application/zip',
  };

  static String mimeFor(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return _mimeTypes[ext] ?? 'application/octet-stream';
  }

  /// Devuelve la ruta o URI donde se guardo, o null si se cancelo.
  static Future<String?> save(String fileName, Uint8List bytes) async {
    if (bytes.isEmpty) {
      throw const AppFailure.validation('No hay nada que guardar.');
    }
    try {
      final uri = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeFor(fileName),
        dialogTitle: 'Guardar $fileName',
      );
      if (uri != null) Log.i('Guardado', 'Fichero guardado en $uri');
      return uri?.toString();
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Guardando $fileName');
    }
  }
}
