import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:puppeteer/puppeteer.dart';

typedef PlanoTrabalhoLog = void Function(String message);

/// Cadastro de documento externo Plano no SEI, controlado pelo Puppeteer/Dart.
class PlanoTrabalhoAutomationService {
  Browser? _browser;
  Page? _page;
  bool get isConnected =>
      _browser?.isConnected == true && _page != null && !_page!.isClosed;

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

  Future<void> focus() async {
    if (isConnected) await _page!.bringToFront();
  }

  Future<void> insertPlan({
    required String pdfPath,
    required String numero,
    required String nomeArvore,
    required String interessado,
    required PlanoTrabalhoLog log,
  }) async {
    final browser = _browser;
    if (!isConnected || browser == null) {
      throw StateError('Abra o Edge, entre no SEI e deixe aberto o processo.');
    }
    final file = File(pdfPath);
    if (!await file.exists() || p.extension(pdfPath).toLowerCase() != '.pdf') {
      throw StateError('Selecione um arquivo PDF existente.');
    }
    final header = await file.open();
    try {
      final signature = await header.read(1024);
      if (!String.fromCharCodes(signature).contains('%PDF-')) {
        throw StateError('O arquivo selecionado não parece ser um PDF válido.');
      }
    } finally {
      await header.close();
    }
    final host = Uri.tryParse(_page!.url ?? '')?.host.toLowerCase() ?? '';
    if (!host.contains('sei.ufu.br')) {
      throw StateError('A janela atual não está no SEI da UFU.');
    }
    final cleanNumber = numero.trim();
    final cleanTree = nomeArvore.trim();
    if (cleanNumber.isEmpty && cleanTree.isEmpty) {
      throw StateError('Informe o número ou o nome na árvore do documento.');
    }
    final day = DateTime.now();
    final date =
        '${day.day.toString().padLeft(2, '0')}/'
        '${day.month.toString().padLeft(2, '0')}/${day.year}';
    final before = await _documentNodes();

    if (await _anyFrame<bool>(_isMetadataFormScript) != true) {
      if (await _anyFrame<bool>(_isTypeChoiceScript) != true) {
        await _waitUntil(
          () => _anyFrame<bool>(_clickIncludeDocumentScript),
          'o comando Incluir Documento',
        );
        log('SEI: inclusão de documento iniciada.');
      }
      await _waitUntil(() async {
        if (await _anyFrame<bool>(_chooseExternalTypeScript) == true)
          return true;
        await _anyFrame<bool>(_filterExternalTypeScript);
        return await _anyFrame<bool>(_chooseExternalTypeScript);
      }, 'o tipo Externo na lista de documentos');
    }
    log('SEI: tipo de documento Externo selecionado.');

    final metadata = await _waitUntilValue<Map<String, dynamic>>(
      () => _anyFrame<Map<String, dynamic>>(
        _fillMetadataScript,
        args: [
          <String, String>{
            'date': date,
            'number': cleanNumber,
            'tree': cleanTree,
          },
        ],
      ),
      'o formulário de documento externo',
    );
    if (metadata['error'] != null) throw StateError('${metadata['error']}');
    log(
      'SEI: documento Plano, data $date, nato-digital e acesso público conferidos.',
    );

    if (interessado.trim().isNotEmpty) {
      await _includeInterested(interessado.trim());
      log('SEI: interessado selecionado.');
    }
    await _attachPdf(file);
    log('SEI: PDF anexado e nome do arquivo confirmado.');

    var alertText = '';
    final dialogSubscriptions = <StreamSubscription<Dialog>>[];
    for (final page in await browser.pages) {
      dialogSubscriptions.add(
        page.onDialog.listen((dialog) async {
          alertText = dialog.message ?? '';
          await dialog.accept();
        }),
      );
    }
    try {
      final saved = await _anyFrame<bool>(_saveExternalScript);
      if (saved != true)
        throw StateError('Não encontrei o botão Salvar do SEI.');
      log('SEI: salvando o documento externo.');
      await _waitUntil(() async {
        if (alertText.isNotEmpty) return true;
        final nodes = await _documentNodes();
        final beforeKeys = before.map(_nodeKey).toSet();
        final identifier = _normalize(
          cleanNumber.isNotEmpty ? cleanNumber : cleanTree,
        );
        return nodes.any((node) {
          if (beforeKeys.contains(_nodeKey(node))) return false;
          final text = _normalize('${node['text']} ${node['title']}');
          return text.contains('plano') &&
              (identifier.isEmpty || text.contains(identifier));
        });
      }, 'a confirmação do documento na árvore do processo');
    } finally {
      for (final subscription in dialogSubscriptions) {
        await subscription.cancel();
      }
    }
    if (alertText.isNotEmpty) {
      throw StateError('O SEI exibiu um alerta ao salvar: $alertText');
    }
    log('SEI: documento confirmado na árvore do processo.');
  }

