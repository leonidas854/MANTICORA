import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/device_profile.dart';
import '../../core/error_orchestrator.dart';
import '../../core/failure.dart';
import '../../core/logger.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/validators.dart';
import '../../data/repositories/storage_service.dart';
import '../../imaging/filters.dart';
import '../../imaging/ocr_service.dart';
import '../../imaging/pipeline.dart';
import '../../widgets/common.dart';
import '../crop/crop_screen.dart';
import '../scan/scan_session.dart';

/// Revision de las capturas: filtro, recorte, giro y guardado.
class EditScreen extends ConsumerStatefulWidget {
  final ScanSession session;

  /// Si se indica, las paginas se anaden a ese documento en vez de crear uno.
  final String? appendToDocumentId;

  const EditScreen({super.key, required this.session, this.appendToDocumentId});

  @override
  ConsumerState<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends ConsumerState<EditScreen> {
  static const String _tag = 'Edicion';

  late final PageController _pageController;
  final DeviceProfile _profile = DeviceProfile.current;

  /// Cola de vistas previas pendientes. Se procesan **de una en una**: lanzar
  /// un isolate por pagina a la vez agota la memoria en gama baja.
  final Queue<int> _renderQueue = Queue<int>();
  final Set<int> _queued = {};
  bool _rendering = false;

  int _index = 0;
  bool _busy = false;
  bool _saved = false;
  bool _showAdjustments = false;
  Timer? _debounce;

  ScanSession get _session => widget.session;
  List<CapturedShot> get _shots => _session.shots;
  CapturedShot get _current => _shots[_index.clamp(0, _shots.length - 1)];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    final defaultFilter = ref.read(settingsProvider).defaultFilter;
    for (final s in _shots) {
      s.filter = defaultFilter;
    }
    _enqueueAll();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pageController.dispose();
    // Si se guardo, el repositorio ya tiene copia propia de las imagenes.
    if (!_saved) unawaited(_session.dispose());
    super.dispose();
  }

  // ------------------------------------------------------- vistas previas

  void _enqueueAll() {
    for (var i = 0; i < _shots.length; i++) {
      _enqueue(i);
    }
  }

  void _enqueue(int index, {bool priority = false}) {
    if (index < 0 || index >= _shots.length) return;
    if (_queued.contains(index)) return;
    _queued.add(index);
    priority ? _renderQueue.addFirst(index) : _renderQueue.addLast(index);
    unawaited(_pumpQueue());
  }

