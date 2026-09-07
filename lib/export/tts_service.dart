import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/failure.dart';
import '../core/logger.dart';
import 'media_export.dart';

/// Sintesis de voz enteramente local.
///
/// Cada plataforma usa lo que ya trae instalado, sin enviar el documento a
/// ningun servidor: Android el motor TTS del telefono a traves de un canal
/// nativo, Windows `System.Speech` (parte del propio sistema, via PowerShell) y
/// Linux `espeak-ng` (o `espeak`).
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
      } else if (Platform.isWindows) {
        await _synthesizeWindows(
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

  /// Windows trae `System.Speech` desde Windows 7: no hay nada que instalar.
  ///
  /// El texto y el guion viajan en ficheros temporales en vez de en la linea de
  /// ordenes: asi ni las comillas, ni los acentos, ni un `$` sueltos pueden
  /// romper la llamada o ejecutar algo que no toca.
  static Future<void> _synthesizeWindows(
    String text,
    File file, {
    required String language,
    required double rate,
  }) async {
    final work = file.parent;
    final stem = file.uri.pathSegments.last;
    final textFile = File('${work.path}${Platform.pathSeparator}$stem.txt');
    final scriptFile = File('${work.path}${Platform.pathSeparator}$stem.ps1');

    try {
      await textFile.writeAsString(text, flush: true);
      await scriptFile.writeAsString(
        windowsSpeechScript(
          textPath: textFile.path,
          wavPath: file.path,
          language: language,
          rate: rate,
        ),
        flush: true,
      );

      Object? lastError;
      for (final shell in const ['powershell', 'pwsh']) {
        try {
          final result = await Process.run(shell, [
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            scriptFile.path,
          ]).timeout(const Duration(seconds: 120));
          if (result.exitCode == 0) return;
          lastError = '${result.stderr}'.trim();
        } on ProcessException catch (e) {
          lastError = e;
        }
      }

      Log.w('Audio', 'System.Speech no genero el audio: $lastError');
      throw const AppFailure(
        kind: FailureKind.document,
        message: 'El motor de voz de Windows no ha podido leer este texto. '
            'Comprueba que haya una voz instalada en Configuracion > Hora e '
            'idioma > Voz.',
      );
    } on AppFailure {
      rethrow;
    } catch (e, st) {
      throw AppFailure(
        kind: FailureKind.document,
        message: 'No se ha podido ejecutar el motor de voz de Windows.',
        cause: e,
        stackTrace: st,
      );
    } finally {
      for (final temp in [textFile, scriptFile]) {
        try {
          if (await temp.exists()) await temp.delete();
        } catch (_) {
          // Un temporal que no se deja borrar no invalida el audio.
        }
      }
    }
  }

  /// Guion de PowerShell que sintetiza a WAV.
  ///
  /// Las rutas van entre comillas simples con las comillas internas duplicadas,
  /// que es como PowerShell escapa una cadena literal: un fichero llamado
  /// `it's.wav` no puede cerrar la cadena ni colar una orden detras.
  @visibleForTesting
  static String windowsSpeechScript({
    required String textPath,
    required String wavPath,
    required String language,
    required double rate,
  }) {
    // System.Speech mide la velocidad de -10 a 10, con 0 como ritmo normal.
    final speed = (((rate.clamp(0.5, 1.6) - 1) * 10).round()).clamp(-10, 10);
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    return '''
\$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
\$texto = [System.IO.File]::ReadAllText(${quote(textPath)}, [System.Text.Encoding]::UTF8)
\$voz = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
  try {
    \$cultura = New-Object System.Globalization.CultureInfo(${quote(language)})
    \$voz.SelectVoiceByHints(
      [System.Speech.Synthesis.VoiceGender]::NotSet,
      [System.Speech.Synthesis.VoiceAge]::NotSet,
      0,
      \$cultura)
  } catch {
    # Sin voz para ese idioma se usa la predeterminada del sistema.
  }
  \$voz.Rate = $speed
  \$voz.SetOutputToWaveFile(${quote(wavPath)})
  \$voz.Speak(\$texto)
} finally {
  \$voz.Dispose()
}
''';
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
