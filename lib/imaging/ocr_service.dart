import 'dart:convert';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

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
      final list = jsonDecode(json) as List;
      return list
          .map((e) => OcrLine.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}

/// Reconocimiento de texto sin conexion (ML Kit, modelo empaquetado).
class OcrService {
  OcrService._();
  static final OcrService instance = OcrService._();

  final Map<TextRecognitionScript, TextRecognizer> _recognizers = {};

  TextRecognizer _recognizer(TextRecognitionScript script) =>
      _recognizers.putIfAbsent(script, () => TextRecognizer(script: script));

  /// Reconoce el texto de una imagen en disco.
  Future<OcrResult> recognizeFile(
    String path, {
    TextRecognitionScript script = TextRecognitionScript.latin,
  }) async {
    final input = InputImage.fromFilePath(path);
    final recognized = await _recognizer(script).processImage(input);

    final lines = <OcrLine>[];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        final r = line.boundingBox;
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
  }

  Future<void> dispose() async {
    for (final r in _recognizers.values) {
      await r.close();
    }
    _recognizers.clear();
  }
}
