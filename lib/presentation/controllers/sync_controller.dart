import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:gestor_ufu/core/utils/macro_resolver.dart';
import 'package:gestor_ufu/core/utils/string_matcher.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/domain/entities/moodle_entities.dart';
import 'package:gestor_ufu/domain/repositories/i_moodle_repository.dart';

class SyncController extends ChangeNotifier {
  final IMoodleRepository _repo;

  SyncController(this._repo);

  List<MoodleCourse> _courses = [];
  List<MoodleSection> _moodleSections = [];
  List<SectionMatch> _matches = [];
  bool _loading = false;
  String? _error;
  double _progress = 0;
  String _progressMessage = '';
  bool _syncing = false;
  String _syncLog = '';

  List<MoodleCourse> get courses => _courses;
  List<MoodleSection> get moodleSections => _moodleSections;
  List<SectionMatch> get matches => _matches;
  bool get loading => _loading;
  String? get error => _error;
  double get progress => _progress;
  String get progressMessage => _progressMessage;
  bool get syncing => _syncing;
  String get syncLog => _syncLog;

  Future<void> loadCourses(String token, String baseUrl) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _courses = await _repo.getCourses(token, baseUrl);
    } catch (e) {
      _error = e.toString();
    }
    _loading = false;
    notifyListeners();
  }

  Future<void> loadMoodleSections(
    String token,
    String baseUrl,
    int courseId,
  ) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _moodleSections = await _repo.getCourseContents(token, baseUrl, courseId);
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    _loading = false;
    notifyListeners();
  }

  /// Gera correspondências entre seções locais e seções do Moodle.
  /// Vinculados (moodleSectionId/moodleModuleId) são pareados diretamente.
  /// Score = média de 3 critérios: vínculo (link), nome, posição.
  void generateMatches(CourseConfig config) {
    _matches = [];

    // Pool de seções Moodle disponíveis (indexadas por id)
    final availableMoodleSections = {for (final s in _moodleSections) s.id: s};

    // 1ª passada: parear seções que já têm moodleSectionId vinculado
    final linkedSections = <String, MoodleSection>{}; // localId → MoodleSection
    for (final section in config.sections) {
      if (section.moodleSectionId != null &&
          availableMoodleSections.containsKey(section.moodleSectionId)) {
        linkedSections[section.id] = availableMoodleSections.remove(
          section.moodleSectionId,
        )!;
      }
    }

    // Ordem das seções Moodle para comparar posição (apenas seções vinculadas)
    final linkedMoodleSectionIds = linkedSections.values
        .map((s) => s.id)
        .toSet();
    final moodleSectionOrder = _moodleSections
        .where((s) => linkedMoodleSectionIds.contains(s.id))
        .map((s) => s.id)
        .toList();

    // Lookup global de módulos em todas as seções (construído uma vez)
    final globalModuleLookup = <int, MoodleModule>{};
    for (final ms in _moodleSections) {
      for (final m in ms.modules) {
        globalModuleLookup[m.id] = m;
      }
    }

    // Evitar que o mesmo módulo seja vinculado a atividades de seções diferentes
    final claimedModuleIds = <int>{};

    int relativeSIdx = 0;
    for (int sIdx = 0; sIdx < config.sections.length; sIdx++) {
      final section = config.sections[sIdx];
      MoodleSection? matched;
      double linkScore = 0;
      double nameScore = 0;
      double posScore = 0;

      if (linkedSections.containsKey(section.id)) {
        matched = linkedSections[section.id];
        linkScore = 1.0;
      }
      // Sem vínculo → score de link = 0, sem match Moodle

      if (matched != null) {
        // Score de nome da seção
        final sectionRefDate = config.semesterStartDate.add(
          Duration(days: section.referenceDaysOffset),
        );
        final resolvedName = MacroResolver.resolve(
          section.name,
          config.semesterStartDate,
          sectionRefDate,
        );
        nameScore = resolvedName == matched.name
            ? 1.0
            : StringMatcher.jaroWinkler(resolvedName, matched.name);

        // Score de posição: comparar ordem relativa das seções vinculadas
        final moodleIdx = moodleSectionOrder.indexOf(matched.id);
        posScore = (moodleIdx >= 0 && moodleIdx == relativeSIdx) ? 1.0 : 0.0;
      }
      if (linkedSections.containsKey(section.id)) relativeSIdx++;

      final sectionScore = matched != null
          ? (linkScore + nameScore + posScore) / 3.0
          : 0.0;

      // Atividades
      final activityMatches = <ActivityMatch>[];
      if (matched != null) {
        // Pool de módulos disponíveis nesta seção
        final availableModules = {for (final m in matched.modules) m.id: m};

        // 1ª passada: atividades já vinculadas
        final linkedActivities = <String, MoodleModule>{};
        for (final activity in section.activities) {
          if (activity.moodleModuleId != null &&
              !claimedModuleIds.contains(activity.moodleModuleId)) {
            if (availableModules.containsKey(activity.moodleModuleId)) {
              linkedActivities[activity.id] = availableModules.remove(
                activity.moodleModuleId,
              )!;
              claimedModuleIds.add(activity.moodleModuleId!);
            } else if (globalModuleLookup.containsKey(
              activity.moodleModuleId,
            )) {
              // Módulo vinculado existe no Moodle mas em outra seção
              linkedActivities[activity.id] =
                  globalModuleLookup[activity.moodleModuleId]!;
              claimedModuleIds.add(activity.moodleModuleId!);
            }
          }
        }

        // Ordem dos módulos Moodle na seção para comparar posição
        // Filtrar apenas módulos vinculados para comparação relativa
        final linkedModIds = linkedActivities.values.map((m) => m.id).toSet();
        final moodleModOrder = matched.modules
            .where((m) => linkedModIds.contains(m.id))
            .map((m) => m.id)
            .toList();

        int relativeIdx = 0;
        for (int aIdx = 0; aIdx < section.activities.length; aIdx++) {
          final activity = section.activities[aIdx];
          if (linkedActivities.containsKey(activity.id)) {
            final mod = linkedActivities[activity.id]!;
            double aLink = 1.0;

            // Score de nome
            final sectionRefDate = config.semesterStartDate.add(
              Duration(days: section.referenceDaysOffset),
            );
            final resolvedActName = MacroResolver.resolve(
              activity.name,
              config.semesterStartDate,
              sectionRefDate,
              activity.computeOpenDate(sectionRefDate),
              activity.computeCloseDate(sectionRefDate),
            );
            double aName = resolvedActName == mod.name
                ? 1.0
                : StringMatcher.jaroWinkler(resolvedActName, mod.name);

            // Labels: nome sempre = 1.0 (não é sincronizado)
            if (activity.activityType == 'Área de texto e mídia') {
              aName = 1.0;
            }

            // Score de posição: comparar ordem relativa dos módulos vinculados
            // (ignora módulos Moodle que não estão no config local)
            final modRelIdx = moodleModOrder.indexOf(mod.id);
            double aPos = (modRelIdx >= 0 && modRelIdx == relativeIdx)
                ? 1.0
                : 0.0;

            activityMatches.add(
              ActivityMatch(
                local: activity,
                moodleModule: mod,
                score: (aLink + aName + aPos) / 3.0,
                linkScore: aLink,
                nameScore: aName,
                posScore: aPos,
              ),
            );
            relativeIdx++;
          } else {
            activityMatches.add(
              ActivityMatch(local: activity, moodleModule: null, score: 0),
            );
          }
        }
      } else {
        for (final activity in section.activities) {
          activityMatches.add(
            ActivityMatch(local: activity, moodleModule: null, score: 0),
          );
        }
      }

      _matches.add(
        SectionMatch(
          local: section,
          moodleSection: matched,
          score: sectionScore,
          linkScore: linkScore,
          nameScore: nameScore,
          posScore: posScore,
          activityMatches: activityMatches,
        ),
      );
    }
    notifyListeners();
  }

  /// Sugere vínculos por similaridade para itens sem vínculo.
  /// Retorna lista de sugestões para seções e atividades.
  List<LinkSuggestion> suggestLinks(CourseConfig config) {
    final suggestions = <LinkSuggestion>[];

    // Seções Moodle já vinculadas (excluir do pool)
    final linkedMoodleSectionIds = <int>{};
    for (final section in config.sections) {
      if (section.moodleSectionId != null) {
        linkedMoodleSectionIds.add(section.moodleSectionId!);
      }
    }
    final availableMoodleSections = _moodleSections
        .where((s) => !linkedMoodleSectionIds.contains(s.id))
        .toList();
    final availableNames = availableMoodleSections.map((s) => s.name).toList();

    for (final section in config.sections) {
      if (section.moodleSectionId != null) continue; // já vinculado
      if (availableNames.isEmpty) continue;

      final (idx, score) = StringMatcher.findBestMatch(
        section.name,
        availableNames,
      );
      if (idx >= 0 && score > 0.3) {
        final suggested = availableMoodleSections[idx];
        suggestions.add(
          LinkSuggestion(
            type: LinkSuggestionType.section,
            sectionId: section.id,
            localName: section.name,
            suggestedMoodleId: suggested.id,
            suggestedMoodleName: suggested.name,
            score: score,
            allMoodleOptions: availableMoodleSections,
          ),
        );
        availableMoodleSections.removeAt(idx);
        availableNames.removeAt(idx);
      } else {
        suggestions.add(
          LinkSuggestion(
            type: LinkSuggestionType.section,
            sectionId: section.id,
            localName: section.name,
            suggestedMoodleId: null,
            suggestedMoodleName: null,
            score: 0,
            allMoodleOptions: availableMoodleSections,
          ),
        );
      }
    }

    // Atividades sem vínculo — dentro de seções já vinculadas
    for (final section in config.sections) {
      if (section.moodleSectionId == null) continue;
      final moodleSection = _moodleSections.firstWhere(
        (s) => s.id == section.moodleSectionId,
        orElse: () => MoodleSection(
          id: 0,
          section: 0,
          name: '',
          summary: '',
          visible: true,
          modules: [],
        ),
      );
      if (moodleSection.id == 0) continue;

      // Módulos Moodle já vinculados
      final linkedModuleIds = <int>{};
      for (final act in section.activities) {
        if (act.moodleModuleId != null) {
          linkedModuleIds.add(act.moodleModuleId!);
        }
      }
      final availableModules = moodleSection.modules
          .where((m) => !linkedModuleIds.contains(m.id))
          .toList();
      final availableModNames = availableModules.map((m) => m.name).toList();

      for (final activity in section.activities) {
        if (activity.moodleModuleId != null) continue; // já vinculado
        if (availableModNames.isEmpty) continue;

        final (idx, score) = StringMatcher.findBestMatch(
          activity.name,
          availableModNames,
        );
        if (idx >= 0 && score > 0.3) {
          final suggested = availableModules[idx];
          suggestions.add(
            LinkSuggestion(
              type: LinkSuggestionType.activity,
              sectionId: section.id,
              activityId: activity.id,
              localName: activity.name,
              suggestedMoodleId: suggested.id,
              suggestedMoodleName: suggested.name,
              score: score,
              allMoodleOptions: availableModules,
            ),
          );
          availableModules.removeAt(idx);
          availableModNames.removeAt(idx);
        }
      }
    }

    return suggestions;
  }

  /// Executa a sincronização para o Moodle.
  Future<void> syncToMoodle(
    String token,
    String baseUrl,
    CourseConfig config,
  ) async {
    _syncing = true;
    _progress = 0;
    _progressMessage = 'Iniciando sincronização...';
    _error = null;
    _syncLog = '';
    notifyListeners();

    final totalSteps = _matches.length;
    int step = 0;
    final errors = <String>[];
    // Flags para pular operações sem permissão após o 1º erro
    bool canUpdateNames = true;
    int skippedNameOps = 0;
    String?
    firstAccessErrorDetail; // Detalhe do 1º erro de acesso para diagnóstico

    for (final match in _matches) {
      step++;
      _progress = step / totalSteps;

      if (match.moodleSection == null) {
        _progressMessage =
            'Seção "${match.local.name}" - sem correspondência no Moodle';
        notifyListeners();
        continue;
      }

      // Data de referência para resolver macros da seção
      final sectionRefDate = config.semesterStartDate.add(
        Duration(days: match.local.referenceDaysOffset),
      );

      // Resolver macros no nome da seção antes de enviar ao Moodle
      final resolvedSectionName = MacroResolver.resolve(
        match.local.name,
        config.semesterStartDate,
        sectionRefDate,
      );

      // Atualizar nome da seção se diferente
      if (resolvedSectionName != match.moodleSection!.name) {
        if (canUpdateNames) {
          _progressMessage = 'Atualizando seção: $resolvedSectionName';
          notifyListeners();
          try {
            await _repo.updateSectionName(
              token,
              baseUrl,
              match.moodleSection!.id,
              resolvedSectionName,
            );
          } catch (e) {
            if (_isAccessError(e)) {
              canUpdateNames = false;
              firstAccessErrorDetail ??= e.toString();
              skippedNameOps++;
            } else {
              errors.add('Seção "${match.local.name}": $e');
            }
          }
        } else {
          skippedNameOps++;
        }
      }

      // Atualizar visibilidade e nomes de módulos
      for (final am in match.activityMatches) {
        if (am.moodleModule == null) continue;

        // Resolver macros no nome da atividade
        final resolvedActivityName = MacroResolver.resolve(
          am.local.name,
          config.semesterStartDate,
          sectionRefDate,
          am.local.computeOpenDate(sectionRefDate),
          am.local.computeCloseDate(sectionRefDate),
        );

        // Atualizar visibilidade se diferente
        if (am.local.visibility != am.moodleModule!.visibility) {
          _progressMessage = 'Visibilidade: $resolvedActivityName';
          notifyListeners();
          try {
            await _repo.updateModuleVisibility(
              token,
              baseUrl,
              am.moodleModule!.id,
              am.local.visibility,
            );
          } catch (e) {
            errors.add('Visibilidade "${am.local.name}": $e');
          }
        }

        // Para labels: atualizar nome e conteúdo HTML
        if (am.local.activityType == 'Área de texto e mídia') {
          if (canUpdateNames) {
            _progressMessage = 'Label: $resolvedActivityName';
            notifyListeners();
            try {
              await _repo.updateModuleName(
                token,
                baseUrl,
                am.moodleModule!.id,
                resolvedActivityName,
              );
            } catch (e) {
              if (_isAccessError(e)) {
                canUpdateNames = false;
                firstAccessErrorDetail ??= e.toString();
                skippedNameOps++;
              } else {
                errors.add('Nome label "${am.local.name}": $e');
              }
            }
          } else {
            skippedNameOps++;
          }
        } else {
          // Atividades normais (não-label): atualizar nome se diferente
          if (resolvedActivityName != am.moodleModule!.name) {
            if (canUpdateNames) {
              _progressMessage = 'Nome: $resolvedActivityName';
              notifyListeners();
              try {
                await _repo.updateModuleName(
                  token,
                  baseUrl,
                  am.moodleModule!.id,
                  resolvedActivityName,
                );
              } catch (e) {
                if (_isAccessError(e)) {
                  canUpdateNames = false;
                  firstAccessErrorDetail ??= e.toString();
                  skippedNameOps++;
                } else {
                  errors.add('Nome "${am.local.name}": $e');
                }
              }
            } else {
              skippedNameOps++;
            }
          }
        }
      }

      // ── Atualizar datas de abertura/encerramento das atividades ──
      // Sempre envia para atividades com offsets configurados (forçar push).
      // Após envio, re-busca dados do Moodle para verificar se aplicou.
      _syncLog += '\n── Datas seção "${match.local.name}" ──\n';
      final datePushList =
          <
            ({
              int cmid,
              String modname,
              String actName,
              DateTime? openDate,
              DateTime? closeDate,
            })
          >[];

      for (final am in match.activityMatches) {
        if (am.moodleModule == null) continue;

        final localOpenDate = am.local.computeOpenDate(sectionRefDate);
        final localCloseDate = am.local.computeCloseDate(sectionRefDate);

        final actName = am.local.name.length > 25
            ? am.local.name.substring(0, 25)
            : am.local.name;

        // Pular atividades que não têm nenhum offset configurado
        final hasOpenOffset = am.local.openOffsetDays != null;
        final hasCloseOffset = am.local.closeOffsetDays != null;

        _syncLog +=
            '  "$actName" modname=${am.moodleModule!.modname} '
            'openOffset=${am.local.openOffsetDays} closeOffset=${am.local.closeOffsetDays} '
            'openTime=${am.local.openTimeMinutes} closeTime=${am.local.closeTimeMinutes}\n'
            '    local:  open=$localOpenDate close=$localCloseDate\n';

        if (!hasOpenOffset && !hasCloseOffset) {
          _syncLog += '    (sem offsets configurados – pulando)\n';
          continue;
        }

        datePushList.add((
          cmid: am.moodleModule!.id,
          modname: am.moodleModule!.modname,
          actName: actName,
          openDate: localOpenDate,
          closeDate: localCloseDate,
        ));
      }

      // Enviar atualizações de data FORÇADAS para todas as atividades com offsets
      for (final dp in datePushList) {
        final resolvedName = dp.actName;
        _progressMessage = 'Datas: $resolvedName';
        notifyListeners();
        try {
          final result = await _repo.updateModuleDates(
            token,
            baseUrl,
            dp.cmid,
            dp.modname,
            dp.openDate,
            dp.closeDate,
          );
          _syncLog += '    ✓ ENVIADO (cmid=${dp.cmid}): $result\n';
        } catch (e) {
          _syncLog += '    ✗ ERRO datas (cmid=${dp.cmid}): $e\n';
          if (!_isAccessError(e)) {
            errors.add('Datas "${dp.actName}": $e');
          }
        }
      }

      // Verificação pós-envio: re-buscar datas do Moodle e comparar
      if (datePushList.isNotEmpty) {
        _progressMessage = 'Verificando datas...';
        notifyListeners();
        try {
          final freshSections = await _repo.getCourseContents(
            token,
            baseUrl,
            config.moodleCourseId!,
          );
          // Encontrar a seção correspondente
          final freshSection = freshSections
              .where((s) => s.id == match.moodleSection!.id)
              .firstOrNull;
          if (freshSection != null) {
            _syncLog += '  ── Verificação pós-envio ──\n';
            for (final dp in datePushList) {
              final freshMod = freshSection.modules
                  .where((m) => m.id == dp.cmid)
                  .firstOrNull;
              if (freshMod == null) {
                _syncLog +=
                    '    ⚠ cmid=${dp.cmid} não encontrado na re-busca\n';
                continue;
              }
              DateTime? freshOpen;
              DateTime? freshClose;
              for (final d in freshMod.dates) {
                if (d.timestamp <= 0) continue;
                if (d.isOpenDate) {
                  freshOpen = d.dateTime;
                } else if (d.isCloseDate) {
                  freshClose ??= d.dateTime;
                }
              }
              final openOk = !_datesDiffer(dp.openDate, freshOpen);
              final closeOk = !_datesDiffer(dp.closeDate, freshClose);
              if (openOk && closeOk) {
                _syncLog +=
                    '    ✓ VERIFICADO cmid=${dp.cmid}: '
                    'open=$freshOpen close=$freshClose\n';
              } else {
                _syncLog +=
                    '    ✗ DIVERGÊNCIA cmid=${dp.cmid}: '
                    'esperado open=${dp.openDate} close=${dp.closeDate} | '
                    'moodle open=$freshOpen close=$freshClose\n';
                errors.add(
                  'Verificação "${dp.actName}": datas não aplicadas no Moodle',
                );
              }
            }
          }
        } catch (e) {
          _syncLog += '  ⚠ Erro na verificação pós-envio: $e\n';
        }
      }

      // ── Reordenar atividades dentro da seção ──
      // Comparar a ordem desejada (local) com a ordem atual (Moodle)
      // e mover atividades que estejam fora de posição.
      final desiredOrder = <int>[]; // IDs dos módulos na ordem local
      for (final am in match.activityMatches) {
        if (am.moodleModule != null) {
          desiredOrder.add(am.moodleModule!.id);
        }
      }

      _syncLog +=
          '\n── Seção "${match.local.name}" (moodleId: ${match.moodleSection!.id}) ──\n';
      _syncLog += 'desiredOrder (${desiredOrder.length}): $desiredOrder\n';
      _syncLog +=
          'moodle modules na seção: ${match.moodleSection!.modules.map((m) => '${m.id}(${m.name.substring(0, m.name.length > 20 ? 20 : m.name.length)})').toList()}\n';

      // Ordem atual no Moodle (apenas módulos que fazem parte do match)
      final desiredSet = desiredOrder.toSet();
      final currentOrder = match.moodleSection!.modules
          .where((m) => desiredSet.contains(m.id))
          .map((m) => m.id)
          .toList();

      _syncLog +=
          'currentOrder (filtrado, ${currentOrder.length}): $currentOrder\n';

      // Módulos que estão em outra seção no Moodle e precisam ser movidos
      final modulesInOtherSections = desiredSet.difference(
        currentOrder.toSet(),
      );

      _syncLog += 'modulesInOtherSections: $modulesInOtherSections\n';

      final needsReorder =
          desiredOrder.isNotEmpty &&
          (!_listsEqual(desiredOrder, currentOrder) ||
              modulesInOtherSections.isNotEmpty);
      _syncLog += 'listsEqual: ${_listsEqual(desiredOrder, currentOrder)}\n';
      _syncLog += 'needsReorder: $needsReorder\n';

      if (needsReorder) {
        _progressMessage =
            'Reordenando atividades na seção "${match.local.name}"';
        notifyListeners();
        // cm_move usa targetcmid = "colocar ANTES deste módulo"
        // e targetcmid=null = "final da seção".
        // Processar do último ao primeiro: cada módulo é colocado
        // ANTES do módulo seguinte na ordem desejada.
        for (int i = desiredOrder.length - 1; i >= 0; i--) {
          final moduleId = desiredOrder[i];
          // Último elemento → null (final da seção)
          // Demais → antes do próximo elemento na ordem desejada
          final targetCmId = i == desiredOrder.length - 1
              ? null
              : desiredOrder[i + 1];

          _syncLog +=
              '  [$i] moduleId=$moduleId targetCmId=$targetCmId → MOVENDO...\n';

          try {
            final resp = await _repo.moveModule(
              token,
              baseUrl,
              config.moodleCourseId!,
              moduleId,
              targetCmId,
              match.moodleSection!.id,
            );
            _syncLog +=
                '    ✓ OK (resp: ${resp.length > 80 ? '${resp.substring(0, 80)}...' : resp})\n';
          } catch (e) {
            _syncLog += '    ✗ ERRO: $e\n';
            errors.add('Reordenar "${match.local.name}": $e');
            break;
          }
        }
      } else {
        _syncLog += '  (nenhuma reordenação necessária)\n';
      }
    }

    // Recarregar seções do Moodle para refletir o estado pós-sync
    _progressMessage = 'Verificando resultado...';
    notifyListeners();
    try {
      _moodleSections = await _repo.getCourseContents(
        token,
        baseUrl,
        config.moodleCourseId!,
      );
      generateMatches(config);
    } catch (_) {
      // Não falhar se o reload não funcionar
    }

    // Construir mensagem final
    final messages = <String>[];
    if (skippedNameOps > 0) {
      final detail = firstAccessErrorDetail ?? 'Erro desconhecido';
      messages.add(
        'Atualização de nomes não disponível ($skippedNameOps operações puladas).\n\n'
        'Motivo: $detail\n\n'
        'Faça logout e login novamente para renovar a sessão.',
      );
    }
    if (errors.isNotEmpty) {
      messages.add('${errors.length} erro(s):\n${errors.join('\n')}');
    }
    // Sempre anexar log de reordenação para diagnóstico
    if (_syncLog.isNotEmpty) {
      messages.add('── Log de Reordenação ──$_syncLog');
    }

    if (messages.isEmpty) {
      _progressMessage = 'Sincronização concluída com sucesso!';
    } else if (errors.isEmpty && skippedNameOps > 0) {
      _progressMessage = 'Concluída (visibilidade OK, nomes ignorados)';
    } else {
      _progressMessage = 'Concluída com problemas';
    }
    _progress = 1;
    _error = messages.isNotEmpty ? messages.join('\n\n') : null;
    _syncing = false;
    notifyListeners();
  }

  /// Verifica se o erro é de controle de acesso / permissão / sessão AJAX.
  bool _isAccessError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('controle de acesso') ||
        msg.contains('access control') ||
        msg.contains('accessexception') ||
        msg.contains('not allowed') ||
        msg.contains('not available') ||
        msg.contains('não disponível') ||
        msg.contains('sessão ajax') ||
        msg.contains('sessão expirada') ||
        msg.contains('sessão foi finalizada') ||
        msg.contains('expirou') ||
        msg.contains('logintoken');
  }

  /// Compara duas listas de inteiros por igualdade posicional.
  bool _listsEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Compara duas datas (com tolerância de 60s) para detectar diferenças.
  bool _datesDiffer(DateTime? a, DateTime? b) {
    if (a == null && b == null) return false;
    if (a == null || b == null) return true;
    return a.difference(b).inSeconds.abs() > 60;
  }

  void clearMatches() {
    _matches = [];
    _moodleSections = [];
    notifyListeners();
  }

  // ── Mapeamento modname → tipo local ──────────────────────────────────────

  static const _modNameMap = <String, String>{
    'assign': 'Tarefa',
    'quiz': 'Questionário',
    'survey': 'Pesquisa',
    'feedback': 'Pesquisa',
    'choice': 'Escolha',
    'forum': 'Fórum',
    'resource': 'Arquivo',
    'url': 'URL',
    'page': 'Página',
    'folder': 'Pasta',
    'wiki': 'Wiki',
    'glossary': 'Glossário',
    'lesson': 'Lição',
    'h5pactivity': 'H5P',
    'hvp': 'Conteúdo interativo',
    'data': 'Base de dados',
    'journal': 'Diário',
    'attendance': 'Presença',
    'jitsi': 'Jitsi',
    'bigbluebuttonbn': 'ConferênciaWeb',
    'book': 'Livro',
    'scorm': 'Pacote SCORM',
    'imscp': 'Conteúdo do pacote IMS',
    'simplecertificate': 'Certificado Simples',
    'checklist': 'Checklist',
    'geogebra': 'GeoGebra',
    'workshop': 'Laboratório de Avaliação',
    'label': 'Área de texto e mídia',
    'hotpot': 'Atividade Hot Potatoes',
    'quizventure': 'Quizventure',
  };

  static String _mapModName(String modname) => _modNameMap[modname] ?? modname;

  // ── Importar config a partir do Moodle ──────────────────────────────────

  /// Lê as seções e módulos do curso Moodle e constrói um [CourseConfig]
  /// com todos os IDs do Moodle já vinculados.
  Future<CourseConfig> buildConfigFromMoodle(
    String token,
    String baseUrl,
    MoodleCourse course,
    DateTime semesterStart,
  ) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final sections = await _repo.getCourseContents(token, baseUrl, course.id);
      final uuid = const Uuid();
      final configSections = <SectionEntry>[];
      int orderIndex = 0;

      // Data base normalizada (sem hora)
      final semesterStartDay = DateTime(
        semesterStart.year,
        semesterStart.month,
        semesterStart.day,
      );

      for (final mSection in sections) {
        // Pular seção 0 "General" vazia
        if (mSection.section == 0 &&
            mSection.name.isEmpty &&
            mSection.modules.isEmpty) {
          continue;
        }

        orderIndex++;
        final activities = <ActivityEntry>[];

        for (final mod in mSection.modules) {
          // Pular labels (áreas de texto) se não tiver nome
          if (mod.name.isEmpty) continue;

          // Extrair datas do módulo (open/close)
          DateTime? openDate;
          DateTime? closeDate;
          for (final d in mod.dates) {
            if (d.timestamp <= 0) continue;
            if (d.isOpenDate) {
              openDate = d.dateTime;
            } else if (d.isCloseDate) {
              closeDate ??= d.dateTime;
            }
          }

          activities.add(
            ActivityEntry(
              id: uuid.v4(),
              name: mod.name,
              activityType: _mapModName(mod.modname),
              moodleModuleId: mod.id,
              visibility: mod.visibility,
              openDate: openDate,
              closeDate: closeDate,
            ),
          );
        }

        // As duas primeiras seções têm offset 0, as demais avançam +7 dias cada
        final int sectionOffset = orderIndex <= 2 ? 0 : (orderIndex - 2) * 7;

        final sectionRefDate = semesterStartDay.add(
          Duration(days: sectionOffset),
        );

        // Recalcular atividades com offsets relativos à seção
        final activitiesWithOffsets = activities.map((activity) {
          int? openOffsetDays;
          int? closeOffsetDays;
          int? openTimeMinutes;
          int? closeTimeMinutes;

          if (activity.openDate != null) {
            final openDay = DateTime(
              activity.openDate!.year,
              activity.openDate!.month,
              activity.openDate!.day,
            );
            openOffsetDays = openDay.difference(sectionRefDate).inDays;
            openTimeMinutes =
                activity.openDate!.hour * 60 + activity.openDate!.minute;
          } else {
            // Sem data de abertura: usar offset 0 (data da seção)
            openOffsetDays = 0;
          }

          if (activity.closeDate != null) {
            final closeDay = DateTime(
              activity.closeDate!.year,
              activity.closeDate!.month,
              activity.closeDate!.day,
            );
            closeOffsetDays = closeDay.difference(sectionRefDate).inDays;
            closeTimeMinutes =
                activity.closeDate!.hour * 60 + activity.closeDate!.minute;
          }

          return activity.copyWith(
            openOffsetDays: openOffsetDays,
            closeOffsetDays: closeOffsetDays,
            openTimeMinutes: openTimeMinutes,
            closeTimeMinutes: closeTimeMinutes,
          );
        }).toList();

        configSections.add(
          SectionEntry(
            id: uuid.v4(),
            orderIndex: orderIndex,
            name: mSection.name.isNotEmpty
                ? mSection.name
                : 'Seção ${mSection.section}',
            referenceDaysOffset: sectionOffset,
            date: sectionRefDate,
            offsetDays: sectionOffset,
            moodleSectionId: mSection.id,
            visible: mSection.visible,
            activities: activitiesWithOffsets,
            moodleDescription: mSection.summary.isNotEmpty
                ? mSection.summary
                : null,
          ),
        );
      }

      // ── Substituir datas hardcoded por macros nos textos ──────────────────
      for (int i = 0; i < configSections.length; i++) {
        final section = configSections[i];
        final sectionRefDate = semesterStartDay.add(
          Duration(days: section.referenceDaysOffset),
        );

        final newName = MacroResolver.replaceDatesWithMacros(
          section.name,
          sectionRefDate,
        );
        final newDesc = section.moodleDescription != null
            ? MacroResolver.replaceDatesWithMacros(
                section.moodleDescription!,
                sectionRefDate,
              )
            : null;

        final updatedActivities = section.activities.map((activity) {
          final openDate = activity.computeOpenDate(sectionRefDate);
          final closeDate = activity.computeCloseDate(sectionRefDate);
          final newActName = MacroResolver.replaceDatesWithMacros(
            activity.name,
            sectionRefDate,
            activityOpenDate: openDate,
            activityCloseDate: closeDate,
          );
          return newActName != activity.name
              ? activity.copyWith(name: newActName)
              : activity;
        }).toList();

        configSections[i] = section.copyWith(
          name: newName,
          moodleDescription: newDesc,
          activities: updatedActivities,
        );
      }

      final now = DateTime.now();
      final config = CourseConfig(
        id: uuid.v4(),
        name: course.fullname,
        moodleCourseId: course.id,
        moodleCourseName: course.fullname,
        semesterStartDate: semesterStart,
        createdAt: now,
        updatedAt: now,
        sections: configSections,
      );

      _loading = false;
      notifyListeners();
      return config;
    } catch (e) {
      _loading = false;
      _error = 'Erro ao importar do Moodle: $e';
      notifyListeners();
      rethrow;
    }
  }
}

