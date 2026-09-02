import 'dart:io';

import 'package:manticora/imaging/raster.dart';

import 'document_fixtures.dart';

/// Documentos reales de dominio publico usados como material de prueba.
///
/// No se versionan (pesan y se pueden volver a bajar): las pruebas que los
/// necesitan se saltan solas si la carpeta esta vacia, para que `flutter test`
/// siga funcionando sin conexion.  Descargalos con `./setup.sh corpus`.
class Corpus {
  Corpus._();

  static const directory = 'test/corpus';

  /// Documentos disponibles, con una nota de que aporta cada uno.
  static const expected = <String, String>{
    'factura-sichuan.jpg': 'factura impresa con rejilla de tabla',
    'factura-1849.jpg': 'documento manuscrito antiguo',
    'tabla-sharon-1854.jpg': 'papel amarilleado con manchas e iluminacion irregular',
    'instrucciones.jpg': 'pagina impresa moderna con titulos y parrafos',
  };

  static bool get isAvailable => available().isNotEmpty;

  static List<String> available() {
    final dir = Directory(directory);
    if (!dir.existsSync()) return const [];
    return expected.keys
        .where((name) => File('$directory/$name').existsSync())
        .toList();
  }

  static String get missingReason =>
      'Faltan los documentos de prueba en $directory. '
      'Descargalos con: ./setup.sh corpus';

  /// Carga un documento del corpus como imagen RGB.
  static RgbImage load(String name) {
    final file = File('$directory/$name');
    if (!file.existsSync()) {
      throw StateError('No esta el documento de prueba "$name". $missingReason');
    }
    return DocumentFixtures.decodeJpeg(file.readAsBytesSync());
  }

  /// Reduce una imagen para que las pruebas no tarden una eternidad.
  static RgbImage loadScaled(String name, {int maxSide = 900}) {
    final image = load(name);
    final longest = image.width > image.height ? image.width : image.height;
    if (longest <= maxSide) return image;
    final s = maxSide / longest;
    return downscaleRgb(
      image,
      (image.width * s).round(),
      (image.height * s).round(),
    );
  }
}
