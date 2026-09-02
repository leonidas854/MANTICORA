import 'dart:async';
import 'dart:io';

/// Familias de fallo que la aplicacion sabe distinguir y explicar.
enum FailureKind {
  storage('Almacenamiento'),
  storageFull('Sin espacio'),
  memory('Memoria insuficiente'),
  camera('Camara'),
  permission('Permisos'),
  ocr('Reconocimiento de texto'),
  pdf('PDF'),
  document('Documento'),
  database('Base de datos'),
  validation('Datos no validos'),
  notFound('No encontrado'),
  timeout('Tiempo agotado'),
  cancelled('Cancelado'),
  unsupported('No disponible aqui'),
  unknown('Error inesperado');

  final String label;
  const FailureKind(this.label);
}

/// Error de la aplicacion ya traducido a algo que se le puede enseñar a una
/// persona, conservando el detalle tecnico para el registro.
class AppFailure implements Exception {
  final FailureKind kind;

  /// Mensaje en castellano, concreto y accionable.
  final String message;

  /// Que estaba haciendo la app cuando fallo ("Exportando a PDF").
  final String? context;

  final Object? cause;
  final StackTrace? stackTrace;

  /// Si es false, no tiene sentido reintentar la misma operacion.
  final bool retryable;

  const AppFailure({
    required this.kind,
    required this.message,
    this.context,
    this.cause,
    this.stackTrace,
    this.retryable = true,
  });

  /// Fallo de validacion: lo provoca el usuario, no el sistema.
  const AppFailure.validation(this.message, {this.context})
      : kind = FailureKind.validation,
        cause = null,
        stackTrace = null,
        retryable = false;

  const AppFailure.notFound(this.message, {this.context})
      : kind = FailureKind.notFound,
        cause = null,
        stackTrace = null,
        retryable = false;

  String get technicalDetail {
    final buf = StringBuffer(kind.name);
    if (context != null) buf.write(' @ $context');
    if (cause != null) buf.write(' :: $cause');
    return buf.toString();
  }

  @override
  String toString() => 'AppFailure(${kind.name}): $message'
      '${context == null ? '' : ' [$context]'}'
      '${cause == null ? '' : ' <- $cause'}';

