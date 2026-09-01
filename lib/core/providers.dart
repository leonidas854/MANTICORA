import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../data/repositories/document_repository.dart';

final repositoryProvider = Provider((ref) => DocumentRepository.instance);

/// Se dispara cada vez que el repositorio cambia; las vistas dependen de el
/// para recargarse solas.
final repositoryTickProvider = StreamProvider<void>((ref) {
  return ref.watch(repositoryProvider).changes;
});

/// Filtros activos del listado principal.
class LibraryQuery {
  final String? folderId;
  final String search;
  final bool trash;
  final bool favoritesOnly;

  const LibraryQuery({
    this.folderId,
    this.search = '',
    this.trash = false,
    this.favoritesOnly = false,
  });

  LibraryQuery copyWith({
    String? folderId,
    bool clearFolder = false,
    String? search,
    bool? trash,
    bool? favoritesOnly,
  }) =>
      LibraryQuery(
        folderId: clearFolder ? null : (folderId ?? this.folderId),
        search: search ?? this.search,
        trash: trash ?? this.trash,
        favoritesOnly: favoritesOnly ?? this.favoritesOnly,
      );

  @override
  bool operator ==(Object other) =>
      other is LibraryQuery &&
      other.folderId == folderId &&
      other.search == search &&
      other.trash == trash &&
      other.favoritesOnly == favoritesOnly;

  @override
  int get hashCode => Object.hash(folderId, search, trash, favoritesOnly);
}

final libraryQueryProvider =
    StateProvider<LibraryQuery>((ref) => const LibraryQuery());

/// Documentos que cumplen el filtro actual.
final documentsProvider = FutureProvider<List<ScanDocument>>((ref) async {
  ref.watch(repositoryTickProvider);
  final q = ref.watch(libraryQueryProvider);
  return ref.watch(repositoryProvider).listDocuments(
        folderId: q.folderId,
        rootOnly: q.folderId == null && q.search.isEmpty && !q.favoritesOnly,
        query: q.search,
        trash: q.trash,
        favoritesOnly: q.favoritesOnly,
      );
});

/// Carpetas del nivel actual.
final foldersProvider = FutureProvider<List<Folder>>((ref) async {
  ref.watch(repositoryTickProvider);
  final q = ref.watch(libraryQueryProvider);
  if (q.trash || q.search.isNotEmpty) return const [];
  return ref.watch(repositoryProvider).listFolders(parentId: q.folderId);
});

/// Un documento concreto con sus paginas.
final documentProvider =
    FutureProvider.family<DocumentWithPages?, String>((ref, id) async {
  ref.watch(repositoryTickProvider);
  return ref.watch(repositoryProvider).getDocument(id);
});

/// Numero de elementos en la papelera (para el aviso del menu).
final trashCountProvider = FutureProvider<int>((ref) async {
  ref.watch(repositoryTickProvider);
  final docs = await ref.watch(repositoryProvider).listDocuments(trash: true);
  return docs.length;
});
