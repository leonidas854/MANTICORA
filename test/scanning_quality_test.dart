import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/imaging/detector.dart';
import 'package:manticora/imaging/geometry.dart';
import 'package:manticora/imaging/raster.dart';

import 'support/document_fixtures.dart';

void main() {
  group('Orden de las esquinas', () {
    /// Reordenar mal las esquinas hace que el enderezado gire o espeje la
    /// pagina: es exactamente el sintoma de "la foto se va hacia otro lado".
    /// Prueba las 24 permutaciones posibles de los cuatro puntos: el trazado
    /// de contornos puede entregarlos en cualquier orden y en cualquiera de
    /// los dos sentidos de giro.
    void expectRecoversOrder(Quad original, {String? reason}) {
      final pts = original.points;
      final indices = [0, 1, 2, 3];
      final permutations = <List<int>>[];
      void permute(List<int> current, List<int> rest) {
        if (rest.isEmpty) {
          permutations.add(List.of(current));
          return;
        }
        for (var i = 0; i < rest.length; i++) {
          permute([...current, rest[i]], [...rest]..removeAt(i));
        }
      }

      permute(const [], indices);
      expect(permutations.length, 24);

      for (final perm in permutations) {
        final recovered = Quad.fromUnordered([for (final i in perm) pts[i]]);
        expect(
          DocumentFixtures.maxCornerError(recovered, original),
          lessThan(1.0),
          reason: '${reason ?? ''} (permutacion $perm)',
        );
      }
    }

    test('rectangulo recto', () {
      expectRecoversOrder(Quad.full(400, 600));
    });

    test('trapecio por perspectiva', () {
      expectRecoversOrder(
        const Quad(Pt(60, 20), Pt(340, 40), Pt(360, 560), Pt(40, 540)),
        reason: 'perspectiva',
      );
    });

    test('pagina girada, en ambos sentidos', () {
      for (final degrees in [-35, -20, -8, 8, 20, 35]) {
        final quad = DocumentFixtures.perspectiveQuad(
          800,
          1000,
          rotation: degrees * math.pi / 180,
        );
        expectRecoversOrder(quad, reason: 'giro de $degrees grados');
      }
    });

    test('pagina apaisada', () {
      expectRecoversOrder(
        const Quad(Pt(20, 80), Pt(580, 60), Pt(600, 320), Pt(10, 340)),
        reason: 'apaisada',
      );
    });
  });

  group('Deteccion del documento', () {
    late RgbImage page;

    setUp(() {
      page = DocumentFixtures.renderPage();
    });

    ({Quad? found, Quad truth}) detectIn(Quad quad, {double lighting = 0}) {
      final scene = DocumentFixtures.placeInScene(
        page,
        sceneWidth: 900,
        sceneHeight: 1200,
        quad: quad,
        lightingGradient: lighting,
      );
      return (
        found: DocumentDetector.detect(rgbToGray(scene.scene)),
        truth: scene.truth,
      );
    }

    test('encuentra una pagina fotografiada de frente', () {
      final r = detectIn(DocumentFixtures.frontalQuad(900, 1200));
      expect(r.found, isNotNull, reason: 'deberia encontrar la pagina');
      expect(DocumentFixtures.maxCornerError(r.found!, r.truth), lessThan(14));
    });

    test('encuentra una pagina en perspectiva', () {
      final r = detectIn(DocumentFixtures.perspectiveQuad(900, 1200, tilt: 0.08));
      expect(r.found, isNotNull);
      expect(DocumentFixtures.maxCornerError(r.found!, r.truth), lessThan(22));
    });

    test('encuentra una pagina girada', () {
      final r = detectIn(
        DocumentFixtures.perspectiveQuad(900, 1200, rotation: 12 * math.pi / 180),
      );
      expect(r.found, isNotNull);
      expect(DocumentFixtures.maxCornerError(r.found!, r.truth), lessThan(25));
    });

    test('aguanta la luz lateral', () {
      final r = detectIn(
        DocumentFixtures.frontalQuad(900, 1200),
        lighting: 0.35,
      );
      expect(r.found, isNotNull);
      expect(DocumentFixtures.maxCornerError(r.found!, r.truth), lessThan(20));
    });

    test('NO recorta contenido de mas', () {
      // El sintoma que se ve al usarlo: la foto sale cortada porque el
      // detector se queda con un bloque interior en vez de con la hoja.
      for (final quad in [
        DocumentFixtures.frontalQuad(900, 1200),
        DocumentFixtures.perspectiveQuad(900, 1200, tilt: 0.05),
        DocumentFixtures.perspectiveQuad(900, 1200, rotation: 8 * math.pi / 180),
      ]) {
        final r = detectIn(quad);
        expect(r.found, isNotNull);
        final coverage = DocumentFixtures.areaCoverage(r.found!, r.truth);
        expect(
          coverage,
          greaterThan(0.93),
          reason: 'se esta perdiendo el ${((1 - coverage) * 100).round()}% de la hoja',
        );
        expect(coverage, lessThan(1.12), reason: 'coge fondo de mas');
      }
    });

    test('una pagina que llena casi todo el encuadre tambien se detecta', () {
      final r = detectIn(DocumentFixtures.frontalQuad(900, 1200, fill: 0.94));
      expect(r.found, isNotNull);
      expect(DocumentFixtures.areaCoverage(r.found!, r.truth), greaterThan(0.90));
    });
  });

  _aspectRatioTests();

  group('Enderezado', () {
    test('las marcas quedan donde deben tras corregir la perspectiva', () {
      final page = DocumentFixtures.renderPage();
      final quad = DocumentFixtures.perspectiveQuad(900, 1200, tilt: 0.09);
      final scene = DocumentFixtures.placeInScene(
        page,
        sceneWidth: 900,
        sceneHeight: 1200,
        quad: quad,
      );

      final warped = warpPerspective(scene.scene, scene.truth, 620, 877);

      // Cada marca de referencia debe aparecer oscura en su posicion relativa.
      for (final m in DocumentFixtures.markers) {
        // La marca mide 10 px en una pagina de 620x877: se muestrea justo
        // dentro de ella, no una caja mayor que la diluya.
        final luma = DocumentFixtures.regionLuma(
          warped,
          m.x - 0.006,
          m.y - 0.004,
          m.x + 0.006,
          m.y + 0.004,
        );
        expect(luma, lessThan(120),
            reason: 'la marca (${m.x}, ${m.y}) no esta donde deberia');
      }

      // Y el centro entre marcas debe ser papel, no tinta.
      expect(DocumentFixtures.regionLuma(warped, 0.45, 0.45, 0.55, 0.5),
          greaterThan(150));
    });

    test('detectar y enderezar reconstruye la pagina de frente', () {
      final page = DocumentFixtures.renderPage();
      final quad = DocumentFixtures.perspectiveQuad(900, 1200, tilt: 0.07);
      final scene = DocumentFixtures.placeInScene(
        page,
        sceneWidth: 900,
        sceneHeight: 1200,
        quad: quad,
      );

      final detected = DocumentDetector.detect(rgbToGray(scene.scene));
      expect(detected, isNotNull);

      final warped = warpPerspective(scene.scene, detected!, 620, 877);

      // Los bordes deben ser papel: si sale fondo oscuro, el recorte se fue.
      final borderLuma = [
        DocumentFixtures.regionLuma(warped, 0.02, 0.30, 0.06, 0.70),
        DocumentFixtures.regionLuma(warped, 0.94, 0.30, 0.98, 0.70),
        DocumentFixtures.regionLuma(warped, 0.30, 0.02, 0.70, 0.05),
      ];
      for (final luma in borderLuma) {
        expect(luma, greaterThan(140),
            reason: 'aparece fondo oscuro dentro del recorte');
      }
    });
  });
}

