import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/failure.dart';
import 'package:manticora/data/db/app_database.dart';
import 'package:manticora/data/repositories/document_repository.dart';
import 'package:manticora/data/repositories/storage_service.dart';
import 'package:manticora/imaging/filters.dart';
import 'package:manticora/imaging/geometry.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Redirige el almacenamiento de la app a una carpeta temporal de la prueba.
class _TempPathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _TempPathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Uint8List _fakeJpeg([int size = 512]) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(size, 0x20), 0xFF, 0xD9]);

void main() {
  late Directory temp;
  late DocumentRepository repo;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    temp = await Directory.systemTemp.createTemp('manticora_test_');
    PathProviderPlatform.instance = _TempPathProvider(temp.path);
    // Estado limpio en cada prueba: los singletons cachean la carpeta raiz.
    await AppDatabase.instance.resetForTesting();
    StorageService.instance.resetForTesting();
    repo = DocumentRepository.instance;
  });

  tearDown(() async {
    await AppDatabase.instance.resetForTesting();
    StorageService.instance.resetForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<String> makeDocument({String title = 'Documento', int pages = 1}) async {
    final doc = await repo.createDocument(title: title);
    for (var i = 0; i < pages; i++) {
      await repo.addPage(
        documentId: doc.id,
        originalJpeg: _fakeJpeg(),
        processedJpeg: _fakeJpeg(),
        thumbnailJpeg: _fakeJpeg(128),
        width: 800,
        height: 1100,
      );
    }
    return doc.id;
  }

  group('Documentos', () {
    test('crear un documento lo deja listado', () async {
      await makeDocument(title: 'Factura de marzo');
      final docs = await repo.listDocuments();
      expect(docs, hasLength(1));
      expect(docs.first.title, 'Factura de marzo');
    });

    test('las paginas se guardan y se recuperan en orden', () async {
      final id = await makeDocument(pages: 3);
      final doc = await repo.getDocument(id);
      expect(doc!.pages, hasLength(3));
      expect(doc.pages.map((p) => p.position), [0, 1, 2]);
      expect(doc.document.pageCount, 3);
    });

    test('las imagenes acaban de verdad en disco', () async {
      final id = await makeDocument();
      final doc = await repo.getDocument(id);
      final file = await repo.pageFile(doc!.pages.first);
      expect(await file.exists(), isTrue);
      expect(await file.length(), greaterThan(0));
    });

    test('renombrar rechaza un titulo vacio', () async {
      final id = await makeDocument();
      expect(() => repo.renameDocument(id, '   '), throwsA(isA<AppFailure>()));
    });

    test('reordenar cambia el orden de verdad', () async {
      final id = await makeDocument(pages: 3);
      var doc = await repo.getDocument(id);
      final ids = doc!.pages.map((p) => p.id).toList();

      await repo.reorderPages(id, [ids[2], ids[0], ids[1]]);
      doc = await repo.getDocument(id);
      expect(doc!.pages.map((p) => p.id).toList(), [ids[2], ids[0], ids[1]]);
    });

    test('borrar una pagina renumera el resto y borra sus ficheros', () async {
      final id = await makeDocument(pages: 3);
      var doc = await repo.getDocument(id);
      final page = doc!.pages[1];
      final file = await repo.pageFile(page);

      await repo.deletePage(page);
      doc = await repo.getDocument(id);

      expect(doc!.pages, hasLength(2));
      expect(doc.pages.map((p) => p.position), [0, 1]);
      expect(await file.exists(), isFalse, reason: 'el fichero deberia borrarse');
    });

    test('reeditar una pagina invalida el OCR, sus cajas y el indice de busqueda',
        () async {
      final id = await makeDocument(title: 'Documento neutro');
      var page = (await repo.getDocument(id))!.pages.single;
      await repo.setOcrText(
        page.id,
        id,
        'palabraunica reconocida antes de editar',
        boxesJson: '[{"t":"palabraunica","x":1,"y":2,"w":3,"h":4}]',
      );
      page = (await repo.getDocument(id))!.pages.single;
      expect(await repo.listDocuments(query: 'palabraunica'), hasLength(1));

      await repo.replacePageImage(
        page,
        processedJpeg: _fakeJpeg(700),
        thumbnailJpeg: _fakeJpeg(140),
        filter: ScanFilter.grayscale,
      );

      final refreshed = (await repo.getDocument(id))!;
      expect(refreshed.pages.single.ocrText, isNull);
      expect(refreshed.pages.single.ocrBoxes, isNull);
      expect(refreshed.combinedText, isEmpty);
      expect(await repo.listDocuments(query: 'palabraunica'), isEmpty,
          reason: 'el FTS no debe conservar texto de una imagen anterior');
    });

    test('sin conservar original guarda una base neutra para no recortar dos veces',
        () async {
      final doc = await repo.createDocument(title: 'Sin originales');
      final original = _fakeJpeg(600);
      final processed = _fakeJpeg(900);

      final page = await repo.addPage(
        documentId: doc.id,
        originalJpeg: original,
        processedJpeg: processed,
        thumbnailJpeg: _fakeJpeg(120),
        quad: Quad.inset(800, 1100, 0.10),
        filter: ScanFilter.blackWhite,
        adjustments: const Adjustments(brightness: 0.2, contrast: 0.3),
        rotation: 1,
        width: 640,
        height: 880,
        keepOriginal: false,
      );

      final storedOriginal = await repo.absoluteFile(page.originalFile);
      expect(await storedOriginal.readAsBytes(), processed,
          reason: 'la base editable debe ser exactamente la salida ya procesada');
      expect(page.quad, isNull,
          reason: 'volver a aplicar el quad recortaria por segunda vez');
      expect(page.filter, ScanFilter.original,
          reason: 'el filtro ya esta horneado en la base editable');
      expect(page.adjustments.isIdentity, isTrue);
      expect(page.rotation, 0, reason: 'el giro ya esta horneado en la imagen');

      final persisted = (await repo.getDocument(doc.id))!.pages.single;
      expect(persisted.quad, isNull);
      expect(persisted.filter, ScanFilter.original);
      expect(persisted.adjustments.isIdentity, isTrue);
      expect(persisted.rotation, 0);
    });
  });

  group('Papelera', () {
    test('mover a la papelera lo saca del listado principal', () async {
      final id = await makeDocument(title: 'Temporal');
      await repo.moveToTrash(id);

      expect(await repo.listDocuments(), isEmpty);
      expect(await repo.listDocuments(trash: true), hasLength(1));
    });

    test('restaurar lo devuelve al listado', () async {
      final id = await makeDocument(title: 'Recuperable');
      await repo.moveToTrash(id);
      await repo.restore(id);

      final docs = await repo.listDocuments();
      expect(docs, hasLength(1));
      expect(docs.first.title, 'Recuperable');
      expect(await repo.listDocuments(trash: true), isEmpty);
    });

    test('vaciar la papelera borra los ficheros del disco', () async {
      final id = await makeDocument(pages: 2);
      final doc = await repo.getDocument(id);
      final file = await repo.pageFile(doc!.pages.first);
      await repo.moveToTrash(id);

      final removed = await repo.emptyTrash();

      expect(removed, 1);
      expect(await repo.listDocuments(trash: true), isEmpty);
      expect(await file.exists(), isFalse);
    });

    test('un documento en la papelera no aparece en las busquedas', () async {
      final id = await makeDocument(title: 'Contrato de alquiler');
      await repo.moveToTrash(id);
      expect(await repo.listDocuments(query: 'Contrato'), isEmpty);
    });
  });

  group('Favoritos y etiquetas', () {
    test('marcar como favorito y filtrar por favoritos', () async {
      final a = await makeDocument(title: 'Importante');
      await makeDocument(title: 'Normal');
      await repo.setFavorite(a, true);

      final favoritos = await repo.listDocuments(favoritesOnly: true);
      expect(favoritos, hasLength(1));
      expect(favoritos.first.title, 'Importante');
      expect(favoritos.first.favorite, isTrue);
    });

    test('quitar el favorito lo saca del filtro', () async {
      final a = await makeDocument();
      await repo.setFavorite(a, true);
      await repo.setFavorite(a, false);
      expect(await repo.listDocuments(favoritesOnly: true), isEmpty);
    });

    test('las etiquetas se guardan y se limpian', () async {
      final id = await makeDocument();
      await repo.setTags(id, ['casa', '  banco  ', '', 'con,coma']);
      final doc = await repo.getDocument(id);
      expect(doc!.document.tags, ['casa', 'banco', 'con coma']);
    });
  });

  group('Busqueda', () {
    test('encuentra por titulo', () async {
      await makeDocument(title: 'Contrato de alquiler');
      await makeDocument(title: 'Recibo de la luz');

      final result = await repo.listDocuments(query: 'alquiler');
      expect(result, hasLength(1));
      expect(result.first.title, 'Contrato de alquiler');
    });

    test('encuentra dentro del texto reconocido', () async {
      final id = await makeDocument(title: 'Sin titulo util');
      final doc = await repo.getDocument(id);
      await repo.setOcrText(
        doc!.pages.first.id,
        id,
        'El importe total asciende a novecientos euros',
      );

      final result = await repo.listDocuments(query: 'novecientos');
      expect(result, hasLength(1));
      expect(result.first.id, id);
    });

    test('una busqueda sin resultados devuelve vacio', () async {
      await makeDocument(title: 'Factura');
      expect(await repo.listDocuments(query: 'inexistente'), isEmpty);
    });

    test('los caracteres raros no rompen la busqueda', () async {
      await makeDocument(title: 'Factura');
      for (final q in ['"', '*', '((', '%_', 'a"b*']) {
        expect(() => repo.listDocuments(query: q), returnsNormally);
      }
    });
  });

  group('Carpetas', () {
    test('crear una carpeta y meter documentos dentro', () async {
      final folder = await repo.createFolder('Trabajo');
      final id = await makeDocument(title: 'Nomina');
      await repo.setFolder(id, folder.id);

      expect(await repo.countInFolder(folder.id), 1);
      expect(await repo.listDocuments(folderId: folder.id), hasLength(1));
      // Ya no esta en la raiz.
      expect(await repo.listDocuments(rootOnly: true), isEmpty);
    });

    test('borrar la carpeta devuelve los documentos a la raiz', () async {
      final folder = await repo.createFolder('Temporal');
      final id = await makeDocument();
      await repo.setFolder(id, folder.id);

      await repo.deleteFolder(folder.id);

      expect(await repo.listFolders(), isEmpty);
      final docs = await repo.listDocuments(rootOnly: true);
      expect(docs, hasLength(1));
      expect(docs.first.id, id);
    });

    test('una carpeta sin nombre se rechaza', () async {
      expect(() => repo.createFolder('  '), throwsA(isA<AppFailure>()));
    });
  });

  group('Integridad', () {
    test('detecta y limpia una pagina cuya imagen ha desaparecido', () async {
      final id = await makeDocument(pages: 2);
      final doc = await repo.getDocument(id);
      final file = await repo.pageFile(doc!.pages.first);
      await file.delete(); // se simula un borrado externo

      final problems = await repo.verifyIntegrity();

      expect(problems, greaterThanOrEqualTo(1));
      final after = await repo.getDocument(id);
      expect(after!.pages, hasLength(1));
    });

    test('sin incidencias no toca nada', () async {
      await makeDocument(pages: 2);
      expect(await repo.verifyIntegrity(), 0);
    });
  });

  group('Almacenamiento', () {
    test('cuenta el espacio ocupado', () async {
      await makeDocument(pages: 2);
      expect(await StorageService.instance.usedBytes(), greaterThan(0));
    });

    test('no deja escribir fuera de la carpeta de la app', () async {
      expect(
        () => StorageService.instance.fileFor('../../fuera.txt'),
        throwsA(isA<AppFailure>()),
      );
    });
  });
}
