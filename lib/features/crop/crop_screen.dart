import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../imaging/geometry.dart';
import '../../imaging/pipeline.dart';
import '../../widgets/common.dart';
import '../../widgets/quad_overlay.dart';

/// Resultado del recorte: cuadrilatero en coordenadas de la imagen ORIGINAL.
class CropResult {
  final Quad quad;
  final int rotation;
  const CropResult(this.quad, this.rotation);
}

/// Ajuste manual de las cuatro esquinas del documento.
class CropScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final int originalWidth, originalHeight;
  final Quad? initialQuad;
  final int initialRotation;

  const CropScreen({
    super.key,
    required this.imageBytes,
    required this.originalWidth,
    required this.originalHeight,
    this.initialQuad,
    this.initialRotation = 0,
  });

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  static const int _previewSide = 1400;

  ui.Image? _preview;
  double _scale = 1; // original / preview
  Quad? _quad;
  int _rotation = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _rotation = widget.initialRotation;
    _load();
  }

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Decodificamos reducido: mover esquinas sobre una imagen de 12 MP
    // gastaria memoria sin ganar precision visual.
    final longest = widget.originalWidth > widget.originalHeight
        ? widget.originalWidth
        : widget.originalHeight;
    final target = longest > _previewSide ? _previewSide : longest;
    final codec = await ui.instantiateImageCodec(
      widget.imageBytes,
      targetWidth: widget.originalWidth >= widget.originalHeight ? target : null,
      targetHeight: widget.originalHeight > widget.originalWidth ? target : null,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    final scale = widget.originalWidth / frame.image.width;
    setState(() {
      _preview = frame.image;
      _scale = scale;
      final q = widget.initialQuad ??
          Quad.inset(widget.originalWidth.toDouble(), widget.originalHeight.toDouble(), 0.05);
      _quad = q.scaled(1 / scale, 1 / scale);
    });
  }

  Future<void> _autoDetect() async {
    setState(() => _busy = true);
    final detected = await ImagePipeline.detectInJpeg(widget.imageBytes);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (detected != null) {
        _quad = detected.scaled(1 / _scale, 1 / _scale);
      }
    });
    if (detected == null && mounted) {
      showMessage(context, 'No se ha detectado ningun documento');
    }
  }

  void _selectAll() {
    final img = _preview;
    if (img == null) return;
    setState(() => _quad = Quad.full(img.width.toDouble(), img.height.toDouble()));
  }

  void _confirm() {
    final q = _quad;
    if (q == null) return;
    Navigator.pop(context, CropResult(q.scaled(_scale, _scale), _rotation));
  }

  @override
  Widget build(BuildContext context) {
    final image = _preview;
    final quad = _quad;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Ajustar bordes'),
        actions: [
          TextButton(
            onPressed: image == null ? null : _confirm,
            child: const Text('Aplicar', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: (image == null || quad == null)
                  ? const Center(child: CircularProgressIndicator())
                  : RotatedBox(
                      quarterTurns: _rotation,
                      child: QuadEditor(
                        image: image,
                        quad: quad,
                        onChanged: (q) => setState(() => _quad = q),
                      ),
                    ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          Container(
            color: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: SafeArea(
              top: false,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _action(Icons.auto_fix_high, 'Detectar', _autoDetect),
                  _action(Icons.crop_free, 'Todo', _selectAll),
                  _action(Icons.rotate_left, 'Girar', () {
                    setState(() => _rotation = (_rotation + 3) % 4);
                  }),
                  _action(Icons.rotate_right, 'Girar', () {
                    setState(() => _rotation = (_rotation + 1) % 4);
                  }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) => InkWell(
        onTap: _busy ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      );
}
