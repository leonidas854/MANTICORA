import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/error_orchestrator.dart';
import '../../core/logger.dart';
import '../../core/settings.dart';

/// Envuelve la aplicacion y exige autenticacion biometrica (o PIN del
/// dispositivo) cuando el bloqueo esta activado en los ajustes.
///
/// Se vuelve a bloquear al mandar la app a segundo plano, que es lo que se
/// espera de una carpeta con documentos personales.
class LockGate extends ConsumerStatefulWidget {
  final Widget child;
  const LockGate({super.key, required this.child});

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> with WidgetsBindingObserver {
  final _auth = LocalAuthentication();
  bool _unlocked = false;
  bool _authenticating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al salir de la app se vuelve a exigir la huella.
    if (state == AppLifecycleState.paused && ref.read(settingsProvider).appLock) {
      setState(() => _unlocked = false);
    }
  }

  Future<void> _authenticate() async {
    if (_authenticating) return;
    setState(() {
      _authenticating = true;
      _error = null;
    });
    final ok = await ErrorOrchestrator.guard<bool>(
      'Desbloqueando la aplicacion',
      () => _auth.authenticate(
        localizedReason: 'Desbloquea Manticora para ver tus documentos',
        // Se admite tambien el PIN o patron del sistema, no solo la huella:
        // muchos moviles basicos no tienen lector de huella.
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      ),
      tag: 'Bloqueo',
      notifyUser: false,
    );

    if (!mounted) return;
    setState(() {
      _authenticating = false;
      _unlocked = ok == true;
      if (ok == null) {
        _error = 'No se ha podido usar el bloqueo del dispositivo. '
            'Puedes desactivarlo en Ajustes.';
      } else if (!ok) {
        _error = 'No se pudo verificar tu identidad.';
      } else {
        _error = null;
        Log.i('Bloqueo', 'Aplicacion desbloqueada');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final locked = ref.watch(settingsProvider).appLock;
    if (!locked || _unlocked) return widget.child;

    // El primer intento se lanza solo, sin bloquear el build.
    if (!_authenticating && _error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
    }

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.lock_outline, size: 48, color: scheme.primary),
              ),
              const SizedBox(height: 24),
              Text(
                'Manticora esta bloqueada',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error),
                ),
              ],
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _authenticating ? null : _authenticate,
                icon: const Icon(Icons.fingerprint),
                label: Text(_authenticating ? 'Verificando...' : 'Desbloquear'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
