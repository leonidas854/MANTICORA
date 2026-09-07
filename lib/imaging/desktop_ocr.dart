import 'dart:io';

import '../core/failure.dart';
import '../core/logger.dart';
import 'ocr_service.dart';

/// Reconocimiento de texto en escritorio apoyandose en Tesseract.
///
/// ML Kit solo existe en movil, asi que en Linux y Windows se usa el motor
/// libre que la persona ya tenga instalado. Se invoca como proceso (nunca por
/// shell) y se le pide el formato TSV, que ademas del texto trae la caja de
/// cada palabra: eso es lo que permite seguir generando PDF buscables con la
/// capa de texto en su sitio.
abstract final class DesktopOcr {
  static const _tag = 'OCR';
  static const String executable = 'tesseract';

  /// Idiomas preferidos, en orden. Se usa el primero que este instalado.
  static const List<String> preferredLanguages = ['spa+eng', 'spa', 'eng'];

  static bool? _available;
  static List<String>? _installedLanguages;

  /// Indica si el sistema tiene Tesseract. El resultado se recuerda.
  static Future<bool> isAvailable() async {
    final cached = _available;
    if (cached != null) return cached;
    try {
      final probe = await Process.run(executable, const ['--version'])
          .timeout(const Duration(seconds: 10));
      _available = probe.exitCode == 0;
    } catch (_) {
      _available = false;
    }
    if (_available == false) {
      Log.i(_tag, 'Tesseract no esta instalado: no hay OCR en este escritorio');
    }
    return _available!;
  }

  /// Idiomas instalados, tal y como los lista Tesseract.
  static Future<List<String>> installedLanguages() async {
    final cached = _installedLanguages;
    if (cached != null) return cached;
    try {
      final result = await Process.run(executable, const ['--list-langs'])
          .timeout(const Duration(seconds: 15));
      // La primera linea es un encabezado, no un idioma.
      _installedLanguages = '${result.stdout}${result.stderr}'
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.contains(' '))
          .toList();
    } catch (e) {
      Log.w(_tag, 'No se han podido listar los idiomas de Tesseract', e);
      _installedLanguages = const [];
    }
    return _installedLanguages!;
  }

  /// Elige el mejor `-l` disponible, o null si no se puede saber.
  static String? bestLanguage(List<String> installed) {
    for (final candidate in preferredLanguages) {
      final parts = candidate.split('+');
      if (parts.every(installed.contains)) return candidate;
    }
    return installed.isEmpty ? null : installed.first;
  }

  /// Reconoce el texto de una imagen ya guardada en disco.
  static Future<OcrResult> recognizeFile(String path) async {
    if (!await isAvailable()) throw missingEngineFailure();

    final language = bestLanguage(await installedLanguages());
    final arguments = <String>[
      path,
      'stdout',
      if (language != null) ...['-l', language],
      '--psm',
      '3',
      'tsv',
    ];

    try {
      final result = await Process.run(executable, arguments)
          .timeout(const Duration(minutes: 2));
      if (result.exitCode != 0) {
        final detail = '${result.stderr}'.trim();
        Log.w(_tag, 'Tesseract termino con codigo ${result.exitCode}: $detail');
        throw AppFailure(
          kind: FailureKind.ocr,
          message: 'El motor de texto del escritorio no ha podido leer esta '
              'imagen.',
          cause: detail,
          retryable: false,
        );
      }
      return parseTsv('${result.stdout}');
    } on AppFailure {
      rethrow;
    } catch (e, st) {
      throw AppFailure(
        kind: FailureKind.ocr,
        message: 'No se ha podido ejecutar el motor de texto del escritorio.',
        cause: e,
        stackTrace: st,
      );
    }
  }

  /// Fallo con instrucciones concretas segun el sistema.
  static AppFailure missingEngineFailure() => AppFailure(
        kind: FailureKind.unsupported,
        message: Platform.isWindows
            ? 'Para reconocer texto en Windows instala Tesseract OCR '
                '(github.com/UB-Mannheim/tesseract) y reinicia la aplicacion.'
            : 'Para reconocer texto en el escritorio instala Tesseract. En '
                'Arch: "sudo pacman -S tesseract tesseract-data-spa '
                'tesseract-data-eng"; en Debian o Ubuntu: "sudo apt install '
                'tesseract-ocr tesseract-ocr-spa".',
        retryable: false,
      );

  /// Convierte el TSV de Tesseract en lineas con su caja.
  ///
  /// El TSV trae una fila por palabra (nivel 5) mas filas de estructura. Se
  /// agrupan las palabras por bloque/parrafo/linea y se une su caja, porque una
  /// caja por palabra suelta no sirve para la capa de texto de un PDF.
  static OcrResult parseTsv(String tsv) {
    final rows = tsv.split(RegExp(r'[\r\n]+'));
    if (rows.isEmpty) return const OcrResult('', []);

    final header = rows.first.split('\t');
    final index = {
      for (var i = 0; i < header.length; i++) header[i].trim(): i,
    };
    int? column(String name) => index[name];

    final level = column('level');
    final block = column('block_num');
    final par = column('par_num');
    final lineNum = column('line_num');
    final left = column('left');
    final top = column('top');
    final width = column('width');
    final height = column('height');
    final conf = column('conf');
    final textCol = column('text');
    if ([level, block, par, lineNum, left, top, width, height, textCol]
        .any((c) => c == null)) {
      Log.w(_tag, 'TSV de Tesseract sin las columnas esperadas');
      return const OcrResult('', []);
    }

    final grouped = <String, _LineAccumulator>{};
    final order = <String>[];

    for (var i = 1; i < rows.length; i++) {
      final cells = rows[i].split('\t');
      if (cells.length <= textCol!) continue;
      if (cells[level!].trim() != '5') continue; // solo palabras

      final word = cells[textCol].trim();
      if (word.isEmpty) continue;
      // Tesseract marca con -1 lo que ni siquiera intento leer.
      final confidence =
          conf == null ? 0.0 : double.tryParse(cells[conf].trim()) ?? 0;
      if (confidence < 0) continue;

      final key = '${cells[block!]}/${cells[par!]}/${cells[lineNum!]}';
      final x = double.tryParse(cells[left!].trim()) ?? 0;
      final y = double.tryParse(cells[top!].trim()) ?? 0;
      final w = double.tryParse(cells[width!].trim()) ?? 0;
      final h = double.tryParse(cells[height!].trim()) ?? 0;

      final accumulator = grouped.putIfAbsent(key, () {
        order.add(key);
        return _LineAccumulator();
      });
      accumulator.add(word, x, y, w, h);
    }

    final lines = <OcrLine>[];
    for (final key in order) {
      final line = grouped[key]!.toLine();
      if (line != null) lines.add(line);
    }
    return OcrResult(lines.map((l) => l.text).join('\n'), lines);
  }

  /// Solo para pruebas: olvida lo que se detecto del sistema.
  static void resetProbeForTesting() {
    _available = null;
    _installedLanguages = null;
  }
}

class _LineAccumulator {
  final List<String> words = [];
  double minX = double.infinity;
  double minY = double.infinity;
  double maxX = -double.infinity;
  double maxY = -double.infinity;

  void add(String word, double x, double y, double w, double h) {
    words.add(word);
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (x + w > maxX) maxX = x + w;
    if (y + h > maxY) maxY = y + h;
  }

  OcrLine? toLine() {
    if (words.isEmpty || minX > maxX || minY > maxY) return null;
    return OcrLine(words.join(' '), minX, minY, maxX - minX, maxY - minY);
  }
}
