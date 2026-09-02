import 'dart:io';
import 'dart:math' as math;

import 'logger.dart';

/// Gama del dispositivo. Determina cuanta memoria y CPU nos podemos permitir.
enum DeviceTier {
  low('Gama basica'),
  mid('Gama media'),
  high('Gama alta');

  final String label;
  const DeviceTier(this.label);
}

/// Calidad de captura pedida a la camara, sin acoplar este fichero al plugin.
enum CameraQuality { medium, high, veryHigh }

/// Perfil de rendimiento del dispositivo.
///
/// Todo el procesamiento de imagen consulta este perfil antes de decidir
/// resoluciones, calidades y cadencias. El objetivo es que la app siga siendo
/// usable en un movil de 2 GB de RAM sin castigar a los que tienen 12 GB.
class DeviceProfile {
  final DeviceTier tier;
  final int totalRamMb;
  final int cores;

  const DeviceProfile({
    required this.tier,
    required this.totalRamMb,
    required this.cores,
  });

  /// Perfil prudente que se usa mientras se detecta el real.
  static const DeviceProfile fallback =
      DeviceProfile(tier: DeviceTier.mid, totalRamMb: 4096, cores: 4);

  static DeviceProfile _current = fallback;
  static bool _detected = false;

  static DeviceProfile get current => _current;

  /// Detecta la gama una sola vez, al arrancar. Nunca lanza excepciones.
  static Future<DeviceProfile> detect() async {
    if (_detected) return _current;
    _detected = true;

    var ramMb = 0;
    var cores = 1;

    try {
      cores = math.max(1, Platform.numberOfProcessors);
    } catch (_) {
      cores = 4;
    }

    try {
      // En Android /proc/meminfo es legible sin permisos.
      final file = File('/proc/meminfo');
      if (await file.exists()) {
        final content = await file.readAsString();
        final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(content);
        if (match != null) {
          ramMb = (int.tryParse(match.group(1)!) ?? 0) ~/ 1024;
        }
      }
    } catch (_) {
      ramMb = 0;
    }

    final DeviceTier tier;
    if (ramMb <= 0) {
      // Sin dato fiable de memoria, decidimos por nucleos y tiramos a lo seguro.
      tier = cores <= 4 ? DeviceTier.low : DeviceTier.mid;
    } else if (ramMb < 3072 || cores <= 4) {
      tier = DeviceTier.low;
    } else if (ramMb < 6144) {
      tier = DeviceTier.mid;
    } else {
      tier = DeviceTier.high;
    }

    _current = DeviceProfile(tier: tier, totalRamMb: ramMb, cores: cores);
    Log.i(
      'Dispositivo',
      'Gama detectada: ${tier.label} (RAM ${ramMb}MB, $cores nucleos). '
          'Lado maximo ${_current.maxImageSide}px, calidad JPEG '
          '${_current.jpegQuality}, deteccion en vivo cada '
          '${_current.liveDetectInterval.inMilliseconds}ms',
    );
    return _current;
  }

  /// Solo para pruebas: fija un perfil concreto.
  static void overrideForTesting(DeviceProfile profile) {
    _current = profile;
    _detected = true;
  }

  // ------------------------------------------------------------ parametros

  /// Lado mayor de la imagen procesada que se guarda en disco.
  /// 1600 px siguen dando ~200 ppp en A4, suficiente para imprimir y para OCR.
  int get maxImageSide => switch (tier) {
        DeviceTier.low => 1600,
        DeviceTier.mid => 2100,
        DeviceTier.high => 2600,
      };

  int get jpegQuality => switch (tier) {
        DeviceTier.low => 80,
        DeviceTier.mid => 86,
        DeviceTier.high => 90,
      };

  /// Techo de megapixeles al decodificar. Por encima se reduce antes de operar,
  /// que es lo que evita los cierres por falta de memoria en gama baja.
  int get maxDecodeMegapixels => switch (tier) {
        DeviceTier.low => 8,
        DeviceTier.mid => 16,
        DeviceTier.high => 32,
      };

  /// Lado de trabajo del detector de bordes.
  int get detectorWorkSize => switch (tier) {
        DeviceTier.low => 288,
        DeviceTier.mid => 384,
        DeviceTier.high => 448,
      };

  /// Cada cuanto se analiza un fotograma de la camara.
  Duration get liveDetectInterval => switch (tier) {
        DeviceTier.low => const Duration(milliseconds: 450),
        DeviceTier.mid => const Duration(milliseconds: 280),
        DeviceTier.high => const Duration(milliseconds: 180),
      };

  CameraQuality get cameraQuality => switch (tier) {
        DeviceTier.low => CameraQuality.high,
        DeviceTier.mid => CameraQuality.veryHigh,
        DeviceTier.high => CameraQuality.veryHigh,
      };

  /// Ancho al que se decodifican las miniaturas en las rejillas.
  int get thumbnailCacheWidth => switch (tier) {
        DeviceTier.low => 200,
        DeviceTier.mid => 280,
        DeviceTier.high => 360,
      };

  /// Lado de la vista previa en el editor de filtros.
  int get previewSide => switch (tier) {
        DeviceTier.low => 700,
        DeviceTier.mid => 900,
        DeviceTier.high => 1100,
      };

  /// Lado de la imagen que se carga en el editor de esquinas.
  int get cropPreviewSide => switch (tier) {
        DeviceTier.low => 1000,
        DeviceTier.mid => 1400,
        DeviceTier.high => 1600,
      };

  /// Cuantas paginas se procesan antes de ceder el hilo y dejar respirar a la
  /// interfaz y al recolector de basura.
  int get pagesBeforeYield => switch (tier) {
        DeviceTier.low => 1,
        DeviceTier.mid => 2,
        DeviceTier.high => 4,
      };

  /// En gama baja el OCR automatico multiplica el tiempo de guardado, asi que
  /// no se ofrece activado por defecto.
  bool get autoOcrRecommended => tier != DeviceTier.low;

  /// Numero maximo de paginas que se aceptan en una sola exportacion.
  int get maxPagesPerExport => switch (tier) {
        DeviceTier.low => 60,
        DeviceTier.mid => 150,
        DeviceTier.high => 400,
      };

  /// Tamano maximo de la cache de imagenes de Flutter. El valor de fabrica
  /// (100 MB) es demasiado para un movil de 2 GB compartidos con el sistema.
  int get imageCacheBytes => switch (tier) {
        DeviceTier.low => 24 << 20,
        DeviceTier.mid => 56 << 20,
        DeviceTier.high => 100 << 20,
      };

  /// Numero maximo de imagenes vivas en la cache.
  int get imageCacheCount => switch (tier) {
        DeviceTier.low => 60,
        DeviceTier.mid => 120,
        DeviceTier.high => 200,
      };

  /// Puntos por pulgada al rasterizar PDFs (comprimir, convertir a imagenes).
  double get rasterDpi => switch (tier) {
        DeviceTier.low => 110,
        DeviceTier.mid => 150,
        DeviceTier.high => 200,
      };

  @override
  String toString() =>
      'DeviceProfile(${tier.name}, ${totalRamMb}MB, $cores nucleos)';
}
