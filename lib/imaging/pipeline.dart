import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import '../core/device_profile.dart';
import '../core/failure.dart';
import '../core/logger.dart';
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

/// Imagen convertida a JPEG con sus dimensiones finales.
class NormalizedImage {
  final Uint8List jpeg;
  final int width, height;
  const NormalizedImage(this.jpeg, this.width, this.height);
}

/// Todo el trabajo pesado de imagen vive aqui y se ejecuta SIEMPRE en un
/// isolate, para que la interfaz nunca pierda fotogramas.
///
/// Las resoluciones y calidades salen de [DeviceProfile]: en un movil de gama
/// baja se trabaja mas pequeño para no agotar la memoria, y en uno potente se
/// aprovecha el margen.
class ImagePipeline {
  ImagePipeline._();

  static const int thumbSide = 320;

  /// Techo absoluto: por encima de esto ninguna gama intenta decodificar en
  /// un isolate; primero se reduce con el decodificador nativo.
  static const int _absoluteMaxMegapixels = 50;

  static int get maxOutputSide => DeviceProfile.current.maxImageSide;
  static int get jpegQuality => DeviceProfile.current.jpegQuality;

  // -------------------------------------------------------------- deteccion

  /// Detecta el documento en un JPEG, en coordenadas de la imagen original.
  static Future<Quad?> detectInJpeg(Uint8List jpegBytes) async {
    if (jpegBytes.isEmpty) return null;
    final targetSize = DeviceProfile.current.detectorWorkSize;
    try {
      return await Isolate.run(() => _detectSync(jpegBytes, targetSize));
    } catch (e, st) {
      Log.w('Imagen', 'Fallo la deteccion automatica de bordes', e, st);
      return null;
    }
  }

  static Quad? _detectSync(Uint8List jpegBytes, int targetSize) {
    final decoded = img.decodeJpg(jpegBytes);
    if (decoded == null) return null;
    final rgb = _toRgb(decoded);
    return DocumentDetector.detect(rgbToGray(rgb), targetSize: targetSize);
  }

  // -------------------------------------------------------------- procesado

  /// Recorta con correccion de perspectiva, aplica filtro y codifica a JPEG.
  ///
  /// Lanza [AppFailure] con un motivo comprensible si algo va mal, para que
  /// quien llama pueda decidir si avisar o continuar con el resto de paginas.
  static Future<ProcessedPage> processPage({
    required Uint8List sourceJpeg,
    Quad? quad,
    ScanFilter filter = ScanFilter.magic,
    Adjustments adjustments = Adjustments.none,
    int rotationQuarterTurns = 0,
    int? maxSide,
    int? quality,
  }) async {
    if (sourceJpeg.isEmpty) {
      throw const AppFailure.validation('La imagen de origen esta vacia.');
    }
    final side = maxSide ?? maxOutputSide;
    final q = quality ?? jpegQuality;
    final thumb = thumbSide;

    try {
      return await Isolate.run(() => _processSync(
            sourceJpeg,
            quad,
            filter,
            adjustments,
            rotationQuarterTurns,
            side,
            q,
            thumb,
          ));
    } on AppFailure {
      rethrow;
    } catch (e, st) {
      Log.e('Imagen', 'Error procesando una pagina', e, st);
      throw AppFailure.from(e, st, 'Procesando la pagina');
    }
  }

