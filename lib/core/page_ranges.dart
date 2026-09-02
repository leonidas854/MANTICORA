/// Interpreta expresiones de paginas escritas por el usuario, del estilo
/// "1-3,5,8". Devuelve indices desde 0, ordenados y sin repetidos, o null si
/// la expresion no es valida para un documento de [pageCount] paginas.
List<int>? parsePageRanges(String input, int pageCount) {
  final out = <int>{};
  for (final part in input.split(RegExp(r'[,;\s]+'))) {
    if (part.isEmpty) continue;
    final range = part.split('-');
    if (range.length == 1) {
      final n = int.tryParse(range[0]);
      if (n == null || n < 1 || n > pageCount) return null;
      out.add(n - 1);
    } else if (range.length == 2) {
      final a = int.tryParse(range[0]);
      final b = int.tryParse(range[1]);
      if (a == null || b == null || a < 1 || b < a || b > pageCount) return null;
      for (var i = a; i <= b; i++) {
        out.add(i - 1);
      }
    } else {
      return null;
    }
  }
  return out.isEmpty ? null : (out.toList()..sort());
}
