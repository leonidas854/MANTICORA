import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../export/pdf_builder.dart';
import '../imaging/filters.dart';
import 'device_profile.dart';
import 'error_orchestrator.dart';
import 'logger.dart';

/// Preferencias persistentes de la aplicacion.
class AppSettings {
  final ScanFilter defaultFilter;
  final PdfQuality pdfQuality;
  final PdfPageSize pdfPageSize;
  final bool autoOcr;
  final bool gridView;
  final bool appLock;
  final ThemeMode themeMode;
  final bool keepOriginals;
  final bool searchablePdf;

  const AppSettings({
    this.defaultFilter = ScanFilter.magic,
    this.pdfQuality = PdfQuality.high,
    this.pdfPageSize = PdfPageSize.a4,
    this.autoOcr = false,
    this.gridView = true,
    this.appLock = false,
    this.themeMode = ThemeMode.system,
    this.keepOriginals = true,
    this.searchablePdf = true,
  });

  AppSettings copyWith({
    ScanFilter? defaultFilter,
    PdfQuality? pdfQuality,
    PdfPageSize? pdfPageSize,
    bool? autoOcr,
    bool? gridView,
    bool? appLock,
    ThemeMode? themeMode,
    bool? keepOriginals,
    bool? searchablePdf,
  }) =>
      AppSettings(
        defaultFilter: defaultFilter ?? this.defaultFilter,
        pdfQuality: pdfQuality ?? this.pdfQuality,
        pdfPageSize: pdfPageSize ?? this.pdfPageSize,
        autoOcr: autoOcr ?? this.autoOcr,
        gridView: gridView ?? this.gridView,
        appLock: appLock ?? this.appLock,
        themeMode: themeMode ?? this.themeMode,
        keepOriginals: keepOriginals ?? this.keepOriginals,
        searchablePdf: searchablePdf ?? this.searchablePdf,
      );
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(const AppSettings()) {
    _load();
  }

  SharedPreferences? _prefs;

  /// Se pone a true en cuanto se leen las preferencias: hasta entonces no se
  /// guarda nada, para no pisar los ajustes reales con los valores por defecto.
  bool _loaded = false;
  bool get isLoaded => _loaded;

  Future<void> _load() async {
    final prefs = await ErrorOrchestrator.guard<SharedPreferences>(
      'Leyendo las preferencias',
      SharedPreferences.getInstance,
      tag: 'Ajustes',
      notifyUser: false,
    );
    if (prefs == null) {
      // Sin almacenamiento de preferencias la app funciona igual, solo que no
      // recuerda los ajustes entre sesiones.
      Log.w('Ajustes', 'No hay preferencias persistentes; se usan las de fabrica');
      _loaded = true;
      return;
    }
    final p = _prefs = prefs;
    _loaded = true;
    state = AppSettings(
      defaultFilter: ScanFilter.fromName(p.getString('defaultFilter')),
      pdfQuality: PdfQuality.values.firstWhere(
        (e) => e.name == p.getString('pdfQuality'),
        orElse: () => PdfQuality.high,
      ),
      pdfPageSize: PdfPageSize.values.firstWhere(
        (e) => e.name == p.getString('pdfPageSize'),
        orElse: () => PdfPageSize.a4,
      ),
      // En gama baja el OCR automatico ralentiza mucho el guardado, asi que
      // solo viene activado de fabrica donde el equipo lo aguanta.
      autoOcr: p.getBool('autoOcr') ?? false,
      gridView: p.getBool('gridView') ?? true,
      appLock: p.getBool('appLock') ?? false,
      themeMode: ThemeMode.values.firstWhere(
        (e) => e.name == p.getString('themeMode'),
        orElse: () => ThemeMode.system,
      ),
      keepOriginals: p.getBool('keepOriginals') ?? true,
      searchablePdf: p.getBool('searchablePdf') ?? true,
    );
  }

  Future<void> _save() async {
    if (!_loaded) return;
    final p = _prefs;
    if (p == null) return;
    await p.setString('defaultFilter', state.defaultFilter.name);
    await p.setString('pdfQuality', state.pdfQuality.name);
    await p.setString('pdfPageSize', state.pdfPageSize.name);
    await p.setBool('autoOcr', state.autoOcr);
    await p.setBool('gridView', state.gridView);
    await p.setBool('appLock', state.appLock);
    await p.setString('themeMode', state.themeMode.name);
    await p.setBool('keepOriginals', state.keepOriginals);
    await p.setBool('searchablePdf', state.searchablePdf);
  }

  void update(AppSettings Function(AppSettings) fn) {
    state = fn(state);
    // Guardar no debe poder tumbar la pantalla de ajustes.
    ErrorOrchestrator.guard(
      'Guardando los ajustes',
      _save,
      tag: 'Ajustes',
      notifyUser: false,
    );
  }

  /// Valores recomendados para la gama del dispositivo, para el boton de
  /// "restablecer" de la pantalla de ajustes.
  AppSettings recommendedForDevice() {
    final profile = DeviceProfile.current;
    return state.copyWith(
      autoOcr: profile.autoOcrRecommended && state.autoOcr,
      pdfQuality: switch (profile.tier) {
        DeviceTier.low => PdfQuality.medium,
        DeviceTier.mid => PdfQuality.high,
        DeviceTier.high => PdfQuality.high,
      },
      keepOriginals: profile.tier != DeviceTier.low,
    );
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) => SettingsNotifier());
