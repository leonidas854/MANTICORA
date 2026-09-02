import 'dart:io';
import 'dart:typed_data';

import 'failure.dart';

/// Comprobaciones de entrada reutilizables.
///
/// Devuelven `null` si el valor es correcto o un [AppFailure] de validacion
/// con el motivo concreto. Asi la interfaz puede decidir si avisar o abortar.
class Validators {
  Validators._();

  /// Longitud maxima de un titulo, para que quepa en nombres de fichero.
  static const int maxTitleLength = 120;

  /// Tamano maximo aceptado al importar un fichero (150 MB).
  static const int maxImportBytes = 150 * 1024 * 1024;

  /// Firmas de los formatos que sabemos leer.
  static const _jpegMagic = [0xFF, 0xD8, 0xFF];
  static const _pngMagic = [0x89, 0x50, 0x4E, 0x47];
  static const _pdfMagic = [0x25, 0x50, 0x44, 0x46]; // %PDF

  // ------------------------------------------------------------------ texto

  static AppFailure? title(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) {
      return const AppFailure.validation('El titulo no puede estar vacio.');
    }
    if (v.length > maxTitleLength) {
      return const AppFailure.validation(
        'El titulo es demasiado largo (maximo $maxTitleLength caracteres).',
      );
    }
    return null;
  }

  static AppFailure? password(String? value) {
    final v = value ?? '';
    if (v.isEmpty) {
      return const AppFailure.validation('La contrasena no puede estar vacia.');
    }
    if (v.length < 4) {
      return const AppFailure.validation(
        'La contrasena debe tener al menos 4 caracteres.',
      );
    }
    if (v.length > 127) {
      // Limite del propio formato PDF.
      return const AppFailure.validation(
        'La contrasena no puede superar los 127 caracteres.',
      );
    }
    return null;
  }

  /// Convierte cualquier texto en un nombre de fichero seguro.
  static String safeFileName(String raw, String extension) {
    var name = raw.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    name = name.replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'^\.+'), '');
    if (name.length > 80) name = name.substring(0, 80).trim();
    if (name.isEmpty) name = 'documento';
    // Nombres reservados en algunos sistemas de ficheros.
    const reserved = {'con', 'prn', 'aux', 'nul', 'com1', 'lpt1'};
    if (reserved.contains(name.toLowerCase())) name = '_$name';
    return '$name.$extension';
  }

  // ---------------------------------------------------------------- ficheros

  static AppFailure? fileSize(int bytes, {String what = 'fichero'}) {
    if (bytes <= 0) {
      return AppFailure.validation('El $what esta vacio.');
    }
    if (bytes > maxImportBytes) {
      final mb = (bytes / (1024 * 1024)).toStringAsFixed(0);
      return AppFailure.validation(
        'El $what ocupa $mb MB y supera el limite admitido '
        '(${maxImportBytes ~/ (1024 * 1024)} MB).',
      );
    }
    return null;
  }

  static bool _startsWith(Uint8List bytes, List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  /// Comprueba que los bytes son realmente un PDF, no solo que acabe en .pdf.
  static AppFailure? pdfBytes(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return const AppFailure.validation('No se ha podido leer el PDF.');
    }
    final sizeError = fileSize(bytes.length, what: 'PDF');
    if (sizeError != null) return sizeError;
    if (!_startsWith(bytes, _pdfMagic)) {
      return const AppFailure.validation(
        'El fichero no es un PDF valido o esta dañado.',
      );
    }
    return null;
  }

  /// Comprueba que los bytes son una imagen que sabemos decodificar.
  static AppFailure? imageBytes(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return const AppFailure.validation('No se ha podido leer la imagen.');
    }
    final sizeError = fileSize(bytes.length, what: 'imagen');
    if (sizeError != null) return sizeError;
    if (!_startsWith(bytes, _jpegMagic) && !_startsWith(bytes, _pngMagic)) {
      // El decodificador admite mas formatos; solo descartamos lo evidente.
      if (bytes.length < 16) {
        return const AppFailure.validation('La imagen esta incompleta o dañada.');
      }
    }
    return null;
  }

  /// Verifica que un fichero existe y tiene contenido antes de usarlo.
  static Future<AppFailure?> readableFile(File file, {String what = 'fichero'}) async {
    try {
      if (!await file.exists()) {
        return AppFailure.notFound('No se encuentra el $what.');
      }
      if (await file.length() <= 0) {
        return AppFailure.validation('El $what esta vacio.');
      }
      return null;
    } catch (e) {
      return AppFailure(
        kind: FailureKind.storage,
        message: 'No se ha podido acceder al $what.',
        cause: e,
      );
    }
  }

  // ------------------------------------------------------------------ listas

  static AppFailure? nonEmptyPages(int count) {
    if (count <= 0) {
      return const AppFailure.validation(
        'El documento no tiene paginas que exportar.',
      );
    }
    return null;
  }

  static AppFailure? pageLimit(int count, int maximum) {
    if (count > maximum) {
      return AppFailure.validation(
        'Son $count paginas y este dispositivo admite $maximum de una vez. '
        'Divide el documento o exporta por partes.',
      );
    }
    return null;
  }

  static AppFailure? minimumFiles(int count, int minimum, String action) {
    if (count < minimum) {
      return AppFailure.validation(
        'Necesitas al menos $minimum ficheros para $action.',
      );
    }
    return null;
  }

  // --------------------------------------------------------------- capacidad

  /// Comprueba que queda espacio libre razonable antes de escribir algo grande.
  ///
  /// Si no se puede consultar el espacio (no todos los sistemas lo permiten),
  /// devuelve `null` y se deja continuar: mejor intentarlo que bloquear.
  static Future<AppFailure?> freeSpaceFor(Directory dir, int neededBytes) async {
    try {
      final stat = await Process.run('df', ['-k', dir.path])
          .timeout(const Duration(seconds: 3));
      if (stat.exitCode != 0) return null;
      final lines = (stat.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      final parts = lines.last.split(RegExp(r'\s+'));
      if (parts.length < 4) return null;
      final availableKb = int.tryParse(parts[3]);
      if (availableKb == null) return null;
      final availableBytes = availableKb * 1024;
      // Se exige el doble de lo necesario: hacen falta ficheros intermedios.
      if (availableBytes < neededBytes * 2) {
        final mb = (neededBytes * 2 / (1024 * 1024)).toStringAsFixed(0);
        return AppFailure(
          kind: FailureKind.storageFull,
          message: 'No hay espacio suficiente. Se necesitan unos $mb MB libres.',
          retryable: false,
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
