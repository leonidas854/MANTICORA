import 'dart:async';

import 'package:flutter/material.dart';

import '../core/error_orchestrator.dart';
import '../core/failure.dart';
import '../core/logger.dart';

/// Ejecuta una tarea larga mostrando un dialogo de progreso.
///
/// Absorbe cualquier excepcion: la registra, avisa a la persona con un mensaje
/// comprensible y devuelve `null`. Asi ninguna pantalla se queda con el
/// dialogo colgado ni revienta por un fallo de la tarea.
Future<T?> runWithProgress<T>(
  BuildContext context,
  String message,
  Future<T> Function(void Function(String) setMessage) task, {
  String tag = 'Tarea',
  bool notifyOnError = true,
  Duration showAfter = const Duration(milliseconds: 140),
}) async {
  final notifier = ValueNotifier<String>(message);

  BuildContext? dialogContext;
  Future<void>? dialogClosed;
  var finished = false;

  // El dialogo solo aparece si la tarea tarda de verdad. Asi se evita el
  // parpadeo en las operaciones rapidas y, sobre todo, la carrera de mostrar
  // un dialogo para algo que ya termino.
  final timer = Timer(showAfter, () {
    if (finished || !context.mounted) return;
    dialogClosed = showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) {
        dialogContext = ctx;
        return PopScope(
          canPop: false,
          child: Dialog(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: ValueListenableBuilder<String>(
                      valueListenable: notifier,
                      builder: (_, value, _) => Text(value),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  });

  try {
    return await task((m) {
      if (!finished) notifier.value = m;
    });
  } catch (error, stack) {
    final failure = AppFailure.from(error, stack, message);
    Log.e(tag, 'Fallo la tarea "$message"', error, stack);
    if (notifyOnError) ErrorOrchestrator.notify(failure);
    return null;
  } finally {
    finished = true;
    timer.cancel();

    final ctx = dialogContext;
    if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
    dialogContext = null;

    // El notificador debe seguir vivo mientras el dialogo se desmonta: si se
    // libera antes, el ValueListenableBuilder lo usaria ya liberado.
    if (dialogClosed != null) await dialogClosed;
    notifier.dispose();
  }
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Aceptar',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                )
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String label = '',
  String confirmLabel = 'Guardar',
  bool obscure = false,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: obscure,
        decoration: InputDecoration(labelText: label.isEmpty ? null : label),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = result?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

void showMessage(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
}

/// Estado vacio con icono, titulo y accion opcional.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 44, color: scheme.primary),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[i]}';
}
