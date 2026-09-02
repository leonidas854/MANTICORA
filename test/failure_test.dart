import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manticora/core/failure.dart';

void main() {
  group('AppFailure.from clasifica', () {
    test('falta de memoria', () {
      final f = AppFailure.from(OutOfMemoryError());
      expect(f.kind, FailureKind.memory);
      expect(f.message, contains('memoria'));
    });

    test('disco lleno', () {
      final f = AppFailure.from(
        const FileSystemException('No space left on device', '/data/x.jpg'),
      );
      expect(f.kind, FailureKind.storageFull);
      expect(f.retryable, isFalse);
    });

    test('fichero inexistente', () {
      final f = AppFailure.from(
        const FileSystemException('No such file or directory', '/data/x.jpg'),
      );
      expect(f.kind, FailureKind.notFound);
    });

    test('permiso denegado sobre un fichero', () {
      final f = AppFailure.from(
        const FileSystemException('Permission denied', '/data/x.jpg'),
      );
      expect(f.kind, FailureKind.permission);
    });

    test('tiempo agotado', () {
      final f = AppFailure.from(TimeoutException('tardo demasiado'));
      expect(f.kind, FailureKind.timeout);
    });

    test('formato invalido', () {
      final f = AppFailure.from(const FormatException('cabecera corrupta'));
      expect(f.kind, FailureKind.validation);
      expect(f.retryable, isFalse);
    });

    test('PDF protegido', () {
      final f = AppFailure.from(Exception('invalid password for encrypted document'));
      expect(f.kind, FailureKind.pdf);
    });

    test('plugin sin implementacion en la plataforma', () {
      // Es lo que ocurre al ejecutar en escritorio algo pensado para el movil.
      final f = AppFailure.from(
        Exception('MissingPluginException(No implementation found for method '
            'availableCameras on channel plugins.flutter.io/camera)'),
      );
      expect(f.kind, FailureKind.unsupported);
      expect(f.retryable, isFalse);
      expect(f.message, contains('no esta disponible'));
    });

    test('error desconocido cae en unknown', () {
      final f = AppFailure.from(Exception('algo raro'));
      expect(f.kind, FailureKind.unknown);
      expect(f.message, isNotEmpty);
    });
  });

  group('AppFailure', () {
    test('no re-envuelve un fallo que ya lo es', () {
      const original = AppFailure.validation('titulo vacio');
      final wrapped = AppFailure.from(original);
      expect(identical(wrapped, original), isTrue);
    });

    test('anade contexto a un fallo que no lo tenia', () {
      const original = AppFailure.validation('titulo vacio');
      final wrapped = AppFailure.from(original, null, 'Creando documento');
      expect(wrapped.context, 'Creando documento');
      expect(wrapped.message, original.message);
      expect(wrapped.kind, original.kind);
    });

    test('conserva el contexto original si ya tenia uno', () {
      const original = AppFailure.validation('vacio', context: 'Original');
      final wrapped = AppFailure.from(original, null, 'Otro');
      expect(wrapped.context, 'Original');
    });

    test('el detalle tecnico incluye tipo, contexto y causa', () {
      final f = AppFailure.from(
        const FileSystemException('boom'),
        StackTrace.current,
        'Guardando pagina',
      );
      expect(f.technicalDetail, contains('storage'));
      expect(f.technicalDetail, contains('Guardando pagina'));
      expect(f.technicalDetail, contains('boom'));
    });

    test('los mensajes de validacion no invitan a reintentar', () {
      const f = AppFailure.validation('el titulo no puede estar vacio');
      expect(f.retryable, isFalse);
      expect(f.kind, FailureKind.validation);
    });
  });

  group('Result', () {
    test('Success expone el valor y no el fallo', () {
      const r = Success<int>(42);
      expect(r.isSuccess, isTrue);
      expect(r.valueOrNull, 42);
      expect(r.failureOrNull, isNull);
      expect(r.fold((v) => 'ok $v', (f) => 'mal'), 'ok 42');
    });

    test('Failed expone el fallo y no el valor', () {
      const r = Failed<int>(AppFailure.validation('mal'));
      expect(r.isFailure, isTrue);
      expect(r.valueOrNull, isNull);
      expect(r.failureOrNull?.message, 'mal');
      expect(r.fold((v) => 'ok', (f) => 'fallo: ${f.message}'), 'fallo: mal');
    });
  });
}
