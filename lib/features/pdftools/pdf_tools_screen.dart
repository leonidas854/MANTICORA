import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/error_orchestrator.dart';
import '../../core/failure.dart';
import '../../core/page_ranges.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/repositories/storage_service.dart';
import '../../export/docx_builder.dart';
import '../../export/export_service.dart';
import '../../export/file_saver.dart';
import '../../export/pdf_builder.dart';
import '../../export/pdf_tools.dart';
import '../../imaging/pipeline.dart';
import '../../widgets/common.dart';

/// Caja de herramientas para PDFs ya existentes.
class PdfToolsScreen extends ConsumerStatefulWidget {
  /// Documentos escaneados preseleccionados (para unirlos directamente).
  final List<String> preselectedDocumentIds;

  const PdfToolsScreen({super.key, this.preselectedDocumentIds = const []});

  @override
  ConsumerState<PdfToolsScreen> createState() => _PdfToolsScreenState();
}

class _PdfToolsScreenState extends ConsumerState<PdfToolsScreen> {
  static const String _tag = 'HerramientasPDF';

  @override
  void initState() {
    super.initState();
    if (widget.preselectedDocumentIds.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _mergeScanned());
    }
  }

  @override
  Widget build(BuildContext context) {
    final tools = <_Tool>[
      _Tool(Icons.merge_type, 'Unir PDF', 'Combina varios PDF en uno solo', _merge),
      _Tool(Icons.call_split, 'Dividir PDF', 'Separa en varios ficheros', _split),
      _Tool(Icons.content_cut, 'Extraer paginas', 'Crea un PDF con las paginas que elijas',
          _extract),
      _Tool(Icons.delete_sweep_outlined, 'Eliminar paginas', 'Quita paginas del PDF',
          _deletePages),
      _Tool(Icons.compress, 'Comprimir PDF', 'Reduce el tamano del fichero', _compress),
      _Tool(Icons.rotate_90_degrees_cw, 'Girar paginas', 'Gira todas las paginas',
          _rotate),
      _Tool(Icons.lock_outline, 'Proteger con contrasena', 'Cifrado AES-256', _protect),
      _Tool(Icons.lock_open, 'Quitar contrasena', 'Necesitas conocer la actual',
          _unprotect),
      _Tool(Icons.description_outlined, 'PDF a Word', 'Extrae el texto a un .docx',
          _pdfToWord),
      _Tool(Icons.image_outlined, 'PDF a imagenes', 'Una imagen por pagina', _pdfToImages),
      _Tool(Icons.picture_as_pdf_outlined, 'Imagenes a PDF', 'Crea un PDF desde fotos',
          _imagesToPdf),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Herramientas PDF')),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: tools.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, i) {
          final t = tools[i];
          return ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
              child: Icon(t.icon, color: Theme.of(context).colorScheme.primary),
            ),
            title: Text(t.title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(t.subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: t.action,
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------ utilidades

  /// Selecciona varios PDF.
  Future<List<PlatformFile>> _pickPdfs() async =>
      await ErrorOrchestrator.guard<List<PlatformFile>>(
        'Abriendo el selector de ficheros',
        () => FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['pdf'],
          dialogTitle: 'Selecciona los PDF',
        ),
        tag: _tag,
      ) ??
      const [];

  /// Selecciona un unico PDF.
  Future<PlatformFile?> _pickPdf() => ErrorOrchestrator.guard<PlatformFile?>(
        'Abriendo el selector de ficheros',
        () => FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['pdf'],
          dialogTitle: 'Selecciona un PDF',
        ),
        tag: _tag,
      );

  /// Cuenta las paginas avisando con un mensaje claro si el PDF no sirve.
  Future<int?> _countPages(Uint8List bytes, String? password) =>
      ErrorOrchestrator.guard<int>(
        'Leyendo el PDF',
        () async => PdfTools.pageCount(bytes, password: password),
        tag: _tag,
      );

  Future<Uint8List?> _bytesOf(PlatformFile f) async {
    try {
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Pide la contrasena si el PDF esta cifrado.
  Future<String?> _passwordIfNeeded(Uint8List bytes) async {
    if (!PdfTools.needsPassword(bytes)) return null;
    if (!mounted) return null;
    return promptText(context,
        title: 'PDF protegido',
        label: 'Contrasena',
        confirmLabel: 'Abrir',
        obscure: true);
  }

  Future<void> _deliver(String fileName, Uint8List bytes) async {
    if (bytes.isEmpty) {
      ErrorOrchestrator.notify(const AppFailure(
        kind: FailureKind.pdf,
        message: 'El fichero generado ha salido vacio.',
      ));
      return;
    }
    final file = await ErrorOrchestrator.guard<File>(
      'Guardando el resultado',
      () async {
        final dir = await StorageService.instance.exportsDir;
        final out = File(p.join(dir.path, fileName));
        await out.parent.create(recursive: true);
        await out.writeAsBytes(bytes, flush: true);
        return out;
      },
      tag: _tag,
    );
    if (file == null || !mounted) return;

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
                  Text(fileName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(formatBytes(bytes.length),
                      style: Theme.of(ctx).textTheme.bodySmall),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Compartir'),
              onTap: () async {
                Navigator.pop(ctx);
                if (mounted) await shareFiles(context, [file]);
              },
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('Guardar en el dispositivo'),
              onTap: () async {
                Navigator.pop(ctx);
                final saved = await ErrorOrchestrator.guard<String?>(
                  'Guardando en el dispositivo',
                  () => FileSaver.save(fileName, bytes),
                  tag: _tag,
                );
                if (mounted) {
                  showMessage(context,
                      saved == null ? 'Guardado cancelado' : 'Guardado correctamente');
                }
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- acciones

  /// Une los documentos escaneados que llegaron preseleccionados.
  Future<void> _mergeScanned() async {
    final repo = ref.read(repositoryProvider);
    final settings = ref.read(settingsProvider);

    final bytes = await runWithProgress<Uint8List?>(context, 'Uniendo documentos...',
        (setMessage) async {
      final parts = <Uint8List>[];
      for (var i = 0; i < widget.preselectedDocumentIds.length; i++) {
        setMessage('Documento ${i + 1} de ${widget.preselectedDocumentIds.length}...');
        final doc = await repo.getDocument(widget.preselectedDocumentIds[i]);
        if (doc == null || doc.pages.isEmpty) continue;
        final export = await ExportService.instance.toPdf(
          doc,
          pageSize: settings.pdfPageSize,
          quality: settings.pdfQuality,
          searchableText: settings.searchablePdf,
        );
        parts.add(await export.file.readAsBytes());
      }
      if (parts.isEmpty) return null;
      if (parts.length == 1) return parts.first;
      setMessage('Combinando...');
      return PdfTools.merge(parts);
    });

    if (bytes == null) {
      if (mounted) showMessage(context, 'No hay nada que unir', error: true);
      return;
    }
    await _deliver('documentos-unidos.pdf', bytes);
  }

  Future<void> _merge() async {
    final files = await _pickPdfs();
    if (files.length < 2) {
      if (mounted && files.isNotEmpty) {
        showMessage(context, 'Selecciona al menos dos PDF');
      }
      return;
    }
    if (!mounted) return;

    final bytes = await runWithProgress<Uint8List?>(context, 'Uniendo PDF...',
        (setMessage) async {
      final parts = <Uint8List>[];
      final passwords = <String?>[];
      for (final f in files) {
        final b = await _bytesOf(f);
        if (b == null) continue;
        parts.add(b);
        passwords.add(null);
      }
      setMessage('Combinando ${parts.length} ficheros...');
      return PdfTools.merge(parts, passwords: passwords);
    });

    if (bytes != null) await _deliver('unido.pdf', bytes);
  }

  Future<void> _split() async {
    final file = await _pickPdf();
    if (file == null || !mounted) return;
    final source = await _bytesOf(file);
    if (source == null || !mounted) return;

    final password = await _passwordIfNeeded(source);
    final total = await _countPages(source, password);
    if (total == null || !mounted) return;

    final answer = await promptText(context,
        title: 'Dividir PDF',
        label: 'Paginas por fichero (total: $total)',
        initial: '1',
        confirmLabel: 'Dividir');
    final perChunk = int.tryParse(answer ?? '');
    if (perChunk == null || perChunk < 1 || !mounted) return;

    final parts = await runWithProgress<List<Uint8List>>(context, 'Dividiendo...',
        (_) => PdfTools.splitEvery(source, perChunk, password: password),
        tag: _tag);
    if (parts == null || !mounted) return;

    final base = p.basenameWithoutExtension(file.name);
    for (var i = 0; i < parts.length; i++) {
      await _deliver('$base-parte${i + 1}.pdf', parts[i]);
      if (!mounted) return;
    }
  }

  Future<void> _extract() => _pageSubsetOperation(
        title: 'Extraer paginas',
        label: 'Paginas a extraer (ej. 1-3,5)',
        suffix: 'extraido',
        run: (bytes, indices, password) =>
            PdfTools.extractPages(bytes, indices, password: password),
      );

  Future<void> _deletePages() => _pageSubsetOperation(
        title: 'Eliminar paginas',
        label: 'Paginas a eliminar (ej. 2,4-6)',
        suffix: 'sin-paginas',
        run: (bytes, indices, password) =>
            PdfTools.deletePages(bytes, indices.toSet(), password: password),
      );

  Future<void> _pageSubsetOperation({
    required String title,
    required String label,
    required String suffix,
    required Future<Uint8List> Function(Uint8List, List<int>, String?) run,
  }) async {
    final file = await _pickPdf();
    if (file == null || !mounted) return;
    final source = await _bytesOf(file);
    if (source == null || !mounted) return;

    final password = await _passwordIfNeeded(source);
    final total = await _countPages(source, password);
    if (total == null || !mounted) return;

    final answer = await promptText(context,
        title: title, label: '$label · $total paginas', confirmLabel: 'Aplicar');
    if (answer == null || !mounted) return;

    final indices = parsePageRanges(answer, total);
    if (indices == null) {
      showMessage(context, 'Rango no valido', error: true);
      return;
    }

    final result = await runWithProgress<Uint8List>(
        context, 'Procesando...', (_) => run(source, indices, password),
        tag: _tag);
    if (result == null || !mounted) return;
    await _deliver('${p.basenameWithoutExtension(file.name)}-$suffix.pdf', result);
  }

  Future<void> _compress() async {
    final file = await _pickPdf();
    if (file == null || !mounted) return;
    final source = await _bytesOf(file);
    if (source == null || !mounted) return;

    final level = await showModalBottomSheet<PdfQuality>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Nivel de compresion',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            for (final q in PdfQuality.values)
              ListTile(
                leading: const Icon(Icons.compress),
                title: Text(q.label),
                onTap: () => Navigator.pop(ctx, q),
              ),
          ],
        ),
      ),
    );
    if (level == null || !mounted) return;

    final dpi = switch (level) {
      PdfQuality.high => 200.0,
      PdfQuality.medium => 140.0,
      PdfQuality.low => 100.0,
    };

    final result = await runWithProgress<Uint8List>(context, 'Comprimiendo...',
        (setMessage) => PdfTools.compress(
              source,
              dpi: dpi,
              jpegQuality: level.jpegQuality,
              onPage: (done) => setMessage('Pagina $done...'),
            ));
    if (result == null || !mounted) return;

    final saved = source.length - result.length;
    await _deliver(
      '${p.basenameWithoutExtension(file.name)}-comprimido.pdf',
      result,
    );
    if (mounted && saved > 0) {
      showMessage(context, 'Reducido ${formatBytes(saved)}');
    }
  }

  Future<void> _rotate() async {
    final file = await _pickPdf();
    if (file == null || !mounted) return;
    final source = await _bytesOf(file);
    if (source == null || !mounted) return;
    final password = await _passwordIfNeeded(source);
    if (!mounted) return;

    final turns = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const [
              (1, '90 grados a la derecha'),
              (2, '180 grados'),
              (3, '90 grados a la izquierda'),
            ])
              ListTile(
                leading: const Icon(Icons.rotate_right),
                title: Text(entry.$2),
                onTap: () => Navigator.pop(ctx, entry.$1),
              ),
          ],
        ),
      ),
    );
    if (turns == null || !mounted) return;

    final result = await runWithProgress<Uint8List>(context, 'Girando paginas...',
        (_) => PdfTools.rotatePages(source, const {}, turns, password: password),
        tag: _tag);
    if (result == null || !mounted) return;
    await _deliver('${p.basenameWithoutExtension(file.name)}-girado.pdf', result);
  }

  Future<void> _protect() async {
    final file = await _pickPdf();
    if (file == null || !mounted) return;
    final source = await _bytesOf(file);
    if (source == null || !mounted) return;
    final current = await _passwordIfNeeded(source);
    if (!mounted) return;

    final password = await promptText(context,
        title: 'Proteger PDF',
        label: 'Contrasena nueva',
        confirmLabel: 'Proteger',
        obscure: true);
    if (password == null || !mounted) return;

    final result = await runWithProgress<Uint8List>(
        context,
        'Cifrando...',
        (_) => PdfTools.protect(source,
            userPassword: password, currentPassword: current));
    if (result == null || !mounted) return;
    await _deliver(
        '${p.basenameWithoutExtension(file.name)}-protegido.pdf', result);
  }

  Future<void> _unprotect() async {
    final file = await _pickPdf();
    if (file == null || !mounted) return;
    final source = await _bytesOf(file);
    if (source == null || !mounted) return;

    final password = await promptText(context,
        title: 'Quitar contrasena',
        label: 'Contrasena actual',
        confirmLabel: 'Quitar',
        obscure: true);
    if (password == null || !mounted) return;

    final result = await runWithProgress<Uint8List>(
      context,
      'Descifrando...',
      (_) => PdfTools.removeProtection(source, password),
      tag: _tag,
    );
    if (result == null || !mounted) return;
    await _deliver('${p.basenameWithoutExtension(file.name)}-sin-clave.pdf', result);
  }

  Future<void> _pdfToWord() async {
    final file = await _pickPdf();
    if (file == null || !mounted) return;
    final source = await _bytesOf(file);
    if (source == null || !mounted) return;
    final password = await _passwordIfNeeded(source);
    if (!mounted) return;

    final result = await runWithProgress<Uint8List>(context, 'Extrayendo texto...',
        (setMessage) async {
      final texts = PdfTools.extractText(source, password: password)
          .map(PdfTools.normalizeExtractedText)
          .toList();
      setMessage('Creando documento Word...');
      return DocxBuilder.build(
        pages: [for (final t in texts) DocxPageInput(text: t)],
        title: p.basenameWithoutExtension(file.name),
        mode: DocxMode.textOnly,
      );
    });
    if (result == null || !mounted) return;

    await _deliver('${p.basenameWithoutExtension(file.name)}.docx', result);
  }

  Future<void> _pdfToImages() async {
    final file = await _pickPdf();
    if (file == null || !mounted) return;
    final source = await _bytesOf(file);
    if (source == null || !mounted) return;

    final rasters = await runWithProgress<List<RasterPage>>(
        context,
        'Convirtiendo paginas...',
        (setMessage) => PdfTools.rasterize(source,
            dpi: 200, onPage: (done) => setMessage('Pagina $done...')));
    if (rasters == null || rasters.isEmpty || !mounted) return;

    final dir = await StorageService.instance.exportsDir;
    final base = p.basenameWithoutExtension(file.name);
    final out = <File>[];
    for (var i = 0; i < rasters.length; i++) {
      final f = File(p.join(dir.path, '$base-${'${i + 1}'.padLeft(3, '0')}.jpg'));
      await f.writeAsBytes(rasters[i].jpeg, flush: true);
      out.add(f);
    }
    if (!mounted) return;
    await shareFiles(context, out, subject: base, bundleName: '$base.zip');
  }

  Future<void> _imagesToPdf() async {
    final files = await FilePicker.pickFiles(
      type: FileType.image,
      dialogTitle: 'Selecciona las imagenes',
    );
    if (files.isEmpty || !mounted) return;

    final bytes = await runWithProgress<Uint8List>(context, 'Creando PDF...',
        (setMessage) async {
      final inputs = <PdfPageInput>[];
      for (var i = 0; i < files.length; i++) {
        setMessage('Imagen ${i + 1} de ${files.length}...');
        final raw = await _bytesOf(files[i]);
        if (raw == null) continue;
        final normalized = await ImagePipeline.normalizeWithSize(raw);
        if (normalized == null) continue;
        inputs.add(PdfPageInput(
          jpeg: normalized.jpeg,
          imageWidth: normalized.width,
          imageHeight: normalized.height,
        ));
      }
      return PdfBuilder.build(
        pages: inputs,
        title: 'Imagenes',
        pageSize: PdfPageSize.a4,
        searchableText: false,
      );
    });
    if (bytes == null || !mounted) return;
    await _deliver('imagenes.pdf', bytes);
  }
}

class _Tool {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback action;
  const _Tool(this.icon, this.title, this.subtitle, this.action);
}
