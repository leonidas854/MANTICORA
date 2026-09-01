import 'dart:typed_data';

import '../../imaging/filters.dart';
import '../../imaging/geometry.dart';

/// Una captura pendiente de procesar y guardar.
class CapturedShot {
  final Uint8List originalJpeg;

  /// Tamano de la imagen original en pixeles.
  final int width, height;

  Quad? quad;
  int rotation;
  ScanFilter filter;
  Adjustments adjustments;

  /// Vista previa ya procesada (pequena) para mostrar en el editor.
  Uint8List? preview;
  int previewWidth, previewHeight;

  CapturedShot({
    required this.originalJpeg,
    required this.width,
    required this.height,
    this.quad,
    this.rotation = 0,
    this.filter = ScanFilter.magic,
    this.adjustments = Adjustments.none,
    this.preview,
    this.previewWidth = 0,
    this.previewHeight = 0,
  });
}