  Future<void> _attachPdf(File file) async {
    final pages = await _browser!.pages;
    for (final page in pages) {
      for (final frame in page.frames) {
        try {
          final hasForm = await frame.evaluate<bool>(_isMetadataFormScript);
          if (!hasForm) continue;
          final chooserFuture = page.waitForFileChooser(
            timeout: const Duration(seconds: 10),
          );
          final clicked = await frame.evaluate<bool>(_clickFileInputScript);
          if (!clicked) continue;
          final chooser = await chooserFuture;
          await chooser.accept([file]);
          await _waitUntil(
            () => frame.evaluate<bool>(
              _hasPdfNameScript,
              args: [p.basename(file.path)],
            ),
            'a confirmação do PDF no formulário',
            timeout: const Duration(seconds: 60),
          );
          return;
        } catch (_) {
          // O SEI pode atualizar o formulário/frame entre detecção e anexo.
        }
      }
    }
    throw StateError(
      'Não consegui anexar ou confirmar o PDF no formulário do SEI.',
    );
  }

  Future<void> _includeInterested(String name) async {
    final already = await _anyFrame<bool>(
      _interestedSelectedScript,
      args: [name],
    );
    if (already == true) return;
    final field = await _anyFrame<bool>(_fillInterestedScript, args: [name]);
    if (field != true)
      throw StateError('Não encontrei o campo Interessados do SEI.');
    await _waitUntil(
      () => _anyFrame<bool>(_selectInterestedSuggestionScript, args: [name]),
      'a sugestão exata do interessado "$name"',
      timeout: const Duration(seconds: 20),
    );
    await _waitUntil(
      () => _anyFrame<bool>(_interestedSelectedScript, args: [name]),
      'a inclusão do interessado no formulário',
    );
  }

  Future<List<Map<String, dynamic>>> _documentNodes() async {
    return await _anyFrame<List<Map<String, dynamic>>>(_treeNodesScript) ?? [];
  }

  Future<T?> _anyFrame<T>(
    String script, {
    List<Object?> args = const [],
  }) async {
    final browser = _browser;
    if (browser == null) return null;
    for (final page in await browser.pages) {
      if (page.isClosed) continue;
      for (final frame in page.frames) {
        try {
          final result = await frame.evaluate<T?>(script, args: args);
          if (result != null && result != false) return result;
        } catch (_) {
          // A página/frame pode navegar enquanto o SEI atualiza a interface.
        }
      }
    }
    return null;
  }

  Future<void> _waitUntil(
    Future<bool?> Function() check,
    String description, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    await _waitUntilValue<bool>(
      () async => await check() == true ? true : null,
      description,
      timeout: timeout,
    );
  }

  Future<T> _waitUntilValue<T>(
    Future<T?> Function() check,
    String description, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final result = await check();
        if (result != null && result != false) return result;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    throw TimeoutException('Tempo esgotado aguardando $description.');
  }

  String _nodeKey(Map<String, dynamic> node) =>
      '${node['href'] ?? ''}|${node['id'] ?? ''}';

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

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
    return p.join(
      local ?? Directory.systemTemp.path,
      'GestorUFU',
      'EdgePlanoTrabalhoProfile',
    );
  }

  Future<void> close() async {
    final browser = _browser;
    _browser = null;
    _page = null;
    if (browser?.isConnected == true) await browser!.close();
  }
}

const _clickIncludeDocumentScript = r'''() => {
 const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/\s+/g,' ').trim();
 for(const e of document.querySelectorAll('a,button,input,img')) { const a=e.closest('a,button')||e; const t=norm([e.textContent,e.title,e.alt,e.value,a.textContent,a.title,a.getAttribute('aria-label')].filter(Boolean).join(' ')); if((a.href||'').toLowerCase().includes('documento_escolher_tipo')||t.includes('incluir documento')||t.includes('gerar documento')){a.click();return true;} } return false;
}''';
const _isMetadataFormScript =
    r'''() => !!(document.getElementById('selSerie')||document.querySelector('[name="selSerie"]'))''';
const _isTypeChoiceScript =
    r'''() => (document.body?.innerText||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().includes('escolha o tipo do documento')''';
