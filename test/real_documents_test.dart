import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/imaging/detector.dart';
import 'package:manticora/imaging/filters.dart';
import 'package:manticora/imaging/geometry.dart';
import 'package:manticora/imaging/raster.dart';

import 'support/corpus.dart';
import 'support/document_fixtures.dart';

/// Pruebas con documentos reales (dominio publico) colocados en escenas con
/// perspectiva conocida: contenido autentico y verdad medible al mismo tiempo.
void main() {
  final documents = Corpus.available();

  group('Flujo completo sobre documentos reales', () {
    for (final name in documents) {
      group(name, () {
        late RgbImage page;

        setUp(() => page = Corpus.loadScaled(name, maxSide: 700));

        ({RgbImage scene, Quad truth}) sceneFor(Quad Function(int, int) build) {
          const w = 900, h = 1200;
          return DocumentFixtures.placeInScene(
            page,
            sceneWidth: w,
            sceneHeight: h,
            quad: build(w, h),
            lightingGradient: 0.18,
          );
        }

        test('se detecta la hoja completa, sin recortar contenido', () {
          final s = sceneFor((w, h) => DocumentFixtures.frontalQuad(w, h, fill: 0.78));
          final found = DocumentDetector.detect(rgbToGray(s.scene));

          expect(found, isNotNull, reason: 'no se ha detectado el documento');
          final coverage = DocumentFixtures.areaCoverage(found!, s.truth);
          expect(coverage, greaterThan(0.90),
              reason: 'se pierde el ${((1 - coverage) * 100).round()}% de la hoja');
          expect(coverage, lessThan(1.15), reason: 'coge demasiado fondo');
        });

        test('se detecta tambien en perspectiva', () {
          final s = sceneFor(
            (w, h) => DocumentFixtures.perspectiveQuad(w, h, tilt: 0.07),
          );
          final found = DocumentDetector.detect(rgbToGray(s.scene));
          expect(found, isNotNull);
          expect(DocumentFixtures.maxCornerError(found!, s.truth), lessThan(30));
        });

        test('el enderezado no deja fondo oscuro dentro de la hoja', () {
          final s = sceneFor(
            (w, h) => DocumentFixtures.perspectiveQuad(w, h, tilt: 0.06),
          );
          final found = DocumentDetector.detect(rgbToGray(s.scene));
          expect(found, isNotNull);

          final warped = warpPerspective(
            s.scene,
            found!,
            found.targetWidth,
            found.targetHeight,
          );

          // Una franja de fondo dentro del recorte delata un recorte torcido.
          final corners = [
            DocumentFixtures.regionLuma(warped, 0.01, 0.01, 0.05, 0.05),
            DocumentFixtures.regionLuma(warped, 0.95, 0.01, 0.99, 0.05),
            DocumentFixtures.regionLuma(warped, 0.01, 0.95, 0.05, 0.99),
            DocumentFixtures.regionLuma(warped, 0.95, 0.95, 0.99, 0.99),
          ];
          final darkCorners = corners.where((l) => l < 90).length;
          expect(darkCorners, lessThanOrEqualTo(1),
              reason: 'hay $darkCorners esquinas con fondo dentro del recorte');
        });
      });
    }
  }, skip: documents.isEmpty ? Corpus.missingReason : null);

  group('Calidad de la mejora de imagen', () {
    for (final name in documents) {
      test('$name: Magic Color aclara el papel y realza el texto', () {
        final page = Corpus.loadScaled(name, maxSide: 700);

        // Se simula la foto tipica: papel apagado y luz desigual.
        final photo = _dim(page, 0.72, gradient: 0.30);
        final before = _paperAndInk(photo);
        final after = _paperAndInk(applyFilter(photo, ScanFilter.magic));

        expect(after.paper, greaterThan(before.paper + 20),
            reason: 'el papel deberia quedar mas claro');
        expect(after.paper, greaterThan(200),
            reason: 'el fondo del papel deberia acercarse al blanco '
                '(quedo en ${after.paper.round()})');
        expect(after.contrast, greaterThan(before.contrast),
            reason: 'deberia ganar contraste entre texto y papel');
      });

      test('$name: "Sin sombras" iguala la iluminacion', () {
        final page = Corpus.loadScaled(name, maxSide: 700);
        final photo = _dim(page, 0.95, gradient: 0.45);

        final beforeSpread = _illuminationSpread(photo);
        final afterSpread = _illuminationSpread(applyFilter(photo, ScanFilter.enhance));

        expect(afterSpread, lessThan(beforeSpread * 0.55),
            reason: 'la diferencia de luz entre lados deberia bajar mucho '
                '(paso de ${beforeSpread.round()} a ${afterSpread.round()})');
      });

      test('$name: blanco y negro conserva el texto', () {
        final page = Corpus.loadScaled(name, maxSide: 700);
        final bw = applyFilter(_dim(page, 0.85, gradient: 0.25), ScanFilter.blackWhite);

        var dark = 0;
        final total = bw.width * bw.height;
        for (var i = 0; i < total; i++) {
          if (bw.data[i * 3] == 0) dark++;
        }
        final ratio = dark / total;
        // Ni pagina en blanco ni pagina en negro: el texto tiene que estar.
        expect(ratio, greaterThan(0.005),
            reason: 'se ha perdido el texto (solo ${(ratio * 100).toStringAsFixed(2)}% oscuro)');
        expect(ratio, lessThan(0.45),
            reason: 'demasiada tinta: el fondo se esta ennegreciendo');
      });
    }
  }, skip: documents.isEmpty ? Corpus.missingReason : null);
}

/// Oscurece la imagen y le aplica un degradado lateral, como una foto a mano.
RgbImage _dim(RgbImage src, double factor, {double gradient = 0.0}) {
  final out = RgbImage(src.width, src.height, Uint8List.fromList(src.data));
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final t = src.width <= 1 ? 0.0 : x / (src.width - 1);
      final f = factor * (1.0 - gradient * t);
      final i = (y * src.width + x) * 3;
      for (var c = 0; c < 3; c++) {
        out.data[i + c] = (src.data[i + c] * f).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// Luminancia del papel (percentil alto) y del texto (percentil bajo).
({double paper, double ink, double contrast}) _paperAndInk(RgbImage image) {
  final lumas = <int>[];
  final n = image.width * image.height;
  final step = math.max(1, n ~/ 40000);
  for (var i = 0; i < n; i += step) {
    final j = i * 3;
    lumas.add((image.data[j] * 77 + image.data[j + 1] * 150 + image.data[j + 2] * 29) >> 8);
  }
  lumas.sort();
  final paper = lumas[(lumas.length * 0.92).floor().clamp(0, lumas.length - 1)].toDouble();
  final ink = lumas[(lumas.length * 0.05).floor().clamp(0, lumas.length - 1)].toDouble();
  return (paper: paper, ink: ink, contrast: paper - ink);
}

/// Diferencia de luminancia del papel entre el lado izquierdo y el derecho.
double _illuminationSpread(RgbImage image) {
  final left = DocumentFixtures.regionLuma(image, 0.02, 0.1, 0.18, 0.9);
  final right = DocumentFixtures.regionLuma(image, 0.82, 0.1, 0.98, 0.9);
  return (left - right).abs();
}
