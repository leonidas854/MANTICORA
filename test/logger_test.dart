import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/logger.dart';

void main() {
  setUp(() async => Log.clear());

  group('Log', () {
    test('guarda los eventos en orden', () {
      Log.i('Prueba', 'primero');
      Log.w('Prueba', 'segundo');
      final entries = Log.entries;
      expect(entries.length, 2);
      expect(entries.first.message, 'primero');
      expect(entries.last.message, 'segundo');
      expect(entries.last.level, LogLevel.warn);
    });

    test('conserva la causa y la traza de los errores', () {
      final error = StateError('roto');
      Log.e('Prueba', 'fallo algo', error, StackTrace.current);
      final entry = Log.entries.last;
      expect(entry.level, LogLevel.error);
      expect(entry.error, error);
      expect(entry.stackTrace, isNotNull);
    });

    test('acota el historial en memoria', () {
      for (var i = 0; i < 600; i++) {
        Log.d('Prueba', 'evento $i');
      }
      // El tope son 400 entradas: un movil modesto no debe acumular mas.
      expect(Log.entries.length, lessThanOrEqualTo(400));
      // Y lo que se conserva es lo mas reciente.
      expect(Log.entries.last.message, 'evento 599');
    });

    test('la linea formateada lleva hora, nivel y etiqueta', () {
      Log.i('Camara', 'lista');
      final line = Log.entries.last.format();
      expect(line, contains('I/Camara'));
      expect(line, contains('lista'));
      expect(line, matches(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} ')));
    });

    test('el volcado incluye todas las entradas', () {
      Log.i('A', 'uno');
      Log.i('B', 'dos');
      final dump = Log.dump();
      expect(dump, contains('uno'));
      expect(dump, contains('dos'));
    });

    test('vaciar deja el registro limpio', () async {
      Log.i('Prueba', 'algo');
      expect(Log.entries, isNotEmpty);
      await Log.clear();
      expect(Log.entries, isEmpty);
    });

    test('avisa a los observadores registrados', () {
      var notifications = 0;
      void listener() => notifications++;
      Log.addListener(listener);
      Log.i('Prueba', 'uno');
      Log.i('Prueba', 'dos');
      Log.removeListener(listener);
      Log.i('Prueba', 'tres');
      expect(notifications, 2);
    });

    test('un observador que falla no rompe el registro', () {
      Log.addListener(() => throw StateError('observador roto'));
      expect(() => Log.i('Prueba', 'sigue funcionando'), returnsNormally);
      expect(Log.entries.last.message, 'sigue funcionando');
    });

    test('los niveles se ordenan de menor a mayor gravedad', () {
      expect(LogLevel.error >= LogLevel.warn, isTrue);
      expect(LogLevel.warn >= LogLevel.info, isTrue);
      expect(LogLevel.debug >= LogLevel.info, isFalse);
    });
  });
}
