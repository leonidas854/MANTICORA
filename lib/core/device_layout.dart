import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Tipo fisico de equipo para decidir que experiencia conviene ofrecer.
///
/// No se deduce solo del ancho de la ventana: una ventana estrecha en Linux
/// sigue teniendo raton y teclado, mientras que una tablet Android mantiene
/// interacciones tactiles aunque disponga de bastante espacio.
enum AppDeviceKind { phone, tablet, desktop }

/// Espacio horizontal disponible para componer una pantalla.
enum AppWidthClass { compact, medium, expanded }

/// Clasificacion comun de dispositivo y ancho para toda la interfaz.
abstract final class DeviceLayout {
  static const double mediumBreakpoint = 480;
  static const double expandedBreakpoint = 840;
  static const double tabletShortestSide = 600;

  /// Clasifica el tipo de equipo combinando plataforma y tamano logico.
  static AppDeviceKind classify({
    required TargetPlatform platform,
    required Size logicalSize,
  }) {
    if (_isDesktopPlatform(platform)) return AppDeviceKind.desktop;

    final shortestSide = logicalSize.shortestSide;
    return shortestSide >= tabletShortestSide
        ? AppDeviceKind.tablet
        : AppDeviceKind.phone;
  }

  /// Clasifica el ancho sin confundirlo con el tipo fisico de equipo.
  static AppWidthClass widthClassFor(double logicalWidth) {
    if (logicalWidth < mediumBreakpoint) return AppWidthClass.compact;
    if (logicalWidth < expandedBreakpoint) return AppWidthClass.medium;
    return AppWidthClass.expanded;
  }

  static AppDeviceKind kindOf(
    BuildContext context, {
    TargetPlatform? platform,
  }) => classify(
    platform: platform ?? defaultTargetPlatform,
    logicalSize: MediaQuery.sizeOf(context),
  );

  static AppWidthClass widthClassOf(BuildContext context) =>
      widthClassFor(MediaQuery.sizeOf(context).width);

  static bool _isDesktopPlatform(TargetPlatform platform) => switch (platform) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };
}
