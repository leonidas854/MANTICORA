import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/imaging/detector.dart';
import 'package:manticora/imaging/filters.dart';
import 'package:manticora/imaging/geometry.dart';
import 'package:manticora/imaging/raster.dart';

/// Pinta un cuadrilatero claro sobre un fondo oscuro, imitando una hoja de
/// papel fotografiada en angulo sobre una mesa.
GrayImage _syntheticDocument(int w, int h, Quad quad, {int paper = 235, int desk = 40}) {
  final data = Uint8List(w * h)..fillRange(0, w * h, desk);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (_inside(quad, x + 0.5, y + 0.5)) data[y * w + x] = paper;
    }
  }
  return GrayImage(w, h, data);
}

bool _inside(Quad q, double px, double py) {
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

double _maxCornerError(Quad found, Quad expected) {
  var worst = 0.0;
  for (var i = 0; i < 4; i++) {
    final d = found.points[i].distanceTo(expected.points[i]);
    if (d > worst) worst = d;
  }
  return worst;
}

void main() {
  group('DocumentDetector', () {
    test('encuentra una hoja rectangular centrada', () {
      const expected = Quad(Pt(80, 120), Pt(520, 120), Pt(520, 680), Pt(80, 680));
      final image = _syntheticDocument(600, 800, expected);

      final found = DocumentDetector.detect(image);
      expect(found, isNotNull, reason: 'deberia detectar la hoja');
      // Se trabaja sobre una reduccion a 384 px, asi que el error se mide en
      // pixeles de la imagen original: unos pocos son esperables.
      expect(_maxCornerError(found!, expected), lessThan(25));
    });

    test('encuentra una hoja fotografiada en perspectiva', () {
      const expected = Quad(Pt(110, 90), Pt(500, 150), Pt(470, 700), Pt(70, 640));
      final image = _syntheticDocument(600, 800, expected);

      final found = DocumentDetector.detect(image);
      expect(found, isNotNull);
      expect(_maxCornerError(found!, expected), lessThan(30));
      expect(found.isPlausible, isTrue);
    });

    test('no inventa un documento sobre una imagen uniforme', () {
      final flat = GrayImage(400, 500, Uint8List(400 * 500)..fillRange(0, 200000, 128));
      expect(DocumentDetector.detect(flat), isNull);
    });
  });

  group('warpPerspective', () {
    test('endereza el cuadrilatero a un rectangulo completo', () {
      const quad = Quad(Pt(110, 90), Pt(500, 150), Pt(470, 700), Pt(70, 640));
      final gray = _syntheticDocument(600, 800, quad, paper: 250, desk: 10);
      final rgb = grayToRgb(gray);

      final warped = warpPerspective(rgb, quad, 300, 400);
      expect(warped.width, 300);
      expect(warped.height, 400);

      // Tras enderezar, el centro debe ser papel y las esquinas tambien:
      // el recorte cubre justo la hoja.
      int lum(int x, int y) => warped.data[(y * warped.width + x) * 3];
      expect(lum(150, 200), greaterThan(200), reason: 'centro');
      expect(lum(10, 10), greaterThan(180), reason: 'esquina superior izquierda');
      expect(lum(289, 389), greaterThan(180), reason: 'esquina inferior derecha');
    });
  });

  group('Filtros', () {
    test('blanco y negro deja solo dos niveles', () {
      const quad = Quad(Pt(40, 40), Pt(260, 40), Pt(260, 360), Pt(40, 360));
      final rgb = grayToRgb(_syntheticDocument(300, 400, quad, paper: 210, desk: 90));

      final out = applyFilter(rgb, ScanFilter.blackWhite);
      final levels = <int>{};
      for (var i = 0; i < out.data.length; i += 3) {
        levels.add(out.data[i]);
      }
      expect(levels, {0, 255});
    });

    test('escala de grises deja los tres canales iguales', () {
      final rgb = RgbImage(4, 4, Uint8List.fromList(List.generate(48, (i) => i * 5)));
      final out = applyFilter(rgb, ScanFilter.grayscale);
      for (var i = 0; i < out.data.length; i += 3) {
        expect(out.data[i], out.data[i + 1]);
        expect(out.data[i + 1], out.data[i + 2]);
      }
    });

    test('el filtro original no altera los pixeles', () {
      final rgb = RgbImage(3, 3, Uint8List.fromList(List.generate(27, (i) => i * 9)));
      final out = applyFilter(rgb, ScanFilter.original);
      expect(out.data, rgb.data);
      // Debe ser una copia, no el mismo buffer.
      expect(identical(out.data, rgb.data), isFalse);
    });

    test('conserva las dimensiones en todos los filtros', () {
      final rgb = grayToRgb(_syntheticDocument(
          120, 160, const Quad(Pt(20, 20), Pt(100, 20), Pt(100, 140), Pt(20, 140))));
      for (final f in ScanFilter.values) {
        final out = applyFilter(rgb, f);
        expect(out.width, 120, reason: f.name);
        expect(out.height, 160, reason: f.name);
      }
    });
  });

  group('rotate90', () {
    test('cuatro giros vuelven al punto de partida', () {
      final rgb = RgbImage(2, 3, Uint8List.fromList(List.generate(18, (i) => i)));
      var out = rgb;
      for (var i = 0; i < 4; i++) {
        out = rotate90(out, 1);
      }
      expect(out.width, 2);
      expect(out.height, 3);
      expect(out.data, rgb.data);
    });

    test('un giro intercambia ancho y alto', () {
      final rgb = RgbImage(2, 3, Uint8List(18));
      final out = rotate90(rgb, 1);
      expect(out.width, 3);
      expect(out.height, 2);
    });
  });
}
