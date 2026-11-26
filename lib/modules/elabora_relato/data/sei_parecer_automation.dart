import 'dart:async';
import 'dart:convert';

import 'package:puppeteer/puppeteer.dart';

import 'package:gestor_ufu/modules/elabora_relato/data/sei_parecer_html.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/platform/services/sei_automation_service.dart';

typedef ParecerLog = void Function(String message);

/// Estilos do editor do SEI capturados durante a inserção (CSS das classes
/// de parágrafo e a lista "Escolha o estilo").
typedef SeiEstilosCapturados = ({
  String css,
  List<Map<String, dynamic>> estilos,
});

/// Resultado da inserção: avisos da montagem, modelo nativo lido e estilos.
typedef ParecerInsercao = ({
  List<String> avisos,
  String modeloHtml,
  SeiEstilosCapturados? estilos,
});

/// Insere o parecer no SEI pelo Edge do módulo, como nos Planos de Ensino:
/// gera um documento "Parecer" no processo aberto (ou usa o editor de
/// Parecer já aberto), lê o modelo nativo, encaixa o rascunho nos campos e
/// salva sem assinar.
class SeiParecerAutomation {
  SeiParecerAutomation(this.sei);

  final SeiAutomationService sei;

  /// Há um editor de documento do SEI aberto no Edge do app?
  Future<bool> editorAberto() async => await _acharEditor() != null;

  Future<ParecerInsercao> inserir(
    Parecer parecer, {
    required ParecerLog log,
  }) async {
    final browser = sei.browser;
    final page = sei.page;
    if (browser == null || page == null) {
      throw StateError(
        'Abra o SEI pelo app (botão "Abrir Edge"), entre e abra o processo '
        'que receberá o parecer.',
      );
    }

    (Page, String)? editor = await _acharEditor();
    if (editor != null) {
      log(
        'SEI: editor de documento já aberto; o parecer será preenchido nele.',
      );
    } else {
      final host = Uri.tryParse(page.url ?? '')?.host.toLowerCase() ?? '';
      if (!host.contains('sei.')) {
        throw StateError('A aba do Edge controlada pelo app não está no SEI.');
      }
      await _gerarDocumento(parecer, log);
      editor = await _esperar(
        _acharEditor,
        const Duration(seconds: 40),
        'o editor do documento',
      );
    }
    final (editorPage, root) = editor!;

    final estilos = await _capturarEstilos(editorPage);
    final modelo = await editorPage.evaluate<String?>(
      _readEditorHtmlScript,
      args: [root],
    );
    if (modelo == null || modelo.trim().isEmpty) {
      throw StateError(
        'Não consegui ler o modelo do editor do SEI. Nada foi alterado.',
      );
    }
    final montado = SeiParecerHtmlMerger.merge(modelo, parecer);
    final aplicado = await editorPage.evaluate<bool>(
      _setEditorHtmlScript,
      args: [root, montado.html],
    );
    if (aplicado != true) {
      throw StateError('Não consegui substituir o conteúdo no editor do SEI.');
    }
    log('SEI: assunto, ementa, vocativo e as três seções aplicados ao modelo.');
    for (final aviso in montado.avisos) {
      log('Aviso: $aviso');
    }
    final salvou = await editorPage.evaluate<bool>(_clickEditorSaveScript);
    if (salvou != true) {
      throw StateError(
        'O editor recebeu o parecer, mas o botão Salvar não foi encontrado. '
        'Clique em Salvar no SEI.',
      );
    }
    await _esperar<bool>(
      () async => await editorPage.evaluate<bool>(_isEditorSavedScript) == true
          ? true
          : null,
      const Duration(seconds: 35),
      'o salvamento do documento',
    );
    await editorPage.bringToFront();
    log('SEI: parecer salvo (não assinado). Revise e assine no SEI.');
    return (avisos: montado.avisos, modeloHtml: modelo, estilos: estilos);
  }

  /// Lê os estilos do editor do SEI aberto (sem inserir nada).
  Future<SeiEstilosCapturados?> capturarEstilos() async {
    final editor = await _acharEditor();
    if (editor == null) return null;
    return _capturarEstilos(editor.$1);
  }

