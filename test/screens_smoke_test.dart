import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/providers.dart';
import 'package:manticora/core/theme.dart';
import 'package:manticora/data/models/models.dart';
import 'package:manticora/features/home/home_screen.dart';
import 'package:manticora/features/media/media_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Las pantallas montadas de verdad, con su base de datos y sus proveedores.
///
/// No sustituyen a probarlo a mano en el movil, pero cubren lo que mas se rompe
/// al tocar codigo: que la pantalla se construya, que muestre el estado que
/// toca segun los datos y que la accion principal cambie con el tipo de equipo.
ScanDocument _documento(String titulo, {int paginas = 1}) => ScanDocument(
      id: titulo.hashCode.toString(),
      title: titulo,
      createdAt: DateTime(2026, 3, 1),
      updatedAt: DateTime(2026, 3, 2),
      pageCount: paginas,
    );

ScanPage _pagina({String? texto}) => ScanPage(
      id: 'p1',
      documentId: 'd1',
      position: 0,
      originalFile: 'docs/d1/orig_p1.jpg',
      processedFile: 'docs/d1/page_p1.jpg',
      thumbFile: 'docs/d1/thumb_p1.jpg',
      width: 800,
      height: 1100,
      ocrText: texto,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  /// Avanza unos fotogramas para que los proveedores resuelvan y se repinte.
  ///
  /// No se usa `pumpAndSettle`: mientras algo carga gira un indicador de
  /// progreso, y esperar a que una animacion infinita termine no acaba nunca.
  Future<void> asentar(WidgetTester tester, {int veces = 6}) async {
    for (var i = 0; i < veces; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// Monta una pantalla con la biblioteca ya resuelta.
  ///
  /// Los datos se inyectan en los proveedores en vez de abrir la base de datos:
  /// aqui se comprueba la interfaz, y del almacenamiento se encargan las
  /// pruebas de repositorio y las de extremo a extremo.
  Future<void> montar(
    WidgetTester tester,
    Widget pantalla, {
    List<ScanDocument> documentos = const [],
    List<Folder> carpetas = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryTickProvider.overrideWith((ref) => const Stream<void>.empty()),
          documentsProvider.overrideWith((ref) async {
            final q = ref.watch(libraryQueryProvider);
            if (q.search.isEmpty) return documentos;
            return documentos
                .where((d) => d.title.toLowerCase().contains(q.search.toLowerCase()))
                .toList();
          }),
          foldersProvider.overrideWith((ref) async => carpetas),
          trashCountProvider.overrideWith((ref) async => 0),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          // Las mismas piezas de idioma que monta la aplicacion: sin ellas las
          // fechas en espanol no se pueden formatear y la tarjeta no dibuja.
          locale: const Locale('es'),
          supportedLocales: const [Locale('es'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: pantalla,
        ),
      ),
    );
    await asentar(tester);
  }

  group('Pantalla principal', () {
    testWidgets('sin documentos invita a escanear el primero', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await montar(tester, const HomeScreen());

      expect(find.text('Manticora'), findsOneWidget);
      expect(find.text('Aun no hay documentos'), findsOneWidget);
      expect(find.textContaining('boton de la camara'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('en el escritorio la biblioteca vacia invita a importar',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await montar(tester, const HomeScreen());

      expect(find.text('Aun no hay documentos'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Importar imagenes'), findsOneWidget);
      expect(find.textContaining('boton de la camara'), findsNothing);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('muestra los documentos guardados', (tester) async {
      await montar(
        tester,
        const HomeScreen(),
        documentos: [
          _documento('Contrato de alquiler', paginas: 3),
          _documento('Factura de la luz'),
        ],
      );

      expect(find.text('Contrato de alquiler'), findsOneWidget);
      expect(find.text('Factura de la luz'), findsOneWidget);
      expect(find.text('Aun no hay documentos'), findsNothing);
    });

    testWidgets('en el movil la accion principal es escanear', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await montar(tester, const HomeScreen());

      expect(find.widgetWithText(FloatingActionButton, 'Escanear'), findsOneWidget);
      expect(find.text('Importar'), findsNothing);

      // Se restaura dentro de la prueba: el marco lo comprueba al terminarla.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('en el escritorio la accion principal es importar', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await montar(tester, const HomeScreen());

      expect(find.widgetWithText(FloatingActionButton, 'Importar'), findsOneWidget);
      expect(
        find.byTooltip('Escanear con la camara'),
        findsOneWidget,
        reason: 'la camara sigue estando, pero deja de ser lo primero',
      );

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('el menu ofrece las herramientas y la conversion', (tester) async {
      await montar(tester, const HomeScreen());

      await tester.tap(find.byType(PopupMenuButton<String>));
      await asentar(tester, veces: 3);

      expect(find.text('Herramientas PDF'), findsOneWidget);
      expect(find.text('Convertir a audio o video'), findsOneWidget);
      expect(find.text('Nueva carpeta'), findsOneWidget);
      expect(find.text('Ajustes'), findsOneWidget);
    });

    testWidgets('la busqueda filtra y se puede cerrar', (tester) async {
      await montar(
        tester,
        const HomeScreen(),
        documentos: [
          _documento('Contrato de alquiler'),
          _documento('Factura de la luz'),
        ],
      );

      await tester.tap(find.byIcon(Icons.search));
      await asentar(tester);
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'contrato');
      await asentar(tester);
      expect(find.text('Contrato de alquiler'), findsOneWidget);
      expect(find.text('Factura de la luz'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzz');
      await asentar(tester);
      expect(find.text('Sin resultados'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await asentar(tester);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('Pantalla de conversion a audio y video', () {
    testWidgets('sin origen elegido no deja convertir nada', (tester) async {
      await montar(tester, const MediaScreen());

      expect(find.text('Convertir a audio o video'), findsOneWidget);
      expect(find.text('Elegir un archivo'), findsOneWidget);
      expect(
        find.text('PDF, Word (.docx) o PowerPoint (.pptx)'),
        findsOneWidget,
      );

      final audio = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Crear audio (M4A)'),
      );
      final video = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Crear video (MP4)'),
      );
      expect(audio.onPressed, isNull);
      expect(video.onPressed, isNull);
    });

    testWidgets('con un documento de la biblioteca ya se puede convertir',
        (tester) async {
      final doc = DocumentWithPages(
        _documento('Acta de la reunion'),
        [_pagina(texto: 'texto de la reunion')],
      );

      await montar(tester, MediaScreen(document: doc));

      expect(find.text('Acta de la reunion'), findsOneWidget);
      expect(find.textContaining('1 paginas escaneadas'), findsOneWidget);
      expect(find.textContaining('1 con texto'), findsOneWidget);

      final audio = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Crear audio (M4A)'),
      );
      expect(audio.onPressed, isNotNull);
    });

    testWidgets('avisa cuando el documento aun no tiene texto reconocido',
        (tester) async {
      final doc = DocumentWithPages(_documento('Sin OCR'), [_pagina()]);

      await montar(tester, MediaScreen(document: doc));

      expect(find.textContaining('se hara el OCR'), findsOneWidget);
    });

    testWidgets('al quitar la narracion se ofrece la duracion por pagina',
        (tester) async {
      await montar(tester, const MediaScreen());

      expect(find.text('Velocidad de la voz'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await asentar(tester, veces: 3);

      expect(find.text('Segundos por pagina'), findsOneWidget);
      expect(find.text('Velocidad de la voz'), findsNothing);
    });
  });
}
