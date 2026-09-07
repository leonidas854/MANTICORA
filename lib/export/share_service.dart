import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../core/failure.dart';
import '../core/logger.dart';
import 'file_saver.dart';

/// Forma segura de entregar ficheros en cada plataforma.
enum FileDeliveryStrategy {
  /// Panel nativo de Android/iOS/macOS/Windows o Web Share.
  platformShare,

  /// Selector de destino para un unico fichero.
  saveAs,

  /// ZIP seguido del selector de destino para varios ficheros.
  bundleAndSave,
}

/// Resultado observable de una entrega. [savedLocation] es nulo si se cancelo
/// el selector; [shareResult] conserva el resultado que devuelva el sistema.
class FileDeliveryResult {
  final FileDeliveryStrategy strategy;
  final String? savedLocation;
  final ShareResult? shareResult;

  const FileDeliveryResult({
    required this.strategy,
    this.savedLocation,
    this.shareResult,
  });

  bool get wasCancelled =>
      strategy != FileDeliveryStrategy.platformShare && savedLocation == null;
}

/// Centraliza compartir/guardar para no invocar una funcion no soportada.
///
/// `share_plus` no admite adjuntos en Linux. Alli un fichero se guarda con el
/// selector del sistema y varios se empaquetan primero en ZIP, de modo que
/// nunca se pierda silenciosamente parte de la seleccion.
///
/// Windows si tiene panel nativo, pero solo desde Windows 10 1809; en versiones
/// anteriores `share_plus` lanza [UnimplementedError] y aqui se cae con
/// naturalidad al mismo guardado que en Linux en lugar de dar un error.
abstract final class ShareService {
  static const String _tag = 'Compartir';

  /// Como se guarda un fichero cuando no hay panel de compartir.
  ///
  /// Es un punto de sustitucion para las pruebas: asi se puede comprobar el
  /// camino de Linux y el de un Windows antiguo sin abrir un dialogo real.
  @visibleForTesting
  static Future<String?> Function(String fileName, Uint8List bytes) saveFile =
      FileSaver.save;

  /// Como se abre el panel del sistema. Igual que [saveFile], es un punto de
  /// sustitucion para poder comprobar en pruebas lo que recibe cada plataforma.
  @visibleForTesting
  static Future<ShareResult> Function(ShareParams params) shareWithSystem =
      (params) => SharePlus.instance.share(params);

  /// Devuelve compartir y guardar a su comportamiento normal.
  @visibleForTesting
  static void resetSaverForTesting() {
    saveFile = FileSaver.save;
    shareWithSystem = (params) => SharePlus.instance.share(params);
  }

  static FileDeliveryStrategy strategyFor(
    TargetPlatform platform, {
    required int fileCount,
    bool isWeb = false,
  }) {
    if (isWeb) return FileDeliveryStrategy.platformShare;
    if (platform == TargetPlatform.linux) {
      return fileCount > 1
          ? FileDeliveryStrategy.bundleAndSave
          : FileDeliveryStrategy.saveAs;
    }
    return FileDeliveryStrategy.platformShare;
  }

  static String mimeFor(String fileName) => FileSaver.mimeFor(fileName);

  /// Entrega uno o varios ficheros con la estrategia valida para la plataforma.
  /// En Android el panel nativo mostrara WhatsApp si esta instalado y acepta el
  /// tipo de fichero. En Linux se ofrece un guardado porque el panel disponible
  /// no soporta adjuntos.
  static Future<FileDeliveryResult> deliverFiles({
    required List<XFile> files,
    String? subject,
    String? text,
    String bundleName = 'archivos-manticora.zip',
    Rect? sharePositionOrigin,
    TargetPlatform? platform,
    bool? isWeb,
  }) async {
    if (files.isEmpty) {
      throw const AppFailure.validation('No hay archivos que compartir.');
    }

    final effectivePlatform = platform ?? defaultTargetPlatform;
    final effectiveIsWeb = isWeb ?? kIsWeb;
    final strategy = strategyFor(
      effectivePlatform,
      fileCount: files.length,
      isWeb: effectiveIsWeb,
    );

    try {
      await _validateFiles(files);
      try {
        return await switch (strategy) {
          FileDeliveryStrategy.platformShare => _share(
            files,
            subject: subject,
            text: text,
            sharePositionOrigin: sharePositionOrigin,
          ),
          FileDeliveryStrategy.saveAs => _saveOne(files.single),
          FileDeliveryStrategy.bundleAndSave => _bundleAndSave(
            files,
            bundleName: bundleName,
          ),
        };
      } on UnimplementedError catch (e) {
        if (strategy != FileDeliveryStrategy.platformShare) rethrow;
        // Sistema sin panel para adjuntos: se guarda, que es lo unico que
        // queda, en vez de dejar a la persona sin su fichero.
        Log.w(_tag, 'Sin panel de compartir con adjuntos; se guarda el archivo', e);
        return files.length == 1
            ? await _saveOne(files.single)
            : await _bundleAndSave(files, bundleName: bundleName);
      }
    } on AppFailure {
      rethrow;
    } on UnimplementedError catch (e, st) {
      throw AppFailure(
        kind: FailureKind.unsupported,
        message:
            'Esta plataforma no permite adjuntar archivos al panel de '
            'compartir. Guarda el resultado y adjuntalo desde la aplicacion de destino.',
        context: 'Compartiendo archivos',
        cause: e,
        stackTrace: st,
        retryable: false,
      );
    } catch (e, st) {
      throw AppFailure.from(e, st, 'Compartiendo archivos');
    }
  }

