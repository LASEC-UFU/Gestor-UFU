import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:puppeteer/puppeteer.dart';
import 'package:config_moodle/data/services/sei_plano_html_merger.dart';

typedef PlanoEnsinoLog = void Function(String message);

class PlanosEnsinoAutomationService {
  Browser? _browser;
  Page? _page;

  bool get isConnected =>
      _browser?.isConnected == true && _page != null && !_page!.isClosed;

  Future<void> focus() async {
    if (isConnected) await _page!.bringToFront();
  }

  Future<String> openBrowser(String url) async {
    if (isConnected) {
      await _page!.goto(url, wait: Until.domContentLoaded);
      await _page!.bringToFront();
      return _page!.url ?? url;
    }
    final edge = await _findEdge();
    if (edge == null) throw StateError('Microsoft Edge não foi encontrado.');
    final profile = _profileDirectory();
    await Directory(profile).create(recursive: true);
    _browser = await puppeteer.launch(
      executablePath: edge,
      headless: false,
      defaultViewport: null,
      userDataDir: profile,
      args: const ['--start-maximized'],
      timeout: const Duration(seconds: 45),
      waitForInitialPage: true,
    );
    final pages = await _browser!.pages;
    _page = pages.isEmpty ? await _browser!.newPage() : pages.first;
    await _page!.goto(url, wait: Until.domContentLoaded);
    await _page!.bringToFront();
    return _page!.url ?? url;
  }

  Future<void> insertPlan(Map<String, dynamic> plan, PlanoEnsinoLog log) async {
    if (!isConnected || _page == null) {
      throw StateError(
        'Abra o SEI no Edge e deixe aberto o processo que receberá o plano.',
      );
    }
    final currentPage = _page!;
    final host = Uri.tryParse(currentPage.url ?? '')?.host.toLowerCase() ?? '';
    if (!host.contains('sei.ufu.br')) {
      throw StateError('A página atual do Edge não é o SEI da UFU.');
    }

    final alreadyAtMetadata = await currentPage.evaluate<bool>(
      _isMetadataFormScript,
    );
    final alreadyAtTypeChoice = await currentPage.evaluate<bool>(
      _isTypeChoiceScript,
    );
    if (!alreadyAtMetadata && !alreadyAtTypeChoice) {
      await _waitFor<bool>(() async {
        return await currentPage.evaluate<bool>(_clickIncludeDocumentScript);
      }, const Duration(seconds: 12));
      log('SEI: iniciada a inclusão de documento.');
    }

    if (!alreadyAtMetadata) {
      final typeChosen = await _waitFor<bool>(() async {
        final result = await currentPage.evaluate<bool>(
          _choosePlanTypeScript,
          args: const ['Plano de Ensino'],
        );
        if (result) return true;
        await currentPage.evaluate<bool>(
          _filterPlanTypeScript,
          args: const ['Plano de Ensino'],
        );
        return await currentPage.evaluate<bool>(
          _choosePlanTypeScript,
          args: const ['Plano de Ensino'],
        );
      }, const Duration(seconds: 25));
      if (!typeChosen)
        throw StateError(
          'Não encontrei o tipo Plano de Ensino na escolha de documentos.',
        );
      log('SEI: tipo Plano de Ensino selecionado.');
    } else {
      log('SEI: retomando o formulário de metadados já aberto.');
    }

    final ident = Map<String, dynamic>.from(plan['identificacao'] as Map);
    final name = (ident['nome'] ?? '').toString().trim();
    final code = (ident['codigo'] ?? '').toString().trim();
    final cutName = name.length <= 50
        ? name
        : name.substring(0, 50).trimRight();
    final lastSpace = cutName.lastIndexOf(' ');
    final treeName = name.length <= 50 || lastSpace < 1
        ? cutName
        : cutName.substring(0, lastSpace);
    final metadataReady = await _waitFor<bool>(() async {
      return await currentPage.evaluate<bool>(
        _fillPlanMetadataScript,
        args: [
          <String, String>{
            'descricao': '$code - $name',
            'numero': code,
            'arvore': treeName,
          },
        ],
      );
    }, const Duration(seconds: 20));
    if (!metadataReady)
      throw StateError(
        'Não consegui preencher os metadados do Plano de Ensino.',
      );
    log('SEI: descrição, código, nome na árvore e acesso público conferidos.');

    final saved = await currentPage.evaluate<bool>(_saveMetadataScript);
    if (!saved) throw StateError('Não encontrei o botão Salvar dos metadados.');
    log('SEI: metadados salvos; aguardando o editor do documento.');

    final editor = await _waitFor<(Page, String)?>(
      () async => _findEditor(),
      const Duration(seconds: 35),
    );
    if (editor == null)
      throw StateError(
        'O editor do SEI não abriu o modelo de Plano de Ensino.',
      );
    final editorPage = editor.$1;
    final rootName = editor.$2;
    final modelHtml = await editorPage.evaluate<String?>(
      _readEditorHtmlScript,
      args: [rootName],
    );
    if (modelHtml == null || modelHtml.trim().isEmpty) {
      throw StateError(
        'Não consegui ler o modelo nativo do editor do SEI. Nenhum conteúdo foi alterado.',
      );
    }
    final merged = SeiPlanoHtmlMerger.merge(modelHtml, plan);
    final applied = await editorPage.evaluate<bool>(
      _setEditorHtmlScript,
      args: [rootName, merged.html],
    );
    if (!applied)
      throw StateError('Não consegui substituir o conteúdo no editor do SEI.');
    log(
      'SEI: ${merged.substitutions} correspondências aplicadas ao modelo nativo; cronogramas com ${((plan['cronograma_teorico'] as List?)?.length ?? 0)} aulas teóricas e ${((plan['cronograma_pratico'] as List?)?.length ?? 0)} práticas; estrutura e formatação do SEI preservadas.',
    );
    final commitClicked = await editorPage.evaluate<bool>(
      _clickEditorSaveScript,
    );
    if (!commitClicked)
      throw StateError(
        'O editor recebeu o conteúdo, mas o botão Salvar não foi localizado.',
      );
    await _waitFor<bool>(
      () async => await editorPage.evaluate<bool>(_isEditorSavedScript),
      const Duration(seconds: 35),
    );
    await editorPage.bringToFront();
    log(
      'SEI: documento salvo como não assinado. Revise e assine manualmente no processo.',
    );
  }

