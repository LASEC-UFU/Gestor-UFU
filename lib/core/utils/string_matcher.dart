import 'dart:math';

class StringMatcher {
  /// Calcula similaridade Jaro-Winkler entre duas strings (0.0 a 1.0).
  static double jaroWinkler(String s1, String s2) {
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;

    final a = s1.toLowerCase();
    final b = s2.toLowerCase();

    final jaro = _jaroSimilarity(a, b);
    int prefix = 0;
    for (int i = 0; i < min(4, min(a.length, b.length)); i++) {
      if (a[i] == b[i]) {
        prefix++;
      } else {
        break;
      }
    }
    return jaro + prefix * 0.1 * (1 - jaro);
  }

  static double _jaroSimilarity(String s1, String s2) {
    final maxDist = (max(s1.length, s2.length) ~/ 2) - 1;
    final s1Matches = List<bool>.filled(s1.length, false);
    final s2Matches = List<bool>.filled(s2.length, false);
    int matches = 0;
    int transpositions = 0;

    for (int i = 0; i < s1.length; i++) {
      final start = max(0, i - maxDist);
      final end = min(s2.length, i + maxDist + 1);
      for (int j = start; j < end; j++) {
        if (s2Matches[j] || s1[i] != s2[j]) continue;
        s1Matches[i] = true;
        s2Matches[j] = true;
        matches++;
        break;
      }
    }

    if (matches == 0) return 0.0;

    int k = 0;
    for (int i = 0; i < s1.length; i++) {
      if (!s1Matches[i]) continue;
      while (!s2Matches[k]) {
        k++;
      }
      if (s1[i] != s2[k]) transpositions++;
      k++;
    }

    return (matches / s1.length +
            matches / s2.length +
            (matches - transpositions / 2) / matches) /
        3;
  }

  /// Encontra o melhor match de `query` em uma lista de `candidates`.
  /// Retorna (index, score) ou (-1, 0.0) se nenhum acima do threshold.
  static (int, double) findBestMatch(
    String query,
    List<String> candidates, {
    double threshold = 0.6,
  }) {
    int bestIdx = -1;
    double bestScore = 0.0;

    for (int i = 0; i < candidates.length; i++) {
      final score = jaroWinkler(query, candidates[i]);
      if (score > bestScore) {
        bestScore = score;
        bestIdx = i;
      }
    }

    if (bestScore >= threshold) return (bestIdx, bestScore);
    return (-1, 0.0);
  }
}