  static Future<FileDeliveryResult> _share(
    List<XFile> files, {
    String? subject,
    String? text,
    Rect? sharePositionOrigin,
  }) async {
    final result = await shareWithSystem(
      ShareParams(
        files: files,
        subject: subject,
        title: subject,
        text: text,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
    Log.i(_tag, 'Panel de compartir abierto para ${files.length} archivo(s)');
    return FileDeliveryResult(
      strategy: FileDeliveryStrategy.platformShare,
      shareResult: result,
    );
  }

  static Future<void> _validateFiles(List<XFile> files) async {
    for (final file in files) {
      if (await file.length() <= 0) {
        throw AppFailure.validation(
          'El archivo ${_safeEntryName(file, fallback: 'seleccionado')} esta vacio.',
        );
      }
    }
  }

  static Future<FileDeliveryResult> _saveOne(XFile file) async {
    final bytes = await _readNonEmpty(file);
    final name = _safeEntryName(file, fallback: 'archivo-manticora');
    final saved = await saveFile(name, bytes);
    return FileDeliveryResult(
      strategy: FileDeliveryStrategy.saveAs,
      savedLocation: saved,
    );
  }

  static Future<FileDeliveryResult> _bundleAndSave(
    List<XFile> files, {
    required String bundleName,
  }) async {
    final archive = Archive();
    final usedNames = <String>{};

    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final bytes = await _readNonEmpty(file);
      final base = _safeEntryName(file, fallback: 'archivo-${i + 1}');
      final unique = _uniqueName(base, usedNames);
      archive.addFile(ArchiveFile(unique, bytes.length, bytes));
    }

    final encoded = ZipEncoder().encode(archive);
    if (encoded.isEmpty) {
      throw const AppFailure.validation(
        'No se ha podido crear el archivo ZIP.',
      );
    }
    final bytes = Uint8List.fromList(encoded);
    final name = _safeZipName(bundleName);
    final saved = await saveFile(name, bytes);
    Log.i(_tag, 'Empaquetados ${files.length} archivos en $name');
    return FileDeliveryResult(
      strategy: FileDeliveryStrategy.bundleAndSave,
      savedLocation: saved,
    );
  }

  static Future<Uint8List> _readNonEmpty(XFile file) async {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw AppFailure.validation(
        'El archivo ${_safeEntryName(file, fallback: 'seleccionado')} esta vacio.',
      );
    }
    return bytes;
  }

  static String _safeEntryName(XFile file, {required String fallback}) {
    final candidate = file.name.trim().isNotEmpty
        ? file.name
        : p.basename(file.path);
    final base = p.basename(candidate).trim();
    return base.isEmpty || base == '.' ? fallback : base;
  }

  static String _uniqueName(String requested, Set<String> used) {
    if (used.add(requested)) return requested;
    final extension = p.extension(requested);
    final stem = p.basenameWithoutExtension(requested);
    var suffix = 2;
    while (true) {
      final candidate = '$stem-$suffix$extension';
      if (used.add(candidate)) return candidate;
      suffix++;
    }
  }

  static String _safeZipName(String requested) {
    var name = p.basename(requested.trim());
    if (name.isEmpty || name == '.') name = 'archivos-manticora.zip';
    if (p.extension(name).toLowerCase() != '.zip') name = '$name.zip';
    return name;
  }
}
