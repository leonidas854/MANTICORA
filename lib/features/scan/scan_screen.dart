import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/device_profile.dart';
import '../../core/error_orchestrator.dart';
import '../../core/failure.dart';
import '../../core/logger.dart';
import '../../core/validators.dart';
import '../../imaging/detector_worker.dart';
import '../../imaging/geometry.dart';
import '../../imaging/pipeline.dart';
import '../../widgets/common.dart';
import '../../widgets/quad_overlay.dart';
import 'scan_session.dart';

/// Camara con deteccion de bordes en vivo y captura por lotes.
///
/// Devuelve la [ScanSession] con las capturas, o `null` si se cancela.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  static const String _tag = 'Camara';

  final ScanSession _session = ScanSession();
  final DeviceProfile _profile = DeviceProfile.current;

  CameraController? _controller;
  bool _initializing = true;
  AppFailure? _cameraFailure;

  Quad? _liveQuad;
  Size _previewSourceSize = Size.zero;
  DateTime _lastDetect = DateTime.fromMillisecondsSinceEpoch(0);

  bool _busy = false;
  bool _autoCapture = false;
  int _stableFrames = 0;
  FlashMode _flash = FlashMode.off;
  bool _handedOff = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(DetectorWorker.instance.start());
    unawaited(_setupCamera());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_teardownCamera());
    unawaited(DetectorWorker.instance.stop());
    // Si la pantalla se cierra sin entregar la tanda, se borran los temporales.
    if (!_handedOff) unawaited(_session.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      unawaited(_teardownCamera());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_setupCamera());
    }
  }

  // -------------------------------------------------------------- la camara

  Future<void> _setupCamera() async {
    if (!mounted) return;
    setState(() {
      _initializing = true;
      _cameraFailure = null;
    });

    final result = await ErrorOrchestrator.attempt<CameraController>(
      'Abriendo la camara',
      () async {
        final cameras = await availableCameras();
        if (cameras.isEmpty) {
          throw const AppFailure(
            kind: FailureKind.camera,
            message: 'Este dispositivo no tiene ninguna camara disponible.',
            retryable: false,
          );
        }
        final back = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        );
        final controller = CameraController(
          back,
          _presetFor(_profile.cameraQuality),
          enableAudio: false,
          imageFormatGroup: ImageFormatGroup.yuv420,
        );
        await controller.initialize().timeout(const Duration(seconds: 12));
        return controller;
      },
      tag: _tag,
      notifyUser: false,
    );

    await result.fold(
      (controller) async {
        if (!mounted) {
          await controller.dispose();
          return;
        }
        setState(() {
          _controller = controller;
          _initializing = false;
        });
        // Ni el flash ni el flujo de imagenes son imprescindibles: si fallan,
        // la camara sigue sirviendo para hacer fotos.
        await ErrorOrchestrator.guard(
          'Configurando el flash',
          () => controller.setFlashMode(_flash),
          tag: _tag,
          notifyUser: false,
        );
        await _startStream();
        Log.i(_tag, 'Camara lista (${_profile.cameraQuality.name})');
      },
      (failure) async {
        if (!mounted) return;
        setState(() {
          _initializing = false;
          // Sin plugin de camara (escritorio) el mensaje generico despista:
          // aqui lo util es que se puede seguir importando de la galeria.
          _cameraFailure = failure.kind == FailureKind.unsupported
              ? const AppFailure(
                  kind: FailureKind.unsupported,
                  message: 'Esta plataforma no tiene camara disponible. '
                      'Puedes importar imagenes desde la galeria.',
                  retryable: false,
                )
              : failure;
        });
      },
    );
  }

  ResolutionPreset _presetFor(CameraQuality quality) => switch (quality) {
        CameraQuality.medium => ResolutionPreset.medium,
        CameraQuality.high => ResolutionPreset.high,
        CameraQuality.veryHigh => ResolutionPreset.veryHigh,
      };

  Future<void> _startStream() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || c.value.isStreamingImages) return;
    await ErrorOrchestrator.guard(
      'Iniciando la vista previa',
      () => c.startImageStream(_onFrame),
      tag: _tag,
      notifyUser: false,
      onFailure: (_) => Log.w(_tag, 'Sin deteccion en vivo: el flujo no arranco'),
    );
  }

  Future<void> _teardownCamera() async {
    final c = _controller;
    _controller = null;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  // ------------------------------------------------------- deteccion en vivo

  void _onFrame(CameraImage image) {
    if (!mounted || _busy) return;
    // Cadencia segun la gama: en un movil basico analizar menos evita que la
    // vista previa se atasque y que el telefono se caliente.
    final now = DateTime.now();
    if (now.difference(_lastDetect) < _profile.liveDetectInterval) return;
    if (DetectorWorker.instance.isBusy) return;
    _lastDetect = now;

    try {
      if (image.planes.isEmpty) return;
      final plane = image.planes.first;
      final luma = Uint8List.fromList(plane.bytes);
      final w = image.width, h = image.height;
      if (w <= 0 || h <= 0) return;

      DetectorWorker.instance
          .detect(luma, w, h, plane.bytesPerRow,
              targetSize: _profile.detectorWorkSize)
          .then(_onQuadDetected)
          .catchError((Object e, StackTrace st) {
        Log.w(_tag, 'Fallo analizando un fotograma', e, st);
        return null;
      });
    } catch (e, st) {
      Log.w(_tag, 'Fotograma descartado', e, st);
    }
  }

  void _onQuadDetected(Quad? raw) {
    if (!mounted) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final preview = controller.value.previewSize;
    final sourceW = preview?.height ?? 0;
    final sourceH = preview?.width ?? 0;

    final rotated = _rotateForPreview(raw);
    final stable = rotated != null && _liveQuad != null && _similar(_liveQuad!, rotated);

    setState(() {
      _liveQuad = rotated;
      if (sourceW > 0 && sourceH > 0) {
        _previewSourceSize = _sensorOrientation % 180 == 90
            ? Size(sourceW, sourceH)
            : Size(sourceH, sourceW);
      }
      _stableFrames = stable ? _stableFrames + 1 : 0;
    });

    if (_autoCapture && _stableFrames >= 4 && !_busy) {
      _stableFrames = 0;
      unawaited(_capture());
    }
  }

  int get _sensorOrientation => _controller?.description.sensorOrientation ?? 90;

  /// Los fotogramas llegan en la orientacion del sensor; la vista previa ya
  /// esta girada, asi que giramos tambien el cuadrilatero detectado.
  Quad? _rotateForPreview(Quad? q) {
    if (q == null) return null;
    final controller = _controller;
    final preview = controller?.value.previewSize;
    if (preview == null) return q;
    // previewSize viene en horizontal: ancho = height, alto = width.
    final w = preview.height, h = preview.width;
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
    if (_session.isFull) {
      showMessage(
        context,
        'Maximo ${_session.maxShots} paginas por tanda. Guarda estas y sigue en otro documento.',
        error: true,
      );
      return;
    }

    setState(() => _busy = true);
    try {
      // Algunos dispositivos no permiten disparar con el flujo activo.
      if (c.value.isStreamingImages) {
        await ErrorOrchestrator.guard('Pausando la vista previa',
            c.stopImageStream, tag: _tag, notifyUser: false);
      }

      final shot = await ErrorOrchestrator.guard<XFile>(
        'Tomando la foto',
        () => c.takePicture().timeout(const Duration(seconds: 20)),
        tag: _tag,
      );
      if (shot == null) return;

      final bytes = await ErrorOrchestrator.guard<Uint8List>(
        'Leyendo la foto',
        shot.readAsBytes,
        tag: _tag,
      );
      if (bytes == null) return;

      await _addShot(bytes);
      // El fichero que deja el plugin ya no hace falta.
      unawaited(_deleteQuietly(shot.path));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _startStream();
      }
    }
  }

  /// Normaliza, detecta bordes y guarda la captura en disco.
  Future<void> _addShot(Uint8List raw) async {
    final validation = Validators.imageBytes(raw);
    if (validation != null) {
      ErrorOrchestrator.notify(validation);
      return;
    }

    final added = await ErrorOrchestrator.guard(
      'Preparando la captura',
      () async {
        final normalized = await ImagePipeline.normalizeWithSize(raw);
        if (normalized == null) {
          throw const AppFailure.validation(
            'No se ha podido procesar la foto. Repitela, por favor.',
          );
        }
        final quad = await ImagePipeline.detectInJpeg(normalized.jpeg);
        return _session.add(
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
      },
      tag: _tag,
    );

    if (added != null && mounted) setState(() {});
  }

  Future<void> _pickFromGallery() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final files = await ErrorOrchestrator.guard<List<XFile>>(
        'Abriendo la galeria',
        () => ImagePicker().pickMultiImage(),
        tag: _tag,
      );
      if (files == null || files.isEmpty) return;

      final allowed = _session.maxShots - _session.shots.length;
      final selection = files.take(allowed).toList();
      if (selection.length < files.length && mounted) {
        showMessage(context,
            'Solo caben ${selection.length} imagenes mas en esta tanda.');
      }

      for (final f in selection) {
        if (!mounted) break;
        final bytes = await ErrorOrchestrator.guard<Uint8List>(
          'Leyendo una imagen de la galeria',
          f.readAsBytes,
          tag: _tag,
          notifyUser: false,
        );
        if (bytes != null) await _addShot(bytes);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleFlash() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final next = switch (_flash) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.torch,
      _ => FlashMode.off,
    };
    final ok = await ErrorOrchestrator.guard<bool>(
      'Cambiando el flash',
      () async {
        await c.setFlashMode(next);
        return true;
      },
      tag: _tag,
      notifyUser: false,
    );
    if (ok == true && mounted) setState(() => _flash = next);
  }

  Future<void> _removeLast() async {
    if (_session.shots.isEmpty) return;
    await _session.removeAt(_session.shots.length - 1);
    if (mounted) setState(() {});
  }

  void _finish() {
    if (_session.shots.isEmpty) {
      Navigator.pop(context);
      return;
    }
    _handedOff = true; // los temporales pasan a ser del editor
    Navigator.pop(context, _session);
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _session.shots.isEmpty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await confirm(
          context,
          title: 'Descartar la tanda',
          message: 'Se perderan las ${_session.shots.length} paginas capturadas.',
          confirmLabel: 'Descartar',
          destructive: true,
        );
        if (discard && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _cameraLayer(),
            _topBar(),
            _bottomBar(),
            if (_busy)
              const ColoredBox(
                color: Colors.black38,
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _cameraLayer() {
    if (_initializing) {
      return const Center(child: CircularProgressIndicator());
    }

    final failure = _cameraFailure;
    if (failure != null) {
      return _cameraErrorState(failure);
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final size = MediaQuery.sizeOf(context);
    final preview = controller.value.previewSize;
    final ratio = (preview == null || preview.width <= 0)
        ? 1.0
        : preview.height / preview.width;

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: size.width,
            height: size.width / (ratio == 0 ? 1 : ratio),
            child: CameraPreview(controller),
          ),
        ),
        if (_liveQuad != null && _previewSourceSize != Size.zero)
          CustomPaint(
            painter: QuadPainter(
              quad: _liveQuad,
              sourceSize: _previewSourceSize,
              cover: true,
            ),
          ),
      ],
    );
  }

  /// Si la camara no arranca, la pantalla sigue siendo util: se puede importar.
  Widget _cameraErrorState(AppFailure failure) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined,
                  size: 48, color: Colors.white54),
              const SizedBox(height: 16),
              Text(
                failure.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  if (failure.retryable)
                    FilledButton.icon(
                      onPressed: _setupCamera,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reintentar'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _pickFromGallery,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Usar la galeria'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _topBar() => SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.maybePop(context),
                ),
                const Spacer(),
                if (_controller != null) ...[
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
                      _autoCapture
                          ? Icons.motion_photos_auto
                          : Icons.motion_photos_off,
                      color: _autoCapture
                          ? Theme.of(context).colorScheme.primary
                          : Colors.white,
                    ),
                    onPressed: () => setState(() => _autoCapture = !_autoCapture),
                  ),
                ],
              ],
            ),
          ),
        ),
      );

  Widget _bottomBar() {
    final shots = _session.shots;
    return Align(
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
            if (shots.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: SizedBox(
                  height: 58,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    itemCount: shots.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final shot = shots[shots.length - 1 - i];
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          shot.file,
                          width: 44,
                          height: 58,
                          fit: BoxFit.cover,
                          cacheWidth: 96,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => const SizedBox(
                            width: 44,
                            height: 58,
                            child: ColoredBox(color: Colors.white12),
                          ),
                        ),
                      );
                    },
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
                  onTap: (_busy || _controller == null) ? null : _capture,
                  onLongPress: shots.isEmpty ? null : _removeLast,
                  child: Opacity(
                    opacity: _controller == null ? 0.4 : 1,
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
                ),
                Badge(
                  isLabelVisible: shots.isNotEmpty,
                  label: Text('${shots.length}'),
                  child: FilledButton(
                    onPressed: shots.isEmpty ? null : _finish,
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
}

/// Borrado tolerante: el temporal que deja el plugin ya no hace falta y su
/// borrado nunca debe interrumpir el flujo de captura.
Future<void> _deleteQuietly(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}