  /// Traduce cualquier excepcion a un fallo con mensaje comprensible.
  ///
  /// Se apoya en el nombre del tipo en lugar de importar camera, sqflite y
  /// compañia: asi este fichero no arrastra dependencias de plugins.
  factory AppFailure.from(Object error, [StackTrace? stackTrace, String? context]) {
    if (error is AppFailure) {
      return context == null || error.context != null
          ? error
          : AppFailure(
              kind: error.kind,
              message: error.message,
              context: context,
              cause: error.cause,
              stackTrace: error.stackTrace ?? stackTrace,
              retryable: error.retryable,
            );
    }

    final typeName = error.runtimeType.toString();
    final text = error.toString();
    final lower = text.toLowerCase();

    AppFailure make(FailureKind kind, String message, {bool retryable = true}) =>
        AppFailure(
          kind: kind,
          message: message,
          context: context,
          cause: error,
          stackTrace: stackTrace,
          retryable: retryable,
        );

    // --- memoria ---------------------------------------------------------
    if (error is OutOfMemoryError ||
        lower.contains('out of memory') ||
        lower.contains('cannot allocate') ||
        lower.contains('outofmemory')) {
      return make(
        FailureKind.memory,
        'El dispositivo se ha quedado sin memoria. Prueba con menos paginas a '
        'la vez o baja la calidad en Ajustes.',
      );
    }

    // --- disco -----------------------------------------------------------
    if (error is FileSystemException) {
      if (lower.contains('no space left') || lower.contains('enospc')) {
        return make(
          FailureKind.storageFull,
          'No queda espacio en el dispositivo. Libera espacio y vuelve a intentarlo.',
          retryable: false,
        );
      }
      if (lower.contains('no such file') || lower.contains('cannot open file')) {
        return make(
          FailureKind.notFound,
          'No se encuentra el fichero. Es posible que se haya movido o borrado.',
          retryable: false,
        );
      }
      if (lower.contains('permission denied') || lower.contains('eacces')) {
        return make(
          FailureKind.permission,
          'Sin permiso para acceder a ese fichero.',
          retryable: false,
        );
      }
      return make(FailureKind.storage, 'Error al acceder al almacenamiento.');
    }

    // --- tiempos ---------------------------------------------------------
    if (error is TimeoutException) {
      return make(
        FailureKind.timeout,
        'La operacion ha tardado demasiado y se ha cancelado.',
      );
    }

    // --- plugins ---------------------------------------------------------
    if (typeName == 'CameraException' || lower.contains('cameraexception')) {
      if (lower.contains('permission') || lower.contains('denied')) {
        return make(
          FailureKind.permission,
          'Manticora necesita permiso para usar la camara. Actívalo en los '
          'ajustes del sistema.',
          retryable: false,
        );
      }
      return make(
        FailureKind.camera,
        'No se ha podido usar la camara. Cierra otras apps que la esten usando '
        'y vuelve a intentarlo.',
      );
    }

    // Plugin sin implementacion para esta plataforma: pasa al ejecutar en
    // escritorio funciones pensadas para el movil (camara, biometria...).
    if (typeName == 'MissingPluginException' ||
        lower.contains('no implementation found for method')) {
      return make(
        FailureKind.unsupported,
        'Esta funcion no esta disponible en este dispositivo.',
        retryable: false,
      );
    }

    if (typeName == 'PlatformException') {
      if (lower.contains('permission') || lower.contains('denied')) {
        return make(
          FailureKind.permission,
          'Falta un permiso del sistema para completar la accion.',
          retryable: false,
        );
      }
      if (lower.contains('camera')) {
        return make(FailureKind.camera, 'La camara no responde.');
      }
      return make(FailureKind.unknown, 'El sistema ha rechazado la operacion.');
    }

    if (typeName.contains('DatabaseException') || lower.contains('sqlite')) {
      if (lower.contains('disk') && lower.contains('full')) {
        return make(
          FailureKind.storageFull,
          'No queda espacio para guardar los cambios.',
          retryable: false,
        );
      }
      return make(
        FailureKind.database,
        'Error al guardar en la base de datos local.',
      );
    }

    // --- formatos --------------------------------------------------------
    if (error is FormatException) {
      return make(
        FailureKind.validation,
        'El fichero no tiene un formato valido o esta dañado.',
        retryable: false,
      );
    }

    if (lower.contains('password') || lower.contains('encrypted')) {
      return make(
        FailureKind.pdf,
        'El PDF esta protegido y la contrasena no es correcta.',
        retryable: false,
      );
    }

    if (error is ArgumentError || error is RangeError || error is StateError) {
      return make(
        FailureKind.validation,
        'Los datos de entrada no son validos para esta operacion.',
        retryable: false,
      );
    }

    return make(FailureKind.unknown, 'Ha ocurrido un error inesperado.');
  }
}

/// Resultado de una operacion que puede fallar sin lanzar excepciones.
sealed class Result<T> {
  const Result();

  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is Failed<T>;

  T? get valueOrNull => this is Success<T> ? (this as Success<T>).value : null;
  AppFailure? get failureOrNull =>
      this is Failed<T> ? (this as Failed<T>).failure : null;

  R fold<R>(R Function(T value) onSuccess, R Function(AppFailure f) onFailure) =>
      switch (this) {
        Success<T>(:final value) => onSuccess(value),
        Failed<T>(:final failure) => onFailure(failure),
      };
}

class Success<T> extends Result<T> {
  final T value;
  const Success(this.value);
}

class Failed<T> extends Result<T> {
  final AppFailure failure;
  const Failed(this.failure);
}
