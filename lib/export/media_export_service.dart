import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/device_profile.dart';
import '../core/failure.dart';
import '../core/logger.dart';
import '../core/validators.dart';
import '../data/repositories/storage_service.dart';
import 'media_export.dart';
import 'tts_service.dart';

enum MediaExportKind { audio, video }

class MediaPageInput {
  final String title;
  final String text;
  final File? imageFile;

  const MediaPageInput({
    this.title = '',
    this.text = '',
    this.imageFile,
  });
}

class MediaExportOptions {
  final bool narrated;
  final int secondsPerPage;
  final int videoWidth;
  final int audioBitrateKbps;
  final String language;
  final double speechRate;

  const MediaExportOptions({
    this.narrated = true,
    this.secondsPerPage = 5,
    this.videoWidth = 720,
    this.audioBitrateKbps = 32,
    this.language = 'es-ES',
    this.speechRate = 1,
  });
}

class MediaExportResult {
  final File file;
  final MediaExportKind kind;
  final Duration duration;
  final bool narrated;

  const MediaExportResult({
    required this.file,
    required this.kind,
    required this.duration,
    required this.narrated,
  });
}

/// Exporta narraciones M4A y presentaciones MP4 de forma local.
///
/// - M4A: AAC mono a 32 kbit/s por defecto, pequeno y aceptado por WhatsApp.
/// - MP4: intenta H.264 del sistema y cae a MPEG-4 si el dispositivo no lo
///   expone. Siempre usa yuv420p y `faststart` para maxima compatibilidad.
class MediaExportService {
  MediaExportService._();
  static final MediaExportService instance = MediaExportService._();

  static const _tag = 'Multimedia';

  Future<MediaExportResult> toAudio(
    List<MediaPageInput> pages, {
    required String title,
    MediaExportOptions options = const MediaExportOptions(),
    void Function(String message)? onProgress,
  }) async {
    _validatePages(pages, requireImages: false);
    if (!pages.any((page) => page.text.trim().isNotEmpty)) {
      throw const AppFailure.validation(
        'No hay texto que convertir en audio. Ejecuta primero el OCR.',
      );
    }

    final work = await _newWorkDirectory();
    try {
      final speech = await _prepareSpeech(
        pages,
        work,
        options,
        includeSilenceForEmptyPages: false,
        onProgress: onProgress,
      );
      final concat = await _writeAudioConcat(work, speech.files);
      final output = File(p.join(
        (await StorageService.instance.exportsDir).path,
        Validators.safeFileName(title, 'm4a'),
      ));

      onProgress?.call('Comprimiendo audio ligero...');
      await _runOrThrow(
        MediaCommandPlan.audio(
          concatFile: concat.path,
          outputFile: output.path,
          bitrateKbps: options.audioBitrateKbps,
        ),
        operation: 'Creando el audio',
      );
      await _validateOutput(output, 'audio');
      Log.i(
        _tag,
        'Audio creado: ${output.path} (${await output.length()} bytes, '
            '${speech.duration.inSeconds}s)',
      );
      return MediaExportResult(
        file: output,
        kind: MediaExportKind.audio,
        duration: speech.duration,
        narrated: true,
      );
    } finally {
      await _deleteQuietly(work);
    }
  }

  Future<MediaExportResult> toVideo(
    List<MediaPageInput> pages, {
    required String title,
    MediaExportOptions options = const MediaExportOptions(),
    void Function(String message)? onProgress,
  }) async {
    _validatePages(pages, requireImages: true);
    if (options.narrated && !pages.any((p) => p.text.trim().isNotEmpty)) {
      throw const AppFailure.validation(
        'No hay texto para narrar. Crea el video sin audio o ejecuta el OCR.',
      );
    }

    final work = await _newWorkDirectory();
    try {
      _PreparedSpeech? speech;
      List<Duration> durations;
      if (options.narrated) {
        speech = await _prepareSpeech(
          pages,
          work,
          options,
          includeSilenceForEmptyPages: true,
          onProgress: onProgress,
        );
        durations = speech.pageDurations;
      } else {
        durations = List<Duration>.filled(
          pages.length,
          Duration(seconds: options.secondsPerPage.clamp(2, 30)),
        );
      }

      final imageConcat = await _writeImageConcat(work, pages, durations);
      final audioConcat = speech == null
          ? null
          : await _writeAudioConcat(work, speech.files);
      final output = File(p.join(
        (await StorageService.instance.exportsDir).path,
        Validators.safeFileName(title, 'mp4'),
      ));

      onProgress?.call('Codificando video para compartir...');
      final codecs = Platform.isAndroid
          ? const ['h264_mediacodec', 'mpeg4']
          : const ['libx264', 'mpeg4'];
      Object? lastError;
      for (final codec in codecs) {
        try {
          await _runOrThrow(
            MediaCommandPlan.video(
              imageConcatFile: imageConcat.path,
              audioConcatFile: audioConcat?.path,
              outputFile: output.path,
              width: _effectiveVideoWidth(options.videoWidth),
              videoCodec: codec,
            ),
            operation: 'Codificando video con $codec',
          );
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          Log.w(_tag, 'El codec $codec no esta disponible; se prueba otro', e);
        }
      }
      if (lastError != null) throw lastError;

      await _validateOutput(output, 'video');
      final duration = durations.fold<Duration>(
        Duration.zero,
        (total, value) => total + value,
      );
      Log.i(
        _tag,
        'Video creado: ${output.path} (${await output.length()} bytes, '
            '${duration.inSeconds}s, narrado=${options.narrated})',
      );
      return MediaExportResult(
        file: output,
        kind: MediaExportKind.video,
        duration: duration,
        narrated: options.narrated,
      );
    } finally {
      await _deleteQuietly(work);
    }
  }

