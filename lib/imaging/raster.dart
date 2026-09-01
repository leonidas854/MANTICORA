import 'dart:math' as math;
import 'dart:typed_data';

import 'geometry.dart';

/// Imagen en escala de grises de 8 bits.
class GrayImage {
  final int width, height;
  final Uint8List data;
  GrayImage(this.width, this.height, this.data);

  factory GrayImage.alloc(int w, int h) => GrayImage(w, h, Uint8List(w * h));

  int at(int x, int y) => data[y * width + x];
}

/// Imagen RGB entrelazada (3 bytes por pixel).
class RgbImage {
  final int width, height;
  final Uint8List data;
  RgbImage(this.width, this.height, this.data);

  factory RgbImage.alloc(int w, int h) => RgbImage(w, h, Uint8List(w * h * 3));

  RgbImage copy() => RgbImage(width, height, Uint8List.fromList(data));
}

// ---------------------------------------------------------------- conversion

GrayImage rgbToGray(RgbImage src) {
  final n = src.width * src.height;
  final out = Uint8List(n);
  final d = src.data;
  for (var i = 0, j = 0; i < n; i++, j += 3) {
    // Luma BT.601 en aritmetica entera.
    out[i] = (d[j] * 77 + d[j + 1] * 150 + d[j + 2] * 29) >> 8;
  }
  return GrayImage(src.width, src.height, out);
}

RgbImage grayToRgb(GrayImage src) {
  final n = src.width * src.height;
  final out = Uint8List(n * 3);
  for (var i = 0, j = 0; i < n; i++, j += 3) {
    final v = src.data[i];
    out[j] = v;
    out[j + 1] = v;
    out[j + 2] = v;
  }
  return RgbImage(src.width, src.height, out);
}

// ----------------------------------------------------------------- reescalado

/// Reduccion por caja (promedio de area): rapida y sin aliasing.
GrayImage downscaleGray(GrayImage src, int dw, int dh) {
  if (dw >= src.width || dh >= src.height) return src;
  final out = Uint8List(dw * dh);
  final xr = src.width / dw, yr = src.height / dh;
  for (var y = 0; y < dh; y++) {
    final y0 = (y * yr).floor();
    final y1 = math.min(((y + 1) * yr).ceil(), src.height);
    for (var x = 0; x < dw; x++) {
      final x0 = (x * xr).floor();
      final x1 = math.min(((x + 1) * xr).ceil(), src.width);
      var sum = 0, cnt = 0;
      for (var yy = y0; yy < y1; yy++) {
        final row = yy * src.width;
        for (var xx = x0; xx < x1; xx++) {
          sum += src.data[row + xx];
          cnt++;
        }
      }
      out[y * dw + x] = cnt == 0 ? 0 : sum ~/ cnt;
    }
  }
  return GrayImage(dw, dh, out);
}

RgbImage downscaleRgb(RgbImage src, int dw, int dh) {
  if (dw >= src.width && dh >= src.height) return src;
  final out = Uint8List(dw * dh * 3);
  final xr = src.width / dw, yr = src.height / dh;
  for (var y = 0; y < dh; y++) {
    final y0 = (y * yr).floor();
    final y1 = math.min(((y + 1) * yr).ceil(), src.height);
    for (var x = 0; x < dw; x++) {
      final x0 = (x * xr).floor();
      final x1 = math.min(((x + 1) * xr).ceil(), src.width);
      var r = 0, g = 0, b = 0, cnt = 0;
      for (var yy = y0; yy < y1; yy++) {
        var i = (yy * src.width + x0) * 3;
        for (var xx = x0; xx < x1; xx++) {
          r += src.data[i];
          g += src.data[i + 1];
          b += src.data[i + 2];
          i += 3;
          cnt++;
        }
      }
      final o = (y * dw + x) * 3;
      if (cnt > 0) {
        out[o] = r ~/ cnt;
        out[o + 1] = g ~/ cnt;
        out[o + 2] = b ~/ cnt;
      }
    }
  }
  return RgbImage(dw, dh, out);
}

// -------------------------------------------------------------------- filtros

