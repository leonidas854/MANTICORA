import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/device_profile.dart';
import '../../core/error_orchestrator.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/models/models.dart';
import '../../widgets/common.dart';
import '../pdftools/pdf_tools_screen.dart';
import '../settings/settings_screen.dart';
import '../viewer/document_screen.dart';
import 'scan_flow.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _searchController = TextEditingController();
  bool _searching = false;
  final Set<String> _selection = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _selecting => _selection.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(libraryQueryProvider);
    final docs = ref.watch(documentsProvider);
    final folders = ref.watch(foldersProvider);
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: _selecting ? _selectionBar() : _normalBar(query),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(repositoryTickProvider),
        child: CustomScrollView(
          slivers: [
            if (query.folderId != null) _breadcrumb(query) else const SliverToBoxAdapter(child: SizedBox.shrink()),
            folders.when(
              data: (list) => list.isEmpty
                  ? const SliverToBoxAdapter(child: SizedBox.shrink())
                  : SliverToBoxAdapter(child: _folderRow(list)),
              loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
              error: (_, _) =>
                  const SliverToBoxAdapter(child: SizedBox.shrink()),
            ),
            docs.when(
              loading: () => const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => SliverFillRemaining(
                child: EmptyState(
                  icon: Icons.error_outline,
                  title: 'Error al cargar',
                  subtitle: '$e',
                ),
              ),
              data: (list) {
                if (list.isEmpty) {
                  return SliverFillRemaining(child: _empty(query));
                }
                return settings.gridView ? _grid(list) : _list(list);
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
      floatingActionButton: _selecting ? null : _fab(),
    );
  }

  // ------------------------------------------------------------ barras

  PreferredSizeWidget _normalBar(LibraryQuery query) => AppBar(
    title: _searching
        ? TextField(
            controller: _searchController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Buscar por titulo o texto reconocido',
              border: InputBorder.none,
              filled: false,
            ),
            onChanged: (v) => ref
                .read(libraryQueryProvider.notifier)
                .update((s) => s.copyWith(search: v)),
          )
        : Text(query.trash ? 'Papelera' : 'Manticora'),
    actions: [
      IconButton(
        icon: Icon(_searching ? Icons.close : Icons.search),
        onPressed: () {
          setState(() => _searching = !_searching);
          if (!_searching) {
            _searchController.clear();
            ref
                .read(libraryQueryProvider.notifier)
                .update((s) => s.copyWith(search: ''));
          }
        },
      ),
      IconButton(
        tooltip: 'Vista',
        icon: Icon(
          ref.watch(settingsProvider).gridView
              ? Icons.view_list_outlined
              : Icons.grid_view_outlined,
        ),
        onPressed: () => ref
            .read(settingsProvider.notifier)
            .update((s) => s.copyWith(gridView: !s.gridView)),
      ),
      PopupMenuButton<String>(
        onSelected: _onMenu,
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'pdftools',
            child: ListTile(
              leading: Icon(Icons.picture_as_pdf_outlined),
              title: Text('Herramientas PDF'),
            ),
          ),
          const PopupMenuItem(
            value: 'folder',
            child: ListTile(
              leading: Icon(Icons.create_new_folder_outlined),
              title: Text('Nueva carpeta'),
            ),
          ),
          PopupMenuItem(
            value: 'trash',
            child: ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(query.trash ? 'Salir de la papelera' : 'Papelera'),
            ),
          ),
          const PopupMenuItem(
            value: 'settings',
            child: ListTile(
              leading: Icon(Icons.settings_outlined),
              title: Text('Ajustes'),
            ),
          ),
        ],
      ),
    ],
  );

  PreferredSizeWidget _selectionBar() => AppBar(
    leading: IconButton(
      icon: const Icon(Icons.close),
      onPressed: () => setState(_selection.clear),
    ),
    title: Text('${_selection.length} seleccionados'),
    actions: [
      IconButton(
        tooltip: 'Unir en un PDF',
        icon: const Icon(Icons.merge_type),
        onPressed: _mergeSelection,
      ),
      IconButton(
        tooltip: 'Mover a carpeta',
        icon: const Icon(Icons.drive_file_move_outline),
        onPressed: _moveSelection,
      ),
      IconButton(
        tooltip: 'Eliminar',
        icon: const Icon(Icons.delete_outline),
        onPressed: _deleteSelection,
      ),
    ],
  );

  // ----------------------------------------------------------- contenido

  Widget _empty(LibraryQuery query) {
    if (query.trash) {
      return const EmptyState(
        icon: Icons.delete_outline,
        title: 'La papelera esta vacia',
        subtitle: 'Lo que borres aparecera aqui y podras recuperarlo '
            'manteniendolo pulsado.',
      );
    }
    if (query.search.isNotEmpty) {
      return const EmptyState(
        icon: Icons.search_off,
        title: 'Sin resultados',
        subtitle: 'Prueba con otras palabras. Se busca tambien dentro del texto reconocido.',
      );
    }
    return EmptyState(
      icon: Icons.document_scanner_outlined,
      title: 'Aun no hay documentos',
      subtitle:
          'Pulsa el boton de la camara para escanear tu primer documento.',
      action: FilledButton.icon(
        onPressed: () => startScan(context, ref),
        icon: const Icon(Icons.camera_alt_outlined),
        label: const Text('Escanear'),
      ),
    );
  }

  Widget _breadcrumb(LibraryQuery query) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => ref
                .read(libraryQueryProvider.notifier)
                .update((s) => s.copyWith(clearFolder: true)),
          ),
          const Text('Carpeta', style: TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    ),
  );

  Widget _folderRow(List<Folder> folders) => SizedBox(
    height: 96,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: folders.length,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (context, i) {
        final f = folders[i];
        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => ref
              .read(libraryQueryProvider.notifier)
              .update((s) => s.copyWith(folderId: f.id)),
          onLongPress: () => _folderMenu(f),
          child: Container(
            width: 118,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(
                  Icons.folder,
                  color: Theme.of(context).colorScheme.primary,
                ),
                Text(
                  f.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  Widget _grid(List<ScanDocument> docs) => SliverPadding(
    padding: const EdgeInsets.all(12),
    sliver: SliverGrid(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        childAspectRatio: 0.68,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, i) => _DocumentCard(
          document: docs[i],
          selected: _selection.contains(docs[i].id),
          selecting: _selecting,
          onTap: () => _openOrSelect(docs[i]),
          onLongPress: () => setState(() => _selection.add(docs[i].id)),
        ),
        childCount: docs.length,
      ),
    ),
  );

  Widget _list(List<ScanDocument> docs) => SliverList.separated(
    itemCount: docs.length,
    separatorBuilder: (_, _) => const Divider(height: 1, indent: 84),
    itemBuilder: (context, i) {
      final d = docs[i];
      return ListTile(
        selected: _selection.contains(d.id),
        leading: _Thumb(path: d.coverThumb, width: 46, height: 60),
        title: Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${d.pageCount} pag. · ${DateFormat('d MMM y', 'es').format(d.updatedAt)}',
        ),
        trailing: d.favorite ? const Icon(Icons.star, size: 18) : null,
        onTap: () => _openOrSelect(d),
        onLongPress: () => setState(() => _selection.add(d.id)),
      );
    },
  );

  Widget _fab() => FloatingActionButton.extended(
    onPressed: () => startScan(context, ref),
    icon: const Icon(Icons.camera_alt_outlined),
    label: const Text('Escanear'),
  );

  // ------------------------------------------------------------ acciones

  void _openOrSelect(ScanDocument doc) {
    if (_selecting) {
      setState(() {
        if (!_selection.remove(doc.id)) _selection.add(doc.id);
      });
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DocumentScreen(documentId: doc.id)),
    );
  }

  Future<void> _onMenu(String value) async {
    switch (value) {
      case 'pdftools':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PdfToolsScreen()),
        );
      case 'folder':
        final name = await promptText(
          context,
          title: 'Nueva carpeta',
          label: 'Nombre',
          confirmLabel: 'Crear',
        );
        if (name != null) {
          await ref
              .read(repositoryProvider)
              .createFolder(
                name,
                parentId: ref.read(libraryQueryProvider).folderId,
              );
        }
      case 'trash':
        ref
            .read(libraryQueryProvider.notifier)
            .update((s) => LibraryQuery(trash: !s.trash));
      case 'settings':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        );
    }
  }

  Future<void> _folderMenu(Folder folder) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Renombrar'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Eliminar carpeta'),
              subtitle: const Text('Los documentos se conservan'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    final repo = ref.read(repositoryProvider);
    if (action == 'rename') {
      final name = await promptText(
        context,
        title: 'Renombrar carpeta',
        initial: folder.name,
      );
      if (name != null) await repo.renameFolder(folder.id, name);
    } else if (action == 'delete') {
      await repo.deleteFolder(folder.id);
    }
  }

  Future<void> _deleteSelection() async {
    final query = ref.read(libraryQueryProvider);
    final repo = ref.read(repositoryProvider);
    final permanent = query.trash;
    if (!await confirm(
      context,
      title: permanent ? 'Eliminar definitivamente' : 'Mover a la papelera',
      message: permanent
          ? 'Se borraran ${_selection.length} documentos y sus imagenes. No se puede deshacer.'
          : 'Podras recuperarlos desde la papelera.',
      confirmLabel: 'Eliminar',
      destructive: true,
    )) {
      return;
    }
    final ids = _selection.toList();
    var done = 0;
    for (final id in ids) {
      final ok = await ErrorOrchestrator.guard<bool>(
        permanent ? 'Eliminando definitivamente' : 'Moviendo a la papelera',
        () async {
          permanent ? await repo.purge(id) : await repo.moveToTrash(id);
          return true;
        },
        tag: 'Inicio',
        notifyUser: false,
      );
      if (ok == true) done++;
    }
    if (!mounted) return;
    setState(_selection.clear);
    if (done < ids.length) {
      showMessage(context, 'Se procesaron $done de ${ids.length} documentos.',
          error: true);
    }
  }

  Future<void> _moveSelection() async {
    final repo = ref.read(repositoryProvider);
    final folders = await repo.listFolders(rootOnly: false);
    if (!mounted) return;
    final target = await showModalBottomSheet<String?>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Raiz (sin carpeta)'),
              onTap: () => Navigator.pop(ctx, ''),
            ),
            for (final f in folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(f.name),
                onTap: () => Navigator.pop(ctx, f.id),
              ),
          ],
        ),
      ),
    );
    if (target == null) return;
    for (final id in _selection.toList()) {
      await ErrorOrchestrator.guard(
        'Moviendo el documento',
        () => repo.setFolder(id, target.isEmpty ? null : target),
        tag: 'Inicio',
        notifyUser: false,
      );
    }
    if (mounted) setState(_selection.clear);
  }

  Future<void> _mergeSelection() async {
    final ids = _selection.toList();
    setState(_selection.clear);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PdfToolsScreen(preselectedDocumentIds: ids),
      ),
    );
  }
}

