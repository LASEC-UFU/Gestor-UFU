import 'dart:async';

import 'package:puppeteer/puppeteer.dart';

import 'package:gestor_ufu/modules/progressao/application/progressao_requerimento_sei_html.dart';
import 'package:gestor_ufu/modules/progressao/application/progressao_sei_text.dart';
import 'package:gestor_ufu/modules/progressao/domain/progressao.dart';
import 'package:gestor_ufu/platform/services/sei_automation_service.dart';

class ProgressaoSeiRequerimento {
  ProgressaoSeiRequerimento(this.sei);

  static const hipotesePessoal =
      'Informação Pessoal (Art. 31 da Lei nº 12.527/2011)';

  final SeiAutomationService sei;

  /// Aguarda login humano; não lê nem preenche credenciais.
  Future<void> aguardarLogin({
    required SeiLog log,
    bool Function()? cancelado,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    // Não use _checkReady() aqui: antes do login o SEI redireciona para o
    // SIP (sip.ufu.br), e a espera precisa tolerar essa página.
    if (!sei.isConnected) {
      throw StateError('Abra o Edge do SEI e entre no portal.');
    }
    log(
      'SEI: aguardando login manual; depois confirme a unidade antes de criar.',
    );
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cancelado?.call() == true) {
        throw StateError('A espera pelo login no SEI foi interrompida.');
      }
      if (!sei.isConnected) {
        throw StateError('A conexão com o Edge foi encerrada durante o login.');
      }
      if (await sei.adotarAbaSei() &&
          await _anyFrame<bool>(_loggedInScript) == true) {
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw TimeoutException('Login no SEI não foi concluído.');
  }

  Future<String> iniciarProcesso(
    ProgressaoDocente processo, {
    required String tipo,
    required String especificacao,
    required String interessado,
    required String hipoteseLegal,
    required SeiLog log,
  }) async {
    _checkReady();
    final unidade = await unidadeAtual();
    if (unidade.trim().isEmpty) {
      throw StateError(
        'Selecione uma unidade do SEI antes de criar o processo.',
      );
    }
    log(
      'SEI: unidade atual: ${unidade.isEmpty ? "não identificada" : unidade}.',
    );
    var atMetadata = await _anyFrame<bool>(_isProcessMetadataScript) == true;
    if (!atMetadata) {
      final clicked = await _wait<bool>(
        () => _anyFrame<bool>(_clickStartProcessScript),
        'o comando Iniciar Processo',
      );
      if (!clicked) throw StateError('Não encontrei Iniciar Processo no SEI.');
      log('SEI: iniciando processo $tipo.');
      final typeSelected = await _wait<bool>(() async {
        // O clique no tipo navega para o formulário e pode derrubar o retorno
        // do script; o formulário aberto confirma a escolha.
        if (await _anyFrame<bool>(_isProcessMetadataScript) == true) {
          return true;
        }
        var ok = await _anyFrame<bool>(_chooseProcessTypeScript, args: [tipo]);
        if (ok == true) return true;
        await _anyFrame<bool>(_showAllProcessTypesScript);
        ok = await _anyFrame<bool>(_chooseProcessTypeScript, args: [tipo]);
        return ok == true ? true : null;
      }, 'o tipo de processo "$tipo"');
      if (!typeSelected)
        throw StateError('O tipo de processo "$tipo" não foi localizado.');
      atMetadata = await _wait<bool>(
        () => _anyFrame<bool>(_isProcessMetadataScript),
        'o formulário de autuação do processo',
      );
    }
    if (!atMetadata)
      throw StateError('O formulário de autuação do processo não abriu.');
    final numeroAnterior = await numeroProcessoAtual();
    final filled = await _anyFrame<Map<String, dynamic>>(
      _fillProcessMetadataScript,
      args: [
        <String, String>{
          'specification': especificacao,
          'interested': interessado,
          'hypothesis': hipoteseLegal,
        },
      ],
    );
    if (filled == null || filled['ok'] != true) {
      throw StateError(
        '${filled?['error'] ?? 'Não consegui preencher os metadados do processo.'}',
      );
    }
    final interessadoSelecionado = await _wait<bool>(
      () => _anyFrame<bool>(_selectInterestedScript, args: [interessado]),
      'a seleção do interessado na lista do SEI',
    );
    if (!interessadoSelecionado) {
      throw StateError('Selecione o docente na lista de interessados do SEI.');
    }
    log('SEI: especificação, interessado e acesso restrito conferidos.');
    final saved = await _anyFrame<bool>(_saveProcessScript);
    if (saved != true)
      throw StateError('Não encontrei Salvar na autuação do processo.');
    log('SEI: processo salvo; identificando o número gerado.');
    final number = await _wait<String?>(() async {
      final value = await numeroProcessoAtual();
      return value.isEmpty || value == numeroAnterior ? null : value;
    }, 'o número do processo criado');
    log('SEI: processo criado: $number.');
    if (number == null || number.isEmpty) {
      throw StateError('O SEI não apresentou o número do processo criado.');
    }
    return number;
  }

  Future<void> abrirProcesso(String numero) async {
    _checkReady();
    final normalized = numero.trim();
    if (normalized.isEmpty) return;
    if (await numeroProcessoAtual() == normalized &&
        (sei.currentUrl ?? '').contains('procedimento_trabalhar')) {
      return;
    }
    final search = await _anyFrame<bool>(
      _searchProcessScript,
      args: [normalized],
    );
    if (search != true)
      throw StateError('Campo Pesquisa Rápida não encontrado no SEI.');
    await _wait<bool>(() async {
      final atual = await numeroProcessoAtual();
      return atual == normalized &&
              ((sei.currentUrl ?? '').contains('procedimento_trabalhar'))
          ? true
          : null;
    }, 'a abertura do processo $normalized');
  }

  /// O Edge controlado está no SEI com sessão ativa (menu "Iniciar Processo")?
  Future<bool> estaLogado() async {
    if (!sei.isConnected) return false;
    await sei.adotarAbaSei();
    final host = Uri.tryParse(sei.currentUrl ?? '')?.host.toLowerCase() ?? '';
    if (!host.contains('sei.ufu.br')) return false;
    return await _anyFrame<bool>(_loggedInScript) == true;
  }

  Future<String> numeroProcessoAtual() async {
    if (!sei.isConnected) return '';
    final number = await _anyFrame<String>(_currentProcessNumberScript);
    return number?.trim() ?? '';
  }

  Future<String> unidadeAtual() async {
    if (!sei.isConnected) return '';
    return await _anyFrame<String>(_currentUnitScript) ?? '';
  }

  Future<bool> inserirRequerimento(
    ProgressaoDocente processo, {
    required SeiLog log,
  }) async {
    _checkReady();
    const nome = 'Requerimento de Progressão / Promoção Docente';
    if (await sei.existeDocumento([nome])) {
      final aberto = await _editorDoRequerimentoAberto(nome);
      if (aberto != null) {
        log('SEI: requerimento existente com editor aberto; preenchendo.');
        return _preencherEditor(aberto, processo, log: log, nome: nome);
      }
      log('SEI: requerimento já existente; mantido sem duplicar.');
      return false;
    }
    var metadata =
        await _anyFrame<bool>(_isGeneratedDocumentFormScript) == true;
    if (!metadata) {
      var typeChoice = await _anyFrame<bool>(_isTypeChoiceScript) == true;
      if (!typeChoice) {
        await _wait<bool>(
          () => _anyFrame<bool>(_clickIncludeDocumentScript),
          'Incluir Documento',
        );
      }
      final chosen = await _wait<bool>(() async {
        var ok = await _anyFrame<bool>(_chooseDocumentTypeScript, args: [nome]);
        if (ok == true) return true;
        await _anyFrame<bool>(_filterDocumentTypeScript, args: [nome]);
        ok = await _anyFrame<bool>(_chooseDocumentTypeScript, args: [nome]);
        return ok == true ? true : null;
      }, 'o tipo de documento "$nome"');
      if (!chosen)
        throw StateError('O tipo de requerimento "$nome" não está disponível.');
      metadata = await _wait<bool>(
        () => _anyFrame<bool>(_isGeneratedDocumentFormScript),
        'o formulário de metadados do requerimento',
      );
    }
    if (!metadata) throw StateError('O formulário do requerimento não abriu.');
    final descriptor = descricaoRequerimentoSei(processo);
    final form = await _anyFrame<Map<String, dynamic>>(
      _fillRequestMetadataScript,
      args: [
        <String, String>{
          'description': descriptor.length > 250
              ? descriptor.substring(0, 250)
              : descriptor,
          'interested': processo.docente.trim(),
        },
      ],
    );
    if (form == null || form['ok'] != true) {
      throw StateError(
        '${form?['error'] ?? 'Não consegui preencher os metadados do requerimento.'}',
      );
    }
    final interessadoSelecionado = await _wait<bool>(
      () => _anyFrame<bool>(
        _selectInterestedScript,
        args: [processo.docente.trim()],
      ),
      'a seleção do interessado do requerimento',
    );
    if (!interessadoSelecionado) {
      throw StateError('Selecione o docente nos interessados do requerimento.');
    }
    final saved = await _anyFrame<bool>(_saveMetadataScript);
    if (saved != true)
      throw StateError('Não encontrei Salvar do formulário do requerimento.');
    log('SEI: requerimento gerado; aguardando o editor do modelo.');
    final editor = await _wait<(Page, String)?>(
      _findEditor,
      'o editor do requerimento',
    );
    if (editor == null) throw StateError('O editor do requerimento não abriu.');
    return _preencherEditor(editor, processo, log: log, nome: nome);
  }

  /// Editor aberto de um requerimento já gerado (ex.: execução anterior
  /// interrompida depois de criar o documento e antes de salvar o conteúdo).
  Future<(Page, String)?> _editorDoRequerimentoAberto(String nome) async {
    final editor = await _findEditor();
    if (editor == null) return null;
    try {
      final titulo = await editor.$1.title ?? '';
      return titulo.contains(nome) ? editor : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _preencherEditor(
    (Page, String) editor,
    ProgressaoDocente processo, {
    required SeiLog log,
    required String nome,
  }) async {
    final page = editor.$1;
    final root = editor.$2;
    final model = await page.evaluate<String?>(
      _readEditorHtmlScript,
      args: [root],
    );
    if (model == null || model.trim().isEmpty) {
      throw StateError(
        'Não consegui ler o modelo nativo. O requerimento não foi alterado.',
      );
    }
    final merged = ProgressaoRequerimentoSeiHtml.merge(model, processo);
    if (merged.ausentes.isNotEmpty) {
      throw StateError(
        'Modelo do requerimento divergente. Não salvei; campos não localizados: ${merged.ausentes.join(', ')}. O editor ficou aberto.',
      );
    }
    final applied = await page.evaluate<bool>(
      _setEditorHtmlScript,
      args: [root, merged.html],
    );
    if (applied != true)
      throw StateError('Não consegui aplicar os dados ao modelo do SEI.');
    final savedEditor = await page.evaluate<bool>(_clickEditorSaveScript);
    if (savedEditor != true)
      throw StateError(
        'Não encontrei Salvar no editor; revise e salve manualmente.',
      );
    await _wait<bool>(
      () async =>
          await page.evaluate<bool>(_isEditorSavedScript) == true ? true : null,
      'a gravação do requerimento',
    );
    await page.bringToFront();
    if (await sei.existeDocumento([nome])) {
      log(
        'SEI: requerimento preenchido e salvo, sem assinatura. Confira e assine manualmente.',
      );
      return true;
    }
    throw StateError(
      'O SEI não confirmou o requerimento na árvore do processo.',
    );
  }

  void _checkReady() {
    if (!sei.isConnected)
      throw StateError('Abra o Edge do SEI e entre no portal.');
    final host = Uri.tryParse(sei.currentUrl ?? '')?.host.toLowerCase() ?? '';
    if (!host.contains('sei.ufu.br'))
      throw StateError('O Edge controlado não está no SEI da UFU.');
  }

  Future<(Page, String)?> _findEditor() async {
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

  // Ignora resultados vazios (ex.: número do processo só existe em ifrArvore)
  // e alcança iframes cujo contexto o puppeteer perdeu.
  Future<T?> _anyFrame<T>(String script, {List<Object?> args = const []}) =>
      seiEvaluateAnyFrame<T>(sei.browser, script, args: args);

  Future<T> _wait<T>(Future<T?> Function() action, String description) async {
    final deadline = DateTime.now().add(const Duration(seconds: 35));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final result = await action();
        if (result != null && result != false) return result;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    throw TimeoutException('Tempo esgotado aguardando $description.');
  }
}

const _clickStartProcessScript = r'''() => {
 const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().trim();
 const items=[...document.querySelectorAll('a,button,[onclick]')];
 const el=items.find(e=>norm(e.textContent||e.title||e.getAttribute('aria-label'))==='iniciar processo');
 if(!el)return false;(el.closest('a,button,[onclick]')||el).click();return true;
}''';
const _loggedInScript = r'''() => {
 const n=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().trim();
 return [...document.querySelectorAll('a,button,[onclick]')].some(e=>n(e.textContent||e.title||e.getAttribute('aria-label'))==='iniciar processo');
}''';
const _selectInterestedScript = r'''(name) => {
 const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/\s+/g,' ').trim().toLowerCase();
 const target=norm(name);
 // A lista de interessados do SEI não marca as opções como selecionadas.
 const selected=[...document.querySelectorAll('select[id*="nteress"],select[name*="nteress"]')].some(s=>[...s.options].some(o=>norm(o.textContent).includes(target)));
 if(selected)return true;
 const candidates=[...document.querySelectorAll('.ui-autocomplete li,.ac_results li,[role=listbox] [role=option],.infraAutoCompletar li,[id*="Interessado"] li')];
 const item=candidates.find(e=>(e.offsetWidth||e.offsetHeight||e.getClientRects().length)&&norm(e.textContent).includes(target));
 if(!item)return false;
 // infraAjaxAutoCompletar escolhe o item no mousedown do <li>; o <a> só retorna false.
 item.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}));
 const after=[...document.querySelectorAll('select[id*="nteress"],select[name*="nteress"]')].some(s=>[...s.options].some(o=>norm(o.textContent).includes(target)));
 if(!after)(item.querySelector('a,button')||item).click();
 return false;
}''';
const _showAllProcessTypesScript = r'''() => {
 try{if(typeof window.exibirTiposProcedimento==='function'){window.exibirTiposProcedimento('T');return true;}}catch(e){}
 const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();
 const el=[...document.querySelectorAll('a,button,[onclick],img')].find(e=>norm([e.textContent,e.title,e.alt,e.getAttribute('aria-label')].join(' ')).includes('exibir todos os tipos'));
 if(el){(el.closest('a,button,[onclick]')||el).click();return true;}return false;
}''';
const _chooseProcessTypeScript = r'''(wanted) => {
 const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/\s+/g,' ').trim().toLowerCase();
 const candidates=[...document.querySelectorAll('a,button,[onclick],tr,td,span,div')].filter(e=>(e.offsetWidth||e.offsetHeight||e.getClientRects().length)&&norm(e.textContent)===norm(wanted)).sort((a,b)=>a.childElementCount-b.childElementCount);
 if(!candidates.length)return false;let el=candidates[0];for(let i=0;i<4&&el;i++,el=el.parentElement){if(el.matches('a,button,[onclick]')){el.click();return true;}}
 candidates[0].click();return true;
}''';
const _isProcessMetadataScript = r'''() => {
 const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/\s+/g,' ').trim().toLowerCase();
 // A lista "Escolha o Tipo do Processo" contém tipos com a palavra
 // "Especificação"; exija o campo do formulário, não só o texto da página.
 // Só a ação atual importa (o formulário traz acao_origem=procedimento_escolher_tipo).
 if(/[?&]acao=procedimento_escolher_tipo(&|$)/.test(location.href||''))return false;
 const known=document.getElementById('txtEspecificacao')||document.querySelector('[name="txtEspecificacao"]');
 if(known)return true;
 // SEI da UFU: formulário procedimento_gerar usa selTipoProcedimento + txtDescricao.
 if(document.getElementById('selTipoProcedimento')&&document.getElementById('txtDescricao'))return true;
 const visible=e=>!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length);
 const label=[...document.querySelectorAll('label')].find(l=>visible(l)&&norm(l.textContent).startsWith('especificacao'));
 return !!label&&norm(document.body?.innerText).includes('tipo do processo');
}''';
const _fillProcessMetadataScript = r'''async (d) => {
 const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/\s+/g,' ').trim();
 const field=id=>document.getElementById(id)||document.querySelector(`[name="${id}"]`);
 const byLabel=term=>{
  const label=[...document.querySelectorAll('label')].find(x=>norm(x.innerText||x.textContent).includes(term));
  if(!label)return null;
  if(label.htmlFor){const target=document.getElementById(label.htmlFor);if(target)return target;}
  for(let p=label.parentElement,depth=0;p&&p!==document.body&&depth<4;p=p.parentElement,depth++){
   const controls=[...p.querySelectorAll('input:not([type=hidden]),textarea')].filter(x=>x.offsetWidth||x.offsetHeight||x.getClientRects().length);
   if(controls.length===1)return controls[0];
  }
  return null;
 };
 const spec=field('txtEspecificacao')||field('txtDescricao')||byLabel('especificacao');if(!spec)return null; // formulário está em outro frame
 const fill=(el,v)=>{if(!el)return;el.value=v;el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));};
 fill(spec,d.specification);
 const interested=field('txtInteressadoProcedimento')||field('txtInteressado')||field('txtInteressados')||document.querySelector('input[name*="Interessado"],input[id*="Interessado"]')||byLabel('interessado');
 if(!interested)return {error:'Campo Interessado não localizado.'};
 interested.focus();fill(interested,d.interested);
 // O autocompletar do SEI (infraAjaxAutoCompletar) só pesquisa no keyup.
 const keyup=new KeyboardEvent('keyup',{key:'s',bubbles:true});
 Object.defineProperty(keyup,'keyCode',{get:()=>83});Object.defineProperty(keyup,'which',{get:()=>83});
 interested.dispatchEvent(keyup);
 const labels=[...document.querySelectorAll('label')];
 const r=field('optRestrito')||[...document.querySelectorAll('input[type=radio]')].find(x=>{const l=x.labels?.[0]||labels.find(y=>y.htmlFor===x.id);return norm(`${l?.textContent||''} ${x.parentElement?.textContent||''}`).includes('restrito');})||field('rdoNivelAcesso1');
 if(!r)return {error:'Opção de acesso Restrito não localizada.'};if(!r.checked)r.click();
 let hypothesis=field('selHipoteseLegal')||document.querySelector('select[name*="Hipotese"]');
 for(let i=0;!hypothesis&&i<10;i++){await new Promise(resolve=>setTimeout(resolve,200));hypothesis=field('selHipoteseLegal')||document.querySelector('select[name*="Hipotese"]');}
 if(!hypothesis)return {error:'Campo Hipótese Legal não apareceu após selecionar Restrito.'};
 // O SEI carrega as opções da hipótese depois de marcar Restrito.
 const findOption=()=>[...hypothesis.options].find(o=>norm(o.textContent).includes(norm(d.hypothesis)));
 let option=findOption();
 for(let i=0;!option&&i<40;i++){await new Promise(resolve=>setTimeout(resolve,250));option=findOption();}
 if(!option)return {error:'Hipótese Informação Pessoal (Art. 31) não disponível.'};
 hypothesis.value=option.value;hypothesis.dispatchEvent(new Event('change',{bubbles:true}));
 if(spec.value!==d.specification||!interested.value||!r.checked||hypothesis.value!==option.value)return {error:'O formulário não manteve os dados de autuação.'};
 return {ok:true};
}''';
const _saveProcessScript =
    r'''() => {const b=document.getElementById('btnSalvar')||[...document.querySelectorAll('button,input[type=submit],input[type=button]')].find(x=>(x.innerText||x.value||'').trim().toLowerCase()==='salvar');if(!b||b.disabled)return false;b.click();return true;}''';
const _currentProcessNumberScript = r'''() => {
 const m=(document.body?.innerText||'').match(/\b\d{5}\.\d{6}\/\d{4}-\d{2}\b/);return m?m[0]:'';
}''';
const _currentUnitScript = r'''() => {
 const norm=s=>(s||'').replace(/\s+/g,' ').trim();
 for(const e of document.querySelectorAll('[id*="Unidade"],[class*="unidade"],[title]')){const t=norm(e.textContent||e.title);if(t&&t.length<90&&/(FEELT|CADFEELT|COCCA|Unidade)/i.test(t))return t;}
 return '';
}''';
const _searchProcessScript = r'''(number) => {
 const input=document.getElementById('txtPesquisaRapida');if(!input)return false;
 input.focus();input.value=number;input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));
 input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));input.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
 if(input.form)input.form.requestSubmit?.();return true;
}''';
const _isGeneratedDocumentFormScript =
    r'''() => !!(document.getElementById('txtDescricao')||document.querySelector('[name="txtDescricao"]'))''';
const _chooseDocumentTypeScript = r'''(wanted) => {
 const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/\s+/g,' ').trim().toLowerCase();
 if(!norm(document.body?.innerText).includes('escolha o tipo do documento'))return false;
 const items=[...document.querySelectorAll('a,button,[onclick],tr,li,td,span,div,p')].filter(e=>(e.offsetWidth||e.offsetHeight||e.getClientRects().length)&&norm(e.textContent||e.value||e.title)===norm(wanted)).sort((a,b)=>a.childElementCount-b.childElementCount);
 if(!items.length)return false;let target=items[0];for(let i=0;i<4&&target;i++,target=target.parentElement){if(target.matches('a,button,[onclick]')){target.click();return true;}}
 items[0].click();return true;
}''';
const _filterDocumentTypeScript =
    r'''(value) => {const n=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();if(!n(document.body?.innerText).includes('escolha o tipo do documento'))return false;const i=[...document.querySelectorAll('input[type=text],input:not([type])')].find(x=>x.offsetWidth||x.offsetHeight);if(!i)return false;const set=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;set.call(i,value);i.dispatchEvent(new Event('input',{bubbles:true}));i.dispatchEvent(new Event('change',{bubbles:true}));return true;}''';
const _fillRequestMetadataScript = r'''(d) => {
 const norm=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/\s+/g,' ').trim();
 const desc=document.getElementById('txtDescricao')||document.querySelector('[name="txtDescricao"]');if(!desc)return null; // formulário está em outro frame
 desc.value=d.description;desc.dispatchEvent(new Event('input',{bubbles:true}));desc.dispatchEvent(new Event('change',{bubbles:true}));
 let access=document.querySelector('#rdoNivelAcesso0,input[name="rdoNivelAcesso"][value="0"],#optPublico');
 if(!access){const label=[...document.querySelectorAll('label')].find(x=>norm(x.textContent)==='publico');if(label)access=(label.htmlFor&&document.getElementById(label.htmlFor))||label.querySelector('input[type=radio]');}
 if(!access)return {error:'Opção de acesso Público do requerimento não localizada.'};if(!access.checked)access.click();
 const input=document.getElementById('txtInteressado')||document.getElementById('txtInteressados')||document.querySelector('input[name*="Interessado"]');
 if(!input)return {error:'Campo Interessado do requerimento não localizado.'};input.focus();input.value=d.interested;input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));
 const keyup=new KeyboardEvent('keyup',{key:'s',bubbles:true});Object.defineProperty(keyup,'keyCode',{get:()=>83});Object.defineProperty(keyup,'which',{get:()=>83});input.dispatchEvent(keyup);
 const options=[...document.querySelectorAll('.ui-autocomplete li,.ac_results li,[role=listbox] [role=option],.infraAutoCompletar li')].filter(x=>x.offsetWidth||x.offsetHeight);
 const suggestion=options.find(x=>norm(x.textContent).includes(norm(d.interested)));
 if(suggestion)(suggestion.querySelector('a')||suggestion).click();
 return desc.value===d.description&&access.checked?{ok:true}:{error:'O SEI não manteve descrição/acesso do requerimento.'};
}''';
const _saveMetadataScript =
    r'''() => {const n=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().trim();const b=document.getElementById('btnSalvar')||[...document.querySelectorAll('button,input[type=submit],input[type=button],a')].find(x=>n(x.innerText||x.value||x.title)==='salvar');if(!b||b.disabled)return false;b.click();return true;}''';
const _clickIncludeDocumentScript =
    r'''() => {const n=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();for(const e of document.querySelectorAll('a,button,input,img')){const t=e.closest('a,button')||e;const text=n([e.textContent,e.title,e.alt,e.value,t.textContent,t.title,t.getAttribute('aria-label')].join(' '));if((t.href||'').toLowerCase().includes('documento_escolher_tipo')||text.includes('incluir documento')||text.includes('gerar documento')){t.click();return true;}}return false;}''';
const _isTypeChoiceScript =
    r'''() => (document.body?.innerText||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().includes('escolha o tipo do documento')''';
const _editorRootScript =
    r'''() => {const i=window.infraEditor;if(i?.isReady&&i.editor){const e=document.querySelector('.infra-editor__secao-principal[id][contenteditable=true],div[id^="txaEditor_"][contenteditable=true]');if(e&&[...i.editor.model.document.getRoots()].some(r=>r.rootName===e.id))return 'ck:'+e.id;}const t=document.querySelector('textarea[name^="txaEditor_"],textarea[id^="txaEditor_"]');return t?'ta:'+(t.id||t.name):null;}''';
const _readEditorHtmlScript =
    r'''(root) => {if(root.startsWith('ck:')){const i=window.infraEditor;if(!i?.isReady||!i.editor)return null;const n=root.substring(3);return [...i.editor.model.document.getRoots()].some(r=>r.rootName===n)?i.editor.getData({rootName:n}):null;}const s=root.substring(3),t=document.getElementById(s)||[...document.querySelectorAll('textarea')].find(x=>x.name===s);return t?.value||null;}''';
const _setEditorHtmlScript =
    r'''(root,html) => {if(root.startsWith('ck:')){const i=window.infraEditor;if(!i?.isReady||!i.editor)return false;const d={};for(const r of i.editor.model.document.getRoots())d[r.rootName]=i.editor.getData({rootName:r.rootName});const n=root.substring(3);if(!(n in d))return false;d[n]=html;i.editor.setData(d);return true;}const s=root.substring(3),t=document.getElementById(s)||[...document.querySelectorAll('textarea')].find(x=>x.name===s);if(!t)return false;t.value=html;t.dispatchEvent(new Event('input',{bubbles:true}));t.dispatchEvent(new Event('change',{bubbles:true}));return true;}''';
const _clickEditorSaveScript =
    r'''() => {const n=s=>(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().trim();const b=[...document.querySelectorAll('button,input[type=button],input[type=submit],a')].find(x=>n(x.innerText||x.value||x.title)==='salvar');if(!b||b.disabled)return false;b.click();return true;}''';
const _isEditorSavedScript =
    r'''() => {const i=window.infraEditor;if(i?.editor?.plugins?.has('Salvar')){const s=i.editor.plugins.get('Salvar');return !s.isSaving&&!s.isDirty;}return document.readyState==='complete';}''';
