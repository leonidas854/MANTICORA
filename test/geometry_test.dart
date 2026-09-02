import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/imaging/geometry.dart';

void main() {
  group('Quad', () {
    test('ordena cuatro puntos desordenados en tl, tr, br, bl', () {
      final q = Quad.fromUnordered(const [
        Pt(100, 100), // br
        Pt(0, 100), // bl
        Pt(0, 0), // tl
        Pt(100, 0), // tr
      ]);
      expect(q.tl, const Pt(0, 0));
      expect(q.tr, const Pt(100, 0));
      expect(q.br, const Pt(100, 100));
      expect(q.bl, const Pt(0, 100));
    });

    test('calcula el area de un rectangulo', () {
      expect(Quad.full(200, 100).area, closeTo(20000, 1e-6));
    });

    test('acepta un rectangulo y rechaza uno degenerado', () {
      expect(Quad.full(200, 100).isPlausible, isTrue);
      // Cuatro vertices colineales no forman un cuadrilatero.
      expect(const Quad(Pt(0, 0), Pt(10, 0), Pt(20, 0), Pt(30, 0)).isPlausible, isFalse);
    });

    test('estima el tamano de destino con el lado mas largo', () {
      const q = Quad(Pt(0, 0), Pt(300, 10), Pt(290, 420), Pt(5, 400));
      expect(q.targetWidth, greaterThanOrEqualTo(290));
      expect(q.targetHeight, greaterThanOrEqualTo(400));
    });

    test('sobrevive a un viaje de ida y vuelta por JSON', () {
      final q = Quad.inset(400, 600, 0.1);
      final back = Quad.fromJson(q.toJson());
      expect(back, isNotNull);
      expect(back!.tl.x, closeTo(q.tl.x, 1e-9));
      expect(back.br.y, closeTo(q.br.y, 1e-9));
    });
  });

  group('Homografia', () {
    test('la identidad deja los puntos donde estaban', () {
      const pts = [Pt(0, 0), Pt(10, 0), Pt(10, 10), Pt(0, 10)];
      final h = Homography.fromCorrespondences(pts, pts);
      expect(h, isNotNull);
      final mapped = h!.apply(5, 5);
      expect(mapped.x, closeTo(5, 1e-6));
      expect(mapped.y, closeTo(5, 1e-6));
    });

    test('mapea un rectangulo sobre un trapecio en las cuatro esquinas', () {
      const src = [Pt(0, 0), Pt(100, 0), Pt(100, 100), Pt(0, 100)];
      const dst = [Pt(10, 20), Pt(190, 5), Pt(210, 260), Pt(0, 240)];
      final h = Homography.fromCorrespondences(src, dst)!;
      for (var i = 0; i < 4; i++) {
        final m = h.apply(src[i].x, src[i].y);
        expect(m.x, closeTo(dst[i].x, 1e-6), reason: 'esquina $i');
        expect(m.y, closeTo(dst[i].y, 1e-6), reason: 'esquina $i');
      }
    });

    test('devuelve null si los puntos son colineales', () {
      const degenerate = [Pt(0, 0), Pt(1, 1), Pt(2, 2), Pt(3, 3)];
      expect(Homography.fromCorrespondences(degenerate, degenerate), isNull);
    });
  });

  group('Envolvente convexa y simplificacion', () {
    test('la envolvente de un cuadrado ignora los puntos interiores', () {
      final hull = convexHull(const [
        Pt(0, 0), Pt(10, 0), Pt(10, 10), Pt(0, 10),
        Pt(5, 5), Pt(3, 7), Pt(8, 2),
      ]);
      expect(hull.length, 4);
    });

    test('Douglas-Peucker reduce una linea casi recta a sus extremos', () {
      final pts = [
        for (var i = 0; i <= 20; i++) Pt(i.toDouble(), i.isEven ? 0.0 : 0.05),
      ];
      expect(douglasPeucker(pts, 1.0).length, lessThanOrEqualTo(2));
    });

    test('el cuadrilatero de area maxima se acerca al cuadrado inscrito', () {
      final circle = [
        for (var i = 0; i < 16; i++)
          Pt(100 * math.cos(i * 2 * math.pi / 16), 100 * math.sin(i * 2 * math.pi / 16)),
      ];
      final quad = maxAreaQuad(convexHull(circle));
      expect(quad, isNotNull);
      // El cuadrado inscrito en un circulo de radio 100 tiene area 20000.
      expect(quad!.area, greaterThan(18000));
    });
  });
}
