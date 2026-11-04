import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_ufu/core/utils/macro_resolver.dart';

void main() {
  group('replaceDatesWithMacros', () {
    test('substitui data exata de início (AI)', () {
      final sectionRef = DateTime(2026, 2, 16);
      final openDate = DateTime(2026, 4, 24);
      final closeDate = DateTime(2026, 5, 1);

      final result = MacroResolver.replaceDatesWithMacros(
        'Entrega até 24/04/2026',
        sectionRef,
        activityOpenDate: openDate,
        activityCloseDate: closeDate,
      );

      expect(result, 'Entrega até <DD/MM/YYYY>AI');
    });

    test('substitui data exata de fim (AF)', () {
      final sectionRef = DateTime(2026, 2, 16);
      final openDate = DateTime(2026, 4, 24);
      final closeDate = DateTime(2026, 5, 1);

      final result = MacroResolver.replaceDatesWithMacros(
        'Prazo final: 01/05/2026',
        sectionRef,
        activityOpenDate: openDate,
        activityCloseDate: closeDate,
      );

      expect(result, 'Prazo final: <DD/MM/YYYY>AF');
    });

    test('substitui data com offset da seção (offset 0)', () {
      final sectionRef = DateTime(2026, 2, 16);

      final result = MacroResolver.replaceDatesWithMacros(
        'Semana de 16/02/2026',
        sectionRef,
      );

      expect(result, 'Semana de <DD/MM/YYYY>');
    });

    test('substitui data com offset positivo da seção', () {
      final sectionRef = DateTime(2026, 2, 16);

      final result = MacroResolver.replaceDatesWithMacros(
        'Prova em 23/02/2026',
        sectionRef,
      );

      expect(result, 'Prova em <DD/MM/YYYY + 7>');
    });

    test('substitui data com offset negativo da seção', () {
      final sectionRef = DateTime(2026, 2, 23);

      final result = MacroResolver.replaceDatesWithMacros(
        'Revisão de 16/02/2026',
        sectionRef,
      );

      expect(result, 'Revisão de <DD/MM/YYYY - 7>');
    });

    test('prioridade: AI > AF > seção', () {
      final sectionRef = DateTime(2026, 2, 16);
      final openDate = DateTime(2026, 2, 16);
      final closeDate = DateTime(2026, 2, 23);

      // A data 16/02/2026 é tanto sectionRef (offset 0) quanto openDate (AI)
      // Deve priorizar AI
      final result = MacroResolver.replaceDatesWithMacros(
        'De 16/02/2026 a 23/02/2026',
        sectionRef,
        activityOpenDate: openDate,
        activityCloseDate: closeDate,
      );

      expect(result, 'De <DD/MM/YYYY>AI a <DD/MM/YYYY>AF');
    });

    test('múltiplas datas no mesmo texto', () {
      final sectionRef = DateTime(2026, 2, 16);
      final openDate = DateTime(2026, 2, 16);
      final closeDate = DateTime(2026, 3, 1);

      final result = MacroResolver.replaceDatesWithMacros(
        'Início: 16/02/2026, Fim: 01/03/2026, Extra: 20/02/2026',
        sectionRef,
        activityOpenDate: openDate,
        activityCloseDate: closeDate,
      );

      expect(
        result,
        'Início: <DD/MM/YYYY>AI, Fim: <DD/MM/YYYY>AF, Extra: <DD/MM/YYYY + 4>',
      );
    });

    test('texto sem datas permanece inalterado', () {
      final sectionRef = DateTime(2026, 2, 16);

      final result = MacroResolver.replaceDatesWithMacros(
        'Atividade sem datas',
        sectionRef,
      );

      expect(result, 'Atividade sem datas');
    });

    test('data sem zero à esquerda: d/M/yyyy', () {
      final sectionRef = DateTime(2026, 2, 16);
      final openDate = DateTime(2026, 4, 3);

      final result = MacroResolver.replaceDatesWithMacros(
        'Entrega 3/4/2026',
        sectionRef,
        activityOpenDate: openDate,
      );

      expect(result, 'Entrega <DD/MM/YYYY>AI');
    });

    test('data mista: dd/M/yyyy e d/MM/yyyy', () {
      final sectionRef = DateTime(2026, 2, 16);

      final result = MacroResolver.replaceDatesWithMacros(
        'De 16/2/2026 a 3/02/2026',
        sectionRef,
      );

      expect(result, contains('<DD/MM/YYYY>'));
    });

    test('ida e volta: replaceDates → resolve produz texto original', () {
      final sectionRef = DateTime(2026, 2, 16);
      final openDate = DateTime(2026, 4, 24);
      final closeDate = DateTime(2026, 5, 1);
      final original = 'De 24/04/2026 até 01/05/2026 ref 16/02/2026';

      final macros = MacroResolver.replaceDatesWithMacros(
        original,
        sectionRef,
        activityOpenDate: openDate,
        activityCloseDate: closeDate,
      );

      final resolved = MacroResolver.resolve(
        macros,
        sectionRef,
        sectionRef,
        openDate,
        closeDate,
      );

      expect(resolved, original);
    });
  });
}