  Future<SeiEstilosCapturados?> _capturarEstilos(Page page) async {
    try {
      final raw = await page.evaluate<String?>(_captureStylesScript);
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final css = '${json['css'] ?? ''}';
      if (css.trim().isEmpty) return null;
      return (
        css: css,
        estilos: [
          for (final e in (json['estilos'] as List? ?? const []))
            if (e is Map) Map<String, dynamic>.from(e),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _gerarDocumento(Parecer parecer, ParecerLog log) async {
    final jaNoFormulario = await _emQualquerFrame<bool>(_isMetadataFormScript);
    if (jaNoFormulario != true) {
      final naEscolha = await _emQualquerFrame<bool>(_isTypeChoiceScript);
      if (naEscolha != true) {
        await _esperar<bool>(
          () => _emQualquerFrame<bool>(_clickIncludeDocumentScript),
          const Duration(seconds: 15),
          'o botão "Incluir Documento" do processo',
        );
        log('SEI: iniciada a inclusão de documento.');
      }
      await _esperar<bool>(
        () async {
          final ok = await _emQualquerFrame<bool>(
            _chooseTypeScript,
            args: const ['Parecer'],
          );
          if (ok == true) return true;
          await _emQualquerFrame<bool>(
            _filterTypeScript,
            args: const ['Parecer'],
          );
          return null;
        },
        const Duration(seconds: 25),
        'o tipo de documento "Parecer"',
      );
      log('SEI: tipo Parecer selecionado.');
    } else {
      log('SEI: retomando o formulário do documento já aberto.');
    }
    final descricao = parecer.descricaoSei.trim().isNotEmpty
        ? parecer.descricaoSei.trim()
        : parecer.assunto.trim();
    await _esperar<bool>(
      () => _emQualquerFrame<bool>(
        _fillMetadataScript,
        args: [
          descricao.length > 250 ? descricao.substring(0, 250) : descricao,
        ],
      ),
      const Duration(seconds: 20),
      'o formulário do documento',
    );
    log('SEI: descrição e nível de acesso público definidos.');
    final salvo = await _emQualquerFrame<bool>(_saveMetadataScript);
    if (salvo != true) {
      throw StateError('Não encontrei o botão Salvar do formulário do SEI.');
    }
    log('SEI: documento gerado; aguardando o editor.');
  }

  Future<(Page, String)?> _acharEditor() async {
    final browser = sei.browser;
    if (browser == null) return null;
    for (final page in await browser.pages) {
      if (page.isClosed) continue;
      try {
        final root = await page.evaluate<String?>(_editorRootScript);
        if (root != null) return (page, root);
      } catch (_) {}
    }
    return null;
  }

  Future<T?> _emQualquerFrame<T>(
    String script, {
    List<Object?> args = const [],
  }) async {
    final browser = sei.browser;
    if (browser == null) return null;
    for (final page in await browser.pages) {
      if (page.isClosed) continue;
      for (final frame in page.frames) {
        try {
          final r = await frame.evaluate<T?>(script, args: args);
          if (r != null && r != false) return r;
        } catch (_) {}
      }
    }
    return null;
  }

  Future<T> _esperar<T>(
    Future<T?> Function() acao,
    Duration limite,
    String descricao,
  ) async {
    final fim = DateTime.now().add(limite);
    while (DateTime.now().isBefore(fim)) {
      try {
        final r = await acao();
        if (r != null && r != false) return r;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    throw TimeoutException('Tempo esgotado aguardando $descricao.');
  }
}

const _clickIncludeDocumentScript = r'''() => {
  const norm = v => (v || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/\s+/g, ' ').trim();
  for (const e of document.querySelectorAll('a,button,input,img')) {
    const t = e.closest('a,button') || e;
    const text = norm([e.textContent, e.title, e.alt, e.value, t.textContent, t.title, t.getAttribute('aria-label')].filter(Boolean).join(' '));
    if ((t.href || '').toLowerCase().includes('documento_escolher_tipo') || text.includes('incluir documento') || text.includes('gerar documento')) {
      t.click();
      return true;
    }
  }
  return false;
}''';

const _isMetadataFormScript =
    r'''() => !!(document.getElementById('txtDescricao') || document.querySelector('[name="txtDescricao"]'))''';

const _isTypeChoiceScript =
    r'''() => (document.body?.innerText || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().includes('escolha o tipo do documento')''';

const _chooseTypeScript = r'''(wanted) => {
  const norm = v => (v || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/\s+/g, ' ').trim();
  if (!norm(document.body?.innerText).includes('escolha o tipo do documento')) return false;
  const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
  const items = Array.from(document.querySelectorAll('a,button,[onclick],tr,li,td,span,div,p'))
    .filter(e => visible(e) && norm(e.textContent || e.value || e.title) === norm(wanted))
    .sort((a, b) => a.childElementCount - b.childElementCount);
  if (!items.length) return false;
  const item = items[0];
  const target = item.closest('a,button,[onclick]') || item.querySelector('a,button,[onclick]') || item;
  target.scrollIntoView({block: 'center'});
  target.click();
  return true;
}''';

const _filterTypeScript = r'''(value) => {
  const norm = v => (v || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  if (!norm(document.body?.innerText).includes('escolha o tipo do documento')) return false;
  const input = Array.from(document.querySelectorAll('input[type=text],input:not([type])')).find(el => el.offsetParent);
  if (!input) return false;
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  setter.call(input, value);
  input.dispatchEvent(new Event('input', {bubbles: true}));
  input.dispatchEvent(new KeyboardEvent('keyup', {bubbles: true}));
  input.dispatchEvent(new Event('change', {bubbles: true}));
  return true;
}''';

const _fillMetadataScript = r'''(descricao) => {
  const norm = v => (v || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
  const field = id => document.getElementById(id) || document.querySelector('[name="' + id + '"]');
  const description = field('txtDescricao');
  if (!description) return false;
  if (descricao) {
    description.value = descricao;
    description.dispatchEvent(new Event('input', {bubbles: true}));
    description.dispatchEvent(new Event('change', {bubbles: true}));
  }
  let access = document.querySelector('#optPublico,#rdoNivelAcesso0,input[name="rdoNivelAcesso"][value="0"]');
  if (!access) {
    const label = Array.from(document.querySelectorAll('label')).find(el => norm(el.textContent) === 'publico');
    if (label) access = document.getElementById(label.htmlFor) || label.querySelector('input[type=radio]');
  }
  if (!access) return false;
  if (!access.checked) access.click();
  return access.checked && (!descricao || description.value === descricao);
}''';

const _saveMetadataScript = r'''() => {
  const norm = v => (v || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
  let button = document.querySelector('#btnSalvar');
  if (!button) button = Array.from(document.querySelectorAll('button,input[type=submit],input[type=button],a'))
    .find(el => norm(el.innerText || el.value || el.title) === 'salvar');
  if (!button || button.disabled) return false;
  button.click();
  return true;
}''';

const _editorRootScript = r'''() => {
  const infra = window.infraEditor;
  if (infra?.isReady && infra.editor) {
    const principal = document.querySelector('.infra-editor__secao-principal[id][contenteditable=true],div[id^="txaEditor_"][contenteditable=true]');
    if (principal) {
      const root = Array.from(infra.editor.model.document.getRoots()).find(item => item.rootName === principal.id);
      if (root) return 'ck:' + root.rootName;
    }
  }
  const textarea = document.querySelector('textarea[name^="txaEditor_"],textarea[id^="txaEditor_"]');
  return textarea ? 'ta:' + (textarea.id || textarea.name) : null;
}''';

const _readEditorHtmlScript = r'''(root) => {
  if (root.startsWith('ck:')) {
    const infra = window.infraEditor;
    if (!infra?.isReady || !infra.editor) return null;
    const name = root.substring(3);
    const roots = Array.from(infra.editor.model.document.getRoots());
    if (!roots.some(item => item.rootName === name)) return null;
    return infra.editor.getData({rootName: name});
  }
  const selector = root.substring(3);
  const textarea = document.getElementById(selector) || Array.from(document.querySelectorAll('textarea')).find(el => el.name === selector);
  return textarea?.value || null;
}''';

const _setEditorHtmlScript = r'''(root, html) => {
  if (root.startsWith('ck:')) {
    const infra = window.infraEditor;
    if (!infra?.isReady || !infra.editor) return false;
    const data = {};
    for (const item of infra.editor.model.document.getRoots()) data[item.rootName] = infra.editor.getData({rootName: item.rootName});
    const name = root.substring(3);
    if (!(name in data)) return false;
    data[name] = html;
    infra.editor.setData(data);
    return true;
  }
  const selector = root.substring(3);
  const textarea = document.getElementById(selector) || Array.from(document.querySelectorAll('textarea')).find(el => el.name === selector);
  if (!textarea) return false;
  textarea.value = html;
  textarea.textContent = html;
  textarea.dispatchEvent(new Event('input', {bubbles: true}));
  textarea.dispatchEvent(new Event('change', {bubbles: true}));
  return true;
}''';

const _clickEditorSaveScript = r'''() => {
  const norm = v => (v || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
  const button = Array.from(document.querySelectorAll('button,input[type=button],input[type=submit],a')).find(el => norm(el.innerText || el.value || el.title) === 'salvar');
  if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true') return false;
  button.click();
  return true;
}''';

const _isEditorSavedScript = r'''() => {
  const infra = window.infraEditor;
  if (infra?.editor?.plugins?.has('Salvar')) {
    const save = infra.editor.plugins.get('Salvar');
    return !save.isSaving && !save.isDirty;
  }
  return document.readyState === 'complete';
}''';

/// CSS das classes de parágrafo (p.Classe) e a lista de estilos do editor.
const _captureStylesScript = r'''() => {
  const css = [];
  for (const sheet of Array.from(document.styleSheets)) {
    let rules;
    try { rules = sheet.cssRules; } catch (e) { continue; }
    for (const r of Array.from(rules || [])) {
      if (r.selectorText && /(^|,)\s*(p|table|td|span|div)\.[A-Za-z_]/.test(r.selectorText) && !/ck-|infra-/.test(r.selectorText)) css.push(r.cssText);
    }
  }
  let estilos = [];
  try {
    const defs = window.infraEditor?.editor?.config?.get('style.definitions') || [];
    estilos = defs.map(d => ({name: d.name, element: d.element, classes: d.classes}));
  } catch (e) {}
  return JSON.stringify({css: css.join('\n'), estilos});
}''';
