import 'dart:math' as math;
import 'dart:typed_data';

/// Utilidades compartidas por la narracion. Android limita la cantidad de
/// texto que acepta el motor TTS en una sola llamada, por eso nunca se le
/// entrega un documento entero de golpe.
class NarrationText {
  NarrationText._();

  static List<String> split(String raw, {int maxChars = 2800}) {
    if (maxChars < 32) {
      throw ArgumentError.value(maxChars, 'maxChars', 'Debe ser al menos 32');
    }
    final normalized = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return const [];

    final chunks = <String>[];
    var current = StringBuffer();

    void flush() {
      final value = current.toString().trim();
      if (value.isNotEmpty) chunks.add(value);
      current = StringBuffer();
    }

    for (final word in normalized.split(' ')) {
      // Una URL o identificador desmesurado no puede bloquear toda la
      // exportacion. Se parte solo cuando no existe ningun limite natural.
      if (word.length > maxChars) {
        flush();
        for (var start = 0; start < word.length; start += maxChars) {
          chunks.add(word.substring(start, math.min(start + maxChars, word.length)));
        }
        continue;
      }
      final extra = current.isEmpty ? word.length : word.length + 1;
      if (current.length + extra > maxChars) flush();
      if (current.isNotEmpty) current.write(' ');
      current.write(word);
    }
    flush();
    return chunks;
  }

  /// Aproximacion conservadora para videos sin narracion o mientras aun no
  /// se conoce la duracion exacta del WAV sintetizado.
  static Duration estimatedDuration(
    String text, {
    double wordsPerMinute = 150,
  }) {
    final words = text.trim().isEmpty
        ? 0
        : text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final seconds = words == 0 ? 3.0 : math.max(3.0, words * 60 / wordsPerMinute + 0.8);
    return Duration(milliseconds: (seconds * 1000).ceil());
  }
}

/// Lector pequeno y tolerante de WAV RIFF. No asume que `fmt ` y `data`
/// esten pegados: algunos motores TTS insertan chunks LIST/JUNK intermedios.
class WavInfo {
  WavInfo._();

  static Duration? duration(Uint8List bytes) {
    if (bytes.length < 12 ||
        _ascii(bytes, 0, 4) != 'RIFF' ||
        _ascii(bytes, 8, 4) != 'WAVE') {
      return null;
    }

    final data = ByteData.sublistView(bytes);
    int? byteRate;
    int? dataSize;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = _ascii(bytes, offset, 4);
      final size = data.getUint32(offset + 4, Endian.little);
      final payload = offset + 8;
      if (payload > bytes.length || size > bytes.length - payload) return null;

      if (id == 'fmt ' && size >= 16) {
        byteRate = data.getUint32(payload + 8, Endian.little);
      } else if (id == 'data') {
        dataSize = size;
      }
      if (byteRate != null && dataSize != null) break;
      offset = payload + size + (size.isOdd ? 1 : 0);
    }

    if (byteRate == null || byteRate <= 0 || dataSize == null) return null;
    return Duration(microseconds: (dataSize * Duration.microsecondsPerSecond / byteRate).round());
  }

  static String _ascii(Uint8List bytes, int start, int count) {
    if (start < 0 || start + count > bytes.length) return '';
    return String.fromCharCodes(bytes.sublist(start, start + count));
  }
}

/// Argumentos FFmpeg como lista (no como una cadena de shell). De ese modo un
/// nombre con espacios, comillas o signos `$` nunca se ejecuta ni se rompe.
class MediaCommandPlan {
  MediaCommandPlan._();

  static List<String> audio({
    required String concatFile,
    required String outputFile,
    int bitrateKbps = 32,
  }) =>
      [
        '-y',
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        concatFile,
        '-vn',
        '-c:a',
        'aac',
        '-b:a',
        '${bitrateKbps.clamp(24, 96)}k',
        '-ac',
        '1',
        '-ar',
        '24000',
        '-movflags',
        '+faststart',
        outputFile,
      ];

  static List<String> video({
    required String imageConcatFile,
    required String outputFile,
    int width = 720,
    String? audioConcatFile,
    String videoCodec = 'mpeg4',
  }) {
    final evenWidth = math.max(320, width.clamp(320, 1920)) ~/ 2 * 2;
    final args = <String>[
      '-y',
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      imageConcatFile,
    ];
    if (audioConcatFile != null) {
      args.addAll(['-f', 'concat', '-safe', '0', '-i', audioConcatFile]);
    }
    args.addAll([
      '-vf',
      'scale=$evenWidth:-2:flags=lanczos,format=yuv420p',
      '-r',
      '20',
      '-c:v',
      videoCodec,
    ]);
    if (videoCodec == 'mpeg4') {
      args.addAll(['-q:v', '5']);
    } else {
      args.addAll(['-b:v', '1200k']);
    }
    if (audioConcatFile == null) {
      args.add('-an');
    } else {
      args.addAll([
        '-c:a',
        'aac',
        '-b:a',
        '48k',
        '-ac',
        '1',
        '-ar',
        '24000',
        '-shortest',
      ]);
    }
    args.addAll(['-movflags', '+faststart', outputFile]);
    return args;
  }
}
