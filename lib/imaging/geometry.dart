import 'dart:math' as math;

/// Punto en coordenadas de imagen (pixeles, origen arriba-izquierda).
class Pt {
  final double x, y;
  const Pt(this.x, this.y);

  Pt operator +(Pt o) => Pt(x + o.x, y + o.y);
  Pt operator -(Pt o) => Pt(x - o.x, y - o.y);
  Pt operator *(double s) => Pt(x * s, y * s);

  double get length => math.sqrt(x * x + y * y);
  double distanceTo(Pt o) => (this - o).length;
  Pt scaled(double sx, double sy) => Pt(x * sx, y * sy);

  Map<String, dynamic> toJson() => {'x': x, 'y': y};
  factory Pt.fromJson(Map<String, dynamic> j) =>
      Pt((j['x'] as num).toDouble(), (j['y'] as num).toDouble());

  @override
  String toString() => '(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';
}

/// Cuadrilatero del documento, siempre en orden tl, tr, br, bl.
class Quad {
  final Pt tl, tr, br, bl;
  const Quad(this.tl, this.tr, this.br, this.bl);

  List<Pt> get points => [tl, tr, br, bl];

  /// Cuadrilatero que cubre toda la imagen.
  factory Quad.full(double w, double h) =>
      Quad(const Pt(0, 0), Pt(w, 0), Pt(w, h), Pt(0, h));

  /// Recuadro centrado al [inset] del borde (usado como valor por defecto).
  factory Quad.inset(double w, double h, double inset) {
    final dx = w * inset, dy = h * inset;
    return Quad(Pt(dx, dy), Pt(w - dx, dy), Pt(w - dx, h - dy), Pt(dx, h - dy));
  }

  /// Ordena 4 puntos arbitrarios en tl,tr,br,bl usando el centroide.
  factory Quad.fromUnordered(List<Pt> pts) {
    assert(pts.length == 4);
    final cx = pts.map((p) => p.x).reduce((a, b) => a + b) / 4;
    final cy = pts.map((p) => p.y).reduce((a, b) => a + b) / 4;
    final sorted = [...pts]..sort((a, b) =>
        math.atan2(a.y - cy, a.x - cx).compareTo(math.atan2(b.y - cy, b.x - cx)));
    // atan2 crece desde -pi (izquierda) pasando por arriba (-pi/2).
    // Rotamos hasta que el primero sea el mas cercano al origen.
    var best = 0;
    var bestScore = double.infinity;
    for (var i = 0; i < 4; i++) {
      final s = sorted[i].x + sorted[i].y;
      if (s < bestScore) {
        bestScore = s;
        best = i;
      }
    }
    final o = [for (var i = 0; i < 4; i++) sorted[(best + i) % 4]];
    return Quad(o[0], o[1], o[2], o[3]);
  }

  Quad scaled(double sx, double sy) =>
      Quad(tl.scaled(sx, sy), tr.scaled(sx, sy), br.scaled(sx, sy), bl.scaled(sx, sy));

  double get area {
    var a = 0.0;
    final p = points;
    for (var i = 0; i < 4; i++) {
      final q = p[(i + 1) % 4];
      a += p[i].x * q.y - q.x * p[i].y;
    }
    return a.abs() / 2;
  }

  /// Ancho/alto de destino estimados a partir de los lados opuestos.
  int get targetWidth =>
      math.max(tl.distanceTo(tr), bl.distanceTo(br)).round().clamp(16, 8000);
  int get targetHeight =>
      math.max(tl.distanceTo(bl), tr.distanceTo(br)).round().clamp(16, 8000);

  /// Convexo y sin lados degenerados: filtro de calidad para la deteccion.
  bool get isPlausible {
    final p = points;
    var sign = 0;
    for (var i = 0; i < 4; i++) {
      final a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4];
      final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      if (cross.abs() < 1e-6) return false;
      final s = cross > 0 ? 1 : -1;
      if (sign == 0) {
        sign = s;
      } else if (s != sign) {
        return false;
      }
    }
    for (var i = 0; i < 4; i++) {
      if (p[i].distanceTo(p[(i + 1) % 4]) < 8) return false;
    }
    return true;
  }

  List<Map<String, dynamic>> toJson() => points.map((p) => p.toJson()).toList();

  static Quad? fromJson(dynamic j) {
    if (j is! List || j.length != 4) return null;
    final p = j.map((e) => Pt.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    return Quad(p[0], p[1], p[2], p[3]);
  }
}

/// Homografia 3x3 que mapea src -> dst, resuelta por eliminacion gaussiana.
class Homography {
  final List<double> m; // 9 elementos, fila mayor, m[8] == 1
  const Homography(this.m);

