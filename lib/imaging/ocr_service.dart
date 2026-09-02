import 'dart:convert';
import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../core/failure.dart';
import '../core/logger.dart';

/// Una linea reconocida con su caja, en pixeles de la imagen de origen.
class OcrLine {
  final String text;
  final double left, top, width, height;
  const OcrLine(this.text, this.left, this.top, this.width, this.height);

  Map<String, dynamic> toJson() =>
      {'t': text, 'x': left, 'y': top, 'w': width, 'h': height};

  factory OcrLine.fromJson(Map<String, dynamic> j) => OcrLine(
        j['t'] as String? ?? '',
        (j['x'] as num?)?.toDouble() ?? 0,
        (j['y'] as num?)?.toDouble() ?? 0,
        (j['w'] as num?)?.toDouble() ?? 0,
        (j['h'] as num?)?.toDouble() ?? 0,
      );
}

class OcrResult {
  final String text;
  final List<OcrLine> lines;
  const OcrResult(this.text, this.lines);

  bool get isEmpty => text.trim().isEmpty;

  String get boxesJson => jsonEncode(lines.map((l) => l.toJson()).toList());

  static List<OcrLine> parseBoxes(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      final out = <OcrLine>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        try {
          out.add(OcrLine.fromJson(Map<String, dynamic>.from(e)));
        } catch (_) {
          // Una caja corrupta no invalida el resto de la pagina.
        }
      }
      return out;
    } catch (e) {
      Log.w('OCR', 'Cajas de texto ilegibles; se ignoran', e);
      return const [];
    }
  }
}

/// Reconocimiento de texto sin conexion (ML Kit, modelo empaquetado).
class OcrService {
  OcrService._();
  static final OcrService instance = OcrService._();

  /// Solo se empaqueta el modelo latino, que es el que cubre el espanol y el
  /// resto de lenguas con alfabeto latino. Anadir chino, japones, coreano o
  /// devanagari exige incluir sus dependencias nativas (y ~40 MB mas de APK).
  TextRecognizer? _recognizer;

  TextRecognizer get _latin =>
      _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);

  /// Reconoce el texto de una imagen en disco.
  ///
  /// Lanza [AppFailure] con un motivo comprensible: el OCR depende de los
  /// servicios de Google Play, que pueden faltar o estar desactualizados.
  Future<OcrResult> recognizeFile(
    String path, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (path.isEmpty) {
      throw const AppFailure.validation('No hay imagen que analizar.');
    }
    final file = File(path);
    if (!await file.exists()) {
      throw const AppFailure.notFound('La imagen de la pagina ya no esta.');
    }

    try {
      final input = InputImage.fromFilePath(path);
      final recognized = await _latin.processImage(input).timeout(timeout);

      final lines = <OcrLine>[];
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          final r = line.boundingBox;
          if (r.width <= 0 || r.height <= 0) continue;
          if (line.text.trim().isEmpty) continue;
          lines.add(OcrLine(
            line.text,
            r.left.toDouble(),
            r.top.toDouble(),
            r.width.toDouble(),
            r.height.toDouble(),
          ));
        }
      }
      return OcrResult(recognized.text, lines);
    } on AppFailure {
      rethrow;
    } catch (e, st) {
      final text = e.toString().toLowerCase();
      if (text.contains('google play') || text.contains('unavailable')) {
        throw AppFailure(
          kind: FailureKind.ocr,
          message: 'El reconocimiento de texto necesita los Servicios de Google '
              'Play actualizados en este dispositivo.',
          cause: e,
          stackTrace: st,
          retryable: false,
        );
      }
      throw AppFailure(
        kind: FailureKind.ocr,
        message: 'No se ha podido reconocer el texto de esta pagina.',
        cause: e,
        stackTrace: st,
      );
    }
  }

  Future<void> dispose() async {
    try {
      await _recognizer?.close();
    } catch (e) {
      Log.w('OCR', 'Error cerrando el reconocedor', e);
    }
    _recognizer = null;
  }
}