/// Desenfoque gaussiano separable (dos pasadas 1-D).
GrayImage gaussianBlur(GrayImage src, double sigma) {
  final radius = math.max(1, (sigma * 3).round());
  final size = radius * 2 + 1;
  final k = Float32List(size);
  var sum = 0.0;
  for (var i = 0; i < size; i++) {
    final d = (i - radius).toDouble();
    k[i] = math.exp(-(d * d) / (2 * sigma * sigma));
    sum += k[i];
  }
  for (var i = 0; i < size; i++) {
    k[i] /= sum;
  }

  final w = src.width, h = src.height;
  final tmp = Float32List(w * h);
  final out = Uint8List(w * h);

  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      var acc = 0.0;
      for (var i = 0; i < size; i++) {
        final xx = (x + i - radius).clamp(0, w - 1);
        acc += src.data[row + xx] * k[i];
      }
      tmp[row + x] = acc;
    }
  }
  for (var x = 0; x < w; x++) {
    for (var y = 0; y < h; y++) {
      var acc = 0.0;
      for (var i = 0; i < size; i++) {
        final yy = (y + i - radius).clamp(0, h - 1);
        acc += tmp[yy * w + x] * k[i];
      }
      out[y * w + x] = acc.round().clamp(0, 255);
    }
  }
  return GrayImage(w, h, out);
}

/// Magnitud del gradiente de Sobel, normalizada a 0..255.
GrayImage sobelMagnitude(GrayImage src) {
  final w = src.width, h = src.height;
  final out = Uint8List(w * h);
  final raw = Int32List(w * h);
  var maxV = 1;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final tl = src.data[i - w - 1], t = src.data[i - w], tr = src.data[i - w + 1];
      final l = src.data[i - 1], r = src.data[i + 1];
      final bl = src.data[i + w - 1], b = src.data[i + w], br = src.data[i + w + 1];
      final gx = (tr + 2 * r + br) - (tl + 2 * l + bl);
      final gy = (bl + 2 * b + br) - (tl + 2 * t + tr);
      final m = gx.abs() + gy.abs();
      raw[i] = m;
      if (m > maxV) maxV = m;
    }
  }
  for (var i = 0; i < raw.length; i++) {
    out[i] = (raw[i] * 255 ~/ maxV).clamp(0, 255);
  }
  return GrayImage(w, h, out);
}

/// Umbral global de Otsu.
int otsuThreshold(Uint8List data) {
  final hist = Int32List(256);
  for (final v in data) {
    hist[v]++;
  }
  final total = data.length;
  var sumAll = 0.0;
  for (var i = 0; i < 256; i++) {
    sumAll += i * hist[i];
  }
  var sumB = 0.0, wB = 0, best = 0;
  var maxVar = -1.0;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB;
    final mF = (sumAll - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > maxVar) {
      maxVar = between;
      best = t;
    }
  }
  return best;
}

Uint8List binarize(GrayImage src, int threshold) {
  final out = Uint8List(src.data.length);
  for (var i = 0; i < src.data.length; i++) {
    out[i] = src.data[i] > threshold ? 1 : 0;
  }
  return out;
}

/// Dilatacion 3x3 (elemento estructurante cuadrado).
Uint8List dilate(Uint8List bin, int w, int h) {
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = 0;
      for (var dy = -1; dy <= 1 && v == 0; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          if (bin[yy * w + xx] != 0) {
            v = 1;
            break;
          }
        }
      }
      out[y * w + x] = v;
    }
  }
  return out;
}

// -------------------------------------------------------- componentes conexas

class Component {
  final int label, size;
  final int minX, minY, maxX, maxY;
  Component(this.label, this.size, this.minX, this.minY, this.maxX, this.maxY);
  int get boxArea => (maxX - minX + 1) * (maxY - minY + 1);
}

class LabelResult {
  final Int32List labels;
  final List<Component> components;
  LabelResult(this.labels, this.components);
}

