import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/export/share_service.dart';

void main() {
  group('ShareService', () {
    test('Android abre el panel nativo que incluye WhatsApp', () {
      expect(
        ShareService.strategyFor(TargetPlatform.android, fileCount: 1),
        FileDeliveryStrategy.platformShare,
      );
    });

    test('Linux guarda un fichero porque su panel no admite adjuntos', () {
      expect(
        ShareService.strategyFor(TargetPlatform.linux, fileCount: 1),
        FileDeliveryStrategy.saveAs,
      );
    });

    test('Linux empaqueta varios adjuntos para no perder ninguno', () {
      expect(
        ShareService.strategyFor(TargetPlatform.linux, fileCount: 4),
        FileDeliveryStrategy.bundleAndSave,
      );
    });

    test('declara MIME correctos para audio y video', () {
      expect(ShareService.mimeFor('lectura.m4a'), 'audio/mp4');
      expect(ShareService.mimeFor('resumen.mp4'), 'video/mp4');
    });
  });
}