/// Tarjeta de documento con portada.
class _DocumentCard extends StatelessWidget {
  final ScanDocument document;
  final bool selected, selecting;
  final VoidCallback onTap, onLongPress;

  const _DocumentCard({
    required this.document,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Thumb(path: document.coverThumb),
                  if (selecting)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Icon(
                        selected ? Icons.check_circle : Icons.circle_outlined,
                        color: selected ? scheme.primary : Colors.white70,
                      ),
                    ),
                  if (document.favorite)
                    const Positioned(
                      top: 6,
                      left: 6,
                      child: Icon(Icons.star, size: 18, color: Colors.amber),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    document.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${document.pageCount} pag. · ${DateFormat('d MMM', 'es').format(document.updatedAt)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Miniatura leida de disco por ruta relativa.
class _Thumb extends ConsumerWidget {
  final String? path;
  final double? width, height;

  const _Thumb({this.path, this.width, this.height});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rel = path;
    if (rel == null) {
      return Container(
        width: width,
        height: height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.description_outlined),
      );
    }
    return FutureBuilder<File>(
      future: ref.read(repositoryProvider).absoluteFile(rel),
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null || !file.existsSync()) {
          return Container(
            width: width,
            height: height,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          );
        }
        return Image.file(
          file,
          width: width,
          height: height,
          fit: BoxFit.cover,
          // Decodificar a la resolucion que se va a mostrar, no a la original:
          // es lo que evita que una rejilla llena de miniaturas agote la RAM.
          cacheWidth: DeviceProfile.current.thumbnailCacheWidth,
          errorBuilder: (_, _, _) => Container(
            width: width,
            height: height,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.broken_image_outlined, size: 18),
          ),
        );
      },
    );
  }
}
