import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/device_profile.dart';

void main() {
  const low = DeviceProfile(tier: DeviceTier.low, totalRamMb: 2048, cores: 4);
  const mid = DeviceProfile(tier: DeviceTier.mid, totalRamMb: 4096, cores: 8);
  const high = DeviceProfile(tier: DeviceTier.high, totalRamMb: 12288, cores: 8);

  group('parametros por gama', () {
    test('la gama baja trabaja mas pequeno que la alta', () {
      expect(low.maxImageSide, lessThan(mid.maxImageSide));
      expect(mid.maxImageSide, lessThan(high.maxImageSide));
    });

    test('la calidad JPEG crece con la gama', () {
      expect(low.jpegQuality, lessThan(high.jpegQuality));
    });

    test('la gama baja analiza la camara con menos frecuencia', () {
      expect(low.liveDetectInterval, greaterThan(mid.liveDetectInterval));
      expect(mid.liveDetectInterval, greaterThan(high.liveDetectInterval));
    });

    test('el detector nunca baja del minimo util', () {
      for (final p in [low, mid, high]) {
        expect(p.detectorWorkSize, greaterThanOrEqualTo(240));
      }
    });

    test('el techo de decodificacion protege a la gama baja', () {
      expect(low.maxDecodeMegapixels, lessThan(high.maxDecodeMegapixels));
      expect(low.maxDecodeMegapixels, greaterThan(0));
    });

    test('la gama baja admite menos paginas por exportacion', () {
      expect(low.maxPagesPerExport, lessThan(mid.maxPagesPerExport));
      expect(mid.maxPagesPerExport, lessThan(high.maxPagesPerExport));
    });

    test('el OCR automatico no se recomienda en gama baja', () {
      expect(low.autoOcrRecommended, isFalse);
      expect(mid.autoOcrRecommended, isTrue);
      expect(high.autoOcrRecommended, isTrue);
    });

    test('la gama baja cede el hilo mas a menudo', () {
      expect(low.pagesBeforeYield, lessThan(high.pagesBeforeYield));
      expect(low.pagesBeforeYield, greaterThanOrEqualTo(1));
    });

    test('las miniaturas se decodifican mas pequenas en gama baja', () {
      expect(low.thumbnailCacheWidth, lessThan(high.thumbnailCacheWidth));
    });

    test('la camara no pide la maxima resolucion en gama baja', () {
      expect(low.cameraQuality, CameraQuality.high);
      expect(high.cameraQuality, CameraQuality.veryHigh);
    });

    test('la cache de imagenes se acota en gama baja', () {
      expect(low.imageCacheBytes, lessThan(high.imageCacheBytes));
      expect(low.imageCacheCount, lessThan(high.imageCacheCount));
      // 24 MB es un techo razonable para un movil de 2 GB.
      expect(low.imageCacheBytes, lessThanOrEqualTo(32 << 20));
    });

    test('todos los valores son positivos y coherentes', () {
      for (final p in [low, mid, high]) {
        expect(p.maxImageSide, greaterThan(0));
        expect(p.previewSide, greaterThan(0));
        expect(p.cropPreviewSide, greaterThanOrEqualTo(p.previewSide));
        expect(p.rasterDpi, greaterThan(0));
        expect(p.jpegQuality, inInclusiveRange(1, 100));
      }
    });
  });

  group('deteccion', () {
    test('se puede fijar un perfil concreto para pruebas', () {
      DeviceProfile.overrideForTesting(low);
      expect(DeviceProfile.current.tier, DeviceTier.low);
      DeviceProfile.overrideForTesting(high);
      expect(DeviceProfile.current.tier, DeviceTier.high);
    });

    test('el perfil de reserva es prudente', () {
      expect(DeviceProfile.fallback.tier, DeviceTier.mid);
    });
  });
}
