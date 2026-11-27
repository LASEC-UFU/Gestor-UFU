import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:gestor_ufu/modules/equivalencia/application/certidao_pdf.dart';
import 'package:gestor_ufu/modules/equivalencia/application/equivalencia_planilhas.dart';
import 'package:gestor_ufu/modules/equivalencia/data/equivalencia_repository.dart';
import 'package:gestor_ufu/modules/equivalencia/domain/equivalencia_models.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

/// Regras da Equivalência de Alunos. A tela e os comandos (inclusive os do
/// Agente de IA) usam os mesmos métodos; quem escuta é avisado a cada mudança.
class EquivalenciaService extends ChangeNotifier {
  EquivalenciaService(this._repository, {CertidaoPdf? certidao})
    : _certidao = certidao ?? const CertidaoPdf();

  final EquivalenciaRepository _repository;
  final CertidaoPdf _certidao;
  EquivalenciaState? _state;

  bool get isLoaded => _state != null;

  EquivalenciaState get state =>
      _state ??
      const EquivalenciaState(curricula: [], cases: [], currentId: null);

  /// Relê o banco (o agente ou outro computador podem ter alterado).
  Future<EquivalenciaState> load() async {
    _state = await _repository.load();
    notifyListeners();
    return _state!;
  }

  Future<EquivalenciaState> _ensure() async => _state ?? await load();

  Future<void> _commit(EquivalenciaState next) async {
    _state = next;
    await _repository.save(next);
    notifyListeners();
  }

  // ---------------------------------------------------------- currículos

  Future<void> selectCurriculum(String? id) async {
    final current = await _ensure();
    await _commit(current.copyWith(currentId: id));
  }

  /// Substitui a lista de currículos (diálogo "Currículos").
  Future<void> replaceCurricula(List<Curriculum> curricula) async {
    if (curricula.isEmpty) return;
    final current = await _ensure();
    final keepSelection = curricula.any((c) => c.id == current.currentId);
    await _commit(
      current.copyWith(
        curricula: curricula,
        currentId: keepSelection ? current.currentId : curricula.first.id,
      ),
    );
  }

  Future<void> removeCurriculumSubject(
    String curriculumId,
    Subject subject,
  ) async {
    final current = await _ensure();
    final key = subjectCatalogKey(subject);
    await _commit(
      current.copyWith(
        curricula: [
          for (final c in current.curricula)
            c.id == curriculumId
                ? c.copyWith(
                    subjects: c.subjects
                        .where((s) => subjectCatalogKey(s) != key)
                        .toList(),
                  )
                : c,
        ],
      ),
    );
  }

  /// Lê uma planilha ou um currículo JSON (sem gravar).
  List<Subject> parseCurriculum(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4b) {
      return EquivalenciaPlanilhas.curriculumSubjects(bytes);
    }
    final data = jsonDecode(utf8.decode(bytes));
    final subjects = data is Map ? data['subjects'] : data;
    if (subjects is! List) {
      throw const FormatException('O currículo JSON precisa de subjects.');
    }
    return mergeSubjects([
      for (final subject in subjects)
        Subject.fromJson(Map<String, dynamic>.from(subject as Map)),
    ]);
  }

  /// Importa as disciplinas da planilha para um currículo existente
  /// ([curriculumId]) ou novo ([course] + [name]). [replace] troca a lista;
  /// senão mescla sem repetir.
  Future<({Curriculum curriculum, int imported})> importCurriculum(
    Uint8List bytes, {
    String? curriculumId,
    String? course,
    String? name,
    bool replace = false,
  }) async {
    final subjects = parseCurriculum(bytes);
    final current = await _ensure();
    var target = current.curriculum(curriculumId);
    if (target == null) {
      if (curriculumId != null) {
        throw CommandException(
          'curriculo_nao_encontrado',
          'Currículo "$curriculumId" não encontrado.',
        );
      }
      if ((course ?? '').trim().isEmpty || (name ?? '').trim().isEmpty) {
        throw const CommandException(
          'entrada_invalida',
          'Informe curriculumId de um currículo existente ou course e name '
              'para criar um novo.',
        );
      }
      target = Curriculum(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        course: course!.trim(),
        name: name!.trim(),
      );
    }
    final updated = target.copyWith(
      subjects: replace
          ? mergeSubjects(subjects)
          : mergeSubjects([...target.subjects, ...subjects]),
    );
    final exists = current.curricula.any((c) => c.id == updated.id);
    await _commit(
      current.copyWith(
        curricula: exists
            ? [
                for (final c in current.curricula)
                  c.id == updated.id ? updated : c,
              ]
            : [...current.curricula, updated],
      ),
    );
    return (curriculum: updated, imported: subjects.length);
  }

  // ---------------------------------------------------------- análises

  /// Lê uma análise de planilha (sem gravar).
  Future<EquivalenceCase> parseAnalysis(
    Uint8List bytes, {
    String? curriculumId,
  }) async {
    final current = await _ensure();
    final target = curriculumId ?? current.currentId;
    if (target == null || current.curriculum(target) == null) {
      throw const CommandException(
        'curriculo_nao_selecionado',
        'Selecione um currículo atual antes de importar a análise.',
      );
    }
    return EquivalenciaPlanilhas.analysis(bytes, currentCurriculumId: target);
  }

  /// Insere ou atualiza uma análise (novas entram no topo da lista).
  Future<void> saveCase(EquivalenceCase item) async {
    final current = await _ensure();
    item = item.copyWith(history: item.historyFor());
    final cases = [...current.cases];
    final index = cases.indexWhere((c) => c.id == item.id);
    if (index < 0) {
      cases.insert(0, item);
    } else {
      cases[index] = item;
    }
    await _commit(current.copyWith(cases: cases));
  }

  Future<EquivalenceCase> importAnalysis(
    Uint8List bytes, {
    String? curriculumId,
  }) async {
    final item = await parseAnalysis(bytes, curriculumId: curriculumId);
    await saveCase(item);
    return item;
  }

  Future<EquivalenceCase> removeCase(String caseId) async {
    final current = await _ensure();
    final item = current.caseById(caseId);
    if (item == null) {
      throw CommandException(
        'analise_nao_encontrada',
        'Análise "$caseId" não encontrada.',
      );
    }
    await _commit(
      current.copyWith(
        cases: current.cases.where((c) => c.id != caseId).toList(),
      ),
    );
    return item;
  }

  /// Gera a certidão de estudos em PDF de uma análise e grava em [path].
  Future<String> exportCertidao(String caseId, String path) async {
    final current = await _ensure();
    final item = current.caseById(caseId);
    if (item == null) {
      throw CommandException(
        'analise_nao_encontrada',
        'Análise "$caseId" não encontrada.',
      );
    }
    final target = path.toLowerCase().endsWith('.pdf') ? path : '$path.pdf';
    final bytes = await _certidao.build(
      item,
      current.curriculum(item.currentCurriculumId),
    );
    await File(target).writeAsBytes(bytes, flush: true);
    return target;
  }
}
