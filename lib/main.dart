import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'app.dart';
import 'core/device_profile.dart';
import 'core/error_orchestrator.dart';
import 'core/logger.dart';
import 'data/repositories/storage_service.dart';

void main() {
  // Toda la aplicacion corre dentro de una zona vigilada: cualquier error
  // asincrono que nadie recoja acaba en el registro en vez de morir en silencio.
  ErrorOrchestrator.runGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    ErrorOrchestrator.install();

    // El arranque nunca debe impedir que la app se abra: cada paso va
    // protegido y, si falla, se sigue con valores por defecto.
    await _bootstrap();

    runApp(const ProviderScope(child: ManticoraApp()));
  });
}

Future<void> _bootstrap() async {
  final started = DateTime.now();

  // 1. Registro en disco. Si no hay sitio, queda solo el registro en memoria.
  await ErrorOrchestrator.guard(
    'Iniciando el registro',
    () async {
      final root = await StorageService.instance.root;
      await Log.init(Directory(p.join(root.path, 'logs')));
    },
    tag: 'Arranque',
    notifyUser: false,
  );

  Log.i('Arranque', 'Manticora iniciando');

  // 2. Gama del dispositivo: de aqui salen resoluciones y calidades.
  await ErrorOrchestrator.guard(
    'Detectando la gama del dispositivo',
    DeviceProfile.detect,
    tag: 'Arranque',
    notifyUser: false,
  );

  // 3. Cache de imagenes acotada a la gama del equipo.
  ErrorOrchestrator.guardSync(
    'Ajustando la cache de imagenes',
    () {
      final profile = DeviceProfile.current;
      PaintingBinding.instance.imageCache
        ..maximumSizeBytes = profile.imageCacheBytes
        ..maximumSize = profile.imageCacheCount;
      Log.i(
        'Arranque',
        'Cache de imagenes: ${profile.imageCacheBytes >> 20} MB / '
            '${profile.imageCacheCount} imagenes',
      );
    },
    tag: 'Arranque',
  );

  // 4. Orientacion. En tablets antiguas puede fallar; no es critico.
  await ErrorOrchestrator.guard(
    'Fijando la orientacion',
    () => SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]),
    tag: 'Arranque',
    notifyUser: false,
  );

  ErrorOrchestrator.guardSync(
    'Ajustando la barra del sistema',
    () => SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(systemNavigationBarColor: Colors.transparent),
    ),
    tag: 'Arranque',
  );

  // 5. Limpieza de temporales de sesiones anteriores, en segundo plano.
  unawaited(ErrorOrchestrator.guard(
    'Limpiando temporales',
    StorageService.instance.clearTmp,
    tag: 'Arranque',
    notifyUser: false,
  ));

  final ms = DateTime.now().difference(started).inMilliseconds;
  Log.i('Arranque', 'Listo en ${ms}ms · ${DeviceProfile.current}');
}
