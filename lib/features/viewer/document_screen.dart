import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/models/models.dart';
import '../../export/docx_builder.dart';
import '../../export/export_service.dart';
import '../../export/pdf_builder.dart';
import '../../imaging/ocr_service.dart';
import '../../widgets/common.dart';
import '../home/scan_flow.dart';
import 'page_viewer.dart';

class DocumentScreen extends ConsumerStatefulWidget {
  final String documentId;
  const DocumentScreen({super.key, required this.documentId});

  @override
  ConsumerState<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends ConsumerState<DocumentScreen> {
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(documentProvider(widget.documentId));

    return async.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: EmptyState(icon: Icons.error_outline, title: 'Error', subtitle: '$e'),
      ),
      data: (doc) {
        if (doc == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.description_outlined,
              title: 'El documento ya no existe',
            ),
          );
        }
        return _build(doc);
      },
    );
  }

  Widget _build(DocumentWithPages doc) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: () => _rename(doc),
          child: Text(doc.document.title, overflow: TextOverflow.ellipsis),
        ),
        actions: [
          if (_selecting)
            IconButton(
              tooltip: 'Eliminar paginas',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteSelectedPages(doc),
            )
          else ...[
            IconButton(
              tooltip: doc.document.favorite ? 'Quitar de favoritos' : 'Favorito',
              icon: Icon(doc.document.favorite ? Icons.star : Icons.star_border),
              onPressed: () => ref
                  .read(repositoryProvider)
                  .setFavorite(doc.document.id, !doc.document.favorite),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => _onMenu(v, doc),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'rename', child: Text('Renombrar')),
                PopupMenuItem(value: 'reorder', child: Text('Reordenar paginas')),
                PopupMenuItem(value: 'ocr', child: Text('Reconocer texto (OCR)')),
                PopupMenuItem(value: 'text', child: Text('Ver texto reconocido')),
                PopupMenuItem(value: 'print', child: Text('Imprimir')),
                PopupMenuItem(value: 'images', child: Text('Exportar imagenes')),
                PopupMenuItem(value: 'delete', child: Text('Mover a la papelera')),
              ],
            ),
          ],
        ],
      ),
      body: doc.pages.isEmpty
          ? EmptyState(
              icon: Icons.add_a_photo_outlined,
              title: 'Documento vacio',
              action: FilledButton.icon(
                onPressed: () => startScan(context, ref,
                    appendToDocumentId: widget.documentId),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Anadir paginas'),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 170,
                childAspectRatio: 0.7,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: doc.pages.length + 1,
              itemBuilder: (context, i) {
                if (i == doc.pages.length) return _addCard();
                return _pageCard(doc, i);
              },
            ),
      bottomNavigationBar: doc.pages.isEmpty ? null : _bottomBar(doc),
    );
  }

  Widget _addCard() => Card(
        child: InkWell(
          onTap: () => _addPages(),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_circle_outline, size: 32),
              SizedBox(height: 8),
              Text('Anadir', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );

  Widget _pageCard(DocumentWithPages doc, int index) {
    final page = doc.pages[index];
    final selected = _selected.contains(page.id);
    final scheme = Theme.of(context).colorScheme;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected ? BorderSide(color: scheme.primary, width: 2) : BorderSide.none,
      ),
      child: InkWell(
        onTap: () {
          if (_selecting) {
            setState(() {
              if (!_selected.remove(page.id)) _selected.add(page.id);
            });
          } else {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PageViewerScreen(
                  documentId: doc.document.id,
                  initialIndex: index,
                ),
              ),
            );
          }
        },
        onLongPress: () => setState(() => _selected.add(page.id)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<File>(
              future: ref.read(repositoryProvider).thumbFile(page),
              builder: (context, snap) {
                final f = snap.data;
                if (f == null || !f.existsSync()) {
                  return const ColoredBox(color: Color(0x11000000));
                }
                return Image.file(f, fit: BoxFit.cover, cacheWidth: 340);
              },
            ),
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
            if (page.hasOcr)
              const Positioned(
                right: 6,
                bottom: 6,
                child: Icon(Icons.text_snippet, size: 16, color: Colors.white70),
              ),
            if (_selecting)
              Positioned(
                top: 6,
                right: 6,
                child: Icon(
                  selected ? Icons.check_circle : Icons.circle_outlined,
                  color: selected ? scheme.primary : Colors.white70,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(DocumentWithPages doc) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _barButton(Icons.picture_as_pdf_outlined, 'PDF', () => _exportPdf(doc)),
              _barButton(Icons.description_outlined, 'Word', () => _exportDocx(doc)),
              _barButton(Icons.text_fields, 'OCR', () => _runOcr(doc)),
              _barButton(Icons.share_outlined, 'Compartir', () => _sharePdf(doc)),
            ],
          ),
        ),
      );

  Widget _barButton(IconData icon, String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon),
              const SizedBox(height: 3),
              Text(label, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      );

  // ------------------------------------------------------------- acciones

  Future<void> _addPages() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Camara'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galeria'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'camera') {
      await startScan(context, ref, appendToDocumentId: widget.documentId);
    } else {
      await importImages(context, ref, appendToDocumentId: widget.documentId);
    }
  }

  Future<void> _rename(DocumentWithPages doc) async {
    final name = await promptText(context,
        title: 'Renombrar', initial: doc.document.title, label: 'Titulo');
    if (name != null) {
      await ref.read(repositoryProvider).renameDocument(doc.document.id, name);
    }
  }

  Future<void> _onMenu(String value, DocumentWithPages doc) async {
    switch (value) {
      case 'rename':
        await _rename(doc);
      case 'reorder':
        await _reorder(doc);
      case 'ocr':
        await _runOcr(doc);
      case 'text':
        await _showText(doc);
      case 'print':
        await _print(doc);
      case 'images':
        await _exportImages(doc);
      case 'delete':
        if (await confirm(context,
            title: 'Mover a la papelera',
            message: 'Podras recuperarlo mas tarde.',
            confirmLabel: 'Mover',
            destructive: true)) {
          await ref.read(repositoryProvider).moveToTrash(doc.document.id);
          if (mounted) Navigator.pop(context);
        }
    }
  }

  Future<void> _deleteSelectedPages(DocumentWithPages doc) async {
    if (!await confirm(context,
        title: 'Eliminar paginas',
        message: 'Se eliminaran ${_selected.length} paginas.',
        confirmLabel: 'Eliminar',
        destructive: true)) {
      return;
    }
    final repo = ref.read(repositoryProvider);
    for (final page in doc.pages.where((p) => _selected.contains(p.id))) {
      await repo.deletePage(page);
    }
    setState(_selected.clear);
  }

  Future<void> _reorder(DocumentWithPages doc) async {
    final pages = List<ScanPage>.of(doc.pages);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (ctx, controller) => StatefulBuilder(
          builder: (ctx, setSheetState) => Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Arrastra para reordenar',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  scrollController: controller,
                  itemCount: pages.length,
                  onReorder: (oldIndex, newIndex) {
                    setSheetState(() {
                      if (newIndex > oldIndex) newIndex--;
                      pages.insert(newIndex, pages.removeAt(oldIndex));
                    });
                  },
                  itemBuilder: (context, i) => ListTile(
                    key: ValueKey(pages[i].id),
                    leading: FutureBuilder<File>(
                      future: ref.read(repositoryProvider).thumbFile(pages[i]),
                      builder: (context, snap) {
                        final f = snap.data;
                        return SizedBox(
                          width: 40,
                          height: 52,
                          child: (f != null && f.existsSync())
                              ? Image.file(f, fit: BoxFit.cover, cacheWidth: 120)
                              : const ColoredBox(color: Color(0x11000000)),
                        );
                      },
                    ),
                    title: Text('Pagina ${i + 1}'),
                    trailing: const Icon(Icons.drag_handle),
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton(
                    onPressed: () async {
                      await ref.read(repositoryProvider).reorderPages(
                            doc.document.id,
                            pages.map((p) => p.id).toList(),
                          );
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Guardar orden'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runOcr(DocumentWithPages doc) async {
    final repo = ref.read(repositoryProvider);
    await runWithProgress<void>(context, 'Reconociendo texto...', (setMessage) async {
      for (var i = 0; i < doc.pages.length; i++) {
        setMessage('Pagina ${i + 1} de ${doc.pages.length}...');
        final page = doc.pages[i];
        final file = await repo.pageFile(page);
        if (!await file.exists()) continue;
        try {
          final result = await OcrService.instance.recognizeFile(file.path);
          await repo.setOcrText(page.id, doc.document.id, result.text,
              boxesJson: result.boxesJson);
        } catch (e) {
          if (mounted) showMessage(context, 'OCR fallido en la pagina ${i + 1}');
        }
      }
    });
    if (mounted) showMessage(context, 'Texto reconocido');
  }

  Future<void> _showText(DocumentWithPages doc) async {
    final text = doc.combinedText;
    if (text.trim().isEmpty) {
      showMessage(context, 'Aun no hay texto. Ejecuta primero el OCR.');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (ctx, controller) => Column(
          children: [
            AppBar(
              title: const Text('Texto reconocido'),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  icon: const Icon(Icons.download_outlined),
                  onPressed: () async {
                    final r = await ExportService.instance.toText(doc);
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) await _offerShare(r.file, 'Texto guardado');
                  },
                ),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: controller,
                padding: const EdgeInsets.all(16),
                child: SelectableText(text),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportPdf(DocumentWithPages doc) async {
    final settings = ref.read(settingsProvider);
    final options = await showModalBottomSheet<_PdfOptions>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _PdfOptionsSheet(
        initialSize: settings.pdfPageSize,
        initialQuality: settings.pdfQuality,
        initialSearchable: settings.searchablePdf,
      ),
    );
    if (options == null || !mounted) return;

    final result = await runWithProgress<File?>(context, 'Creando PDF...',
        (setMessage) async {
      var export = await ExportService.instance.toPdf(
        doc,
        pageSize: options.size,
        quality: options.quality,
        searchableText: options.searchable,
        watermark: options.watermark,
        onProgress: (done, total) => setMessage('Pagina $done de $total...'),
      );
      if (options.password != null && options.password!.isNotEmpty) {
        setMessage('Aplicando contrasena...');
        final protectedBytes = await _protect(
            await export.file.readAsBytes(), options.password!);
        await export.file.writeAsBytes(protectedBytes, flush: true);
      }
      return export.file;
    });

    if (result != null && mounted) {
      await _offerShare(result, 'PDF creado');
    }
  }

  Future<List<int>> _protect(List<int> bytes, String password) async {
    // Import diferido para no cargar Syncfusion si no se usa.
    final tools = await _pdfTools();
    return tools(bytes, password);
  }

  Future<Future<List<int>> Function(List<int>, String)> _pdfTools() async {
    return (bytes, password) async {
      final result = await PdfProtectHelper.protect(bytes, password);
      return result;
    };
  }

  Future<void> _exportDocx(DocumentWithPages doc) async {
    final mode = await showModalBottomSheet<DocxMode>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Exportar a Word',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            for (final m in DocxMode.values)
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(m.label),
                onTap: () => Navigator.pop(ctx, m),
              ),
          ],
        ),
      ),
    );
    if (mode == null || !mounted) return;

    if (mode != DocxMode.imagesOnly && doc.combinedText.trim().isEmpty) {
      final run = await confirm(
        context,
        title: 'Sin texto reconocido',
        message: 'Para incluir texto hay que ejecutar el OCR. Hacerlo ahora?',
        confirmLabel: 'Ejecutar OCR',
      );
      if (run) {
        await _runOcr(doc);
        final refreshed =
            await ref.read(repositoryProvider).getDocument(doc.document.id);
        if (refreshed != null) doc = refreshed;
      }
    }

    final target = doc;
    final result = await runWithProgress<File?>(context, 'Creando documento Word...',
        (setMessage) async {
      final export = await ExportService.instance.toDocx(target, mode: mode);
      return export.file;
    });
    if (result != null && mounted) await _offerShare(result, 'Documento Word creado');
  }

  Future<void> _exportImages(DocumentWithPages doc) async {
    final files = await runWithProgress<List<File>>(
      context,
      'Exportando imagenes...',
      (_) => ExportService.instance.toImages(doc),
    );
    if (files == null || files.isEmpty || !mounted) return;
    await SharePlus.instance.share(
      ShareParams(
        files: files.map((f) => XFile(f.path)).toList(),
        subject: doc.document.title,
      ),
    );
  }

  Future<void> _sharePdf(DocumentWithPages doc) async {
    final settings = ref.read(settingsProvider);
    final result = await runWithProgress<File?>(context, 'Preparando PDF...',
        (setMessage) async {
      final export = await ExportService.instance.toPdf(
        doc,
        pageSize: settings.pdfPageSize,
        quality: settings.pdfQuality,
        searchableText: settings.searchablePdf,
        onProgress: (done, total) => setMessage('Pagina $done de $total...'),
      );
      return export.file;
    });
    if (result == null || !mounted) return;
    await SharePlus.instance.share(
      ShareParams(files: [XFile(result.path)], subject: doc.document.title),
    );
  }

  Future<void> _print(DocumentWithPages doc) async {
    final settings = ref.read(settingsProvider);
    final bytes = await runWithProgress(context, 'Preparando impresion...',
        (_) => ExportService.instance.pdfBytes(
              doc,
              pageSize: settings.pdfPageSize,
              quality: settings.pdfQuality,
            ));
    if (bytes == null || !mounted) return;
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  Future<void> _offerShare(File file, String title) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                    '${file.path.split('/').last} · ${formatBytes(file.lengthSync())}',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Compartir'),
              onTap: () {
                Navigator.pop(ctx);
                SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Guardar en el dispositivo'),
              onTap: () async {
                Navigator.pop(ctx);
                await _saveToDownloads(file);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _saveToDownloads(File file) async {
    try {
      final name = file.path.split('/').last;
      final bytes = await file.readAsBytes();
      final saved = await FileSaver.save(name, bytes);
      if (mounted) {
        showMessage(context, saved == null ? 'Guardado cancelado' : 'Guardado en $saved');
      }
    } catch (e) {
      if (mounted) showMessage(context, 'No se pudo guardar: $e', error: true);
    }
  }
}

/// Opciones elegidas en la hoja de exportacion a PDF.
class _PdfOptions {
  final PdfPageSize size;
  final PdfQuality quality;
  final bool searchable;
  final String? watermark;
  final String? password;

  const _PdfOptions({
    required this.size,
    required this.quality,
    required this.searchable,
    this.watermark,
    this.password,
  });
}

class _PdfOptionsSheet extends StatefulWidget {
  final PdfPageSize initialSize;
  final PdfQuality initialQuality;
  final bool initialSearchable;

  const _PdfOptionsSheet({
    required this.initialSize,
    required this.initialQuality,
    required this.initialSearchable,
  });

  @override
  State<_PdfOptionsSheet> createState() => _PdfOptionsSheetState();
}

class _PdfOptionsSheetState extends State<_PdfOptionsSheet> {
  late PdfPageSize _size = widget.initialSize;
  late PdfQuality _quality = widget.initialQuality;
  late bool _searchable = widget.initialSearchable;
  final _watermark = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _watermark.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Opciones del PDF',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
              const SizedBox(height: 16),
              const Text('Tamano de pagina'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final s in PdfPageSize.values)
                    ChoiceChip(
                      label: Text(s.label),
                      selected: _size == s,
                      onSelected: (_) => setState(() => _size = s),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Calidad'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final q in PdfQuality.values)
                    ChoiceChip(
                      label: Text(q.label),
                      selected: _quality == q,
                      onSelected: (_) => setState(() => _quality = q),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _searchable,
                onChanged: (v) => setState(() => _searchable = v),
                title: const Text('Texto buscable'),
                subtitle: const Text('Anade la capa de texto del OCR'),
              ),
              TextField(
                controller: _watermark,
                decoration: const InputDecoration(
                  labelText: 'Marca de agua (opcional)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Contrasena (opcional)',
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    _PdfOptions(
                      size: _size,
                      quality: _quality,
                      searchable: _searchable,
                      watermark: _watermark.text.trim().isEmpty
                          ? null
                          : _watermark.text.trim(),
                      password:
                          _password.text.trim().isEmpty ? null : _password.text.trim(),
                    ),
                  ),
                  child: const Text('Crear PDF'),
                ),
              ),
            ],
          ),
        ),
      );
}
