import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/device_profile.dart';
import '../../core/error_orchestrator.dart';
import '../../core/logger.dart';
import '../../core/validators.dart';
import '../../imaging/geometry.dart';
import '../../imaging/pipeline.dart';
import '../../widgets/common.dart';
import '../edit/edit_screen.dart';
import '../scan/scan_screen.dart';
import '../scan/scan_session.dart';
import '../viewer/document_screen.dart';

const String _tag = 'Escaneo';

/// Lanza el flujo completo: camara -> edicion -> guardado.
/// Si [appendToDocumentId] no es nulo, las paginas se anaden a ese documento.
Future<void> startScan(
  BuildContext context,
  WidgetRef ref, {
  String? appendToDocumentId,
}) async {
  final session = await Navigator.push<ScanSession>(
    context,
    MaterialPageRoute(builder: (_) => const ScanScreen()),
  );
  if (session == null) return;
  if (session.shots.isEmpty) {
    unawaited(session.dispose());
    return;
  }
  if (!context.mounted) {
    unawaited(session.dispose());
    return;
  }
  await _editAndSave(context, session, appendToDocumentId);
}

/// Importa imagenes de la galeria y entra directo al editor.
Future<void> importImages(
  BuildContext context,
  WidgetRef ref, {
  String? appendToDocumentId,
}) async {
  final files = await ErrorOrchestrator.guard<List<XFile>>(
    'Abriendo la galeria',
    () => ImagePicker().pickMultiImage(),
    tag: _tag,
  );
  if (files == null || files.isEmpty || !context.mounted) return;

  final profile = DeviceProfile.current;
  final selection = files.take(profile.maxPagesPerExport).toList();
  if (selection.length < files.length && context.mounted) {
    showMessage(
      context,
      'Se importaran ${selection.length} imagenes; este dispositivo admite '
      '${profile.maxPagesPerExport} de una vez.',
    );
  }

  final session = ScanSession();
  final built = await runWithProgress<int>(
    context,
    'Preparando imagenes...',
    (setMessage) async {
      var ok = 0;
      for (var i = 0; i < selection.length; i++) {
        setMessage('Analizando ${i + 1} de ${selection.length}...');
        final added = await ErrorOrchestrator.guard(
          'Importando la imagen ${i + 1}',
          () => _addFromFile(session, selection[i]),
          tag: _tag,
          notifyUser: false,
        );
        if (added == true) ok++;
      }
      return ok;
    },
  );

  if (built == null || built == 0) {
    unawaited(session.dispose());
    if (context.mounted) {
      showMessage(context, 'No se ha podido importar ninguna imagen.', error: true);
    }
    return;
  }
  if (built < selection.length && context.mounted) {
    showMessage(context, 'Importadas $built de ${selection.length} imagenes.');
  }
  if (!context.mounted) {
    unawaited(session.dispose());
    return;
  }
  await _editAndSave(context, session, appendToDocumentId);
}

Future<bool> _addFromFile(ScanSession session, XFile file) async {
  final raw = await file.readAsBytes();

  final sizeError = Validators.imageBytes(raw);
  if (sizeError != null) {
    Log.w(_tag, 'Imagen descartada: ${sizeError.message}');
    return false;
  }

  final normalized = await ImagePipeline.normalizeWithSize(raw);
  if (normalized == null) return false;

  final quad = await ImagePipeline.detectInJpeg(normalized.jpeg);
  await session.add(
    normalized.jpeg,
    width: normalized.width,
    height: normalized.height,
    quad: quad ??
        Quad.inset(
          normalized.width.toDouble(),
          normalized.height.toDouble(),
          0.04,
        ),
  );
  return true;
}

Future<void> _editAndSave(
  BuildContext context,
  ScanSession session,
  String? appendToDocumentId,
) async {
  final docId = await Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (_) =>
          EditScreen(session: session, appendToDocumentId: appendToDocumentId),
    ),
  );
  if (docId == null || !context.mounted) return;
  if (appendToDocumentId == null) {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DocumentScreen(documentId: docId)),
    );
  }
}