  int _effectiveVideoWidth(int requested) {
    final capped = switch (DeviceProfile.current.tier) {
      DeviceTier.low => math.min(requested, 640),
      DeviceTier.mid => math.min(requested, 960),
      DeviceTier.high => math.min(requested, 1280),
    };
    return math.max(320, capped) ~/ 2 * 2;
  }

  void _validatePages(List<MediaPageInput> pages, {required bool requireImages}) {
    final empty = Validators.nonEmptyPages(pages.length);
    if (empty != null) throw empty;
    final limit = Validators.pageLimit(
      pages.length,
      DeviceProfile.current.maxPagesPerExport,
    );
    if (limit != null) throw limit;
    if (requireImages) {
      for (var i = 0; i < pages.length; i++) {
        final file = pages[i].imageFile;
        if (file == null || !file.existsSync() || file.lengthSync() == 0) {
          throw AppFailure.notFound(
            'Falta la imagen de la pagina ${i + 1}; no se puede crear el video.',
          );
        }
      }
    }
  }

  Future<_PreparedSpeech> _prepareSpeech(
    List<MediaPageInput> pages,
    Directory work,
    MediaExportOptions options, {
    required bool includeSilenceForEmptyPages,
    void Function(String message)? onProgress,
  }) async {
    final files = <File>[];
    final pageDurations = <Duration>[];

    for (var i = 0; i < pages.length; i++) {
      final text = pages[i].text.trim();
      if (text.isEmpty) {
        if (!includeSilenceForEmptyPages) continue;
        final duration = Duration(seconds: options.secondsPerPage.clamp(2, 30));
        final silence = File(p.join(work.path, 'silencio-$i.wav'));
        await silence.writeAsBytes(_silentWav(duration), flush: true);
        files.add(silence);
        pageDurations.add(duration);
        continue;
      }

      onProgress?.call('Narrando pagina ${i + 1} de ${pages.length}...');
      final chunks = await TtsService.synthesize(
        text,
        directory: work,
        prefix: 'pagina-${i.toString().padLeft(3, '0')}',
        language: options.language,
        rate: options.speechRate,
      );
      var pageDuration = Duration.zero;
      for (final chunk in chunks) {
        final bytes = await chunk.readAsBytes();
        pageDuration += WavInfo.duration(bytes) ?? NarrationText.estimatedDuration(text);
        files.add(chunk);
      }
      pageDurations.add(pageDuration);
    }

    if (files.isEmpty) {
      throw const AppFailure.validation('No hay texto util que narrar.');
    }
    final total = pageDurations.fold<Duration>(
      Duration.zero,
      (sum, duration) => sum + duration,
    );
    return _PreparedSpeech(files, pageDurations, total);
  }

