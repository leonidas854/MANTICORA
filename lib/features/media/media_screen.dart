import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/error_orchestrator.dart';
import '../../core/providers.dart';
import '../../data/models/models.dart';
import '../../export/file_saver.dart';
import '../../export/media_export_service.dart';
import '../../widgets/common.dart';
import 'media_source.dart';

/// Convierte un documento —escaneado, PDF, Word o PowerPoint— en un audio
/// ligero o en un video para compartir.
///
/// Todo se hace en el aparato: el texto sale del OCR o del propio fichero, la
/// voz del motor del sistema y la mezcla de FFmpeg.
class MediaScreen extends ConsumerStatefulWidget {
  /// Documento de la biblioteca ya elegido. Si es nulo se pide un fichero.
  final DocumentWithPages? document;

  const MediaScreen({super.key, this.document});

  @override
  ConsumerState<MediaScreen> createState() => _MediaScreenState();
}

class _MediaScreenState extends ConsumerState<MediaScreen> {
  static const _tag = 'Multimedia';

  Uint8List? _pickedBytes;
  String? _pickedName;

  bool _narrated = true;
  int _secondsPerPage = 5;
  int _videoWidth = 720;
  double _speechRate = 1;

  MediaExportResult? _result;

  bool get _hasSource => widget.document != null || _pickedBytes != null;

