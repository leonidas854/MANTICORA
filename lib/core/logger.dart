import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum LogLevel {
  debug('D'),
  info('I'),
  warn('W'),
  error('E');

  final String tag;
  const LogLevel(this.tag);

  bool operator >=(LogLevel other) => index >= other.index;
}

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  const LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  String get timeLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '.${three(time.millisecond)}';
  }

  /// Linea compacta para el fichero y para la pantalla de diagnostico.
  String format({bool withStack = false}) {
    final buf = StringBuffer('$timeLabel ${level.tag}/$tag: $message');
    if (error != null) buf.write('\n    causa: $error');
    if (withStack && stackTrace != null) {
      final lines = stackTrace.toString().split('\n');
      // Con las primeras lineas basta para situar el fallo; el resto es ruido.
      for (final l in lines.take(8)) {
        if (l.trim().isEmpty) continue;
        buf.write('\n    $l');
      }
    }
    return buf.toString();
  }
}

/// Registro de eventos de la aplicacion.
///
/// Mantiene los ultimos [_maxEntries] sucesos en memoria (para la pantalla de
/// diagnostico) y los vuelca a un fichero rotativo. Esta pensado para moviles
/// modestos: el volcado a disco es asincrono, agrupado y acotado, y ninguna
/// operacion de registro puede lanzar una excepcion.
class Log {
  Log._();

  static const int _maxEntries = 400;
  static const int _maxFileBytes = 256 * 1024;
  static const Duration _flushInterval = Duration(seconds: 3);

  static final Queue<LogEntry> _entries = Queue<LogEntry>();
  static final List<String> _pending = [];
  static final _listeners = <VoidCallback>[];

  static File? _file;
  static Timer? _flushTimer;
  static bool _flushing = false;

  /// En release no se guarda el nivel `debug`: es ruido y desgasta la memoria
  /// flash de los dispositivos baratos.
  static LogLevel minimumFileLevel = kReleaseMode ? LogLevel.info : LogLevel.debug;

  static List<LogEntry> get entries => List.unmodifiable(_entries);
  static File? get file => _file;

  static void addListener(VoidCallback l) => _listeners.add(l);
  static void removeListener(VoidCallback l) => _listeners.remove(l);

  /// Prepara el fichero de registro. Si falla, la app sigue funcionando y solo
  /// se pierde el historial en disco.
  static Future<void> init(Directory logDir) async {
    try {
      if (!await logDir.exists()) await logDir.create(recursive: true);
      final f = File('${logDir.path}/manticora.log');
      if (await f.exists() && await f.length() > _maxFileBytes) {
        // Rotacion sencilla: se conserva una generacion anterior.
        final old = File('${logDir.path}/manticora.log.1');
        if (await old.exists()) await old.delete();
        await f.rename(old.path);
      }
      _file = File('${logDir.path}/manticora.log');
      _flushTimer ??= Timer.periodic(_flushInterval, (_) => _flush());
      i('Log', 'Registro iniciado en ${_file!.path}');
    } catch (e) {
      _file = null;
      // Sin fichero, pero el registro en memoria sigue activo.
      debugPrint('No se pudo iniciar el registro en disco: $e');
    }
  }

  static void d(String tag, String message) => _add(LogLevel.debug, tag, message);
  static void i(String tag, String message) => _add(LogLevel.info, tag, message);

  static void w(String tag, String message, [Object? error, StackTrace? st]) =>
      _add(LogLevel.warn, tag, message, error, st);

  static void e(String tag, String message, [Object? error, StackTrace? st]) =>
      _add(LogLevel.error, tag, message, error, st);

  static void _add(
    LogLevel level,
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    try {
      final entry = LogEntry(
        time: DateTime.now(),
        level: level,
        tag: tag,
        message: message,
        error: error,
        stackTrace: stackTrace,
      );

      _entries.addLast(entry);
      while (_entries.length > _maxEntries) {
        _entries.removeFirst();
      }

      if (!kReleaseMode) debugPrint(entry.format());

      if (level >= minimumFileLevel && _file != null) {
        _pending.add(entry.format(withStack: level == LogLevel.error));
        // Ante un error se vuelca ya: puede ser lo ultimo antes de un cierre.
        if (level == LogLevel.error) unawaited(_flush());
      }

      for (final l in List.of(_listeners)) {
        try {
          l();
        } catch (_) {}
      }
    } catch (_) {
      // El registro jamas debe tumbar a quien lo llama.
    }
  }

  static Future<void> _flush() async {
    if (_flushing || _pending.isEmpty) return;
    final f = _file;
    if (f == null) return;
    _flushing = true;
    final batch = List.of(_pending);
    _pending.clear();
    try {
      await f.writeAsString(
        '${batch.join('\n')}\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // Disco lleno o sin permiso: se descarta el lote y se sigue.
    } finally {
      _flushing = false;
    }
  }

  /// Vuelca lo pendiente y devuelve el fichero, para compartirlo o revisarlo.
  static Future<File?> exportForSharing() async {
    await _flush();
    final f = _file;
    if (f == null || !await f.exists()) return null;
    return f;
  }

  /// Texto completo del registro en memoria.
  static String dump() =>
      _entries.map((e) => e.format(withStack: e.level == LogLevel.error)).join('\n');

  static Future<void> clear() async {
    _entries.clear();
    _pending.clear();
    try {
      final f = _file;
      if (f != null && await f.exists()) await f.writeAsString('');
    } catch (_) {}
    for (final l in List.of(_listeners)) {
      try {
        l();
      } catch (_) {}
    }
  }

  static Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flush();
  }
}
