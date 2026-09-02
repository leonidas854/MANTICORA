import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/error_orchestrator.dart';
import 'core/logger.dart';
import 'core/settings.dart';
import 'core/theme.dart';
import 'features/home/home_screen.dart';
import 'features/lock/lock_gate.dart';

class ManticoraApp extends ConsumerStatefulWidget {
  const ManticoraApp({super.key});

  @override
  ConsumerState<ManticoraApp> createState() => _ManticoraAppState();
}

class _ManticoraAppState extends ConsumerState<ManticoraApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(Log.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Al irse a segundo plano se vuelca el registro pendiente: si el sistema
      // mata el proceso, no se pierde la pista de lo ultimo que paso.
      unawaited(Log.exportForSharing());
    }
  }

  @override
  void didHaveMemoryPressure() {
    // Aviso del sistema de que va justo de memoria: se sueltan las imagenes
    // cacheadas antes de que sea el sistema quien cierre la aplicacion.
    Log.w('Memoria', 'El sistema avisa de falta de memoria; se vacia la cache');
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp(
      title: 'Manticora',
      debugShowCheckedModeBanner: false,
      // Claves globales: permiten al orquestador avisar de un error desde
      // cualquier punto, incluso fuera del arbol de widgets activo.
      scaffoldMessengerKey: ErrorOrchestrator.messengerKey,
      navigatorKey: ErrorOrchestrator.navigatorKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: settings.themeMode,
      locale: const Locale('es'),
      supportedLocales: const [Locale('es'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Sustituye la pantalla roja de error por algo que no asuste y que no
      // deje la app inservible si un widget concreto falla.
      builder: (context, child) {
        ErrorWidget.builder = (details) => _FriendlyErrorWidget(details: details);
        return MediaQuery.withClampedTextScaling(
          // Evita que una escala de texto enorme rompa las rejillas.
          minScaleFactor: 0.8,
          maxScaleFactor: 1.4,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const LockGate(child: HomeScreen()),
    );
  }
}

/// Lo que se ve si un widget concreto revienta durante la construccion.
class _FriendlyErrorWidget extends StatelessWidget {
  final FlutterErrorDetails details;
  const _FriendlyErrorWidget({required this.details});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1D24),
      padding: const EdgeInsets.all(16),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 32),
          const SizedBox(height: 8),
          const Text(
            'No se ha podido mostrar esta parte',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
