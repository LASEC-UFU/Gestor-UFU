class AcademicTerm {
  const AcademicTerm({required this.year, required this.semester});

  final int year;
  final int semester;

  String get key => '${year}_$semester';

  static AcademicTerm? parse(String value) {
    final normalized = value.trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    final keyMatch = RegExp(r'^(\d{4})[_/-]([12])$').firstMatch(normalized);
    if (keyMatch != null) {
      return AcademicTerm(
        year: int.parse(keyMatch.group(1)!),
        semester: int.parse(keyMatch.group(2)!),
      );
    }
    final legacyMatch = RegExp(
      r'^([12])\D*(?:semestre|per[ií]odo)\D*(\d{4})$',
    ).firstMatch(normalized);
    if (legacyMatch == null) return null;
    return AcademicTerm(
      year: int.parse(legacyMatch.group(2)!),
      semester: int.parse(legacyMatch.group(1)!),
    );
  }

  static String displayName(String storedValue) =>
      parse(storedValue)?.key ?? storedValue;

  static List<String> newestFirst(Iterable<String> values) {
    final indexed = values.toSet().toList().asMap().entries.toList();
    indexed.sort((left, right) {
      final leftTerm = parse(left.value);
      final rightTerm = parse(right.value);
      if (leftTerm == null && rightTerm == null) {
        return left.key.compareTo(right.key);
      }
      if (leftTerm == null) return 1;
      if (rightTerm == null) return -1;
      final yearOrder = rightTerm.year.compareTo(leftTerm.year);
      if (yearOrder != 0) return yearOrder;
      final semesterOrder = rightTerm.semester.compareTo(leftTerm.semester);
      if (semesterOrder != 0) return semesterOrder;
      return left.key.compareTo(right.key);
    });
    return indexed.map((entry) => entry.value).toList();
  }

  static String? findEquivalent(Iterable<String> values, String candidate) {
    final parsedCandidate = parse(candidate);
    if (parsedCandidate == null) return null;
    for (final value in values) {
      final parsedValue = parse(value);
      if (parsedValue?.year == parsedCandidate.year &&
          parsedValue?.semester == parsedCandidate.semester) {
        return value;
      }
    }
    return null;
  }
}