  Future<Directory> _newWorkDirectory() async {
    final base = await StorageService.instance.tmpDir;
    final dir = Directory(p.join(base.path, 'media-${const Uuid().v4()}'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _writeAudioConcat(Directory work, List<File> files) async {
    final out = File(p.join(work.path, 'audio.ffconcat'));
    final content = StringBuffer('ffconcat version 1.0\n');
    for (final file in files) {
      content.writeln("file '${_concatEscape(file.absolute.path)}'");
    }
    return out.writeAsString(content.toString(), flush: true);
  }

  Future<File> _writeImageConcat(
    Directory work,
    List<MediaPageInput> pages,
    List<Duration> durations,
  ) async {
    final out = File(p.join(work.path, 'imagenes.ffconcat'));
    final content = StringBuffer('ffconcat version 1.0\n');
    for (var i = 0; i < pages.length; i++) {
      final path = pages[i].imageFile!.absolute.path;
      final seconds = math.max(0.5, durations[i].inMilliseconds / 1000);
      content
        ..writeln("file '${_concatEscape(path)}'")
        ..writeln('duration ${seconds.toStringAsFixed(3)}');
    }
    // El demuxer concat ignora la duracion de la ultima imagen si no se
    // repite. Repetirla no anade otra pagina; solo cierra su intervalo.
    content.writeln("file '${_concatEscape(pages.last.imageFile!.absolute.path)}'");
    return out.writeAsString(content.toString(), flush: true);
  }

  String _concatEscape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll("'", r"'\''");

  /// Ejecuta FFmpeg con el motor que corresponda a la plataforma.
  ///
  /// Android y Windows llevan FFmpeg empaquetado con el plugin, asi que no hay
  /// nada que instalar. Linux no lo empaqueta y usa el `ffmpeg` del sistema. Si
  /// el motor empaquetado no esta disponible en un escritorio (por ejemplo
  /// porque la compilacion no pudo descargar sus binarios), se recurre al
  /// `ffmpeg` del sistema antes de darse por vencido.
  Future<void> _runOrThrow(
    List<String> arguments, {
    required String operation,
  }) async {
    if (Platform.isLinux) return _runSystemFfmpeg(arguments, operation: operation);

    try {
      await _runBundledFfmpeg(arguments, operation: operation);
    } on MissingPluginException catch (e) {
      if (!_isDesktop) {
        throw AppFailure(
          kind: FailureKind.unsupported,
          message: 'Esta version no incluye el codificador multimedia.',
          context: operation,
          cause: e,
          retryable: false,
        );
      }
      Log.w(_tag, 'FFmpeg empaquetado no disponible; se usa el del sistema', e);
      await _runSystemFfmpeg(arguments, operation: operation);
    }
  }

  bool get _isDesktop =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  Future<void> _runSystemFfmpeg(
    List<String> arguments, {
    required String operation,
  }) async {
    try {
      final result = await Process.run('ffmpeg', arguments)
          .timeout(const Duration(minutes: 12));
      if (result.exitCode == 0) return;
      final detail = '${result.stderr}'.trim();
      throw AppFailure(
        kind: FailureKind.document,
        message: 'No se ha podido terminar la conversion multimedia.',
        context: operation,
        cause: detail.length > 1200 ? detail.substring(detail.length - 1200) : detail,
      );
    } on ProcessException catch (e, st) {
      throw AppFailure(
        kind: FailureKind.unsupported,
        message: Platform.isWindows
            ? 'Falta FFmpeg. Instalalo con "winget install Gyan.FFmpeg" y '
                'vuelve a intentarlo.'
            : 'Falta FFmpeg en este escritorio. Instala el paquete "ffmpeg" '
                'para crear audio y video.',
        context: operation,
        cause: e,
        stackTrace: st,
        retryable: false,
      );
    }
  }

  Future<void> _runBundledFfmpeg(
    List<String> arguments, {
    required String operation,
  }) async {
    try {
      final session = await FFmpegKit.executeWithArguments(arguments)
          .timeout(const Duration(minutes: 12));
      final code = await session.getReturnCode();
      if (ReturnCode.isSuccess(code)) return;
      final logs = (await session.getAllLogsAsString()) ?? '';
      throw AppFailure(
        kind: FailureKind.document,
        message: 'No se ha podido terminar la conversion multimedia.',
        context: operation,
        cause: logs.length > 1200 ? logs.substring(logs.length - 1200) : logs,
      );
    } on AppFailure {
      rethrow;
    } on MissingPluginException {
      rethrow;
    } catch (e, st) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'El codificador multimedia no responde.',
        context: operation,
        cause: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _validateOutput(File file, String what) async {
    if (!await file.exists() || await file.length() < 128) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'El $what generado ha salido vacio.',
      );
    }
  }

  Uint8List _silentWav(Duration duration, {int sampleRate = 16000}) {
    final samples = math.max(1, duration.inMilliseconds * sampleRate ~/ 1000);
    final dataSize = samples * 2; // PCM 16-bit mono.
    final bytes = Uint8List(44 + dataSize);
    final data = ByteData.sublistView(bytes);

    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes[offset + i] = value.codeUnitAt(i);
      }
    }

    writeAscii(0, 'RIFF');
    data.setUint32(4, 36 + dataSize, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    data.setUint32(40, dataSize, Endian.little);
    return bytes;
  }

  Future<void> _deleteQuietly(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (e) {
      Log.w(_tag, 'No se pudo retirar un temporal multimedia', e);
    }
  }
}

class _PreparedSpeech {
  final List<File> files;
  final List<Duration> pageDurations;
  final Duration duration;
  const _PreparedSpeech(this.files, this.pageDurations, this.duration);
}
