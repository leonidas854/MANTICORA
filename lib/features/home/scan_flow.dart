import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../imaging/geometry.dart';
import '../../imaging/pipeline.dart';
import '../../widgets/common.dart';
import '../edit/edit_screen.dart';
import '../scan/scan_screen.dart';
import '../scan/scan_session.dart';
import '../viewer/document_screen.dart';

/// Lanza el flujo completo: camara -> edicion -> guardado.
/// Si [appendToDocumentId] no es nulo, las paginas se anaden a ese documento.
Future<void> startScan(
  BuildContext context,
  WidgetRef ref, {
  String? appendToDocumentId,
}) async {
  final shots = await Navigator.push<List<CapturedShot>>(
    context,
    MaterialPageRoute(builder: (_) => const ScanScreen()),
  );
  if (shots == null || shots.isEmpty || !context.mounted) return;
  await _editAndSave(context, shots, appendToDocumentId);
}

/// Importa imagenes de la galeria y entra directo al editor.
Future<void> importImages(
  BuildContext context,
  WidgetRef ref, {
  String? appendToDocumentId,
}) async {
  final files = await ImagePicker().pickMultiImage();
  if (files.isEmpty || !context.mounted) return;

  final shots = await runWithProgress<List<CapturedShot>>(
    context,
    'Preparando imagenes...',
    (setMessage) async {
      final out = <CapturedShot>[];
      for (var i = 0; i < files.length; i++) {
        setMessage('Analizando ${i + 1} de ${files.length}...');
        final raw = await files[i].readAsBytes();
        final shot = await _prepareShot(raw);
        if (shot != null) out.add(shot);
      }
      return out;
    },
  );

  if (shots == null || shots.isEmpty || !context.mounted) return;
  await _editAndSave(context, shots, appendToDocumentId);
}

Future<CapturedShot?> _prepareShot(Uint8List raw) async {
  final jpeg = await ImagePipeline.normalizeToJpeg(raw);
  if (jpeg == null) return null;
  final decoded = await decodeImageFromList(jpeg);
  final w = decoded.width, h = decoded.height;
  decoded.dispose();
  final quad = await ImagePipeline.detectInJpeg(jpeg);
  return CapturedShot(
    originalJpeg: jpeg,
    width: w,
    height: h,
    quad: quad ?? Quad.inset(w.toDouble(), h.toDouble(), 0.04),
  );
}

Future<void> _editAndSave(
  BuildContext context,
  List<CapturedShot> shots,
  String? appendToDocumentId,
) async {
  final docId = await Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (_) => EditScreen(shots: shots, appendToDocumentId: appendToDocumentId),
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
