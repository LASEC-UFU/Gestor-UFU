import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_ufu/data/repositories/config_repository_impl.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/data/datasources/local_datasource.dart';

/// Mock datasource que guarda em memória (sem path_provider).
class MockDatasource extends LocalDatasource {
  final _store = <String, CourseConfig>{};

  @override
  Future<List<CourseConfig>> getAll() async => _store.values.toList();

  @override
  Future<CourseConfig?> getById(String id) async => _store[id];

  @override
  Future<void> save(CourseConfig config) async => _store[config.id] = config;

  @override
  Future<void> delete(String id) async => _store.remove(id);
}

void main() {
  test('parse ININDI xlsx', () async {
    final datasource = MockDatasource();
    final repo = ConfigRepositoryImpl(datasource);

    final config =
        await repo.importFromSpreadsheet('PlanilhaDatasAulasININDI.xlsx');

    expect(config.sections.isNotEmpty, true);
    expect(config.semesterStartDate.year, 2025);
    expect(config.sections.length, greaterThanOrEqualTo(10));
    expect(config.sections.first.date.year, 2025);
  });

  test('parse ININDII xlsx', () async {
    final datasource = MockDatasource();
    final repo = ConfigRepositoryImpl(datasource);

    final config =
        await repo.importFromSpreadsheet('PlanilhaDatasAulasININDII.xlsx');

    expect(config.sections.isNotEmpty, true);
    expect(config.sections.first.activities.isNotEmpty, true);
  });

  test('reject xls files', () async {
    final datasource = MockDatasource();
    final repo = ConfigRepositoryImpl(datasource);

    expect(
      () => repo.importFromSpreadsheet('PlanilhaDatasAulasININDI.xls'),
      throwsA(isA<Exception>().having(
        (e) => e.toString(),
        'message',
        contains('.xls não é suportado'),
      )),
    );
  });
}
