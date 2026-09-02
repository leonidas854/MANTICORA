import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/error_orchestrator.dart';
import 'package:manticora/core/failure.dart';
import 'package:manticora/widgets/common.dart';

/// Monta una pantalla con un boton que lanza [task] con el dialogo de progreso.
Future<void> _pumpHost(
  WidgetTester tester,
  Future<String> Function(void Function(String)) task, {
  void Function(String?)? onResult,
}) async {
  await tester.pumpWidget(MaterialApp(
    scaffoldMessengerKey: ErrorOrchestrator.messengerKey,
    navigatorKey: ErrorOrchestrator.navigatorKey,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () async {
              final result = await runWithProgress<String>(
                context,
                'Trabajando...',
                task,
              );
              onResult?.call(result);
            },
            child: const Text('lanzar'),
          ),
        ),
      ),
    ),
  ));
}

void main() {
  group('runWithProgress', () {
    testWidgets('muestra el dialogo en una tarea larga y lo cierra al terminar',
        (tester) async {
      String? result;
      await _pumpHost(
        tester,
        (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          return 'hecho';
        },
        onResult: (r) => result = r,
      );

      await tester.tap(find.text('lanzar'));
      await tester.pump();
      // El dialogo aparece solo tras el retardo de cortesia.
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Trabajando...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle();

      expect(find.text('Trabajando...'), findsNothing);
      expect(result, 'hecho');
    });

    testWidgets('no muestra nada si la tarea es breve', (tester) async {
      await _pumpHost(tester, (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return 'rapido';
      });

      await tester.tap(find.text('lanzar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      // Ni parpadeo de dialogo para algo que dura menos que el retardo.
      expect(find.byType(Dialog), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('actualiza el mensaje durante la tarea', (tester) async {
      await _pumpHost(tester, (setMessage) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        setMessage('Pagina 2 de 5...');
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return 'ok';
      });

      await tester.tap(find.text('lanzar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Trabajando...'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Pagina 2 de 5...'), findsOneWidget);

      await tester.pumpAndSettle();
    });

    testWidgets('absorbe la excepcion, cierra el dialogo y devuelve null',
        (tester) async {
      var called = false;
      String? result = 'no-tocado';

      await _pumpHost(
        tester,
        (_) async {
          called = true;
          throw const AppFailure.validation('el titulo no puede estar vacio');
        },
        onResult: (r) => result = r,
      );

      await tester.tap(find.text('lanzar'));
      await tester.pumpAndSettle();

      expect(called, isTrue);
      expect(result, isNull, reason: 'un fallo debe devolver null');
      expect(find.text('Trabajando...'), findsNothing,
          reason: 'el dialogo no debe quedarse colgado');
      // El aviso llega por el canal del orquestador.
      expect(find.text('el titulo no puede estar vacio'), findsOneWidget);
    });

    testWidgets('no deja el dialogo colgado si la tarea acaba al instante',
        (tester) async {
      String? result;
      await _pumpHost(
        tester,
        (_) async => 'inmediato',
        onResult: (r) => result = r,
      );

      await tester.tap(find.text('lanzar'));
      await tester.pumpAndSettle();

      expect(result, 'inmediato');
      expect(find.text('Trabajando...'), findsNothing);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('la pantalla de debajo sigue viva tras cerrarse el dialogo',
        (tester) async {
      await _pumpHost(tester, (_) async => 'ok');
      await tester.tap(find.text('lanzar'));
      await tester.pumpAndSettle();
      // Si se hubiera cerrado la ruta equivocada, el boton habria desaparecido.
      expect(find.text('lanzar'), findsOneWidget);
    });
  });
}