  Future<void> _pumpQueue() async {
    if (_rendering) return;
    _rendering = true;
    try {
      while (_renderQueue.isNotEmpty && mounted) {
        final index = _renderQueue.removeFirst();
        _queued.remove(index);
        await _render(index);
        // Un respiro entre paginas: deja que la interfaz responda y que el
        // recolector libere los buffers de la anterior.
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    } finally {
      _rendering = false;
    }
  }

  Future<void> _render(int index) async {
    if (index < 0 || index >= _shots.length || !mounted) return;
    final shot = _shots[index];

    final result = await ErrorOrchestrator.attempt(
      'Generando la vista previa de la pagina ${index + 1}',
      () async {
        final original = await shot.readOriginal();
        return ImagePipeline.processPage(
          sourceJpeg: original,
          quad: shot.quad,
          filter: shot.filter,
          adjustments: shot.adjustments,
          rotationQuarterTurns: shot.rotation,
          maxSide: _profile.previewSide,
          quality: 82,
        );
      },
      tag: _tag,
      notifyUser: false,
    );

    if (!mounted) return;
    result.fold(
      (processed) => setState(() => shot.preview = processed.jpeg),
      (failure) {
        Log.w(_tag, 'Sin vista previa para la pagina ${index + 1}: ${failure.message}');
        if (mounted) setState(() {});
      },
    );
  }

  // ------------------------------------------------------------- acciones

  Future<void> _openCrop() async {
    if (_shots.isEmpty) return;
    final shot = _current;
    final index = _index;

    final bytes = await ErrorOrchestrator.guard(
      'Abriendo el recorte',
      shot.readOriginal,
      tag: _tag,
    );
    if (bytes == null || !mounted) return;

    final result = await Navigator.push<CropResult>(
      context,
      MaterialPageRoute(
        builder: (_) => CropScreen(
          imageBytes: bytes,
          originalWidth: shot.width,
          originalHeight: shot.height,
          initialQuad: shot.quad,
          initialRotation: shot.rotation,
        ),
      ),
    );
    if (result == null) return;
    shot.quad = result.quad;
    shot.rotation = result.rotation;
    _enqueue(index, priority: true);
  }

  void _setFilter(ScanFilter filter, {bool applyToAll = false}) {
    if (_shots.isEmpty) return;
    setState(() {
      if (applyToAll) {
        for (final s in _shots) {
          s.filter = filter;
        }
      } else {
        _current.filter = filter;
      }
    });
    if (applyToAll) {
      _enqueue(_index, priority: true);
      _enqueueAll();
    } else {
      _enqueue(_index, priority: true);
    }
  }

  void _rotate(int turns) {
    if (_shots.isEmpty) return;
    setState(() => _current.rotation = (_current.rotation + turns) % 4);
    _enqueue(_index, priority: true);
  }

  void _updateAdjustments(Adjustments adj) {
    if (_shots.isEmpty) return;
    setState(() => _current.adjustments = adj);
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 320),
      () => _enqueue(_index, priority: true),
    );
  }

  Future<void> _deleteCurrent() async {
    if (_shots.isEmpty) return;
    if (_shots.length == 1) {
      final discard = await confirm(
        context,
        title: 'Descartar',
        message: 'Es la unica pagina. Se descartara el escaneo.',
        confirmLabel: 'Descartar',
        destructive: true,
      );
      if (discard && mounted) Navigator.pop(context);
      return;
    }
    final index = _index;
    await _session.removeAt(index);
    if (!mounted) return;
    setState(() {
      _index = index.clamp(0, _shots.length - 1);
      _queued.clear();
      _renderQueue.clear();
    });
    _pageController.jumpToPage(_index);
  }

  // -------------------------------------------------------------- guardado

  Future<void> _save() async {
    if (_busy || _shots.isEmpty) return;

    final limit = Validators.pageLimit(_shots.length, _profile.maxPagesPerExport);
    if (limit != null) {
      ErrorOrchestrator.notify(limit);
      return;
    }

    setState(() => _busy = true);
    final repo = ref.read(repositoryProvider);
    final settings = ref.read(settingsProvider);

    try {
      // Antes de empezar, comprobamos que hay sitio: unas 2 paginas por MB.
      final space = await Validators.freeSpaceFor(
        await StorageService.instance.root,
        _shots.length * 900 * 1024,
      );
      if (space != null) {
        ErrorOrchestrator.notify(space);
        return;
      }
      if (!mounted) return;

      final outcome = await runWithProgress<_SaveOutcome>(
        context,
        'Procesando paginas...',
        (setMessage) async {
          final docId =
              widget.appendToDocumentId ?? (await repo.createDocument()).id;
          var saved = 0;
          final failed = <int>[];

          for (var i = 0; i < _shots.length; i++) {
            setMessage('Guardando pagina ${i + 1} de ${_shots.length}...');
            final shot = _shots[i];

            // Cada pagina va aislada: que una falle no debe tirar la tanda.
            final page = await ErrorOrchestrator.guard(
              'Guardando la pagina ${i + 1}',
              () async {
                final original = await shot.readOriginal();
                final processed = await ImagePipeline.processPage(
                  sourceJpeg: original,
                  quad: shot.quad,
                  filter: shot.filter,
                  adjustments: shot.adjustments,
                  rotationQuarterTurns: shot.rotation,
                );
                return repo.addPage(
                  documentId: docId,
                  originalJpeg: original,
                  keepOriginal: settings.keepOriginals,
                  processedJpeg: processed.jpeg,
                  thumbnailJpeg: processed.thumbnail,
                  quad: shot.quad,
                  filter: shot.filter,
                  adjustments: shot.adjustments,
                  rotation: shot.rotation,
                  width: processed.width,
                  height: processed.height,
                );
              },
              tag: _tag,
              notifyUser: false,
            );

            if (page == null) {
              failed.add(i + 1);
              continue;
            }
            saved++;

            if (settings.autoOcr) {
              setMessage('Reconociendo texto ${i + 1}/${_shots.length}...');
              await ErrorOrchestrator.guard(
                'OCR de la pagina ${i + 1}',
                () async {
                  final file = await repo.pageFile(page);
                  final ocr = await OcrService.instance.recognizeFile(file.path);
                  if (!ocr.isEmpty) {
                    await repo.setOcrText(page.id, docId, ocr.text,
                        boxesJson: ocr.boxesJson);
                  }
                },
                tag: _tag,
                notifyUser: false,
              );
            }

            // Cede el hilo cada pocas paginas para que la barra avance y para
            // dar aire al recolector de basura.
            if ((i + 1) % _profile.pagesBeforeYield == 0) {
              await Future<void>.delayed(const Duration(milliseconds: 12));
            }
          }
          return _SaveOutcome(docId, saved, failed);
        },
      );

      if (outcome == null || !mounted) return;

      if (outcome.saved == 0) {
        ErrorOrchestrator.notify(const AppFailure(
          kind: FailureKind.document,
          message: 'No se ha podido guardar ninguna pagina. Revisa el espacio libre.',
        ));
        return;
      }

      _saved = true;
      unawaited(_session.dispose());

      if (outcome.failed.isNotEmpty) {
        showMessage(
          context,
          'Guardadas ${outcome.saved} paginas. Fallaron: ${outcome.failed.join(', ')}.',
          error: true,
        );
      }
      Log.i(_tag, 'Guardadas ${outcome.saved}/${_shots.length} paginas');
      Navigator.pop(context, outcome.documentId);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_shots.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.image_not_supported_outlined,
          title: 'No hay paginas que editar',
        ),
      );
    }

    return PopScope(
      canPop: _saved,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _busy) return;
        final discard = await confirm(
          context,
          title: 'Descartar el escaneo',
          message: 'Se perderan las ${_shots.length} paginas sin guardar.',
          confirmLabel: 'Descartar',
          destructive: true,
        );
        if (discard && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text('Pagina ${_index + 1} de ${_shots.length}'),
          actions: [
            IconButton(
              tooltip: 'Eliminar pagina',
              onPressed: _busy ? null : _deleteCurrent,
              icon: const Icon(Icons.delete_outline),
            ),
            TextButton(
              onPressed: _busy ? null : _save,
              child: const Text('Guardar',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _shots.length,
                onPageChanged: (i) {
                  setState(() => _index = i);
                  // La pagina visible pasa al principio de la cola.
                  if (_shots[i].preview == null) _enqueue(i, priority: true);
                },
                itemBuilder: (context, i) => _pageBody(_shots[i]),
              ),
            ),
            if (_showAdjustments) _adjustmentPanel(),
            _filterStrip(scheme),
            _toolbar(),
          ],
        ),
      ),
    );
  }

  Widget _pageBody(CapturedShot shot) {
    final preview = shot.preview;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: preview == null
          ? const Center(child: CircularProgressIndicator())
          : InteractiveViewer(
              maxScale: 4,
              child: Center(
                child: Image.memory(
                  preview,
                  gaplessPlayback: true,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white24,
                    size: 48,
                  ),
                ),
              ),
            ),
    );
  }

  Widget _filterStrip(ColorScheme scheme) => Container(
        color: Colors.black,
        height: 58,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          itemCount: ScanFilter.values.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final f = ScanFilter.values[i];
            final selected = _current.filter == f;
            return GestureDetector(
              onLongPress: () => _setFilter(f, applyToAll: true),
              child: ChoiceChip(
                label: Text(f.label),
                selected: selected,
                onSelected: _busy ? null : (_) => _setFilter(f),
                backgroundColor: const Color(0xFF1E222B),
                selectedColor: scheme.primary,
                labelStyle: TextStyle(
                  color: selected ? scheme.onPrimary : Colors.white70,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            );
          },
        ),
      );

  Widget _adjustmentPanel() {
    final adj = _current.adjustments;
    Widget slider(String label, double value, ValueChanged<double> onChanged) => Row(
          children: [
            SizedBox(
              width: 76,
              child: Text(label,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
            Expanded(
              child: Slider(value: value, min: -1, max: 1, onChanged: onChanged),
            ),
          ],
        );

    return Container(
      color: const Color(0xFF15181F),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          slider('Brillo', adj.brightness,
              (v) => _updateAdjustments(adj.copyWith(brightness: v))),
          slider('Contraste', adj.contrast,
              (v) => _updateAdjustments(adj.copyWith(contrast: v))),
          slider('Color', adj.saturation,
              (v) => _updateAdjustments(adj.copyWith(saturation: v))),
        ],
      ),
    );
  }

  Widget _toolbar() => Container(
        color: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SafeArea(
          top: false,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _tool(Icons.crop, 'Recortar', _openCrop),
              _tool(Icons.rotate_left, 'Girar', () => _rotate(3)),
              _tool(Icons.tune, 'Ajustes',
                  () => setState(() => _showAdjustments = !_showAdjustments)),
              _tool(Icons.done_all, 'A todas',
                  () => _setFilter(_current.filter, applyToAll: true)),
            ],
          ),
        ),
      );

  Widget _tool(IconData icon, String label, VoidCallback onTap) => InkWell(
        onTap: _busy ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(height: 3),
              Text(label,
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ],
          ),
        ),
      );
}

class _SaveOutcome {
  final String documentId;
  final int saved;
  final List<int> failed;
  const _SaveOutcome(this.documentId, this.saved, this.failed);
}
