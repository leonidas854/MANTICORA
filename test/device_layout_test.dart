import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/device_layout.dart';

void main() {
  group('DeviceLayout', () {
    test('un Android estrecho se trata como telefono', () {
      expect(
        DeviceLayout.classify(
          platform: TargetPlatform.android,
          logicalSize: const Size(390, 844),
        ),
        AppDeviceKind.phone,
      );
    });

    test('un Android grande se trata como tablet', () {
      expect(
        DeviceLayout.classify(
          platform: TargetPlatform.android,
          logicalSize: const Size(800, 1280),
        ),
        AppDeviceKind.tablet,
      );
    });

    test('Linux sigue siendo escritorio aunque la ventana sea estrecha', () {
      expect(
        DeviceLayout.classify(
          platform: TargetPlatform.linux,
          logicalSize: const Size(420, 760),
        ),
        AppDeviceKind.desktop,
      );
    });

    test('los puntos de corte dan una interfaz estable al redimensionar', () {
      expect(DeviceLayout.widthClassFor(479), AppWidthClass.compact);
      expect(DeviceLayout.widthClassFor(480), AppWidthClass.medium);
      expect(DeviceLayout.widthClassFor(839), AppWidthClass.medium);
      expect(DeviceLayout.widthClassFor(840), AppWidthClass.expanded);
    });
  });
}
