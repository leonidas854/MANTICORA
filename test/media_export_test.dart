import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/export/media_export.dart';

void main() {
  group('NarrationText', () {
    test('divide texto largo sin perder ni cortar palabras', () {
      final original = List.generate(260, (i) => 'palabra$i').join(' ');
      final chunks = NarrationText.split(original, maxChars: 240);

      expect(chunks.length, greaterThan(1));
      expect(chunks.every((chunk) => chunk.length <= 240), isTrue);
      expect(chunks.join(' '), original);
    });

    test('estima al menos unos segundos por pagina', () {
      expect(
        NarrationText.estimatedDuration('Titulo corto'),
        greaterThanOrEqualTo(const Duration(seconds: 3)),
      );
    });
  });

  group('WavInfo', () {
    test('lee la duracion de PCM incluso con chunks extra', () {
      final wav = _wav(sampleRate: 16000, channels: 1, seconds: 2);
      expect(WavInfo.duration(wav), const Duration(seconds: 2));
    });

    test('no acepta bytes que solo tengan extension WAV', () {
      expect(WavInfo.duration(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  group('MediaCommandPlan', () {
    test('el audio es AAC mono de bajo bitrate y apto para compartir', () {
      final args = MediaCommandPlan.audio(
        concatFile: '/tmp/audio concat.txt',
        outputFile: '/tmp/salida.m4a',
        bitrateKbps: 32,
      );

      expect(args, containsAllInOrder(['-c:a', 'aac', '-b:a', '32k']));
      expect(args, containsAllInOrder(['-ac', '1', '-movflags', '+faststart']));
      expect(args.last, '/tmp/salida.m4a');
    });

    test('el video narrado usa pixeles pares, audio AAC y termina con el audio', () {
      final args = MediaCommandPlan.video(
        imageConcatFile: '/tmp/paginas.txt',
        outputFile: '/tmp/video.mp4',
        width: 721,
        audioConcatFile: '/tmp/voz.txt',
      );
      final joined = args.join(' ');

      expect(joined, contains('scale=720:-2'));
      expect(args, containsAllInOrder(['-c:a', 'aac']));
      expect(args, contains('-shortest'));
      expect(args, contains('+faststart'));
    });

    test('el video silencioso no inventa una pista de audio', () {
      final args = MediaCommandPlan.video(
        imageConcatFile: '/tmp/paginas.txt',
        outputFile: '/tmp/video.mp4',
        width: 720,
      );

      expect(args, contains('-an'));
      expect(args, isNot(contains('-shortest')));
    });
  });
}

Uint8List _wav({
  required int sampleRate,
  required int channels,
  required int seconds,
}) {
  const bits = 16;
  final dataSize = sampleRate * channels * (bits ~/ 8) * seconds;
  final out = Uint8List(44 + dataSize);
  final data = ByteData.sublistView(out);

  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      out[offset + i] = value.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + dataSize, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, bits, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, dataSize, Endian.little);
  return out;
}
