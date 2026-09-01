import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../export/pdf_builder.dart';
import '../imaging/filters.dart';

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

  Future<void> _load() async {
    final p = _prefs = await SharedPreferences.getInstance();
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
    final p = _prefs ??= await SharedPreferences.getInstance();
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
    _save();
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) => SettingsNotifier());
