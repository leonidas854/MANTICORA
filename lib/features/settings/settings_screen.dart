import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/device_profile.dart';
import '../../core/error_orchestrator.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/repositories/storage_service.dart';
import '../../export/pdf_builder.dart';
import '../../imaging/filters.dart';
import '../../widgets/common.dart';
import '../diagnostics/diagnostics_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int? _usedBytes;

  @override
  void initState() {
    super.initState();
    _loadUsage();
  }

  Future<void> _loadUsage() async {
    final bytes = await StorageService.instance.usedBytes();
    if (mounted) setState(() => _usedBytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final trash = ref.watch(trashCountProvider).valueOrNull ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        children: [
          _header('Escaneo'),
          ListTile(
            leading: const Icon(Icons.filter_alt_outlined),
            title: const Text('Filtro por defecto'),
            subtitle: Text(settings.defaultFilter.label),
            onTap: () async {
              final f = await _choose<ScanFilter>(
                'Filtro por defecto',
                ScanFilter.values,
                (f) => f.label,
                settings.defaultFilter,
              );
              if (f != null) notifier.update((s) => s.copyWith(defaultFilter: f));
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.text_fields),
            title: const Text('OCR automatico'),
            subtitle: Text(
              DeviceProfile.current.autoOcrRecommended
                  ? 'Reconoce el texto al guardar cada escaneo'
                  : 'Reconoce el texto al guardar. En este dispositivo hara '
                      'que guardar tarde bastante mas',
            ),
            value: settings.autoOcr,
            onChanged: (v) => notifier.update((s) => s.copyWith(autoOcr: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.photo_library_outlined),
            title: const Text('Conservar imagenes originales'),
            subtitle: const Text('Permite reeditar el recorte sin perder calidad'),
            value: settings.keepOriginals,
            onChanged: (v) => notifier.update((s) => s.copyWith(keepOriginals: v)),
          ),

          _header('PDF'),
          ListTile(
            leading: const Icon(Icons.crop_portrait),
            title: const Text('Tamano de pagina'),
            subtitle: Text(settings.pdfPageSize.label),
            onTap: () async {
              final v = await _choose<PdfPageSize>(
                'Tamano de pagina',
                PdfPageSize.values,
                (e) => e.label,
                settings.pdfPageSize,
              );
              if (v != null) notifier.update((s) => s.copyWith(pdfPageSize: v));
            },
          ),
          ListTile(
            leading: const Icon(Icons.high_quality_outlined),
            title: const Text('Calidad de imagen'),
            subtitle: Text(settings.pdfQuality.label),
            onTap: () async {
              final v = await _choose<PdfQuality>(
                'Calidad de imagen',
                PdfQuality.values,
                (e) => e.label,
                settings.pdfQuality,
              );
              if (v != null) notifier.update((s) => s.copyWith(pdfQuality: v));
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.search),
            title: const Text('PDF con texto buscable'),
            subtitle: const Text('Incrusta una capa de texto invisible del OCR'),
            value: settings.searchablePdf,
            onChanged: (v) => notifier.update((s) => s.copyWith(searchablePdf: v)),
          ),

          _header('Apariencia'),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('Tema'),
            subtitle: Text(switch (settings.themeMode) {
              ThemeMode.light => 'Claro',
              ThemeMode.dark => 'Oscuro',
              ThemeMode.system => 'Segun el sistema',
            }),
            onTap: () async {
              final v = await _choose<ThemeMode>(
                'Tema',
                ThemeMode.values,
                (e) => switch (e) {
                  ThemeMode.light => 'Claro',
                  ThemeMode.dark => 'Oscuro',
                  ThemeMode.system => 'Segun el sistema',
                },
                settings.themeMode,
              );
              if (v != null) notifier.update((s) => s.copyWith(themeMode: v));
            },
          ),

          _header('Seguridad'),
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('Bloquear la aplicacion'),
            subtitle: const Text('Pide huella o PIN al abrir'),
            value: settings.appLock,
            onChanged: (v) async {
              if (v && !await _canAuthenticate()) {
                if (context.mounted) {
                  showMessage(context,
                      'Este dispositivo no tiene huella ni PIN configurado',
                      error: true);
                }
                return;
              }
              notifier.update((s) => s.copyWith(appLock: v));
            },
          ),

          _header('Almacenamiento'),
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: const Text('Espacio usado por los escaneos'),
            subtitle: Text(_usedBytes == null ? 'Calculando...' : formatBytes(_usedBytes!)),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('Vaciar la papelera'),
            subtitle: Text('$trash documentos'),
            onTap: trash == 0
                ? null
                : () async {
                    if (await confirm(context,
                        title: 'Vaciar la papelera',
                        message: 'Se borraran $trash documentos y sus imagenes.',
                        confirmLabel: 'Vaciar',
                        destructive: true)) {
                      await ref.read(repositoryProvider).emptyTrash();
                      await _loadUsage();
                    }
                  },
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Limpiar ficheros temporales'),
            onTap: () async {
              await StorageService.instance.clearTmp();
              await _loadUsage();
              if (context.mounted) {
                showMessage(context, 'Temporales eliminados');
              }
            },
          ),

          _header('Diagnostico'),
          ListTile(
            leading: const Icon(Icons.speed_outlined),
            title: const Text('Gama del dispositivo'),
            subtitle: Text(
              '${DeviceProfile.current.tier.label} · '
              '${DeviceProfile.current.maxImageSide} px de trabajo',
            ),
          ),
          ValueListenableBuilder<int>(
            valueListenable: ErrorOrchestrator.failureCount,
            builder: (_, count, _) => ListTile(
              leading: Icon(
                count == 0 ? Icons.check_circle_outline : Icons.error_outline,
                color: count == 0 ? null : Theme.of(context).colorScheme.error,
              ),
              title: const Text('Registro de la aplicacion'),
              subtitle: Text(count == 0
                  ? 'Sin incidencias en esta sesion'
                  : '$count incidencias en esta sesion'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
              ),
            ),
          ),

          _header('Acerca de'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Manticora'),
            subtitle: Text(
              'Escaner de documentos con OCR, PDF y Word. '
              'Todo el procesamiento ocurre en el dispositivo, sin conexion.',
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  Future<T?> _choose<T>(
    String title,
    List<T> options,
    String Function(T) label,
    T current,
  ) =>
      showModalBottomSheet<T>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
              for (final o in options)
                ListTile(
                  leading: Icon(o == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off),
                  title: Text(label(o)),
                  onTap: () => Navigator.pop(ctx, o),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );

  Future<bool> _canAuthenticate() async {
    try {
      final auth = LocalAuthentication();
      return await auth.isDeviceSupported() && await auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }
}
