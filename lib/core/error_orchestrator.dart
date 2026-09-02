import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'failure.dart';
import 'logger.dart';

/// Punto unico por el que pasan todos los errores de la aplicacion.
///
/// Se encarga de tres cosas:
///  1. Capturar lo que se escapa (errores de Flutter, de la plataforma, de
///     isolates y de zonas asincronas) para que la app no muera en silencio.
///  2. Traducir cualquier excepcion a un [AppFailure] con mensaje comprensible.
///  3. Registrarlo y, si procede, avisar a la persona que esta usando la app.
class ErrorOrchestrator {
  ErrorOrchestrator._();

  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Numero de fallos registrados en esta sesion (lo muestra Diagnostico).
  static final ValueNotifier<int> failureCount = ValueNotifier<int>(0);

  static AppFailure? lastFailure;
  static bool _installed = false;

  /// Evita encadenar diez avisos identicos si algo falla en bucle.
  static String? _lastNotifiedSignature;
  static DateTime _lastNotifiedAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ------------------------------------------------------------- instalacion

  static void install() {
    if (_installed) return;
    _installed = true;

    // Errores del arbol de widgets y del framework.
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final failure = AppFailure.from(
        details.exception,
        details.stack,
        details.library == null ? 'Flutter' : 'Flutter/${details.library}',
      );
      _record(failure, notifyUser: false);
      if (kDebugMode) previous?.call(details);
    };

    // Errores asincronos que llegan al motor sin zona que los recoja.
    PlatformDispatcher.instance.onError = (error, stack) {
      _record(AppFailure.from(error, stack, 'PlatformDispatcher'), notifyUser: false);
      return true; // tratado: no tumbamos el proceso
    };

    // Errores lanzados dentro de isolates que no devuelven resultado.
    try {
      final port = ReceivePort();
      Isolate.current.addErrorListener(port.sendPort);
      port.listen((message) {
        if (message is List && message.isNotEmpty) {
          _record(
            AppFailure.from(message.first ?? 'error en isolate', null, 'Isolate'),
            notifyUser: false,
          );
        }
      });
    } catch (e) {
      Log.w('Errores', 'No se pudo escuchar errores de isolate', e);
    }

    Log.i('Errores', 'Orquestador de errores instalado');
  }

  /// Ejecuta la aplicacion dentro de una zona vigilada.
  static void runGuarded(void Function() body) {
    runZonedGuarded(body, (error, stack) {
      _record(AppFailure.from(error, stack, 'Zona raiz'), notifyUser: false);
    });
  }

  // ------------------------------------------------------------- envoltorios

  /// Ejecuta [task] capturando cualquier fallo. Devuelve `null` si falla.
  ///
  /// Es el envoltorio que deben usar todas las acciones de la interfaz: nunca
  /// deja escapar una excepcion y siempre deja rastro en el registro.
  static Future<T?> guard<T>(
    String context,
    Future<T> Function() task, {
    String tag = 'App',
    bool notifyUser = true,
    Duration? timeout,
    void Function(AppFailure failure)? onFailure,
  }) async {
    final result = await attempt<T>(
      context,
      task,
      tag: tag,
      notifyUser: notifyUser,
      timeout: timeout,
    );
    return result.fold((value) => value, (failure) {
      onFailure?.call(failure);
      return null;
    });
  }

  /// Igual que [guard] pero devolviendo un [Result] para poder distinguir
  /// "fallo" de "resultado nulo legitimo".
  static Future<Result<T>> attempt<T>(
    String context,
    Future<T> Function() task, {
    String tag = 'App',
    bool notifyUser = true,
    Duration? timeout,
  }) async {
    final started = DateTime.now();
    try {
      final future = task();
      final value = timeout == null ? await future : await future.timeout(timeout);
      final ms = DateTime.now().difference(started).inMilliseconds;
      if (ms > 1500) Log.d(tag, '$context completado en ${ms}ms');
      return Success<T>(value);
    } catch (error, stack) {
      final failure = AppFailure.from(error, stack, context);
      _record(failure, notifyUser: notifyUser, tag: tag);
      return Failed<T>(failure);
    }
  }

  /// Version sincrona, para calculos que no deberian tumbar una pantalla.
  static T? guardSync<T>(
    String context,
    T Function() task, {
    String tag = 'App',
    bool notifyUser = false,
    T? fallback,
  }) {
    try {
      return task();
    } catch (error, stack) {
      _record(AppFailure.from(error, stack, context), notifyUser: notifyUser, tag: tag);
      return fallback;
    }
  }

  /// Reintenta una operacion inestable (E/S, plugins) con espera creciente.
  static Future<Result<T>> retry<T>(
    String context,
    Future<T> Function() task, {
    int attempts = 3,
    Duration initialDelay = const Duration(milliseconds: 200),
    String tag = 'App',
    bool notifyUser = true,
  }) async {
    var delay = initialDelay;
    AppFailure? last;
    for (var i = 1; i <= attempts; i++) {
      final result = await attempt<T>(context, task, tag: tag, notifyUser: false);
      if (result case Success<T>()) return result;
      last = result.failureOrNull;
      if (last != null && !last.retryable) break;
      if (i < attempts) {
        Log.d(tag, '$context: reintento $i de $attempts');
        await Future<void>.delayed(delay);
        delay *= 2;
      }
    }
    final failure = last ??
        AppFailure(kind: FailureKind.unknown, message: 'Error desconocido', context: context);
    if (notifyUser) notify(failure);
    return Failed<T>(failure);
  }

  // ------------------------------------------------------------- notificacion

  static void _record(AppFailure failure, {bool notifyUser = true, String tag = 'App'}) {
    lastFailure = failure;
    failureCount.value++;
    Log.e(
      tag,
      '${failure.context ?? 'sin contexto'}: ${failure.message}',
      failure.cause ?? failure,
      failure.stackTrace,
    );
    if (notifyUser) notify(failure);
  }

  /// Muestra el fallo a la persona, sin repetir el mismo aviso en bucle.
  static void notify(AppFailure failure) {
    final signature = '${failure.kind.name}|${failure.message}';
    final now = DateTime.now();
    if (signature == _lastNotifiedSignature &&
        now.difference(_lastNotifiedAt) < const Duration(seconds: 4)) {
      return;
    }
    _lastNotifiedSignature = signature;
    _lastNotifiedAt = now;

    final messenger = messengerKey.currentState;
    if (messenger == null) return;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(failure.message),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Detalles',
            onPressed: () => _showDetails(failure),
          ),
        ),
      );
  }

  static void _showDetails(AppFailure failure) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(failure.kind.label),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(failure.message),
              const SizedBox(height: 16),
              Text(
                'Detalle tecnico',
                style: Theme.of(ctx).textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              SelectableText(
                failure.technicalDetail,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  /// Aviso breve de exito o informacion, por el mismo canal.
  static void toast(String message) {
    messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
