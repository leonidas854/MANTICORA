import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../imaging/filters.dart';
import '../../imaging/ocr_service.dart';
import '../../imaging/pipeline.dart';
import '../../widgets/common.dart';
import '../crop/crop_screen.dart';
import '../scan/scan_session.dart';

/// Revision de las capturas: filtro, recorte, giro y guardado.
class EditScreen extends ConsumerStatefulWidget {
  final List<CapturedShot> shots;

  /// Si se indica, las paginas se anaden a ese documento en vez de crear uno.
  final String? appendToDocumentId;

  const EditScreen({super.key, required this.shots, this.appendToDocumentId});

  @override
  ConsumerState<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends ConsumerState<EditScreen> {
  static const int _previewSide = 900;

  late final PageController _pageController;
  late List<CapturedShot> _shots;
  int _index = 0;
  bool _busy = false;
  bool _showAdjustments = false;
  final Set<int> _rendering = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _shots = List.of(widget.shots);
    final defaultFilter = ref.read(settingsProvider).defaultFilter;
    for (final s in _shots) {
      s.filter = defaultFilter;
    }
    _renderAll();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  CapturedShot get _current => _shots[_index];

  Future<void> _renderAll() async {
    for (var i = 0; i < _shots.length; i++) {
      unawaited(_render(i));
    }
  }

  /// Genera la vista previa reducida de una captura.
  Future<void> _render(int i) async {
    if (i < 0 || i >= _shots.length || _rendering.contains(i)) return;
    _rendering.add(i);
    final shot = _shots[i];
    try {
      final result = await ImagePipeline.processPage(
        sourceJpeg: shot.originalJpeg,
        quad: shot.quad,
        filter: shot.filter,
        adjustments: shot.adjustments,
        rotationQuarterTurns: shot.rotation,
        maxSide: _previewSide,
      );
      if (!mounted) return;
      setState(() {
        shot.preview = result.jpeg;
        shot.previewWidth = result.width;
        shot.previewHeight = result.height;
      });
    } catch (e) {
      if (mounted) showMessage(context, 'Error al procesar: $e', error: true);
    } finally {
      _rendering.remove(i);
    }
  }

  // ------------------------------------------------------------- acciones

  Future<void> _openCrop() async {
    final shot = _current;
    final result = await Navigator.push<CropResult>(
      context,
      MaterialPageRoute(
        builder: (_) => CropScreen(
          imageBytes: shot.originalJpeg,
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
    await _render(_index);
  }

  void _setFilter(ScanFilter filter, {bool applyToAll = false}) {
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
      _renderAll();
    } else {
      _render(_index);
    }
  }

  void _rotate(int turns) {
    setState(() => _current.rotation = (_current.rotation + turns) % 4);
    _render(_index);
  }

  Future<void> _deleteCurrent() async {
    if (_shots.length == 1) {
      if (await confirm(context,
          title: 'Descartar',
          message: 'Es la unica pagina. Se descartara el escaneo.',
          confirmLabel: 'Descartar',
          destructive: true)) {
        if (mounted) Navigator.pop(context);
      }
      return;
    }
    setState(() {
      _shots.removeAt(_index);
      if (_index >= _shots.length) _index = _shots.length - 1;
    });
    _pageController.jumpToPage(_index);
  }

  Timer? _debounce;
  void _updateAdjustments(Adjustments adj) {
    setState(() => _current.adjustments = adj);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 260), () => _render(_index));
  }

  // -------------------------------------------------------------- guardado

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    final repo = ref.read(repositoryProvider);
    final settings = ref.read(settingsProvider);

    try {
      final result = await runWithProgress<String?>(context, 'Procesando paginas...',
          (setMessage) async {
        final docId = widget.appendToDocumentId ??
            (await repo.createDocument()).id;

        for (var i = 0; i < _shots.length; i++) {
          setMessage('Guardando pagina ${i + 1} de ${_shots.length}...');
          final shot = _shots[i];
          final processed = await ImagePipeline.processPage(
            sourceJpeg: shot.originalJpeg,
            quad: shot.quad,
            filter: shot.filter,
            adjustments: shot.adjustments,
            rotationQuarterTurns: shot.rotation,
          );

          final page = await repo.addPage(
            documentId: docId,
            originalJpeg: settings.keepOriginals ? shot.originalJpeg : processed.jpeg,
            processedJpeg: processed.jpeg,
            thumbnailJpeg: processed.thumbnail,
            quad: shot.quad,
            filter: shot.filter,
            adjustments: shot.adjustments,
            rotation: shot.rotation,
            width: processed.width,
            height: processed.height,
          );

          if (settings.autoOcr) {
            setMessage('Reconociendo texto ${i + 1}/${_shots.length}...');
            try {
              final file = await repo.pageFile(page);
              final ocr = await OcrService.instance.recognizeFile(file.path);
              if (!ocr.isEmpty) {
                await repo.setOcrText(page.id, docId, ocr.text,
                    boxesJson: ocr.boxesJson);
              }
            } catch (_) {
              // El OCR es opcional: si falla, el escaneo se guarda igual.
            }
          }
        }
        return docId;
      });

      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (e) {
      if (mounted) showMessage(context, 'No se pudo guardar: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
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
            child: const Text('Guardar', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: _shots.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final shot = _shots[i];
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
                            ),
                          ),
                        ),
                );
              },
            ),
          ),
          if (_showAdjustments) _adjustmentPanel(scheme),
          _filterStrip(scheme),
          _toolbar(),
        ],
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
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final f = ScanFilter.values[i];
            final selected = _current.filter == f;
            return GestureDetector(
              onLongPress: () => _setFilter(f, applyToAll: true),
              child: ChoiceChip(
                label: Text(f.label),
                selected: selected,
                onSelected: (_) => _setFilter(f),
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

  Widget _adjustmentPanel(ColorScheme scheme) {
    final adj = _current.adjustments;
    Widget slider(String label, double value, ValueChanged<double> onChanged) => Row(
          children: [
            SizedBox(
              width: 76,
              child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
            Expanded(
              child: Slider(
                value: value,
                min: -1,
                max: 1,
                onChanged: onChanged,
              ),
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
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ],
          ),
        ),
      );
}