/// Etiquetado de componentes conexas (8-conectividad) por BFS iterativo.
LabelResult connectedComponents(Uint8List bin, int w, int h) {
  final labels = Int32List(w * h);
  final comps = <Component>[];
  final queue = Int32List(w * h);
  var next = 1;
  for (var s = 0; s < bin.length; s++) {
    if (bin[s] == 0 || labels[s] != 0) continue;
    final label = next++;
    var head = 0, tail = 0;
    queue[tail++] = s;
    labels[s] = label;
    var size = 0, minX = w, minY = h, maxX = 0, maxY = 0;
    while (head < tail) {
      final p = queue[head++];
      size++;
      final px = p % w, py = p ~/ w;
      if (px < minX) minX = px;
      if (px > maxX) maxX = px;
      if (py < minY) minY = py;
      if (py > maxY) maxY = py;
      for (var dy = -1; dy <= 1; dy++) {
        final ny = py + dy;
        if (ny < 0 || ny >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final nx = px + dx;
          if (nx < 0 || nx >= w) continue;
          final q = ny * w + nx;
          if (bin[q] != 0 && labels[q] == 0) {
            labels[q] = label;
            queue[tail++] = q;
          }
        }
      }
    }
    comps.add(Component(label, size, minX, minY, maxX, maxY));
  }
  return LabelResult(labels, comps);
}

/// Seguimiento del contorno exterior (vecindad de Moore) de una etiqueta.
List<Pt> traceContour(Int32List labels, int w, int h, int label) {
  const dx = [1, 1, 0, -1, -1, -1, 0, 1];
  const dy = [0, 1, 1, 1, 0, -1, -1, -1];

  var sx = -1, sy = -1;
  for (var y = 0; y < h && sx < 0; y++) {
    for (var x = 0; x < w; x++) {
      if (labels[y * w + x] == label) {
        sx = x;
        sy = y;
        break;
      }
    }
  }
  if (sx < 0) return const [];

  final contour = <Pt>[];
  var cx = sx, cy = sy, dir = 0;
  final maxSteps = 8 * (w + h) + 64;
  var steps = 0;
  while (steps++ < maxSteps) {
    contour.add(Pt(cx.toDouble(), cy.toDouble()));
    var found = false;
    for (var i = 0; i < 8; i++) {
      final nd = (dir + 5 + i) % 8;
      final nx = cx + dx[nd], ny = cy + dy[nd];
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
      if (labels[ny * w + nx] == label) {
        cx = nx;
        cy = ny;
        dir = nd;
        found = true;
        break;
      }
    }
    if (!found) break;
    if (cx == sx && cy == sy) break;
  }
  return contour;
}

// ---------------------------------------------------------- imagen integral

/// Suma acumulada 2-D con borde de ceros: (w+1) x (h+1).
class Integral {
  final int w, h;
  final Float64List sum;
  final Float64List? sqSum;
  Integral(this.w, this.h, this.sum, this.sqSum);

  static Integral build(Uint8List gray, int w, int h, {bool withSquares = false}) {
    final s = Float64List((w + 1) * (h + 1));
    final q = withSquares ? Float64List((w + 1) * (h + 1)) : null;
    for (var y = 0; y < h; y++) {
      var rowSum = 0.0, rowSq = 0.0;
      final o = (y + 1) * (w + 1);
      final p = y * (w + 1);
      for (var x = 0; x < w; x++) {
        final v = gray[y * w + x].toDouble();
        rowSum += v;
        s[o + x + 1] = s[p + x + 1] + rowSum;
        if (q != null) {
          rowSq += v * v;
          q[o + x + 1] = q[p + x + 1] + rowSq;
        }
      }
    }
    return Integral(w, h, s, q);
  }

  /// Media de la ventana centrada en (x,y) con radio r.
  double mean(int x, int y, int r) {
    final x0 = (x - r).clamp(0, w), y0 = (y - r).clamp(0, h);
    final x1 = (x + r + 1).clamp(0, w), y1 = (y + r + 1).clamp(0, h);
    final area = (x1 - x0) * (y1 - y0);
    if (area <= 0) return 0;
    final stride = w + 1;
    final t = sum[y1 * stride + x1] - sum[y0 * stride + x1] - sum[y1 * stride + x0] + sum[y0 * stride + x0];
    return t / area;
  }

