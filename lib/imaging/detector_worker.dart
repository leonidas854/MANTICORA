import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../core/logger.dart';
import 'detector.dart';
import 'geometry.dart';
import 'raster.dart';

/// Detector de bordes en vivo sobre un isolate persistente.
///
/// Crear un isolate por fotograma (como hace `Isolate.run`) cuesta unos pocos
/// milisegundos, pero a varios fotogramas por segundo y en un movil modesto eso
/// es trabajo y basura que se puede evitar. Aqui se levanta un unico isolate y
/// se reutiliza; si llega un fotograma mientras el anterior sigue en curso, se
/// **descarta**, que es justo lo que interesa en una vista previa.
class DetectorWorker {
  DetectorWorker._();
  static final DetectorWorker instance = DetectorWorker._();

  Isolate? _isolate;
  SendPort? _requests;
  ReceivePort? _replies;
  Completer<Quad?>? _pending;
  Future<void>? _starting;

  bool get isBusy => _pending != null;
  bool get isRunning => _requests != null;

  /// Numero de fotogramas descartados por llegar con el detector ocupado.
  int droppedFrames = 0;

  /// Arranca el isolate. Es idempotente y seguro llamarlo varias veces.
  Future<void> start() {
    if (_requests != null) return Future.value();
    return _starting ??= _start();
  }

  Future<void> _start() async {
    try {
      final replies = ReceivePort();
      final ready = Completer<SendPort>();

      replies.listen((message) {
        if (message is SendPort) {
          if (!ready.isCompleted) ready.complete(message);
          return;
        }
        // Respuesta a una peticion: lista de 8 dobles, o null.
        final pending = _pending;
        _pending = null;
        if (pending == null || pending.isCompleted) return;
        if (message is List && message.length == 8) {
          final v = message.cast<double>();
          pending.complete(Quad(
            Pt(v[0], v[1]),
            Pt(v[2], v[3]),
            Pt(v[4], v[5]),
            Pt(v[6], v[7]),
          ));
        } else {
          pending.complete(null);
        }
      });

      _isolate = await Isolate.spawn(
        _detectorEntry,
        replies.sendPort,
        errorsAreFatal: false,
        debugName: 'manticora-detector',
      );
      _replies = replies;
      _requests = await ready.future.timeout(const Duration(seconds: 5));
      Log.i('Detector', 'Isolate de deteccion en vivo listo');
    } catch (e, st) {
      Log.w('Detector', 'No se pudo arrancar el isolate de deteccion', e, st);
      await stop();
    } finally {
      _starting = null;
    }
  }

  /// Analiza un fotograma. Devuelve `null` si no hay documento, si el detector
  /// estaba ocupado (fotograma descartado) o si algo ha fallado.
  Future<Quad?> detect(
    Uint8List luma,
    int width,
    int height,
    int rowStride, {
    int targetSize = 384,
  }) async {
    if (_requests == null) {
      await start();
      if (_requests == null) return null;
    }
    if (_pending != null) {
      droppedFrames++;
      return null;
    }
    if (width <= 0 || height <= 0 || luma.isEmpty) return null;

    final completer = Completer<Quad?>();
    _pending = completer;
    try {
      _requests!.send([luma, width, height, rowStride, targetSize]);
    } catch (e) {
      _pending = null;
      Log.w('Detector', 'No se pudo enviar el fotograma al isolate', e);
      return null;
    }

    // Un fotograma nunca deberia tardar tanto; si pasa, se libera el hueco
    // para no dejar el detector bloqueado para siempre.
    return completer.future.timeout(
      const Duration(seconds: 4),
      onTimeout: () {
        Log.w('Detector', 'Tiempo agotado analizando un fotograma');
        _pending = null;
        return null;
      },
    );
  }

  Future<void> stop() async {
    try {
      _requests?.send('stop');
    } catch (_) {}
    try {
      _isolate?.kill(priority: Isolate.immediate);
    } catch (_) {}
    _replies?.close();
    _isolate = null;
    _requests = null;
    _replies = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete(null);
  }
}

/// Punto de entrada del isolate. Debe ser una funcion de nivel superior.
void _detectorEntry(SendPort mainPort) {
  final port = ReceivePort();
  mainPort.send(port.sendPort);

  port.listen((message) {
    if (message == 'stop') {
      port.close();
      return;
    }
    if (message is! List || message.length != 5) {
      mainPort.send(null);
      return;
    }
    try {
      final luma = message[0] as Uint8List;
      final width = message[1] as int;
      final height = message[2] as int;
      final stride = message[3] as int;
      final targetSize = message[4] as int;

      final packed = _packLuma(luma, width, height, stride);
      if (packed == null) {
        mainPort.send(null);
        return;
      }
      final quad = DocumentDetector.detect(
        GrayImage(width, height, packed),
        targetSize: targetSize,
      );
      if (quad == null) {
        mainPort.send(null);
        return;
      }
      mainPort.send(<double>[
        quad.tl.x, quad.tl.y,
        quad.tr.x, quad.tr.y,
        quad.br.x, quad.br.y,
        quad.bl.x, quad.bl.y,
      ]);
    } catch (_) {
      // Un fotograma malo no debe tumbar el isolate: se responde vacio.
      mainPort.send(null);
    }
  });
}

/// Extrae el plano de luminancia respetando el relleno de cada fila.
Uint8List? _packLuma(Uint8List src, int w, int h, int stride) {
  if (w <= 0 || h <= 0) return null;
  if (stride <= 0) stride = w;
  if (stride == w && src.length >= w * h) {
    return Uint8List.sublistView(src, 0, w * h);
  }
  if (src.length < stride * (h - 1) + w) return null;
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    out.setRange(y * w, y * w + w, src, y * stride);
  }
  return out;
}