  Future<(Page, String)?> _findEditor() async {
    final browser = _browser;
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

  Future<T> _waitFor<T>(Future<T> Function() action, Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final result = await action();
      if (result != null && result != false) return result;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw TimeoutException('Tempo esgotado aguardando o formulário do SEI.');
  }

  Future<String?> _findEdge() async {
    final candidates = <String>[
      r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
      if (Platform.environment['PROGRAMFILES(X86)'] case final path?)
        p.join(path, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      if (Platform.environment['PROGRAMFILES'] case final path?)
        p.join(path, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
    ];
    for (final path in candidates) {
      if (await File(path).exists()) return path;
    }
    return null;
  }

  String _profileDirectory() {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) {
      return p.join(
        Directory.systemTemp.path,
        'GestorUFU',
        'EdgePlanosEnsinoProfile',
      );
    }
    return p.join(local, 'GestorUFU', 'EdgePlanosEnsinoProfile');
  }

  Future<void> close() async {
    final browser = _browser;
    _browser = null;
    _page = null;
    if (browser?.isConnected == true) await browser!.close();
  }
}

const _clickIncludeDocumentScript = r'''() => {
  const norm = value => (value || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/\s+/g, ' ').trim();
  for (const element of document.querySelectorAll('a,button,input,img')) {
    const target = element.closest('a,button') || element;
    const text = norm([element.textContent, element.title, element.alt, element.value, target.textContent, target.title, target.getAttribute('aria-label')].filter(Boolean).join(' '));
    if ((target.href || '').toLowerCase().includes('documento_escolher_tipo') || text.includes('incluir documento') || text.includes('gerar documento')) {
      target.click();
      return true;
    }
  }
  return false;
}''';

const _isMetadataFormScript =
    r'''() => !!(document.getElementById('txtDescricao') || document.querySelector('[name="txtDescricao"]') )''';

const _isTypeChoiceScript = r'''() => {
  const text = (document.body?.innerText || '').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();
  return text.includes('escolha o tipo do documento');
}''';

const _choosePlanTypeScript = r'''(wanted) => {
  const norm = value => (value || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/\s+/g, ' ').trim();
  if (!norm(document.body?.innerText).includes('escolha o tipo do documento')) return false;
  const candidates = Array.from(document.querySelectorAll('a,button,[onclick],tr,li,td,span,div,p'))
    .filter(element => (element.offsetWidth || element.offsetHeight || element.getClientRects().length) && norm(element.textContent || element.value || element.title) === norm(wanted))
    .sort((a,b) => a.childElementCount - b.childElementCount);
  if (!candidates.length) return false;
  const item = candidates[0];
  const target = item.closest('a,button,[onclick]') || item.querySelector('a,button,[onclick]') || item;
  target.scrollIntoView({block:'center'});
  target.click();
  return true;
}''';

const _filterPlanTypeScript = r'''(value) => {
  const norm = text => (text || '').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();
  if (!norm(document.body?.innerText).includes('escolha o tipo do documento')) return false;
  const input = Array.from(document.querySelectorAll('input[type=text],input:not([type])')).find(el => el.offsetParent);
  if (!input) return false;
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  setter.call(input, value);
  input.dispatchEvent(new Event('input',{bubbles:true}));
  input.dispatchEvent(new Event('change',{bubbles:true}));
  return true;
}''';

const _fillPlanMetadataScript = r'''(data) => {
  const norm = value => (value || '').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();
  const field = id => document.getElementById(id) || document.querySelector('[name="'+id+'"]');
  const set = (element, value) => {
    if (!element) return false;
    element.value = value;
    element.dispatchEvent(new Event('input',{bubbles:true}));
    element.dispatchEvent(new Event('change',{bubbles:true}));
    return true;
  };
  const description = field('txtDescricao');
  const number = field('txtNumero');
  const tree = field('txtNomeArvore');
  if (!description || !number || !tree) return false;
  set(description,data.descricao); set(number,data.numero); set(tree,data.arvore);
  let access = document.querySelector('#rdoNivelAcesso0,input[name="rdoNivelAcesso"][value="0"]');
  if (!access) {
    const label = Array.from(document.querySelectorAll('label')).find(el => norm(el.textContent).trim() === 'publico');
    if (label) access = document.getElementById(label.htmlFor) || label.querySelector('input[type=radio]');
  }
  if (!access) return false;
  if (!access.checked) access.click();
  return description.value === data.descricao && number.value === data.numero && tree.value === data.arvore && access.checked;
}''';

const _saveMetadataScript = r'''() => {
  const norm = value => (value || '').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().trim();
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

const _setEditorHtmlScript = r'''(root, html) => {
  if (root.startsWith('ck:')) {
    const infra = window.infraEditor;
    if (!infra?.isReady || !infra.editor) return false;
    const data = {};
    for (const item of infra.editor.model.document.getRoots()) data[item.rootName] = infra.editor.getData({rootName:item.rootName});
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
  textarea.dispatchEvent(new Event('input',{bubbles:true}));
  textarea.dispatchEvent(new Event('change',{bubbles:true}));
  return !!(textarea.form || textarea.closest('form'));
}''';

const _readEditorHtmlScript = r'''(root) => {
  if (root.startsWith('ck:')) {
    const infra = window.infraEditor;
    if (!infra?.isReady || !infra.editor) return null;
    const name = root.substring(3);
    const roots = Array.from(infra.editor.model.document.getRoots());
    if (!roots.some(item => item.rootName === name)) return null;
    return infra.editor.getData({rootName:name});
  }
  const selector = root.substring(3);
  const textarea = document.getElementById(selector) || Array.from(document.querySelectorAll('textarea')).find(el => el.name === selector);
  return textarea?.value || null;
}''';

const _clickEditorSaveScript = r'''() => {
  const norm = value => (value || '').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().trim();
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