/// La perspectiva no solo tuerce la hoja: tambien la estira. Si el enderezado
/// se limita a medir los lados en la foto, un documento fotografiado de lado
/// sale achatado o alargado. Es el sintoma de "la foto se parte / sale rara".
void _aspectRatioTests() {
  group('Relacion de aspecto al enderezar', () {
    /// Proporcion alto/ancho real de una A4 en vertical.
    const a4Ratio = 877 / 620;

    double ratioOf(Quad quad) => quad.targetHeight / quad.targetWidth;

    test('de frente conserva la proporcion', () {
      final page = DocumentFixtures.renderPage();
      final quad = DocumentFixtures.frontalQuad(900, 1200, fill: 0.7);
      final scene = DocumentFixtures.placeInScene(
        page,
        sceneWidth: 900,
        sceneHeight: 1200,
        quad: quad,
      );
      final found = DocumentDetector.detect(rgbToGray(scene.scene))!;
      // La escena es 900x1200, asi que de frente la proporcion es la del hueco.
      expect(ratioOf(found), closeTo(1200 * 0.7 / (900 * 0.7), 0.08));
    });

    test('con perspectiva fuerte la proporcion sigue siendo la del papel', () {
      final page = DocumentFixtures.renderPage();
      // Trapecio marcado: el borde superior mucho mas estrecho.
      final quad = DocumentFixtures.perspectiveQuad(900, 1200, tilt: 0.20);
      final scene = DocumentFixtures.placeInScene(
        page,
        sceneWidth: 900,
        sceneHeight: 1200,
        quad: quad,
      );

      final estimated = ratioOf(scene.truth);
      // La pagina real es A4 (1.41). Medir los lados en la foto da otra cosa.
      expect(
        estimated,
        closeTo(a4Ratio, a4Ratio * 0.15),
        reason: 'la hoja sale deformada: proporcion estimada '
            '${estimated.toStringAsFixed(2)} frente a ${a4Ratio.toStringAsFixed(2)}',
      );
    });
  });
}
