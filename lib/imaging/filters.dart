import 'dart:math' as math;
import 'dart:typed_data';

import 'raster.dart';

/// Filtros de realce disponibles al escanear.
enum ScanFilter {
  original('Original'),
  magic('Magic Color'),
  enhance('Sin sombras'),
  grayscale('Grises'),
  blackWhite('Blanco y negro'),
  lighten('Aclarar');

  final String label;
  const ScanFilter(this.label);

  static ScanFilter fromName(String? n) =>
      ScanFilter.values.firstWhere((e) => e.name == n, orElse: () => ScanFilter.magic);
}

/// Ajustes finos que el usuario puede mover con deslizadores.
class Adjustments {
  final double brightness; // -1..1
  final double contrast; // -1..1
  final double saturation; // -1..1
  final double sharpen; // 0..1

  const Adjustments({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.sharpen = 0,
  });

  static const none = Adjustments();
  bool get isIdentity =>
      brightness == 0 && contrast == 0 && saturation == 0 && sharpen == 0;

  Adjustments copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? sharpen,
  }) =>
      Adjustments(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        sharpen: sharpen ?? this.sharpen,
      );

  Map<String, dynamic> toJson() => {
        'b': brightness,
        'c': contrast,
        's': saturation,
        'sh': sharpen,
      };

  factory Adjustments.fromJson(Map<String, dynamic> j) => Adjustments(
        brightness: (j['b'] as num?)?.toDouble() ?? 0,
        contrast: (j['c'] as num?)?.toDouble() ?? 0,
        saturation: (j['s'] as num?)?.toDouble() ?? 0,
        sharpen: (j['sh'] as num?)?.toDouble() ?? 0,
      );
}

/// Aplica filtro + ajustes. Devuelve una imagen nueva.
RgbImage applyFilter(RgbImage src, ScanFilter filter, [Adjustments adj = Adjustments.none]) {
  RgbImage out;
  switch (filter) {
    case ScanFilter.original:
      out = src.copy();
    case ScanFilter.magic:
      out = _magicColor(src);
    case ScanFilter.enhance:
      out = _removeShadows(src, boostContrast: true);
    case ScanFilter.grayscale:
      out = grayToRgb(rgbToGray(_removeShadows(src, boostContrast: false)));
    case ScanFilter.blackWhite:
      out = _blackWhite(src);
    case ScanFilter.lighten:
      out = _levels(src.copy(), gamma: 0.72);
  }
  if (!adj.isIdentity) out = _applyAdjustments(out, adj);
  return out;
}

// ------------------------------------------------------- mapa de iluminacion

/// Estima el fondo (iluminacion) a baja resolucion. Devuelve un mapa RGB
/// pequeno que luego se muestrea bilinealmente: evita construir imagenes
/// integrales de tamano completo (que serian cientos de MB en un movil).
RgbImage _illuminationMap(RgbImage src, {int targetSide = 96}) {
  final scale = targetSide / math.max(src.width, src.height);
  // Si la imagen ya es mas pequena que el objetivo, se usa tal cual.
  final small = scale >= 1
      ? src
      : downscaleRgb(src, math.max(4, (src.width * scale).round()),
          math.max(4, (src.height * scale).round()));
  final sw = small.width, sh = small.height;

  // Filtro de maximo local suavizado: el fondo del papel es lo mas claro.
  final r = math.max(1, math.min(sw, sh) ~/ 6);
  final out = Uint8List(sw * sh * 3);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      var mr = 0, mg = 0, mb = 0;
      final y0 = math.max(0, y - r), y1 = math.min(sh - 1, y + r);
      final x0 = math.max(0, x - r), x1 = math.min(sw - 1, x + r);
      for (var yy = y0; yy <= y1; yy++) {
        var i = (yy * sw + x0) * 3;
        for (var xx = x0; xx <= x1; xx++, i += 3) {
          if (small.data[i] > mr) mr = small.data[i];
          if (small.data[i + 1] > mg) mg = small.data[i + 1];
          if (small.data[i + 2] > mb) mb = small.data[i + 2];
        }
      }
      final o = (y * sw + x) * 3;
      out[o] = mr;
      out[o + 1] = mg;
      out[o + 2] = mb;
    }
  }
  // Suavizamos el mapa para que no queden escalones.
  final blurred = Uint8List(sw * sh * 3);
  for (var c = 0; c < 3; c++) {
    final ch = Uint8List(sw * sh);
    for (var i = 0; i < sw * sh; i++) {
      ch[i] = out[i * 3 + c];
    }
    final b = gaussianBlur(GrayImage(sw, sh, ch), 3.0);
    for (var i = 0; i < sw * sh; i++) {
      blurred[i * 3 + c] = b.data[i];
    }
  }
  return RgbImage(sw, sh, blurred);
}