  /// Media y desviacion tipica de la ventana centrada en (x,y).
  (double, double) meanStd(int x, int y, int r) {
    final x0 = (x - r).clamp(0, w), y0 = (y - r).clamp(0, h);
    final x1 = (x + r + 1).clamp(0, w), y1 = (y + r + 1).clamp(0, h);
    final area = (x1 - x0) * (y1 - y0);
    if (area <= 0) return (0, 0);
    final stride = w + 1;
    final t = sum[y1 * stride + x1] - sum[y0 * stride + x1] - sum[y1 * stride + x0] + sum[y0 * stride + x0];
    final m = t / area;
    final sq = sqSum;
    if (sq == null) return (m, 0);
    final t2 = sq[y1 * stride + x1] - sq[y0 * stride + x1] - sq[y1 * stride + x0] + sq[y0 * stride + x0];
    final varr = math.max(0.0, t2 / area - m * m);
    return (m, math.sqrt(varr));
  }
}

// ---------------------------------------------------------- warp perspectivo

/// Corrige la perspectiva del cuadrilatero [quad] a un rectangulo [dw]x[dh].
/// Muestreo bilineal con incrementos por fila (3 sumas + 2 divisiones/pixel).
RgbImage warpPerspective(RgbImage src, Quad quad, int dw, int dh) {
  final rect = [
    const Pt(0, 0),
    Pt(dw.toDouble(), 0),
    Pt(dw.toDouble(), dh.toDouble()),
    Pt(0, dh.toDouble()),
  ];
  final hmg = Homography.fromCorrespondences(rect, quad.points);
  if (hmg == null) return src;
  final m = hmg.m;
  final out = Uint8List(dw * dh * 3);
  final sw = src.width, sh = src.height;
  final sd = src.data;
  final maxX = sw - 1, maxY = sh - 1;

  for (var y = 0; y < dh; y++) {
    final yd = y.toDouble();
    var nu = m[1] * yd + m[2];
    var nv = m[4] * yd + m[5];
    var nw = m[7] * yd + m[8];
    var o = y * dw * 3;
    for (var x = 0; x < dw; x++, nu += m[0], nv += m[3], nw += m[6], o += 3) {
      if (nw.abs() < 1e-9) continue;
      final fx = nu / nw, fy = nv / nw;
      if (fx < 0 || fy < 0 || fx > maxX || fy > maxY) continue;
      final x0 = fx.toInt(), y0 = fy.toInt();
      final x1 = x0 < maxX ? x0 + 1 : x0;
      final y1 = y0 < maxY ? y0 + 1 : y0;
      final ax = fx - x0, ay = fy - y0;
      final w00 = (1 - ax) * (1 - ay), w10 = ax * (1 - ay);
      final w01 = (1 - ax) * ay, w11 = ax * ay;
      final i00 = (y0 * sw + x0) * 3, i10 = (y0 * sw + x1) * 3;
      final i01 = (y1 * sw + x0) * 3, i11 = (y1 * sw + x1) * 3;
      for (var c = 0; c < 3; c++) {
        out[o + c] = (sd[i00 + c] * w00 + sd[i10 + c] * w10 + sd[i01 + c] * w01 + sd[i11 + c] * w11)
            .round()
            .clamp(0, 255);
      }
    }
  }
  return RgbImage(dw, dh, out);
}

/// Rotacion en multiplos de 90 grados, sin interpolacion.
RgbImage rotate90(RgbImage src, int quarterTurns) {
  final t = ((quarterTurns % 4) + 4) % 4;
  if (t == 0) return src;
  final w = src.width, h = src.height;
  final nw = t.isOdd ? h : w;
  final nh = t.isOdd ? w : h;
  final out = Uint8List(nw * nh * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      int dx, dy;
      switch (t) {
        case 1:
          dx = h - 1 - y;
          dy = x;
        case 2:
          dx = w - 1 - x;
          dy = h - 1 - y;
        default:
          dx = y;
          dy = w - 1 - x;
      }
      final si = (y * w + x) * 3, di = (dy * nw + dx) * 3;
      out[di] = src.data[si];
      out[di + 1] = src.data[si + 1];
      out[di + 2] = src.data[si + 2];
    }
  }
  return RgbImage(nw, nh, out);
}
