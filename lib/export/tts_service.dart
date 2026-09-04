import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/failure.dart';
import '../core/logger.dart';
import 'media_export.dart';

/// Sintesis de voz enteramente local.
///
/// Android usa el motor TTS instalado en el telefono mediante un canal nativo;
/// Linux usa `espeak-ng` (o `espeak`) sin pasar el documento por un servidor.
class TtsService {
  TtsService._();

  static const MethodChannel _androidChannel = MethodChannel('manticora/tts');

  /// Devuelve uno o mas WAV porque los motores de Android limitan cada frase.
  static Future<List<File>> synthesize(
    String text, {
    required Directory directory,
    required String prefix,
    String language = 'es-ES',
    double rate = 1,
  }) async {
    final chunks = NarrationText.split(text);
    if (chunks.isEmpty) {
      throw const AppFailure.validation(
        'No hay texto que convertir en voz. Ejecuta el OCR primero.',
      );
    }
    await directory.create(recursive: true);

    final output = <File>[];
    for (var i = 0; i < chunks.length; i++) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}$prefix-${i.toString().padLeft(3, '0')}.wav',
      );
      if (await file.exists()) await file.delete();

      if (Platform.isAndroid) {
        await _synthesizeAndroid(
          chunks[i],
          file,
          language: language,
          rate: rate,
        );
      } else if (Platform.isLinux) {
        await _synthesizeLinux(
          chunks[i],
          file,
          language: language,
          rate: rate,
        );
      } else {
        throw const AppFailure(
          kind: FailureKind.unsupported,
          message: 'La conversion a voz todavia no esta disponible en esta plataforma.',
          retryable: false,
        );
      }

      if (!await file.exists() || await file.length() < 44) {
        throw const AppFailure(
          kind: FailureKind.document,
          message: 'El motor de voz no ha generado un audio valido.',
        );
      }
      output.add(file);
    }
    return output;
  }

  static Future<void> _synthesizeAndroid(
    String text,
    File file, {
    required String language,
    required double rate,
  }) async {
    try {
      await _androidChannel
          .invokeMethod<void>('synthesize', {
            'text': text,
            'path': file.path,
            'language': language,
            'rate': rate.clamp(0.5, 1.6),
          })
          .timeout(const Duration(seconds: 90));
    } on AppFailure {
      rethrow;
    } catch (e, st) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'No se ha podido crear la narracion. Comprueba que el '
            'telefono tenga instalada una voz en espanol.',
        cause: e,
        stackTrace: st,
      );
    }
  }

  static Future<void> _synthesizeLinux(
    String text,
    File file, {
    required String language,
    required double rate,
  }) async {
    String? executable;
    for (final candidate in const ['espeak-ng', 'espeak']) {
      try {
        final probe = await Process.run(candidate, const ['--version']);
        if (probe.exitCode == 0) {
          executable = candidate;
          break;
        }
      } on ProcessException {
        // Se prueba el siguiente nombre.
      }
    }
    if (executable == null) {
      throw const AppFailure(
        kind: FailureKind.unsupported,
        message: 'Falta el motor de voz de escritorio. Instala "espeak-ng" '
            'y vuelve a intentarlo.',
        retryable: false,
      );
    }

    final voice = language.split(RegExp('[-_]')).first.toLowerCase();
    final wordsPerMinute = (165 * rate.clamp(0.5, 1.6)).round();
    try {
      final process = await Process.start(executable, [
        '-v',
        voice,
        '-s',
        '$wordsPerMinute',
        '-w',
        file.path,
        '--stdin',
      ]);
      final stderrFuture = utf8.decoder.bind(process.stderr).join();
      final stdoutFuture = process.stdout.drain<void>();
      process.stdin.write(text);
      await process.stdin.close();
      final exit = await process.exitCode.timeout(const Duration(seconds: 90));
      await stdoutFuture;
      final stderr = await stderrFuture;
      if (exit != 0) {
        Log.w('Audio', 'espeak termino con codigo $exit: $stderr');
        throw AppFailure(
          kind: FailureKind.document,
          message: 'El motor de voz no ha podido leer este texto.',
          retryable: false,
        );
      }
    } on AppFailure {
      rethrow;
    } catch (e, st) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'No se ha podido ejecutar el motor de voz del escritorio.',
        cause: e,
        stackTrace: st,
      );
    }
  }
}