  static ProcessedPage _processSync(
    Uint8List sourceJpeg,
    Quad? quad,
    ScanFilter filter,
    Adjustments adjustments,
    int rotation,
    int maxSide,
    int quality,
    int thumbSide,
  ) {
    final decoded = img.decodeImage(sourceJpeg);
    if (decoded == null) {
      throw const AppFailure.validation(
        'No se ha podido leer la imagen: puede estar dañada.',
      );
    }
    if (decoded.width <= 0 || decoded.height <= 0) {
      throw const AppFailure.validation('La imagen no tiene dimensiones validas.');
    }

    var rgb = _toRgb(decoded);

    // 1. Perspectiva. Un cuadrilatero degenerado se ignora en vez de romper.
    if (quad != null && quad.isPlausible) {
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
    final jpeg = Uint8List.fromList(img.encodeJpg(_fromRgb(rgb), quality: quality));
    final small = _fit(rgb, thumbSide);
    final thumbnail =
        Uint8List.fromList(img.encodeJpg(_fromRgb(small), quality: 78));

    return ProcessedPage(jpeg, thumbnail, rgb.width, rgb.height);
  }

  /// Genera una miniatura a partir de un JPEG existente.
  static Future<Uint8List> thumbnail(Uint8List jpegBytes, {int side = thumbSide}) async {
    if (jpegBytes.isEmpty) return Uint8List(0);
    try {
      return await Isolate.run(() {
        final decoded = img.decodeImage(jpegBytes);
        if (decoded == null) return Uint8List(0);
        final small = _fit(_toRgb(decoded), side);
        return Uint8List.fromList(img.encodeJpg(_fromRgb(small), quality: 78));
      });
    } catch (e, st) {
      Log.w('Imagen', 'No se pudo generar la miniatura', e, st);
      return Uint8List(0);
    }
  }

  /// Reduce y recomprime un JPEG. Si falla, devuelve el original: es preferible
  /// exportar algo grande a no exportar nada.
  static Future<Uint8List> recompress(
    Uint8List jpegBytes, {
    int? maxSide,
    int? quality,
  }) async {
    if (jpegBytes.isEmpty) return jpegBytes;
    final side = maxSide ?? maxOutputSide;
    final q = quality ?? jpegQuality;
    try {
      return await Isolate.run(() {
        final decoded = img.decodeImage(jpegBytes);
        if (decoded == null) return jpegBytes;
        final small = _fit(_toRgb(decoded), side);
        return Uint8List.fromList(img.encodeJpg(_fromRgb(small), quality: q));
      });
    } catch (e, st) {
      Log.w('Imagen', 'No se pudo recomprimir la imagen', e, st);
      return jpegBytes;
    }
  }

  /// Normaliza cualquier entrada a JPEG con la orientacion EXIF ya aplicada.
  static Future<Uint8List?> normalizeToJpeg(Uint8List bytes, {int? maxSide}) async {
    final result = await normalizeWithSize(bytes, maxSide: maxSide);
    return result?.jpeg;
  }

  /// Igual que [normalizeToJpeg] pero devolviendo tambien las dimensiones.
  static Future<NormalizedImage?> normalizeWithSize(
    Uint8List bytes, {
    int? maxSide,
  }) async {
    if (bytes.isEmpty) return null;
    // Antes de tocar nada, se reduce lo desmesurado con el decodificador
    // nativo: es lo que evita quedarse sin memoria en gama baja.
    final safe = await shrinkIfHuge(bytes);
    final side = maxSide ?? math.max(maxOutputSide, 2400);
    try {
      return await Isolate.run(() {
        final decoded = img.decodeImage(safe);
        if (decoded == null) return null;
        final oriented = img.bakeOrientation(decoded);
        final rgb = _fit(_toRgb(oriented), side);
        final jpeg = Uint8List.fromList(img.encodeJpg(_fromRgb(rgb), quality: 92));
        return NormalizedImage(jpeg, rgb.width, rgb.height);
      });
    } catch (e, st) {
      Log.w('Imagen', 'No se pudo normalizar la imagen', e, st);
      return null;
    }
  }

  // ------------------------------------------------------- proteccion de RAM

  /// Reduce una imagen enorme usando el decodificador **nativo** de la
  /// plataforma, que sabe escalar sin materializar la imagen completa.
  ///
  /// Debe llamarse desde el isolate principal (necesita `dart:ui`). Si algo
  /// falla, devuelve los bytes originales.
  static Future<Uint8List> shrinkIfHuge(Uint8List bytes) async {
    if (bytes.isEmpty) return bytes;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width, h = descriptor.height;
      if (w <= 0 || h <= 0) return bytes;

      final megapixels = w * h / 1000000;
      final limit = math.min(
        DeviceProfile.current.maxDecodeMegapixels,
        _absoluteMaxMegapixels,
      );
      if (megapixels <= limit) return bytes;

      final scale = math.sqrt(limit * 1000000 / (w * h));
      final targetWidth = math.max(320, (w * scale).round());
      Log.i(
        'Imagen',
        'Imagen de ${megapixels.toStringAsFixed(1)} MP reducida a '
            '${targetWidth}px de ancho antes de procesar',
      );

      codec = await descriptor.instantiateCodec(targetWidth: targetWidth);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return bytes;

      final rgba = data.buffer.asUint8List();
      final iw = image.width, ih = image.height;
      return await Isolate.run(() {
        final decoded = img.Image.fromBytes(
          width: iw,
          height: ih,
          bytes: rgba.buffer,
          numChannels: 4,
          order: img.ChannelOrder.rgba,
        );
        return Uint8List.fromList(img.encodeJpg(decoded, quality: 92));
      });
    } catch (e, st) {
      Log.w('Imagen', 'No se pudo pre-reducir la imagen; se usa tal cual', e, st);
      return bytes;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
    }
  }

  /// Lee el tamano de una imagen sin decodificarla entera.
  static Future<({int width, int height})?> readSize(Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    ui.ImageDescriptor? descriptor;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return (width: descriptor.width, height: descriptor.height);
    } catch (e) {
      Log.w('Imagen', 'No se pudo leer el tamano de la imagen', e);
      return null;
    } finally {
      descriptor?.dispose();
    }
  }

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
