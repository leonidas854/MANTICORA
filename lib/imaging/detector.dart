import 'dart:math' as math;
import 'dart:typed_data';

import 'geometry.dart';
import 'raster.dart';

/// Deteccion automatica del cuadrilatero del documento.
///
/// Se ejecuta sobre una version reducida (~[workSize] px de lado mayor) para
/// que sea viable en tiempo real sobre el flujo de la camara. Combina dos
/// estrategias y se queda con la de mayor puntuacion:
///
///  A) bordes: Sobel -> Otsu -> dilatacion -> componente de mayor caja
///     -> contorno -> Douglas-Peucker hasta 4 vertices.
///  B) region: Otsu sobre la luminancia (papel claro sobre fondo oscuro)
///     -> componente mayor -> envolvente convexa -> cuadrilatero maximo.
class DocumentDetector {
  static const int workSize = 384;
  static const double _minAreaRatio = 0.12;
  static const double _maxAreaRatio = 0.995;

  /// Detecta sobre una imagen en gris ya reducida. Devuelve el cuadrilatero
  /// en coordenadas de ESA imagen reducida.
  static Quad? detectInGray(GrayImage gray) {
    final candidates = <Quad>[];
    final a = _edgeStrategy(gray);
    if (a != null) candidates.add(a);
    final b = _regionStrategy(gray);
    if (b != null) candidates.add(b);
    if (candidates.isEmpty) return null;

    final total = (gray.width * gray.height).toDouble();
    Quad? best;
    var bestScore = -1.0;
    for (final q in candidates) {
      if (!q.isPlausible) continue;
      final ratio = q.area / total;
      if (ratio < _minAreaRatio || ratio > _maxAreaRatio) continue;
      // Preferimos area grande, penalizando formas muy alejadas de un
      // rectangulo (lados opuestos de longitudes muy distintas).
      final score = ratio * _rectangularity(q);
      if (score > bestScore) {
        bestScore = score;
        best = q;
      }
    }
    return best;
  }

  /// Detecta sobre una imagen a resolucion completa (reduce internamente y
  /// reescala el resultado a las coordenadas originales).
  ///
  /// [targetSize] permite bajar la resolucion de trabajo en dispositivos
  /// modestos; por debajo de ~240 px la deteccion pierde fiabilidad.
  static Quad? detect(GrayImage full, {int targetSize = workSize}) {
    final effective = targetSize.clamp(240, 768);
    final scale = effective / math.max(full.width, full.height);
    final GrayImage small;
    if (scale < 1) {
      small = downscaleGray(full, math.max(2, (full.width * scale).round()),
          math.max(2, (full.height * scale).round()));
    } else {
      small = full;
    }
    final q = detectInGray(small);
    if (q == null) return null;
    return q.scaled(full.width / small.width, full.height / small.height);
  }

  static double _rectangularity(Quad q) {
    final a = q.tl.distanceTo(q.tr), b = q.bl.distanceTo(q.br);
    final c = q.tl.distanceTo(q.bl), d = q.tr.distanceTo(q.br);
    if (a + b == 0 || c + d == 0) return 0;
    final r1 = math.min(a, b) / math.max(a, b);
    final r2 = math.min(c, d) / math.max(c, d);
    return r1 * r2;
  }

  // ------------------------------------------------------------ estrategia A
  static Quad? _edgeStrategy(GrayImage gray) {
    final blurred = gaussianBlur(gray, 1.4);
    final mag = sobelMagnitude(blurred);
    var thr = otsuThreshold(mag.data);
    if (thr < 18) thr = 18;
    var bin = binarize(mag, thr);
    bin = dilate(bin, gray.width, gray.height);
    return _quadFromBinary(bin, gray.width, gray.height, preferBox: true);
  }

  // ------------------------------------------------------------ estrategia B
  static Quad? _regionStrategy(GrayImage gray) {
    final blurred = gaussianBlur(gray, 2.0);
    final thr = otsuThreshold(blurred.data);
    final bin = binarize(blurred, thr);
    // El papel suele ser la region clara; si domina el fondo claro, invertimos.
    var bright = 0;
    for (final v in bin) {
      bright += v;
    }
    final ratio = bright / bin.length;
    final use = ratio > 0.92 ? Uint8List.fromList([for (final v in bin) 1 - v]) : bin;
    return _quadFromBinary(use, gray.width, gray.height, preferBox: false);
  }

  static Quad? _quadFromBinary(Uint8List bin, int w, int h, {required bool preferBox}) {
    final res = connectedComponents(bin, w, h);
    if (res.components.isEmpty) return null;

    // Componente con la caja delimitadora mas grande: el borde del documento
    // atraviesa toda la hoja, el texto interior no.
    Component? target;
    var bestArea = 0;
    for (final c in res.components) {
      if (c.size < 24) continue;
      final area = preferBox ? c.boxArea : c.size;
      if (area > bestArea) {
        bestArea = area;
        target = c;
      }
    }
    if (target == null) return null;

    final contour = traceContour(res.labels, w, h, target.label);
    if (contour.length < 8) return null;

    // Perimetro aproximado para escalar epsilon.
    var peri = 0.0;
    for (var i = 0; i < contour.length; i++) {
      peri += contour[i].distanceTo(contour[(i + 1) % contour.length]);
    }
    if (peri < 4) return null;

    // Buscamos el epsilon que deje exactamente 4 vertices.
    for (final f in const [0.02, 0.03, 0.045, 0.06, 0.08, 0.10, 0.015, 0.12]) {
      final simplified = douglasPeucker(contour, peri * f);
      if (simplified.length == 4) {
        final q = Quad.fromUnordered(simplified);
        if (q.isPlausible) return q;
      }
    }

    // Respaldo: cuadrilatero de area maxima dentro de la envolvente convexa.
    final hull = convexHull(contour);
    return maxAreaQuad(hull);
  }
}
