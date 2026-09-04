import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_orchestrator.dart';
import '../../core/providers.dart';
import '../../core/failure.dart';
import '../../data/models/models.dart';
import '../../imaging/filters.dart';
import '../../imaging/ocr_service.dart';
import '../../imaging/pipeline.dart';
import '../../widgets/common.dart';
import '../crop/crop_screen.dart';

/// Visor a pantalla completa con reedicion de la pagina.
class PageViewerScreen extends ConsumerStatefulWidget {
  final String documentId;
  final int initialIndex;

  const PageViewerScreen({
    super.key,
    required this.documentId,
    this.initialIndex = 0,
  });

  @override
  ConsumerState<PageViewerScreen> createState() => _PageViewerScreenState();
}

class _PageViewerScreenState extends ConsumerState<PageViewerScreen> {
  late final PageController _controller;
  late int _index;
  bool _showChrome = true;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(documentProvider(widget.documentId));

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _showChrome
          ? AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: async.maybeWhen(
                data: (doc) => Text(
                  doc == null ? '' : 'Pagina ${_index + 1} de ${doc.pages.length}',
                ),
                orElse: () => const Text(''),
              ),
            )
          : null,
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('$e', style: const TextStyle(color: Colors.white)),
        ),
        data: (doc) {
          if (doc == null || doc.pages.isEmpty) {
            return const Center(
              child: Text('Sin paginas', style: TextStyle(color: Colors.white70)),
            );
          }
          if (_index >= doc.pages.length) _index = doc.pages.length - 1;

          return Stack(
            children: [
              PageView.builder(
                controller: _controller,
                itemCount: doc.pages.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => GestureDetector(
                  onTap: () => setState(() => _showChrome = !_showChrome),
                  child: FutureBuilder<File>(
                    future: ref.read(repositoryProvider).pageFile(doc.pages[i]),
                    builder: (context, snap) {
                      final f = snap.data;
                      if (f == null || !f.existsSync()) {
                        return const Center(
                          child: Icon(Icons.broken_image_outlined, color: Colors.white24),
                        );
                      }
                      return InteractiveViewer(
                        maxScale: 5,
                        child: Center(child: Image.file(f, fit: BoxFit.contain)),
                      );
                    },
                  ),
                ),
              ),
              if (_showChrome)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _toolbar(doc, doc.pages[_index]),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _toolbar(DocumentWithPages doc, ScanPage page) => Container(
        color: Colors.black87,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _tool(Icons.crop, 'Recortar', () => _recrop(page)),
                _tool(Icons.rotate_right, 'Girar', () => _rotate(page)),
                _tool(Icons.filter_b_and_w, 'Filtro', () => _changeFilter(page)),
                _tool(Icons.text_fields, 'OCR', () => _ocr(doc, page)),
                _tool(Icons.share_outlined, 'Compartir', () => _share(page)),
                _tool(Icons.delete_outline, 'Eliminar', () => _delete(page)),
              ],
            ),
          ),
        ),
      );

  Widget _tool(IconData icon, String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
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

  // ------------------------------------------------------------- acciones

  /// Reprocesa la pagina desde la imagen ORIGINAL, para no acumular perdidas.
  Future<void> _reprocess(
    ScanPage page, {
    ScanFilter? filter,
    int? rotation,
    dynamic quad,
  }) async {
    final repo = ref.read(repositoryProvider);
    final original = await repo.absoluteFile(page.originalFile);
    if (!await original.exists()) {
      if (mounted) {
        showMessage(context, 'No se conserva la imagen original', error: true);
      }
      return;
    }
    if (!mounted) return;
    await runWithProgress<void>(context, 'Aplicando cambios...', (setMessage) async {
      final result = await ImagePipeline.processPage(
        sourceJpeg: await original.readAsBytes(),
        quad: quad ?? page.quad,
        filter: filter ?? page.filter,
        adjustments: page.adjustments,
        rotationQuarterTurns: rotation ?? page.rotation,
      );
      final updated = await repo.replacePageImage(
        page,
        processedJpeg: result.jpeg,
        thumbnailJpeg: result.thumbnail,
        quad: quad ?? page.quad,
        filter: filter ?? page.filter,
        rotation: rotation ?? page.rotation,
        width: result.width,
        height: result.height,
      );

      // El texto reconocido correspondia a la imagen anterior y se ha
      // descartado; si la pagina lo tenia, se rehace para no perder ni la
      // busqueda ni la capa de texto del PDF.
      if (page.hasOcr) {
        setMessage('Rehaciendo el texto reconocido...');
        await ErrorOrchestrator.guard(
          'Rehaciendo el OCR de la pagina',
          () async {
            final file = await repo.pageFile(updated);
            final ocr = await OcrService.instance.recognizeFile(file.path);
            if (!ocr.isEmpty) {
              await repo.setOcrText(updated.id, updated.documentId, ocr.text,
                  boxesJson: ocr.boxesJson);
            }
          },
          tag: 'Pagina',
          notifyUser: false,
        );
      }
    });
  }

  Future<void> _recrop(ScanPage page) async {
    final repo = ref.read(repositoryProvider);
    final original = await repo.absoluteFile(page.originalFile);
    if (!await original.exists() || !mounted) return;
    final bytes = await original.readAsBytes();
    final decoded = await decodeImageFromList(bytes);
    final w = decoded.width, h = decoded.height;
    decoded.dispose();
    if (!mounted) return;

    final result = await Navigator.push<CropResult>(
      context,
      MaterialPageRoute(
        builder: (_) => CropScreen(
          imageBytes: bytes,
          originalWidth: w,
          originalHeight: h,
          initialQuad: page.quad,
          initialRotation: page.rotation,
        ),
      ),
    );
    if (result == null || !mounted) return;
    await _reprocess(page, quad: result.quad, rotation: result.rotation);
  }

  Future<void> _rotate(ScanPage page) =>
      _reprocess(page, rotation: (page.rotation + 1) % 4);

  Future<void> _changeFilter(ScanPage page) async {
    final filter = await showModalBottomSheet<ScanFilter>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in ScanFilter.values)
              ListTile(
                leading: Icon(
                  page.filter == f ? Icons.radio_button_checked : Icons.radio_button_off,
                ),
                title: Text(f.label),
                onTap: () => Navigator.pop(ctx, f),
              ),
          ],
        ),
      ),
    );
    if (filter == null || !mounted) return;
    await _reprocess(page, filter: filter);
  }

  Future<void> _ocr(DocumentWithPages doc, ScanPage page) async {
    final repo = ref.read(repositoryProvider);
    final result = await runWithProgress(context, 'Reconociendo texto...', (_) async {
      final file = await repo.pageFile(page);
      final ocr = await OcrService.instance.recognizeFile(file.path);
      await repo.setOcrText(page.id, doc.document.id, ocr.text,
          boxesJson: ocr.boxesJson);
      return ocr;
    });
    if (result == null || !mounted) return;
    if (result.isEmpty) {
      showMessage(context, 'No se ha encontrado texto en esta pagina');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (ctx, controller) => Column(
          children: [
            AppBar(
              title: const Text('Texto de la pagina'),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  onPressed: () => shareText(ctx, result.text),
                ),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: controller,
                padding: const EdgeInsets.all(16),
                child: SelectableText(result.text),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _share(ScanPage page) async {
    final file = await ErrorOrchestrator.guard<File>(
      'Preparando la pagina',
      () async {
        final file = await ref.read(repositoryProvider).pageFile(page);
        if (!await file.exists()) {
          throw const AppFailure.notFound('La imagen de esta pagina ya no esta.');
        }
        return file;
      },
      tag: 'Pagina',
    );
    if (file == null || !mounted) return;
    await shareFiles(context, [file]);
  }

  Future<void> _delete(ScanPage page) async {
    if (!await confirm(context,
        title: 'Eliminar pagina',
        message: 'Esta accion no se puede deshacer.',
        confirmLabel: 'Eliminar',
        destructive: true)) {
      return;
    }
    await ErrorOrchestrator.guard(
      'Eliminando la pagina',
      () => ref.read(repositoryProvider).deletePage(page),
      tag: 'Pagina',
    );
    if (mounted) setState(() {});
  }
}
