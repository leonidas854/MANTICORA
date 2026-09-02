import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/device_profile.dart';
import '../../core/error_orchestrator.dart';
import '../../core/logger.dart';
import '../../core/providers.dart';
import '../../data/db/app_database.dart';
import '../../imaging/detector_worker.dart';
import '../../widgets/common.dart';

/// Ventana al estado interno de la app: gama detectada, fallos y registro.
///
/// Sirve para que, cuando algo no funcione en un movil concreto, se pueda ver
/// exactamente que paso sin tener que conectar el telefono a un ordenador.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  LogLevel _minLevel = LogLevel.debug;

  @override
  void initState() {
    super.initState();
    Log.addListener(_onLog);
  }

  @override
  void dispose() {
    Log.removeListener(_onLog);
    super.dispose();
  }

  void _onLog() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final profile = DeviceProfile.current;
    final entries =
        Log.entries.where((e) => e.level.index >= _minLevel.index).toList().reversed;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostico'),
        actions: [
          IconButton(
            tooltip: 'Copiar el registro',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _copyLog,
          ),
          IconButton(
            tooltip: 'Compartir el registro',
            icon: const Icon(Icons.share_outlined),
            onPressed: _shareLog,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'clear') _clearLog();
              if (v == 'integrity') _runIntegrityCheck();
              if (v == 'vacuum') _vacuum();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'integrity', child: Text('Revisar integridad')),
              PopupMenuItem(value: 'vacuum', child: Text('Compactar base de datos')),
              PopupMenuItem(value: 'clear', child: Text('Vaciar el registro')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _summary(profile),
          const Divider(height: 1),
          _levelFilter(),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? const EmptyState(
                    icon: Icons.article_outlined,
                    title: 'Sin eventos que mostrar',
                  )
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, i) => _LogTile(entry: entries.elementAt(i)),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _summary(DeviceProfile profile) {
    final scheme = Theme.of(context).colorScheme;
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 132,
                child: Text(label,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
              Expanded(
                child: Text(value,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row('Gama detectada', profile.tier.label),
          row('Memoria del equipo',
              profile.totalRamMb > 0 ? '${profile.totalRamMb} MB' : 'desconocida'),
          row('Nucleos', '${profile.cores}'),
          row('Resolucion de trabajo', '${profile.maxImageSide} px · '
              'calidad ${profile.jpegQuality}'),
          row('Deteccion en vivo',
              'cada ${profile.liveDetectInterval.inMilliseconds} ms · '
              '${profile.detectorWorkSize} px'),
          row('Fotogramas descartados', '${DetectorWorker.instance.droppedFrames}'),
          row('Busqueda FTS5',
              AppDatabase.instance.ftsAvailable ? 'disponible' : 'no disponible'),
          ValueListenableBuilder<int>(
            valueListenable: ErrorOrchestrator.failureCount,
            builder: (_, count, _) => row('Fallos en esta sesion', '$count'),
          ),
        ],
      ),
    );
  }

  Widget _levelFilter() => SizedBox(
        height: 50,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            for (final level in LogLevel.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(switch (level) {
                    LogLevel.debug => 'Todo',
                    LogLevel.info => 'Info',
                    LogLevel.warn => 'Avisos',
                    LogLevel.error => 'Errores',
                  }),
                  selected: _minLevel == level,
                  onSelected: (_) => setState(() => _minLevel = level),
                ),
              ),
          ],
        ),
      );

  Future<void> _copyLog() async {
    await Clipboard.setData(ClipboardData(text: Log.dump()));
    if (mounted) showMessage(context, 'Registro copiado al portapapeles');
  }

  Future<void> _shareLog() async {
    final file = await ErrorOrchestrator.guard(
      'Preparando el registro',
      Log.exportForSharing,
      tag: 'Diagnostico',
    );
    if (file == null) {
      if (mounted) showMessage(context, 'No hay registro en disco que compartir');
      return;
    }
    await ErrorOrchestrator.guard(
      'Compartiendo el registro',
      () => SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: 'Registro de Manticora'),
      ),
      tag: 'Diagnostico',
    );
  }

  Future<void> _clearLog() async {
    await Log.clear();
    if (mounted) setState(() {});
  }

  Future<void> _runIntegrityCheck() async {
    final problems = await runWithProgress<int>(
      context,
      'Revisando documentos y ficheros...',
      (_) => ref.read(repositoryProvider).verifyIntegrity(),
      tag: 'Diagnostico',
    );
    if (problems == null || !mounted) return;
    showMessage(
      context,
      problems == 0
          ? 'Todo correcto: no se han encontrado incidencias'
          : 'Se han corregido $problems incidencias',
    );
  }

  Future<void> _vacuum() async {
    await runWithProgress<void>(
      context,
      'Compactando la base de datos...',
      (_) => AppDatabase.instance.vacuum(),
      tag: 'Diagnostico',
    );
    if (mounted) showMessage(context, 'Base de datos compactada');
  }
}

class _LogTile extends StatelessWidget {
  final LogEntry entry;
  const _LogTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (entry.level) {
      LogLevel.debug => scheme.onSurfaceVariant,
      LogLevel.info => scheme.primary,
      LogLevel.warn => Colors.orange,
      LogLevel.error => scheme.error,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 34,
            margin: const EdgeInsets.only(right: 10, top: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(entry.timeLabel,
                        style: TextStyle(
                            fontSize: 11,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: scheme.onSurfaceVariant)),
                    const SizedBox(width: 8),
                    Text(entry.tag,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: color)),
                  ],
                ),
                const SizedBox(height: 1),
                SelectableText(
                  entry.error == null
                      ? entry.message
                      : '${entry.message}\n${entry.error}',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