  String get _sourceTitle =>
      widget.document?.document.title ?? _pickedName ?? 'Documento';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Convertir a audio o video')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          // En el escritorio una columna a lo ancho de la ventana se lee fatal.
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              _sourceCard(),
              const SizedBox(height: 12),
              _optionsCard(),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _hasSource
                    ? () => _export(MediaExportKind.audio)
                    : null,
                icon: const Icon(Icons.headphones_outlined),
                label: const Text('Crear audio (M4A)'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _hasSource
                    ? () => _export(MediaExportKind.video)
                    : null,
                icon: const Icon(Icons.movie_outlined),
                label: const Text('Crear video (MP4)'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              if (_result != null) ...[
                const SizedBox(height: 20),
                _resultCard(_result!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ origen

  Widget _sourceCard() {
    final doc = widget.document;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Text('Que se convierte',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          if (doc != null)
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(doc.document.title,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${doc.pages.length} paginas escaneadas · '
                '${doc.pages.where((p) => p.hasOcr).length} con texto',
              ),
            )
          else if (_pickedName != null)
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(_pickedName!,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(formatBytes(_pickedBytes?.length ?? 0)),
              trailing: TextButton(
                onPressed: _pickFile,
                child: const Text('Cambiar'),
              ),
            )
          else
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Elegir un archivo'),
              subtitle: const Text('PDF, Word (.docx) o PowerPoint (.pptx)'),
              onTap: _pickFile,
            ),
          if (doc != null && doc.pages.every((p) => !p.hasOcr))
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Este documento aun no tiene texto reconocido: se hara el OCR '
                'antes de narrarlo y quedara guardado para la proxima vez.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Future<void> _pickFile() async {
    final picked = await ErrorOrchestrator.guard<PlatformFile?>(
      'Abriendo el selector de ficheros',
      () => FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: MediaSourceLoader.pickableExtensions,
        dialogTitle: 'Selecciona un PDF, Word o PowerPoint',
      ),
      tag: _tag,
    );
    if (picked == null || !mounted) return;

    final bytes = await ErrorOrchestrator.guard<Uint8List>(
      'Leyendo el archivo',
      picked.readAsBytes,
      tag: _tag,
    );
    if (bytes == null || !mounted) return;
    setState(() {
      _pickedBytes = bytes;
      _pickedName = picked.name;
      _result = null;
    });
  }

  // ----------------------------------------------------------------- opciones

  Widget _optionsCard() => Card(
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Text('Como suena y como se ve',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            SwitchListTile(
              value: _narrated,
              onChanged: (v) => setState(() => _narrated = v),
              title: const Text('Narrar el video con voz'),
              subtitle: const Text(
                  'El audio siempre se narra; el video puede ir mudo.'),
            ),
            if (_narrated)
              _slider(
                label: 'Velocidad de la voz',
                value: _speechRate,
                min: 0.8,
                max: 1.4,
                divisions: 6,
                display: '${_speechRate.toStringAsFixed(1)}x',
                onChanged: (v) => setState(() => _speechRate = v),
              )
            else
              _slider(
                label: 'Segundos por pagina',
                value: _secondsPerPage.toDouble(),
                min: 2,
                max: 15,
                divisions: 13,
                display: '$_secondsPerPage s',
                onChanged: (v) => setState(() => _secondsPerPage = v.round()),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Tamano del video'),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 480, label: Text('Ligero')),
                      ButtonSegment(value: 720, label: Text('Normal')),
                      ButtonSegment(value: 1080, label: Text('Nitido')),
                    ],
                    selected: {_videoWidth},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) =>
                        setState(() => _videoWidth = s.first),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text(label), Text(display)],
            ),
            Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: display,
              onChanged: onChanged,
            ),
          ],
        ),
      );

  // --------------------------------------------------------------- resultado

  Widget _resultCard(MediaExportResult result) {
    final size = ErrorOrchestrator.guardSync(
          'Midiendo el fichero',
          result.file.lengthSync,
          fallback: 0,
        ) ??
        0;
    final minutes = result.duration.inMinutes;
    final seconds = result.duration.inSeconds % 60;

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(
              result.kind == MediaExportKind.audio
                  ? Icons.headphones
                  : Icons.movie,
            ),
            title: Text(p.basename(result.file.path)),
            subtitle: Text(
              '${formatBytes(size)} · '
              '${minutes > 0 ? '$minutes min ' : ''}$seconds s'
              '${result.narrated ? ' · con voz' : ' · sin voz'}',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => shareFiles(
                      context,
                      [result.file],
                      subject: _sourceTitle,
                    ),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Compartir'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _save(result.file),
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Guardar'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save(File file) async {
    final saved = await ErrorOrchestrator.guard<String?>(
      'Guardando el archivo',
      () async => FileSaver.save(
        p.basename(file.path),
        await file.readAsBytes(),
      ),
      tag: _tag,
    );
    if (!mounted) return;
    showMessage(
      context,
      saved == null ? 'Guardado cancelado' : 'Guardado correctamente',
    );
  }

  // --------------------------------------------------------------- conversion

  Future<void> _export(MediaExportKind kind) async {
    if (!_hasSource) {
      showMessage(context, 'Elige primero un archivo', error: true);
      return;
    }

    final needImages = kind == MediaExportKind.video;
    MediaSourceContent? content;

    final result = await runWithProgress<MediaExportResult>(
      context,
      'Preparando el contenido...',
      (setMessage) async {
        content = await _load(needImages: needImages, onProgress: setMessage);
        final options = MediaExportOptions(
          // El audio no tiene sentido mudo; el video si.
          narrated: kind == MediaExportKind.audio || _narrated,
          secondsPerPage: _secondsPerPage,
          videoWidth: _videoWidth,
          speechRate: _speechRate,
        );
        final service = MediaExportService.instance;
        return kind == MediaExportKind.audio
            ? service.toAudio(
                content!.pages,
                title: content!.title,
                options: options,
                onProgress: setMessage,
              )
            : service.toVideo(
                content!.pages,
                title: content!.title,
                options: options,
                onProgress: setMessage,
              );
      },
      tag: _tag,
    );

    // Las laminas y las paginas rasterizadas ya no hacen falta.
    await content?.dispose();
    if (result == null || !mounted) return;
    setState(() => _result = result);
  }

  Future<MediaSourceContent> _load({
    required bool needImages,
    required void Function(String message) onProgress,
  }) {
    final doc = widget.document;
    if (doc != null) {
      return MediaSourceLoader.fromScannedDocument(
        doc,
        repository: ref.read(repositoryProvider),
        onProgress: onProgress,
      );
    }
    return MediaSourceLoader.fromBytes(
      _pickedBytes!,
      fileName: _pickedName ?? 'documento',
      needImages: needImages,
      onProgress: onProgress,
    );
  }
}
