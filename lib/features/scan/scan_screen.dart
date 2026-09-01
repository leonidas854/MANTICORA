import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../imaging/geometry.dart';
import '../../imaging/pipeline.dart';
import '../../widgets/common.dart';
import '../../widgets/quad_overlay.dart';
import 'scan_session.dart';

/// Camara con deteccion de bordes en vivo y captura por lotes.
class ScanScreen extends StatefulWidget {
  /// Si es true, al terminar se devuelve la lista de capturas.
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  Future<void>? _initFuture;

  final List<CapturedShot> _shots = [];

  Quad? _liveQuad;
  Size _lumaSize = Size.zero;
  bool _detecting = false;
  DateTime _lastDetect = DateTime.fromMillisecondsSinceEpoch(0);

  bool _busy = false;
  bool _autoCapture = false;
  int _stableFrames = 0;
  FlashMode _flash = FlashMode.off;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initFuture = _setupCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      c.dispose();
    } else if (state == AppLifecycleState.resumed) {
      setState(() => _initFuture = _setupCamera());
    }
  }

  Future<void> _setupCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;
      final back = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      await controller.setFlashMode(_flash);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      await controller.startImageStream(_onFrame);
    } catch (e) {
      if (mounted) showMessage(context, 'No se pudo abrir la camara: $e', error: true);
    }
  }

  // ------------------------------------------------------- deteccion en vivo

  void _onFrame(CameraImage image) {
    if (_detecting || _busy || !mounted) return;
    // Limitamos a ~5 analisis por segundo: mas no aporta y calienta el movil.
    final now = DateTime.now();
    if (now.difference(_lastDetect).inMilliseconds < 200) return;
    _lastDetect = now;
    _detecting = true;

    final plane = image.planes.first;
    final bytes = Uint8List.fromList(plane.bytes);
    final w = image.width, h = image.height;
    final stride = plane.bytesPerRow;

    ImagePipeline.detectInLuma(bytes, w, h, stride).then((quad) {
      if (!mounted) {
        _detecting = false;
        return;
      }
      final rotated = _rotateForPreview(quad, w, h);
      final stable = quad != null && _liveQuad != null && _similar(_liveQuad!, rotated!);
      setState(() {
        _liveQuad = rotated;
        _lumaSize = _previewSourceSize(w, h);
        _stableFrames = stable ? _stableFrames + 1 : 0;
      });
      _detecting = false;
      if (_autoCapture && _stableFrames >= 4 && !_busy) {
        _stableFrames = 0;
        _capture();
      }
    }).catchError((_) {
      _detecting = false;
    });
  }

  int get _sensorOrientation => _controller?.description.sensorOrientation ?? 90;

  Size _previewSourceSize(int w, int h) =>
      (_sensorOrientation % 180 == 90) ? Size(h.toDouble(), w.toDouble()) : Size(w.toDouble(), h.toDouble());

  /// Los fotogramas llegan en la orientacion del sensor; la vista previa ya
  /// esta girada, asi que giramos tambien el cuadrilatero detectado.
  Quad? _rotateForPreview(Quad? q, int w, int h) {
    if (q == null) return null;
    final deg = ((_sensorOrientation % 360) + 360) % 360;
    Pt map(Pt p) => switch (deg) {
          90 => Pt(h - p.y, p.x),
          180 => Pt(w - p.x, h - p.y),
          270 => Pt(p.y, w - p.x),
          _ => p,
        };
    final pts = q.points.map(map).toList();
    return Quad(pts[0], pts[1], pts[2], pts[3]);
  }

  bool _similar(Quad a, Quad b) {
    for (var i = 0; i < 4; i++) {
      if (a.points[i].distanceTo(b.points[i]) > 24) return false;
    }
    return true;
  }

  // ------------------------------------------------------------- acciones

  Future<void> _capture() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _busy) return;
    setState(() => _busy = true);
    try {
      // Algunos dispositivos no permiten disparar con el flujo activo.
      if (c.value.isStreamingImages) await c.stopImageStream();
      final file = await c.takePicture();
      final bytes = await file.readAsBytes();
      await _addShot(bytes);
      if (mounted && c.value.isInitialized) await c.startImageStream(_onFrame);
    } catch (e) {
      if (mounted) showMessage(context, 'Error al capturar: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addShot(Uint8List jpeg) async {
    final normalized = await ImagePipeline.normalizeToJpeg(jpeg) ?? jpeg;
    final size = await _decodeSize(normalized);
    final quad = await ImagePipeline.detectInJpeg(normalized);
    if (!mounted) return;
    setState(() {
      _shots.add(CapturedShot(
        originalJpeg: normalized,
        width: size.width.round(),
        height: size.height.round(),
        quad: quad ?? Quad.inset(size.width, size.height, 0.04),
      ));
    });
  }

  Future<Size> _decodeSize(Uint8List jpeg) async {
    final codec = await ui.instantiateImageCodec(jpeg);
    final frame = await codec.getNextFrame();
    final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    frame.image.dispose();
    codec.dispose();
    return size;
  }

  Future<void> _pickFromGallery() async {
    final picker = ImagePicker();
    final files = await picker.pickMultiImage();
    if (files.isEmpty) return;
    setState(() => _busy = true);
    try {
      for (final f in files) {
        await _addShot(await f.readAsBytes());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleFlash() async {
    final c = _controller;
    if (c == null) return;
    final next = switch (_flash) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.torch,
      _ => FlashMode.off,
    };
    try {
      await c.setFlashMode(next);
      setState(() => _flash = next);
    } catch (_) {}
  }

  void _finish() {
    if (_shots.isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, _shots);
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null && controller.value.isInitialized)
            FutureBuilder(
              future: _initFuture,
              builder: (context, _) => _CameraLayer(
                controller: controller,
                quad: _liveQuad,
                sourceSize: _lumaSize,
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),
          _topBar(),
          _bottomBar(),
          if (_busy)
            Container(
              color: Colors.black38,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _topBar() => SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Flash',
                  icon: Icon(
                    switch (_flash) {
                      FlashMode.off => Icons.flash_off,
                      FlashMode.auto => Icons.flash_auto,
                      _ => Icons.flash_on,
                    },
                    color: Colors.white,
                  ),
                  onPressed: _toggleFlash,
                ),
                IconButton(
                  tooltip: 'Captura automatica',
                  icon: Icon(
                    _autoCapture ? Icons.motion_photos_auto : Icons.motion_photos_off,
                    color: _autoCapture ? Theme.of(context).colorScheme.primary : Colors.white,
                  ),
                  onPressed: () => setState(() => _autoCapture = !_autoCapture),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _bottomBar() => Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black.withValues(alpha: 0.75)],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_shots.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: SizedBox(
                    height: 58,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _shots.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, i) => ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          _shots[i].originalJpeg,
                          width: 44,
                          height: 58,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton.filledTonal(
                    iconSize: 26,
                    onPressed: _busy ? null : _pickFromGallery,
                    icon: const Icon(Icons.photo_library_outlined),
                  ),
                  GestureDetector(
                    onTap: _busy ? null : _capture,
                    child: Container(
                      width: 74,
                      height: 74,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                      ),
                      child: Container(
                        margin: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  Badge(
                    isLabelVisible: _shots.isNotEmpty,
                    label: Text('${_shots.length}'),
                    child: FilledButton(
                      onPressed: _shots.isEmpty ? null : _finish,
                      child: const Text('Listo'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

/// Vista previa a pantalla completa con el contorno detectado encima.
class _CameraLayer extends StatelessWidget {
  final CameraController controller;
  final Quad? quad;
  final Size sourceSize;

  const _CameraLayer({
    required this.controller,
    required this.quad,
    required this.sourceSize,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final preview = controller.value.previewSize;
    // previewSize viene en orientacion horizontal; en vertical hay que girarlo.
    final ratio = preview == null ? 1.0 : preview.height / preview.width;

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: size.width,
            height: size.width / ratio,
            child: CameraPreview(controller),
          ),
        ),
        if (quad != null)
          CustomPaint(
            painter: QuadPainter(quad: quad, sourceSize: sourceSize, cover: true),
          ),
      ],
    );
  }
}