const _chooseExternalTypeScript = r'''() => {
 const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/\s+/g,' ').trim(); if(!norm(document.body?.innerText).includes('escolha o tipo do documento'))return false;
 const visible=e=>!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length); const items=[...document.querySelectorAll('a,button,[onclick],tr,li,td,span,div,p')].filter(e=>visible(e)&&norm(e.textContent||e.value||e.title)==='externo').sort((a,b)=>a.childElementCount-b.childElementCount); if(!items.length)return false; const item=items[0], target=item.closest('a,button,[onclick]')||item.querySelector('a,button,[onclick]')||item; target.click();return true;
}''';
const _filterExternalTypeScript = r'''() => {
 const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();if(!norm(document.body?.innerText).includes('escolha o tipo do documento'))return false;const input=[...document.querySelectorAll('input[type=text],input:not([type])')].find(e=>e.offsetWidth||e.offsetHeight||e.getClientRects().length);if(!input)return false;const set=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;set.call(input,'Externo');input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new KeyboardEvent('keyup',{bubbles:true,key:'o'}));input.dispatchEvent(new Event('change',{bubbles:true}));return true;
}''';
const _fillMetadataScript = r'''(dados) => {
 const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/\s+/g,' ').trim();const campo=id=>document.getElementById(id)||document.querySelector(`[name="${id}"]`);const serie=campo('selSerie'),data=campo('txtDataElaboracao'),file=campo('filArquivo')||document.querySelector('input[type=file]');if(!serie||!data||!file)return null;const numero=campo('txtNumero'),arvore=campo('txtNomeArvore');if(dados.number&&!numero)return {error:'O campo Número não foi encontrado.'};if(dados.tree&&!arvore)return {error:'O campo Nome na Árvore não foi encontrado.'};const option=[...serie.options].find(o=>norm(o.textContent)==='plano');if(!option||option.disabled)return {error:'O tipo de documento externo Plano não está disponível.'};serie.value=option.value;serie.dispatchEvent(new Event('change',{bubbles:true}));const fill=(el,v)=>{if(!el)return;el.value=v;el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));};fill(data,dados.date);fill(numero,dados.number);fill(arvore,dados.tree);let nato=document.querySelector('#divOptNato input[type=radio]');if(!nato){const l=[...document.querySelectorAll('label')].find(x=>norm(x.textContent).includes('nato-digital'));if(l)nato=(l.htmlFor&&document.getElementById(l.htmlFor))||l.querySelector('input[type=radio]');}if(!nato)return {error:'A opção Nato-digital não foi encontrada.'};if(!nato.checked)nato.click();let pub=campo('rdoNivelAcesso0')||document.querySelector('input[name="rdoNivelAcesso"][value="0"]');if(!pub){const l=[...document.querySelectorAll('label')].find(x=>norm(x.textContent)==='publico');if(l)pub=(l.htmlFor&&document.getElementById(l.htmlFor))||l.querySelector('input[type=radio]');}if(!pub)return {error:'A opção de acesso Público não foi encontrada.'};if(!pub.checked)pub.click();if(!nato.checked||!pub.checked||serie.value!==option.value||data.value!==dados.date||(dados.number&&numero.value!==dados.number)||(dados.tree&&arvore.value!==dados.tree))return {error:'O SEI não manteve os dados informados; confira o formulário.'};return {ok:true};
}''';
const _interestedSelectedScript =
    r'''(name) => {const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/\s+/g,' ').trim(),target=norm(name);return [...document.querySelectorAll('select[id*="nteress"],select[name*="nteress"]')].some(s=>[...s.options].some(o=>norm(o.textContent)===target));}''';
const _fillInterestedScript =
    r'''(name) => {const input=document.getElementById('txtInteressado')||document.getElementById('txtInteressados')||document.querySelector('input[name="txtInteressado"],input[name="txtInteressados"]')||[...document.querySelectorAll('label')].find(l=>/interessados?/i.test(l.textContent))?.parentElement?.querySelector('input[type=text]');if(!input)return false;input.focus();input.value=name;input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));return true;}''';
const _selectInterestedSuggestionScript =
    r'''(name) => {const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/\s+/g,' ').trim(),target=norm(name),items=[...document.querySelectorAll('.ui-autocomplete li,.ac_results li,[role=listbox] [role=option],.infraAutoCompletar li')];for(const item of items){if(!(item.offsetWidth||item.offsetHeight||item.getClientRects().length)||norm(item.textContent)!==target)continue;(item.querySelector('a')||item).click();return true;}return false;}''';
const _clickFileInputScript =
    r'''() => {if(!document.getElementById('selSerie'))return false;const input=document.getElementById('filArquivo')||document.querySelector('input[type=file]');if(!input)return false;input.click();return true;}''';
const _hasPdfNameScript =
    r'''(name) => {if(!document.getElementById('selSerie'))return false;return [...document.querySelectorAll('.infraSpanNomeArquivo')].some(e=>(e.textContent||'').trim().toLowerCase().includes(name.toLowerCase()));}''';
const _saveExternalScript =
    r'''() => {if(!document.getElementById('selSerie'))return false;const button=document.getElementById('btnSalvar');if(!button||button.disabled)return false;button.click();return true;}''';
const _treeNodesScript =
    r'''() => {const norm=s=>(s||'').replace(/\s+/g,' ').trim(),seen=new Set(),out=[];for(const a of document.querySelectorAll('a[href],a[id^="anchor"]')){const href=a.getAttribute('href')||'',id=a.id||'',target=a.getAttribute('target')||'';if(!(href.includes('documento_visualizar')||/visualizacao/i.test(target)||/^anchor\d+$/i.test(id)))continue;const key=href+'|'+id,text=norm([a.textContent,a.title,a.getAttribute('aria-label')].filter(Boolean).join(' '));if(seen.has(key)||!text)continue;seen.add(key);out.push({text,title:norm(a.title||''),href,id});}return out;}''';
