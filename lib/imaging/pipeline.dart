import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'detector.dart';
import 'filters.dart';
import 'geometry.dart';
import 'raster.dart';

/// Resultado de procesar una pagina: JPEG listo para guardar + miniatura.
class ProcessedPage {
  final Uint8List jpeg;
  final Uint8List thumbnail;
  final int width, height;
  const ProcessedPage(this.jpeg, this.thumbnail, this.width, this.height);
}

/// Todo el trabajo pesado de imagen vive aqui y se ejecuta SIEMPRE en un
/// isolate, para que la interfaz nunca pierda fotogramas.
class ImagePipeline {
  /// Lado mayor de la imagen procesada que se guarda en disco.
  /// 2400 px ≈ 200 ppp en A4: nitidez de sobra para imprimir y OCR.
  static const int maxOutputSide = 2400;
  static const int thumbSide = 320;
  static const int jpegQuality = 88;

  // -------------------------------------------------------------- deteccion

  /// Detecta el documento en un JPEG. Devuelve el cuadrilatero en coordenadas
  /// de la imagen original (pixeles).
  static Future<Quad?> detectInJpeg(Uint8List jpegBytes) =>
      Isolate.run(() => _detectInJpegSync(jpegBytes));

  static Quad? _detectInJpegSync(Uint8List jpegBytes) {
    final decoded = img.decodeJpg(jpegBytes);
    if (decoded == null) return null;
    final rgb = _toRgb(decoded);
    return DocumentDetector.detect(rgbToGray(rgb));
  }

  /// Detecta sobre el plano de luminancia de un fotograma de camara (YUV420).
  /// No hace falta convertir a RGB: el plano Y ya es la escala de grises.
  static Future<Quad?> detectInLuma(
    Uint8List luma,
    int width,
    int height,
    int rowStride,
  ) =>
      Isolate.run(() {
        final packed = _packLuma(luma, width, height, rowStride);
        final gray = GrayImage(width, height, packed);
        return DocumentDetector.detect(gray);
      });

  static Uint8List _packLuma(Uint8List src, int w, int h, int stride) {
    if (stride == w && src.length >= w * h) {
      return Uint8List.sublistView(src, 0, w * h);
    }
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final s = y * stride;
      if (s + w > src.length) break;
      out.setRange(y * w, y * w + w, src, s);
    }
    return out;
  }

  // -------------------------------------------------------------- procesado

  /// Recorta con correccion de perspectiva, aplica filtro y codifica a JPEG.
  static Future<ProcessedPage> processPage({
    required Uint8List sourceJpeg,
    Quad? quad,
    ScanFilter filter = ScanFilter.magic,
    Adjustments adjustments = Adjustments.none,
    int rotationQuarterTurns = 0,
    int maxSide = maxOutputSide,
  }) =>
      Isolate.run(() => _processSync(
            sourceJpeg,
            quad,
            filter,
            adjustments,
            rotationQuarterTurns,
            maxSide,
          ));

  static ProcessedPage _processSync(
    Uint8List sourceJpeg,
    Quad? quad,
    ScanFilter filter,
    Adjustments adjustments,
    int rotation,
    int maxSide,
  ) {
    final decoded = img.decodeJpg(sourceJpeg);
    if (decoded == null) {
      throw const FormatException('No se pudo decodificar la imagen');
    }
    var rgb = _toRgb(decoded);

    // 1. Perspectiva.
    if (quad != null) {
      var dw = quad.targetWidth, dh = quad.targetHeight;
      final longest = math.max(dw, dh);
      if (longest > maxSide) {
        final s = maxSide / longest;
        dw = math.max(16, (dw * s).round());
        dh = math.max(16, (dh * s).round());
      }
      rgb = warpPerspective(rgb, quad, dw, dh);
    } else {
      rgb = _fit(rgb, maxSide);
    }

    // 2. Rotacion.
    if (rotation % 4 != 0) rgb = rotate90(rgb, rotation);

    // 3. Filtro y ajustes.
    rgb = applyFilter(rgb, filter, adjustments);

    // 4. Codificacion.
    final full = _fromRgb(rgb);
    final jpeg = Uint8List.fromList(img.encodeJpg(full, quality: jpegQuality));

    final t = _fit(rgb, thumbSide);
    final thumb = Uint8List.fromList(img.encodeJpg(_fromRgb(t), quality: 78));

    return ProcessedPage(jpeg, thumb, rgb.width, rgb.height);
  }

  /// Genera una miniatura a partir de un JPEG existente.
  static Future<Uint8List> thumbnail(Uint8List jpegBytes, {int side = thumbSide}) =>
      Isolate.run(() {
        final decoded = img.decodeJpg(jpegBytes);
        if (decoded == null) return Uint8List(0);
        final small = _fit(_toRgb(decoded), side);
        return Uint8List.fromList(img.encodeJpg(_fromRgb(small), quality: 78));
      });

  /// Reduce un JPEG manteniendo proporciones (usado al importar y comprimir).
  static Future<Uint8List> recompress(
    Uint8List jpegBytes, {
    int maxSide = maxOutputSide,
    int quality = jpegQuality,
  }) =>
      Isolate.run(() {
        final decoded = img.decodeJpg(jpegBytes);
        if (decoded == null) return jpegBytes;
        final small = _fit(_toRgb(decoded), maxSide);
        return Uint8List.fromList(img.encodeJpg(_fromRgb(small), quality: quality));
      });

  /// Normaliza cualquier formato de entrada (PNG, HEIC ya decodificado, ...)
  /// a un JPEG con la orientacion EXIF ya aplicada.
  static Future<Uint8List?> normalizeToJpeg(Uint8List bytes, {int maxSide = 3200}) =>
      Isolate.run(() {
        final decoded = img.decodeImage(bytes);
        if (decoded == null) return null;
        final oriented = img.bakeOrientation(decoded);
        final rgb = _fit(_toRgb(oriented), maxSide);
        return Uint8List.fromList(img.encodeJpg(_fromRgb(rgb), quality: 92));
      });

  // ------------------------------------------------------------- utilidades

  static RgbImage _fit(RgbImage src, int maxSide) {
    final longest = math.max(src.width, src.height);
    if (longest <= maxSide) return src;
    final s = maxSide / longest;
    return downscaleRgb(src, math.max(1, (src.width * s).round()),
        math.max(1, (src.height * s).round()));
  }

  static RgbImage _toRgb(img.Image src) {
    final bytes = src.getBytes(order: img.ChannelOrder.rgb);
    return RgbImage(src.width, src.height, Uint8List.fromList(bytes));
  }

  static img.Image _fromRgb(RgbImage src) => img.Image.fromBytes(
        width: src.width,
        height: src.height,
        bytes: src.data.buffer,
        bytesOffset: src.data.offsetInBytes,
        numChannels: 3,
        order: img.ChannelOrder.rgb,
      );
}