/// Muestreo bilineal de un mapa pequeno en coordenadas normalizadas.
void _sampleMap(RgbImage map, double u, double v, Int32List dst) {
  final fx = (u * (map.width - 1)).clamp(0, (map.width - 1).toDouble());
  final fy = (v * (map.height - 1)).clamp(0, (map.height - 1).toDouble());
  final x0 = fx.toInt(), y0 = fy.toInt();
  final x1 = math.min(x0 + 1, map.width - 1), y1 = math.min(y0 + 1, map.height - 1);
  final ax = fx - x0, ay = fy - y0;
  final i00 = (y0 * map.width + x0) * 3, i10 = (y0 * map.width + x1) * 3;
  final i01 = (y1 * map.width + x0) * 3, i11 = (y1 * map.width + x1) * 3;
  for (var c = 0; c < 3; c++) {
    final top = map.data[i00 + c] * (1 - ax) + map.data[i10 + c] * ax;
    final bot = map.data[i01 + c] * (1 - ax) + map.data[i11 + c] * ax;
    dst[c] = (top * (1 - ay) + bot * ay).round();
  }
}

/// Divide por la iluminacion estimada: elimina sombras y amarilleo del papel.
RgbImage _removeShadows(RgbImage src, {required bool boostContrast}) {
  final map = _illuminationMap(src);
  final w = src.width, h = src.height;
  final out = Uint8List(w * h * 3);
  final bg = Int32List(3);
  for (var y = 0; y < h; y++) {
    final v = h > 1 ? y / (h - 1) : 0.0;
    var i = y * w * 3;
    for (var x = 0; x < w; x++, i += 3) {
      final u = w > 1 ? x / (w - 1) : 0.0;
      _sampleMap(map, u, v, bg);
      for (var c = 0; c < 3; c++) {
        final b = math.max(32, bg[c]);
        out[i + c] = (src.data[i + c] * 255 / b).round().clamp(0, 255);
      }
    }
  }
  final img = RgbImage(w, h, out);
  return boostContrast ? _levels(img, gamma: 0.95, contrast: 0.25) : img;
}

/// "Magic Color": corrige iluminacion, estira niveles y realza saturacion.
RgbImage _magicColor(RgbImage src) {
  final base = _removeShadows(src, boostContrast: false);
  final stretched = _percentileStretch(base, lowP: 0.005, highP: 0.995);
  return _applyAdjustments(stretched, const Adjustments(contrast: 0.18, saturation: 0.22, sharpen: 0.35));
}

/// Estiramiento de niveles usando percentiles (robusto frente a motas).
RgbImage _percentileStretch(RgbImage src, {double lowP = 0.01, double highP = 0.99}) {
  final hist = Int32List(256);
  final n = src.width * src.height;
  for (var i = 0; i < n; i++) {
    final j = i * 3;
    hist[(src.data[j] * 77 + src.data[j + 1] * 150 + src.data[j + 2] * 29) >> 8]++;
  }
  var lo = 0, hi = 255, acc = 0;
  final loTarget = (n * lowP).round(), hiTarget = (n * highP).round();
  for (var v = 0; v < 256; v++) {
    acc += hist[v];
    if (acc >= loTarget) {
      lo = v;
      break;
    }
  }
  acc = 0;
  for (var v = 0; v < 256; v++) {
    acc += hist[v];
    if (acc >= hiTarget) {
      hi = v;
      break;
    }
  }
  if (hi - lo < 16) return src;
  final lut = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    lut[v] = (((v - lo) * 255) / (hi - lo)).round().clamp(0, 255);
  }
  final out = Uint8List(src.data.length);
  for (var i = 0; i < out.length; i++) {
    out[i] = lut[src.data[i]];
  }
  return RgbImage(src.width, src.height, out);
}