  static Homography? fromCorrespondences(List<Pt> src, List<Pt> dst) {
    if (src.length != 4 || dst.length != 4) return null;
    // 8 ecuaciones, 8 incognitas.
    final a = List.generate(8, (_) => List<double>.filled(9, 0));
    for (var i = 0; i < 4; i++) {
      final x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y;
      final r0 = a[i * 2], r1 = a[i * 2 + 1];
      r0[0] = x; r0[1] = y; r0[2] = 1; r0[6] = -x * u; r0[7] = -y * u; r0[8] = u;
      r1[3] = x; r1[4] = y; r1[5] = 1; r1[6] = -x * v; r1[7] = -y * v; r1[8] = v;
    }
    // Gauss-Jordan con pivoteo parcial.
    for (var col = 0; col < 8; col++) {
      var piv = col;
      for (var r = col + 1; r < 8; r++) {
        if (a[r][col].abs() > a[piv][col].abs()) piv = r;
      }
      if (a[piv][col].abs() < 1e-12) return null;
      if (piv != col) {
        final t = a[piv];
        a[piv] = a[col];
        a[col] = t;
      }
      final d = a[col][col];
      for (var c = col; c < 9; c++) {
        a[col][c] /= d;
      }
      for (var r = 0; r < 8; r++) {
        if (r == col) continue;
        final f = a[r][col];
        if (f == 0) continue;
        for (var c = col; c < 9; c++) {
          a[r][c] -= f * a[col][c];
        }
      }
    }
    return Homography([for (var i = 0; i < 8; i++) a[i][8], 1.0]);
  }

  Pt apply(double x, double y) {
    final w = m[6] * x + m[7] * y + m[8];
    if (w.abs() < 1e-12) return const Pt(0, 0);
    return Pt((m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w);
  }
}

/// Envolvente convexa (monotone chain de Andrew). O(n log n).
List<Pt> convexHull(List<Pt> pts) {
  if (pts.length < 3) return List.of(pts);
  final p = [...pts]..sort((a, b) => a.x == b.x ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
  double cross(Pt o, Pt a, Pt b) =>
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  final lower = <Pt>[];
  for (final q in p) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, q) <= 0) {
      lower.removeLast();
    }
    lower.add(q);
  }
  final upper = <Pt>[];
  for (final q in p.reversed) {
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, q) <= 0) {
      upper.removeLast();
    }
    upper.add(q);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

/// Simplificacion Douglas-Peucker de una polilinea cerrada.
List<Pt> douglasPeucker(List<Pt> pts, double epsilon) {
  if (pts.length < 3) return List.of(pts);
  double perpDist(Pt p, Pt a, Pt b) {
    final dx = b.x - a.x, dy = b.y - a.y;
    final den = math.sqrt(dx * dx + dy * dy);
    if (den < 1e-9) return p.distanceTo(a);
    return ((p.x - a.x) * dy - (p.y - a.y) * dx).abs() / den;
  }

  List<Pt> rec(int first, int last) {
    var maxD = 0.0;
    var idx = first;
    for (var i = first + 1; i < last; i++) {
      final d = perpDist(pts[i], pts[first], pts[last]);
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (maxD > epsilon) {
      final left = rec(first, idx);
      final right = rec(idx, last);
      return [...left.sublist(0, left.length - 1), ...right];
    }
    return [pts[first], pts[last]];
  }

  final out = rec(0, pts.length - 1);
  if (out.length > 1 && out.first.distanceTo(out.last) < 1e-6) out.removeLast();
  return out;
}

/// Cuadrilatero de area maxima inscrito en una envolvente convexa.
/// Se usa como respaldo cuando Douglas-Peucker no reduce a 4 vertices.
Quad? maxAreaQuad(List<Pt> hull) {
  if (hull.length < 4) return null;
  var pts = hull;
  // Limitamos el coste: muestreamos la envolvente a 24 vertices como mucho.
  if (pts.length > 24) {
    final step = pts.length / 24;
    pts = [for (var i = 0; i < 24; i++) pts[(i * step).floor()]];
  }
  final n = pts.length;
  double best = -1;
  List<int>? bestIdx;
  for (var i = 0; i < n - 3; i++) {
    for (var j = i + 1; j < n - 2; j++) {
      for (var k = j + 1; k < n - 1; k++) {
        for (var l = k + 1; l < n; l++) {
          final q = Quad(pts[i], pts[j], pts[k], pts[l]);
          final a = q.area;
          if (a > best) {
            best = a;
            bestIdx = [i, j, k, l];
          }
        }
      }
    }
  }
  if (bestIdx == null) return null;
  return Quad.fromUnordered([for (final i in bestIdx) pts[i]]);
}