class SectionMatch {
  final SectionEntry local;
  final MoodleSection? moodleSection;
  final double score;
  final double linkScore;
  final double nameScore;
  final double posScore;
  final List<ActivityMatch> activityMatches;

  SectionMatch({
    required this.local,
    this.moodleSection,
    required this.score,
    this.linkScore = 0,
    this.nameScore = 0,
    this.posScore = 0,
    this.activityMatches = const [],
  });
}

class ActivityMatch {
  final ActivityEntry local;
  final MoodleModule? moodleModule;
  final double score;
  final double linkScore;
  final double nameScore;
  final double posScore;

  ActivityMatch({
    required this.local,
    this.moodleModule,
    required this.score,
    this.linkScore = 0,
    this.nameScore = 0,
    this.posScore = 0,
  });
}

enum LinkSuggestionType { section, activity }

class LinkSuggestion {
  final LinkSuggestionType type;
  final String sectionId;
  final String? activityId;
  final String localName;
  int? suggestedMoodleId;
  String? suggestedMoodleName;
  final double score;
  final List<dynamic> allMoodleOptions; // MoodleSection ou MoodleModule

  LinkSuggestion({
    required this.type,
    required this.sectionId,
    this.activityId,
    required this.localName,
    this.suggestedMoodleId,
    this.suggestedMoodleName,
    required this.score,
    this.allMoodleOptions = const [],
  });
}
