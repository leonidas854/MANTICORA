import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:manticora/imaging/geometry.dart';
import 'package:manticora/imaging/raster.dart';

/// Generador de documentos de prueba con **verdad conocida**.
///
/// Fotografiar un documento de verdad no sirve para medir: no se sabe donde
/// estaban exactamente las esquinas. Aqui se hace al reves: se dibuja una
/// pagina, se coloca en una escena con una perspectiva concreta y se guarda
/// ese cuadrilatero. Asi se puede medir el error de deteccion en pixeles.
class DocumentFixtures {
  DocumentFixtures._();

  /// Marcas de referencia en la pagina, en coordenadas relativas (0..1).
  /// Sirven para comprobar que el enderezado deja cada cosa en su sitio.
  static const markers = <({double x, double y})>[
    (x: 0.10, y: 0.08),
    (x: 0.90, y: 0.08),
    (x: 0.90, y: 0.92),
    (x: 0.10, y: 0.92),
  ];

  /// Dibuja una pagina de documento: fondo claro, lineas de texto, y
  /// opcionalmente una tabla con lineas de rejilla.
  static RgbImage renderPage({
    int width = 620,
    int height = 877, // proporcion A4
    bool withTable = true,
    int paper = 246,
    int ink = 38,
  }) {
    final image = RgbImage.alloc(width, height);
    _fill(image, paper, paper, paper);

    // Un papel real no es uniforme: grano suave para que no sea plano.
    _addGrain(image, 3, seed: 7);

    final margin = (width * 0.10).round();
    var y = (height * 0.06).round();

    // Titulo: una barra mas gruesa.
    _rect(image, margin, y, (width * 0.55).round(), 16, ink, ink, ink);
    y += 44;

    // Parrafos: lineas de texto simuladas.
    final random = math.Random(11);
    for (var block = 0; block < 3; block++) {
      for (var line = 0; line < 5; line++) {
        final w = ((width - 2 * margin) * (0.62 + random.nextDouble() * 0.38)).round();
        _rect(image, margin, y, w, 7, ink, ink, ink);
        y += 17;
      }
      y += 16;
    }

    if (withTable) {
      final tableTop = y + 8;
      final tableLeft = margin;
      final tableWidth = width - 2 * margin;
      const rows = 5, cols = 4;
      final rowHeight = 26;
      final colWidth = tableWidth ~/ cols;
      final tableHeight = rows * rowHeight;

      // Rejilla.
      for (var r = 0; r <= rows; r++) {
        _rect(image, tableLeft, tableTop + r * rowHeight, tableWidth, 2, ink, ink, ink);
      }
      for (var c = 0; c <= cols; c++) {
        final x = tableLeft + math.min(c * colWidth, tableWidth - 2).toInt();
        _rect(image, x, tableTop, 2, tableHeight, ink, ink, ink);
      }
      // Contenido de las celdas.
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          _rect(
            image,
            tableLeft + c * colWidth + 6,
            tableTop + r * rowHeight + 9,
            (colWidth * 0.55).round(),
            6,
            ink,
            ink,
            ink,
          );
        }
      }
    }

    // Marcas de referencia.
    for (final m in markers) {
      _rect(
        image,
        (m.x * width).round() - 5,
        (m.y * height).round() - 5,
        10,
        10,
        ink,
        ink,
        ink,
      );
    }

    return image;
  }

  /// Coloca la pagina dentro de una escena con la perspectiva indicada.
  /// Devuelve la escena y el cuadrilatero exacto donde quedo la pagina.
  static ({RgbImage scene, Quad truth}) placeInScene(
    RgbImage page, {
    required int sceneWidth,
    required int sceneHeight,
    required Quad quad,
    int background = 52,
    double lightingGradient = 0.0,
    int noise = 4,
    int seed = 3,
  }) {
    final scene = RgbImage.alloc(sceneWidth, sceneHeight);
    _fill(scene, background, background, (background * 1.08).round().clamp(0, 255));
    _addGrain(scene, 6, seed: seed);

    // Homografia escena -> pagina, para muestrear con mapeo inverso.
    final pageRect = [
      const Pt(0, 0),
      Pt(page.width.toDouble(), 0),
      Pt(page.width.toDouble(), page.height.toDouble()),
      Pt(0, page.height.toDouble()),
    ];
    final toPage = Homography.fromCorrespondences(quad.points, pageRect);
    if (toPage == null) {
      throw ArgumentError('El cuadrilatero de la escena es degenerado');
    }

    // Caja que abarca el cuadrilatero: solo se recorre esa zona.
    var minX = sceneWidth, minY = sceneHeight, maxX = 0, maxY = 0;
    for (final p in quad.points) {
      minX = math.min(minX, p.x.floor());
      minY = math.min(minY, p.y.floor());
      maxX = math.max(maxX, p.x.ceil());
      maxY = math.max(maxY, p.y.ceil());
    }
    minX = minX.clamp(0, sceneWidth - 1);
    minY = minY.clamp(0, sceneHeight - 1);
    maxX = maxX.clamp(0, sceneWidth - 1);
    maxY = maxY.clamp(0, sceneHeight - 1);

    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        if (!_inside(quad, x + 0.5, y + 0.5)) continue;
        final src = toPage.apply(x + 0.5, y + 0.5);
        if (src.x < 0 || src.y < 0 || src.x >= page.width || src.y >= page.height) {
          continue;
        }
        final si = (src.y.toInt() * page.width + src.x.toInt()) * 3;
        final di = (y * scene.width + x) * 3;

        // Sombra suave de izquierda a derecha, como al fotografiar con luz
        // lateral: es donde fallan los filtros mediocres.
        var factor = 1.0;
        if (lightingGradient > 0) {
          final t = (x - minX) / math.max(1, maxX - minX);
          factor = 1.0 - lightingGradient * t;
        }
        for (var c = 0; c < 3; c++) {
          scene.data[di + c] = (page.data[si + c] * factor).round().clamp(0, 255);
        }
      }
    }

    if (noise > 0) _addGrain(scene, noise, seed: seed + 1);
    return (scene: scene, truth: quad);
  }

  /// Cuadrilatero de una pagina fotografiada de frente, centrada.
  static Quad frontalQuad(int sceneW, int sceneH, {double fill = 0.72}) {
    final w = sceneW * fill, h = sceneH * fill;
    final x0 = (sceneW - w) / 2, y0 = (sceneH - h) / 2;
    return Quad(Pt(x0, y0), Pt(x0 + w, y0), Pt(x0 + w, y0 + h), Pt(x0, y0 + h));
  }

  /// Cuadrilatero con perspectiva: la foto tipica hecha a mano alzada.
  static Quad perspectiveQuad(
    int sceneW,
    int sceneH, {
    double fill = 0.74,
    double tilt = 0.06,
    double rotation = 0.0,
  }) {
    final w = sceneW * fill, h = sceneH * fill;
    final cx = sceneW / 2, cy = sceneH / 2;
    // Trapecio: el borde superior mas estrecho, como al inclinar el movil.
    final topInset = w * tilt;
    var pts = [
      Pt(cx - w / 2 + topInset, cy - h / 2),
      Pt(cx + w / 2 - topInset, cy - h / 2),
      Pt(cx + w / 2, cy + h / 2),
      Pt(cx - w / 2, cy + h / 2),
    ];
    if (rotation != 0) {
      final cos = math.cos(rotation), sin = math.sin(rotation);
      pts = pts
          .map((p) => Pt(
                cx + (p.x - cx) * cos - (p.y - cy) * sin,
                cy + (p.x - cx) * sin + (p.y - cy) * cos,
              ))
          .toList();
    }
    return Quad(pts[0], pts[1], pts[2], pts[3]);
  }

  // ------------------------------------------------------------- utilidades

  /// Error maximo, en pixeles, entre dos cuadrilateros esquina a esquina.
  static double maxCornerError(Quad found, Quad expected) {
    var worst = 0.0;
    for (var i = 0; i < 4; i++) {
      final d = found.points[i].distanceTo(expected.points[i]);
      if (d > worst) worst = d;
    }
    return worst;
  }

  /// Cuanto del documento real recoge el cuadrilatero detectado (0..1).
  /// Por debajo de 1 se esta recortando contenido.
  static double areaCoverage(Quad found, Quad expected) =>
      expected.area <= 0 ? 0 : found.area / expected.area;

  static Uint8List encodeJpeg(RgbImage image, {int quality = 92}) {
    final encoded = img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: image.data.buffer,
      bytesOffset: image.data.offsetInBytes,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    );
    return Uint8List.fromList(img.encodeJpg(encoded, quality: quality));
  }

  static RgbImage decodeJpeg(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw StateError('No se pudo decodificar el JPEG');
    return RgbImage(
      decoded.width,
      decoded.height,
      Uint8List.fromList(decoded.getBytes(order: img.ChannelOrder.rgb)),
    );
  }

  /// Luminancia media de una imagen (0..255).
  static double meanLuma(RgbImage image) {
    var sum = 0.0;
    final n = image.width * image.height;
    for (var i = 0; i < n; i++) {
      final j = i * 3;
      sum += (image.data[j] * 77 + image.data[j + 1] * 150 + image.data[j + 2] * 29) >> 8;
    }
    return sum / n;
  }

  /// Desviacion tipica de la luminancia: mide el contraste real.
  static double lumaStdDev(RgbImage image) {
    final mean = meanLuma(image);
    var acc = 0.0;
    final n = image.width * image.height;
    for (var i = 0; i < n; i++) {
      final j = i * 3;
      final v =
          ((image.data[j] * 77 + image.data[j + 1] * 150 + image.data[j + 2] * 29) >> 8)
              .toDouble();
      acc += (v - mean) * (v - mean);
    }
    return math.sqrt(acc / n);
  }

  /// Luminancia media de una region rectangular relativa (0..1).
  static double regionLuma(
    RgbImage image,
    double x0,
    double y0,
    double x1,
    double y1,
  ) {
    final ax = (x0 * image.width).round().clamp(0, image.width - 1);
    final ay = (y0 * image.height).round().clamp(0, image.height - 1);
    final bx = (x1 * image.width).round().clamp(ax + 1, image.width);
    final by = (y1 * image.height).round().clamp(ay + 1, image.height);
    var sum = 0.0;
    var count = 0;
    for (var y = ay; y < by; y++) {
      for (var x = ax; x < bx; x++) {
        final j = (y * image.width + x) * 3;
        sum += (image.data[j] * 77 + image.data[j + 1] * 150 + image.data[j + 2] * 29) >> 8;
        count++;
      }
    }
    return count == 0 ? 0 : sum / count;
  }

  // ------------------------------------------------------------------ dibujo

  static void _fill(RgbImage image, int r, int g, int b) {
    for (var i = 0; i < image.data.length; i += 3) {
      image.data[i] = r;
      image.data[i + 1] = g;
      image.data[i + 2] = b;
    }
  }

  static void _rect(RgbImage image, int x, int y, int w, int h, int r, int g, int b) {
    for (var yy = y; yy < y + h; yy++) {
      if (yy < 0 || yy >= image.height) continue;
      for (var xx = x; xx < x + w; xx++) {
        if (xx < 0 || xx >= image.width) continue;
        final i = (yy * image.width + xx) * 3;
        image.data[i] = r;
        image.data[i + 1] = g;
        image.data[i + 2] = b;
      }
    }
  }

  static void _addGrain(RgbImage image, int amount, {int seed = 1}) {
    if (amount <= 0) return;
    final random = math.Random(seed);
    for (var i = 0; i < image.data.length; i += 3) {
      final n = random.nextInt(amount * 2 + 1) - amount;
      for (var c = 0; c < 3; c++) {
        image.data[i + c] = (image.data[i + c] + n).clamp(0, 255);
      }
    }
  }

  static bool _inside(Quad q, double px, double py) {
    final pts = q.points;
    var sign = 0;
    for (var i = 0; i < 4; i++) {
      final a = pts[i], b = pts[(i + 1) % 4];
      final cross = (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x);
      if (cross == 0) continue;
      final s = cross > 0 ? 1 : -1;
      if (sign == 0) {
        sign = s;
      } else if (s != sign) {
        return false;
      }
    }
    return true;
  }
}
