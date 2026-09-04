import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/features/scan/scan_screen.dart';
import 'package:manticora/imaging/geometry.dart';

void main() {
  group('Encuadre seguro cuando falla la deteccion', () {
    test('usa toda la imagen y no recorta margenes silenciosamente', () {
      final quad = initialDocumentQuad(null, width: 1000, height: 1400);

      expect(quad.tl.x, 0);
      expect(quad.tl.y, 0);
      expect(quad.tr.x, 1000);
      expect(quad.bl.y, 1400);
      expect(quad.area, 1000 * 1400);
    });

    test('conserva el cuadrilatero que si detecto el documento', () {
      const detected = Quad(
        Pt(20, 30),
        Pt(980, 25),
        Pt(970, 1370),
        Pt(25, 1380),
      );

      expect(
        identical(
          initialDocumentQuad(detected, width: 1000, height: 1400),
          detected,
        ),
        isTrue,
      );
    });
  });

  group('Proteccion contra duplicados del disparo automatico', () {
    const page = Quad(
      Pt(80, 100),
      Pt(520, 105),
      Pt(515, 700),
      Pt(75, 695),
    );
    final start = DateTime(2026, 1, 1, 12);

    test('la misma hoja solo se dispara una vez aunque pase el cooldown', () {
      final gate = AutoCaptureGate(
        stableFramesRequired: 3,
        cooldown: const Duration(seconds: 2),
      );

      expect(gate.observe(page, start), isFalse);
      expect(gate.observe(page, start.add(const Duration(milliseconds: 100))), isFalse);
      expect(gate.observe(page, start.add(const Duration(milliseconds: 200))), isTrue);
      gate.registerCapture(page, start.add(const Duration(milliseconds: 200)));

      expect(gate.observe(page, start.add(const Duration(seconds: 3))), isFalse);
      expect(gate.observe(page, start.add(const Duration(seconds: 4))), isFalse);
      expect(gate.observe(page, start.add(const Duration(seconds: 8))), isFalse);
    });

    test('se rearma al retirar la hoja y espera a que la siguiente se estabilice', () {
      final gate = AutoCaptureGate(
        stableFramesRequired: 2,
        cooldown: const Duration(seconds: 2),
      );

      expect(gate.observe(page, start), isFalse);
      expect(gate.observe(page, start.add(const Duration(milliseconds: 100))), isTrue);
      gate.registerCapture(page, start.add(const Duration(milliseconds: 100)));

      expect(gate.observe(null, start.add(const Duration(milliseconds: 500))), isFalse);
      expect(gate.observe(page, start.add(const Duration(seconds: 1))), isFalse,
          reason: 'todavia esta dentro del cooldown');
      expect(gate.observe(page, start.add(const Duration(seconds: 3))), isTrue);
    });

    test('un movimiento pequeno de la camara no se confunde con otra hoja', () {
      final gate = AutoCaptureGate(
        stableFramesRequired: 2,
        cooldown: const Duration(milliseconds: 100),
      );
      final jitter = Quad(
        page.tl + const Pt(3, -2),
        page.tr + const Pt(2, 3),
        page.br + const Pt(-3, 2),
        page.bl + const Pt(-2, -3),
      );

      gate.registerCapture(page, start);
      expect(gate.observe(jitter, start.add(const Duration(seconds: 1))), isFalse);
      expect(gate.observe(jitter, start.add(const Duration(seconds: 2))), isFalse);
    });
  });
}