/// Binarizacion adaptativa de Sauvola. El mapa de umbrales se calcula a 1/4
/// de resolucion (los umbrales varian suavemente) y se interpola.
RgbImage _blackWhite(RgbImage src) {
  final clean = _removeShadows(src, boostContrast: false);
  final gray = rgbToGray(clean);
  final w = gray.width, h = gray.height;

  const div = 4;
  final sw = math.max(8, w ~/ div), sh = math.max(8, h ~/ div);
  final small = downscaleGray(gray, sw, sh);
  final integral = Integral.build(small.data, sw, sh, withSquares: true);
  final radius = math.max(4, math.min(sw, sh) ~/ 14);
  const k = 0.18, r = 128.0;

  final thr = Float32List(sw * sh);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      final (m, s) = integral.meanStd(x, y, radius);
      thr[y * sw + x] = (m * (1 + k * (s / r - 1))).toDouble();
    }
  }

  final out = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    final fy = (y / div).clamp(0, (sh - 1).toDouble());
    final y0 = fy.toInt(), y1 = math.min(y0 + 1, sh - 1);
    final ay = fy - y0;
    for (var x = 0; x < w; x++) {
      final fx = (x / div).clamp(0, (sw - 1).toDouble());
      final x0 = fx.toInt(), x1 = math.min(x0 + 1, sw - 1);
      final ax = fx - x0;
      final t = (thr[y0 * sw + x0] * (1 - ax) + thr[y0 * sw + x1] * ax) * (1 - ay) +
          (thr[y1 * sw + x0] * (1 - ax) + thr[y1 * sw + x1] * ax) * ay;
      final v = gray.data[y * w + x] > t ? 255 : 0;
      final o = (y * w + x) * 3;
      out[o] = v;
      out[o + 1] = v;
      out[o + 2] = v;
    }
  }
  return RgbImage(w, h, out);
}

/// Gamma + contraste mediante tabla de consulta.
RgbImage _levels(RgbImage src, {double gamma = 1.0, double contrast = 0.0}) {
  final lut = Uint8List(256);
  final c = (1 + contrast).clamp(0.0, 4.0);
  for (var v = 0; v < 256; v++) {
    var f = v / 255.0;
    if (gamma != 1.0) f = math.pow(f, gamma).toDouble();
    f = ((f - 0.5) * c + 0.5).clamp(0.0, 1.0);
    lut[v] = (f * 255).round();
  }
  for (var i = 0; i < src.data.length; i++) {
    src.data[i] = lut[src.data[i]];
  }
  return src;
}

RgbImage _applyAdjustments(RgbImage src, Adjustments a) {
  var img = src;
  if (a.sharpen > 0) img = _unsharp(img, a.sharpen);

  final lut = Uint8List(256);
  final c = (1 + a.contrast).clamp(0.0, 4.0);
  final b = a.brightness * 96;
  for (var v = 0; v < 256; v++) {
    var f = ((v - 128) * c + 128 + b);
    lut[v] = f.round().clamp(0, 255);
  }
  final d = img.data;
  final sat = 1 + a.saturation;
  for (var i = 0; i < d.length; i += 3) {
    var r = lut[d[i]], g = lut[d[i + 1]], bl = lut[d[i + 2]];
    if (sat != 1.0) {
      final lum = (r * 77 + g * 150 + bl * 29) >> 8;
      r = (lum + (r - lum) * sat).round().clamp(0, 255);
      g = (lum + (g - lum) * sat).round().clamp(0, 255);
      bl = (lum + (bl - lum) * sat).round().clamp(0, 255);
    }
    d[i] = r;
    d[i + 1] = g;
    d[i + 2] = bl;
  }
  return img;
}

/// Mascara de enfoque: original + amount * (original - desenfoque).
RgbImage _unsharp(RgbImage src, double amount) {
  final w = src.width, h = src.height;
  final out = Uint8List(src.data.length);
  final d = src.data;
  for (var y = 0; y < h; y++) {
    final ym = y > 0 ? y - 1 : 0, yp = y < h - 1 ? y + 1 : h - 1;
    for (var x = 0; x < w; x++) {
      final xm = x > 0 ? x - 1 : 0, xp = x < w - 1 ? x + 1 : w - 1;
      final ci = (y * w + x) * 3;
      for (var c = 0; c < 3; c++) {
        final blur = (d[(ym * w + x) * 3 + c] +
                d[(yp * w + x) * 3 + c] +
                d[(y * w + xm) * 3 + c] +
                d[(y * w + xp) * 3 + c] +
                d[ci + c] * 4) /
            8.0;
        out[ci + c] = (d[ci + c] + amount * (d[ci + c] - blur)).round().clamp(0, 255);
      }
    }
  }
  return RgbImage(w, h, out);
}
