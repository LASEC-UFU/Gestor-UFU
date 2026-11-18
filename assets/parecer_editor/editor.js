/*
 * Editor de uma seção do parecer (Gestor UFU). Usa o CKEditor 5 — o mesmo
 * editor do SEI — com os estilos de parágrafo do SEI, para que o HTML
 * produzido aqui seja inserido no SEI sem conversão.
 *
 * Comunicação com o app (WebView2):
 *   app → página: parecer.iniciar({html, css, estilos, dica}),
 *                 parecer.definir(html), parecer.inserir(html), parecer.foco()
 *                 parecer.reservar(id), parecer.aplicar(id, texto, esperado),
 *                 parecer.liberar(id)
 *   página → app: {tipo:'carregado'}, {tipo:'pronto'}, {tipo:'mudou', html},
 *                 {tipo:'erro', mensagem}, {tipo:'selecao', texto, …},
 *                 {tipo:'consultarIa', texto, …}, {tipo:'comentar'}
 */
(() => {
  'use strict';

  const enviar = (msg) => {
    try { window.chrome.webview.postMessage(msg); } catch (e) { /* fora do app */ }
  };
  window.addEventListener('error', (e) => enviar({ tipo: 'erro', mensagem: String(e.message || e) }));

  const C = window.CKEDITOR;
  const { Plugin, ButtonView } = C;

  // Lista "Escolha o estilo" padrão (substituída pela capturada do SEI).
  const ESTILOS_PADRAO = [
    'Citacao', 'Item_Alinea_Letra', 'Item_Inciso_Romano', 'Item_Nivel1', 'Item_Nivel2',
    'Item_Nivel3', 'Item_Nivel4', 'Paragrafo_Numerado_Nivel1', 'Paragrafo_Numerado_Nivel2',
    'Tabela_Texto_8', 'Tabela_Texto_Alinhado_Direita', 'Tabela_Texto_Alinhado_Esquerda',
    'Tabela_Texto_Centralizado', 'Texto_Alinhado_Direita', 'Texto_Alinhado_Esquerda',
    'Texto_Alinhado_Esquerda_Espacamento_Simples', 'Texto_Alinhado_Esquerda_Espacamento_Simples_Maiusc',
    'Texto_Centralizado', 'Texto_Centralizado_Maiusculas', 'Texto_Centralizado_Maiusculas_Negrito',
    'Texto_Espaco_Duplo_Recuo_Primeira_Linha', 'Texto_Fundo_Cinza_Maiusculas_Negrito',
    'Texto_Fundo_Cinza_Negrito', 'Texto_Justificado', 'Texto_Justificado_Maiusculas',
    'Texto_Justificado_Recuo_Primeira_Linha', 'Texto_Justificado_Recuo_Primeira_Linha_Esp_Simples',
  ].map((c) => ({ name: c, element: 'p', classes: [c] }));

  // Ícones (SVG 20x20) dos botões próprios.
  const ICONE = {
    caixa: '<svg viewBox="0 0 20 20"><text x="1" y="15" font-size="13" font-family="Segoe UI" font-weight="600" fill="currentColor">Aa</text></svg>',
    pincel: '<svg viewBox="0 0 20 20"><path fill="currentColor" d="M15.5 2.5a1 1 0 0 1 1.4 1.4l-6.6 6.6-1.4-1.4zM8.2 9.8l1.4 1.4-1 1c-.4 1.8-2 3.3-4.6 3.3.8-.8 1-1.6 1.1-2.5.1-1.3 1-2.3 2.1-2.4z"/></svg>',
    sei: '<svg viewBox="0 0 20 20"><rect x="0" y="3" width="20" height="14" rx="3" fill="#52b6e0"/><text x="2.5" y="14" font-size="10" font-family="Segoe UI" font-weight="700" fill="#fff">sei!</text></svg>',
    moeda: '<svg viewBox="0 0 20 20"><text x="0" y="15" font-size="12" font-family="Segoe UI" font-weight="700" fill="currentColor">R$</text></svg>',
  };

  // ---------------------------------------------------------- Aa (caixa)
  class AlterarCaixa extends Plugin {
    init() {
      const editor = this.editor;
      editor.ui.componentFactory.add('alterarCaixa', (locale) => {
        const b = new ButtonView(locale);
        b.set({ label: 'Maiúsculas / minúsculas / Iniciais', icon: ICONE.caixa, tooltip: true });
        b.on('execute', () => this.alternar());
        return b;
      });
    }
    alternar() {
      const model = this.editor.model;
      const sel = model.document.selection;
      if (sel.isCollapsed) return;
      const pedacos = [];
      for (const range of sel.getRanges()) {
        for (const item of range.getItems()) {
          if (item.is('$textProxy')) pedacos.push(item);
        }
      }
      const todo = pedacos.map((p) => p.data).join('');
      let f;
      if (todo === todo.toLocaleUpperCase('pt-BR')) f = (t) => t.toLocaleLowerCase('pt-BR');
      else if (todo === todo.toLocaleLowerCase('pt-BR')) {
        f = (t, inicio) => t.replace(/(^|[\s(\-–"“])(\p{L})/gu, (m, a, l, pos) =>
          (pos === 0 && !inicio && a === '') ? m : a + l.toLocaleUpperCase('pt-BR'));
      } else f = (t) => t.toLocaleUpperCase('pt-BR');
      model.change((writer) => {
        const ranges = Array.from(sel.getRanges()).map((r) => writer.createRange(r.start, r.end));
        for (let i = pedacos.length - 1; i >= 0; i--) {
          const p = pedacos[i];
          const anterior = i > 0 ? pedacos[i - 1].data : '';
          const inicio = i === 0 || /\s$/.test(anterior);
          const r = writer.createRangeOn(p);
          const pos = r.start;
          const attrs = Object.fromEntries(p.getAttributes());
          writer.remove(r);
          writer.insertText(f(p.data, inicio), attrs, pos);
        }
        writer.setSelection(ranges);
      });
    }
  }

  // ------------------------------------------------- pincel de formatação
  const ATRIBUTOS_TEXTO = ['bold', 'italic', 'underline', 'strikethrough', 'subscript', 'superscript',
    'fontColor', 'fontBackgroundColor', 'fontSize', 'fontFamily'];
  const ATRIBUTOS_BLOCO = ['htmlPAttributes', 'alignment'];

  class PincelFormatacao extends Plugin {
    init() {
      const editor = this.editor;
      this.copiado = null;
      editor.ui.componentFactory.add('pincel', (locale) => {
        const b = new ButtonView(locale);
        b.set({ label: 'Copiar formatação (pincel)', icon: ICONE.pincel, tooltip: true, isToggleable: true });
        b.on('execute', () => {
          if (this.copiado) { this.copiado = null; b.isOn = false; return; }
          const sel = editor.model.document.selection;
          const texto = {};
          for (const a of ATRIBUTOS_TEXTO) texto[a] = sel.getAttribute(a);
          const bloco = sel.getFirstPosition().parent;
          const blocoAttrs = {};
          for (const a of ATRIBUTOS_BLOCO) blocoAttrs[a] = bloco.getAttribute ? bloco.getAttribute(a) : undefined;
          this.copiado = { texto, bloco: blocoAttrs };
          b.isOn = true;
        });
        this.botao = b;
        return b;
      });
      editor.on('ready', () => {
        const el = editor.ui.getEditableElement();
        const aplicar = () => setTimeout(() => this.aplicar(), 0);
        el.addEventListener('mouseup', aplicar);
        el.addEventListener('keyup', (e) => { if (e.shiftKey) aplicar(); });
      });
    }
    aplicar() {
      if (!this.copiado) return;
      const model = this.editor.model;
      const sel = model.document.selection;
      if (sel.isCollapsed) return;
      const { texto, bloco } = this.copiado;
      model.change((writer) => {
        for (const range of sel.getRanges()) {
          for (const a of ATRIBUTOS_TEXTO) {
            if (texto[a] !== undefined) writer.setAttribute(a, texto[a], range);
            else writer.removeAttribute(a, range);
          }
        }
        for (const b of sel.getSelectedBlocks()) {
          for (const a of ATRIBUTOS_BLOCO) {
            if (!model.schema.checkAttribute(b, a)) continue;
            if (bloco[a] !== undefined) writer.setAttribute(a, bloco[a], b);
            else writer.removeAttribute(a, b);
          }
        }
      });
      this.copiado = null;
      if (this.botao) this.botao.isOn = false;
    }
  }

  // ------------------------------------------------ R$ (valor por extenso)
  const UNI = ['', 'um', 'dois', 'três', 'quatro', 'cinco', 'seis', 'sete', 'oito', 'nove', 'dez', 'onze',
    'doze', 'treze', 'quatorze', 'quinze', 'dezesseis', 'dezessete', 'dezoito', 'dezenove'];
  const DEZ = ['', '', 'vinte', 'trinta', 'quarenta', 'cinquenta', 'sessenta', 'setenta', 'oitenta', 'noventa'];
  const CEM = ['', 'cento', 'duzentos', 'trezentos', 'quatrocentos', 'quinhentos', 'seiscentos', 'setecentos',
    'oitocentos', 'novecentos'];
  const GRUPOS = [['', ''], ['mil', 'mil'], ['milhão', 'milhões'], ['bilhão', 'bilhões'], ['trilhão', 'trilhões']];

  const ate999 = (n) => {
    if (n === 100) return 'cem';
    const c = Math.floor(n / 100), r = n % 100, partes = [];
    if (c) partes.push(CEM[c]);
    if (r < 20) { if (r) partes.push(UNI[r]); } else {
      partes.push(DEZ[Math.floor(r / 10)] + (r % 10 ? ' e ' + UNI[r % 10] : ''));
    }
    return partes.join(' e ');
  };

  const inteiroPorExtenso = (n) => {
    if (n === 0) return 'zero';
    const grupos = [];
    for (let i = 0; n > 0; i++, n = Math.floor(n / 1000)) grupos.push([n % 1000, i]);
    const partes = [];
    for (let k = grupos.length - 1; k >= 0; k--) {
      const [v, i] = grupos[k];
      if (!v) continue;
      let t = (i === 1 && v === 1) ? 'mil' : ate999(v) + (i ? ' ' + GRUPOS[i][v === 1 ? 0 : 1] : '');
      partes.push({ t, v });
    }
    let out = '';
    partes.forEach((p, idx) => {
      if (idx === 0) out = p.t;
      else out += ((idx === partes.length - 1 && (p.v < 100 || p.v % 100 === 0)) ? ' e ' : ', ') + p.t;
    });
    return out;
  };

  const reaisPorExtenso = (centavos) => {
    const r = Math.floor(centavos / 100), c = centavos % 100;
    const partes = [];
    if (r) {
      let t = inteiroPorExtenso(r);
      if (r >= 1e6 && r % 1e6 === 0) t += ' de';
      partes.push(t + (r === 1 ? ' real' : ' reais'));
    }
    if (c) partes.push(inteiroPorExtenso(c) + (c === 1 ? ' centavo' : ' centavos'));
    return partes.length ? partes.join(' e ') : 'zero real';
  };

  const lerValor = (texto) => {
    let t = texto.replace(/R\$|\s/g, '');
    if (!/^[\d.,]+$/.test(t)) return null;
    if (t.includes(',')) t = t.replace(/\./g, '').replace(',', '.');
    else if ((t.match(/\./g) || []).length > 1) t = t.replace(/\./g, '');
    else if (/^\d{1,3}\.\d{3}$/.test(t)) t = t.replace('.', '');
    const v = Number(t);
    return Number.isFinite(v) ? Math.round(v * 100) : null;
  };

  class ValorPorExtenso extends Plugin {
    init() {
      const editor = this.editor;
      editor.ui.componentFactory.add('valorExtenso', (locale) => {
        const b = new ButtonView(locale);
        b.set({ label: 'Valor em R$ por extenso (selecione o número)', icon: ICONE.moeda, tooltip: true });
        b.on('execute', () => {
          const model = editor.model;
          const sel = model.document.selection;
          let selecionado = '';
          for (const r of sel.getRanges()) for (const i of r.getItems()) if (i.is('$textProxy')) selecionado += i.data;
          if (!selecionado.trim()) selecionado = window.prompt('Valor (ex.: 1.234,56):', '') || '';
          const centavos = lerValor(selecionado.trim());
          if (centavos === null) { aviso('Selecione um número, ex.: 1.234,56'); return; }
          const fmt = (centavos / 100).toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
          const texto = `R$ ${fmt} (${reaisPorExtenso(centavos)})`;
          model.change((writer) => {
            const attrs = Object.fromEntries(sel.getAttributes());
            model.insertContent(writer.createText(texto, attrs), sel);
          });
          editor.editing.view.focus();
        });
        return b;
      });
    }
  }

  // ------------------------------------------------------- sei! (link SEI)
  // Igual ao botão do SEI: <a class="ancora_sei" id="lnkSei{id_documento}">
  // {número SEI}</a>. O id interno vem do inventário da árvore extraída.
  let linksSei = {};

  class LinkSei extends Plugin {
    init() {
      const editor = this.editor;
      editor.ui.componentFactory.add('linkSei', (locale) => {
        const b = new ButtonView(locale);
        b.set({
          label: 'Inserir link ou converter texto selecionado para link do sei! (Ctrl+Shift+L)',
          icon: ICONE.sei, tooltip: true,
        });
        b.on('execute', () => this.executar());
        return b;
      });
      editor.keystrokes.set('Ctrl+Shift+L', (_, cancel) => { this.executar(); cancel(); });
    }
    executar() {
      const editor = this.editor;
      const model = editor.model;
      const sel = model.document.selection;
      let texto = '';
      for (const r of sel.getRanges()) for (const i of r.getItems()) if (i.is('$textProxy')) texto += i.data;
      let numero = texto.replace(/\D/g, '');
      if (!numero) numero = (window.prompt('Número SEI do documento:', '') || '').replace(/\D/g, '');
      if (!numero) return;
      let id = linksSei[numero];
      if (!id) {
        id = (window.prompt(
          `O documento ${numero} não está na árvore extraída. Informe o id interno ` +
          '(id_documento no endereço do documento no SEI) ou extraia a árvore do processo:', '') || '').replace(/\D/g, '');
      }
      if (!id) { aviso('Link SEI não criado: id do documento desconhecido.'); return; }
      const html = `<a class="ancora_sei" id="lnkSei${id}">${numero}</a>`;
      model.change(() => { model.insertContent(toModel(html), sel); });
      editor.editing.view.focus();
    }
  }

  // ----------------------------------------------------------- utilidades
  let avisoTimer = null;
  const aviso = (t) => {
    const el = document.getElementById('aviso');
    el.textContent = t;
    clearTimeout(avisoTimer);
    avisoTimer = setTimeout(() => { el.textContent = ''; }, 4000);
  };

  let editor = null;
  let comentarios = [];
  let comentarioAtivo = null;
  let highlightRanges = [];
  let savedModelRange = null;

  function textoEditor() { return editor ? (editor.ui.getEditableElement().textContent || '') : ''; }
  function offsetSelecao(root, node, offset) {
    try { const r = document.createRange(); r.selectNodeContents(root); r.setEnd(node, offset); return r.toString().length; } catch (_) { return -1; }
  }
  function rangeTexto(root, start, length) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let n, pos = 0, a = null, b = null, ao = 0, bo = 0;
    while ((n = walker.nextNode())) { const end = pos + n.nodeValue.length;
      if (a === null && start >= pos && start <= end) { a = n; ao = start - pos; }
      if (a !== null && start + length >= pos && start + length <= end) { b = n; bo = start + length - pos; break; }
      pos = end;
    }
    if (!a || !b) return null;
    const r = document.createRange(); r.setStart(a, ao); r.setEnd(b, bo); return r;
  }
  /** Range do trecho de um comentário (relocaliza pelo contexto se o texto
   *  mudou de lugar); null se o trecho não existe mais. */
  function localizar(c) {
    if (!editor || !c) return null;
    const root = editor.ui.getEditableElement(), all = textoEditor(), selected = String(c.selecionado || '');
    if (!selected) return null;
    const antes = c.localizado;
    const falhou = () => {
      c.localizado = false;
      if (antes !== false) enviar({ tipo: 'statusComentario', comentario: c });
      return null;
    };
    let at = Number(c.posicao);
    if (all.slice(at, at + selected.length) !== selected) {
      const prev = String(c.anterior || '').slice(-30), next = String(c.posterior || '').slice(0, 30);
      const hits = []; let from = 0, i;
      while ((i = all.indexOf(selected, from)) >= 0) { hits.push(i); from = i + Math.max(1, selected.length); }
      if (!hits.length) return falhou();
      const score = (x) => (all.slice(Math.max(0,x-prev.length),x) === prev ? 2 : 0) + (all.slice(x+selected.length,x+selected.length+next.length) === next ? 2 : 0);
      at = hits.sort((x,y) => score(y) - score(x) || Math.abs(x - Number(c.posicao || 0)) - Math.abs(y - Number(c.posicao || 0)))[0];
    }
    const r = rangeTexto(root, at, selected.length);
    if (!r) return falhou();
    c.posicao = at;
    c.localizado = true;
    if (antes === false) enviar({ tipo: 'statusComentario', comentario: c });
    return r;
  }

  function pintar(c) {
    const r = localizar(c);
    if (r) highlightRanges.push(r);
    return !!r;
  }

  /** Repinta todas as marcações e o destaque do comentário selecionado. */
  function repintar() {
    highlightRanges = [];
    for (const c of comentarios) pintar(c);
    if (window.CSS && CSS.highlights && window.Highlight) {
      if (highlightRanges.length) CSS.highlights.set('parecer-comentarios', new Highlight(...highlightRanges));
      else CSS.highlights.delete('parecer-comentarios');
    }
    return pintarAtivo();
  }

  /** Destaque do comentário selecionado: cor própria + sublinhado +
   *  contorno e uma barra na margem (não só a cor). */
  function pintarAtivo() {
    const folha = document.getElementById('folha');
    for (const el of folha.querySelectorAll('.gestor-ativo-caixa, .gestor-ativo-barra')) el.remove();
    if (window.CSS && CSS.highlights) CSS.highlights.delete('parecer-ativo');
    if (comentarioAtivo == null) return null;
    const c = comentarios.find((x) => String(x.id) === String(comentarioAtivo));
    const r = localizar(c);
    if (!r) return null;
    if (window.CSS && CSS.highlights && window.Highlight) {
      const h = new Highlight(r);
      h.priority = 1;
      CSS.highlights.set('parecer-ativo', h);
    }
    const base = folha.getBoundingClientRect();
    const rects = [...r.getClientRects()].filter((q) => q.width > 0.5 && q.height > 0.5);
    for (const q of rects) {
      const d = document.createElement('div');
      d.className = 'gestor-ativo-caixa';
      d.style.left = (q.left - base.left - 1) + 'px';
      d.style.top = (q.top - base.top - 1) + 'px';
      d.style.width = (q.width + 2) + 'px';
      d.style.height = (q.height + 2) + 'px';
      folha.appendChild(d);
    }
    if (rects.length) {
      const topo = Math.min(...rects.map((q) => q.top)) - base.top;
      const fim = Math.max(...rects.map((q) => q.bottom)) - base.top;
      const barra = document.createElement('div');
      barra.className = 'gestor-ativo-barra';
      barra.style.top = topo + 'px';
      barra.style.height = (fim - topo) + 'px';
      folha.appendChild(barra);
    }
    return r;
  }
  window.addEventListener('resize', () => pintarAtivo());


  // Seleção atual (ou cursor) com o contexto em volta, para o app.
  function dadosSelecao() {
    if (!editor) return null;
    const editable = editor.ui.getEditableElement();
    const s = window.getSelection();
    if (!s || !s.rangeCount || !editable.contains(s.anchorNode)) return null;
    const start = offsetSelecao(editable, s.anchorNode, s.anchorOffset);
    const end = offsetSelecao(editable, s.focusNode, s.focusOffset);
    const lo = Math.min(start, end), hi = Math.max(start, end), all = textoEditor();
    const texto = s.isCollapsed ? '' : s.toString();
    return { texto: texto.trim() ? texto : '', colapsado: s.isCollapsed || !texto.trim(), posicao: lo,
      anterior: all.slice(Math.max(0, lo - 400), lo), posterior: all.slice(hi, hi + 400) };
  }
  function reportarSelecao() {
    const d = dadosSelecao(); if (!d) return;
    const mr = editor.model.document.selection.getFirstRange();
    if (mr) savedModelRange = editor.model.createRange(mr.start, mr.end);
    enviar(Object.assign({ tipo: 'selecao' }, d));
  }

  // Menu do botão direito (Shift + botão direito abre o menu padrão).
  function fecharMenu() { const m = document.getElementById('menu-ia'); if (m) m.remove(); }
  function abrirMenu(x, y) {
    fecharMenu();
    const d = dadosSelecao() || { texto: '', colapsado: true };
    const m = document.createElement('div');
    m.id = 'menu-ia';
    const item = (rotulo, acao, ativo = true) => {
      const b = document.createElement('button');
      b.textContent = rotulo; b.disabled = !ativo;
      b.addEventListener('mousedown', (ev) => ev.preventDefault());
      b.addEventListener('click', () => { fecharMenu(); acao(); });
      m.appendChild(b);
    };
    item(d.colapsado ? '✦ Consultar a IA neste ponto…' : '✦ Consultar a IA sobre o trecho…',
      () => enviar(Object.assign({ tipo: 'consultarIa' }, d)));
    item('Comentar seleção', () => enviar({ tipo: 'comentar' }), !d.colapsado);
    item('Copiar', () => document.execCommand('copy'), !d.colapsado);
    item('Recortar', () => document.execCommand('cut'), !d.colapsado);
    const dica = document.createElement('div');
    dica.className = 'dica'; dica.textContent = 'Shift + botão direito: menu padrão';
    m.appendChild(dica);
    document.body.appendChild(m);
    const r = m.getBoundingClientRect();
    m.style.left = Math.max(4, Math.min(x, window.innerWidth - r.width - 4)) + 'px';
    m.style.top = Math.max(4, Math.min(y, window.innerHeight - r.height - 4)) + 'px';
  }
  document.addEventListener('mousedown', (e) => { if (!e.target.closest || !e.target.closest('#menu-ia')) fecharMenu(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') fecharMenu(); });
  window.addEventListener('blur', fecharMenu);
  document.addEventListener('scroll', fecharMenu, true);

  // Texto de um intervalo do modelo (blocos separados por \n).
  function textoModelo(range) {
    let out = '', ultimoBloco = null;
    for (const item of range.getItems()) {
      if (!item.is('$textProxy')) continue;
      const bloco = item.parent;
      if (ultimoBloco && bloco !== ultimoBloco) out += '\n';
      ultimoBloco = bloco;
      out += item.data;
    }
    return out;
  }
  const semEspacos = (t) => String(t || '').replace(/\s+/g, '');
  const nomeMarcador = (id) => 'consulta:' + id;
  const nomeCursor = (id) => 'consultaCursor:' + id;

  const toModel = (html) => editor.data.toModel(editor.data.processor.toView(html));

  window.parecer = {
    async iniciar(opcoes) {
      const o = opcoes || {};
      linksSei = o.linksSei || {};
      if (o.css && o.css.trim()) {
        document.getElementById('estilos-sei').textContent = o.css;
        const padrao = document.getElementById('estilos-padrao');
        if (padrao) padrao.disabled = true;
      }
      const estilos = (Array.isArray(o.estilos) && o.estilos.length) ? o.estilos : ESTILOS_PADRAO;
      const plugins = [
        C.Essentials, C.Paragraph, C.Autoformat, C.Clipboard, C.PasteFromOffice,
        C.Bold, C.Italic, C.Underline, C.Strikethrough, C.Subscript, C.Superscript,
        C.FontColor, C.FontBackgroundColor, C.FontSize, C.FontFamily, C.RemoveFormat,
        C.FindAndReplace, C.ShowBlocks, C.SpecialCharacters, C.SpecialCharactersEssentials,
        C.List, C.ListProperties, C.Indent, C.IndentBlock, C.Alignment,
        C.HorizontalLine, C.PageBreak,
        C.Image, C.ImageToolbar, C.ImageCaption, C.ImageStyle, C.ImageResize, C.ImageUpload,
        C.ImageInsert, C.Base64UploadAdapter,
        C.Table, C.TableToolbar, C.TableProperties, C.TableCellProperties, C.TableColumnResize,
        C.Link, C.Style, C.GeneralHtmlSupport, C.SourceEditing, C.WordCount,
        AlterarCaixa, PincelFormatacao, ValorPorExtenso, LinkSei,
      ];
      try {
        editor = await C.DecoupledEditor.create(document.getElementById('editor'), {
          licenseKey: 'GPL',
          language: 'pt-br',
          translations: [window.CKEDITOR_TRANSLATIONS],
          plugins,
          placeholder: o.dica || 'Digite aqui o texto da seção…',
          initialData: o.html || '',
          toolbar: {
            shouldNotGroupWhenFull: true,
            items: [
              'undo', 'redo', '|', 'style', '|', 'findAndReplace', 'pincel', 'removeFormat', '|',
              'bold', 'italic', 'underline', 'strikethrough', 'subscript', 'superscript', 'alterarCaixa', '|',
              'fontColor', 'fontBackgroundColor', 'fontSize', '|', 'showBlocks', 'specialCharacters', '|',
              'numberedList', 'bulletedList', 'outdent', 'indent', 'alignment', '|',
              'horizontalLine', 'pageBreak', '|', 'insertImage', 'insertTable', 'link', '|', 'linkSei',
              'valorExtenso', '|', 'sourceEditing',
            ],
          },
          style: { definitions: estilos },
          htmlSupport: {
            allow: [{ name: /.*/, attributes: true, classes: true, styles: true }],
            disallow: [{ name: /^(script|iframe|object|embed|form|input|button)$/ }],
          },
          list: { properties: { styles: true, startIndex: true, reversed: true } },
          fontSize: { options: [8, 9, 10, 11, 'default', 13, 14, 16, 18, 20, 24], supportAllValues: true },
          image: {
            toolbar: ['imageStyle:inline', 'imageStyle:block', '|', 'toggleImageCaption', 'imageTextAlternative', 'resizeImage'],
          },
          table: {
            contentToolbar: ['tableColumn', 'tableRow', 'mergeTableCells', 'tableProperties', 'tableCellProperties'],
          },
          link: { addTargetToExternalLinks: true, defaultProtocol: 'https://' },
        });
      } catch (e) {
        enviar({ tipo: 'erro', mensagem: 'Falha ao iniciar o editor: ' + (e && e.message ? e.message : e) });
        return;
      }
      document.getElementById('barra').appendChild(editor.ui.view.toolbar.element);
      const contagem = document.getElementById('contagem');
      const wc = editor.plugins.get('WordCount');
      const atualizarContagem = () => { contagem.textContent = `${wc.words} palavras · ${wc.characters} caracteres`; };
      wc.on('update', atualizarContagem);
      atualizarContagem();

      // Trecho reservado para uma consulta à IA: destacado enquanto a caixa
      // de consulta está aberta (marcadores acompanham as edições).
      editor.conversion.for('editingDowncast').markerToHighlight({
        model: 'consulta', view: { classes: 'gestor-consulta' },
      });
      editor.conversion.for('editingDowncast').markerToElement({
        model: 'consultaCursor',
        view: (data, { writer }) => data.isOpening === false ? null
          : writer.createUIElement('span', { class: 'gestor-consulta-cursor' }),
      });

      comentarios = Array.isArray(o.comentarios) ? o.comentarios : [];
      const editable = editor.ui.getEditableElement();
      editable.addEventListener('mouseup', () => setTimeout(reportarSelecao, 0));
      editable.addEventListener('keyup', reportarSelecao);
      editable.addEventListener('contextmenu', (e) => {
        if (e.shiftKey) return; // Shift + botão direito: menu padrão do navegador.
        e.preventDefault();
        setTimeout(() => { reportarSelecao(); abrirMenu(e.clientX, e.clientY); }, 0);
      });
      repintar();
      editable.addEventListener('click', () => {
        const s = window.getSelection(); if (!s || !s.isCollapsed) return;
        const pos = offsetSelecao(editable, s.anchorNode, s.anchorOffset);
        const c = comentarios.find(x => x.localizado !== false && pos >= Number(x.posicao) && pos <= Number(x.posicao) + String(x.selecionado || '').length);
        if (c) enviar({ tipo: 'comentarioClic', id: c.id });
      });

      let timer = null;
      editor.model.document.on('change:data', () => {
        clearTimeout(timer);
        timer = setTimeout(() => { enviar({ tipo: 'mudou', html: editor.getData() }); repintar(); }, 400);
      });
      // Sai do modo código-fonte: garante que o app receba o HTML editado.
      editor.plugins.get('SourceEditing').on('change:isSourceEditingMode', (_, __, ativo) => {
        if (!ativo) enviar({ tipo: 'mudou', html: editor.getData() });
      });
      enviar({ tipo: 'pronto' });
    },

    definir(html) {
      if (!editor) return false;
      editor.setData(html || '');
      return true;
    },

    inserir(html) {
      if (!editor || !html) return false;
      editor.model.change(() => {
        editor.model.insertContent(toModel(html));
      });
      editor.editing.view.focus();
      enviar({ tipo: 'mudou', html: editor.getData() });
      return true;
    },

    definirLinks(mapa) { linksSei = mapa || {}; },

    definirComentarios(lista) { comentarios = Array.isArray(lista) ? lista : []; repintar(); return true; },

    /// Seleciona o comentário [id]: destaca o trecho e, com [rolar], leva a
    /// folha até ele. Devolve {ok:false} se o trecho não existe mais.
    selecionarComentario(id, rolar) {
      comentarioAtivo = id;
      const r = repintar();
      if (!r) return { ok: false };
      if (rolar !== false) {
        const area = document.getElementById('area');
        const q = r.getBoundingClientRect(), a = area.getBoundingClientRect();
        area.scrollTo({ top: area.scrollTop + q.top - a.top - area.clientHeight * 0.3, behavior: 'smooth' });
      }
      return { ok: true };
    },

    limparSelecaoComentario() { comentarioAtivo = null; pintarAtivo(); return true; },

    /// Reserva a última seleção (ou cursor) para uma consulta: guarda um
    /// marcador vivo e devolve o texto reservado. O relato não é alterado.
    reservar(id) {
      if (!editor) return { ok: false, motivo: 'O editor não está pronto.' };
      const model = editor.model;
      const range = savedModelRange || model.document.selection.getFirstRange();
      if (!range) return { ok: false, motivo: 'Clique no texto ou selecione um trecho.' };
      let texto;
      try { texto = textoModelo(range); } catch (_) { savedModelRange = null; return { ok: false, motivo: 'O texto mudou. Selecione o trecho de novo.' }; }
      model.change((writer) => {
        const nome = range.isCollapsed || !texto.trim() ? nomeCursor(id) : nomeMarcador(id);
        const r = nome === nomeCursor(id) ? model.createRange(range.end) : range;
        if (model.markers.has(nome)) writer.updateMarker(nome, { range: r });
        else writer.addMarker(nome, { range: r, usingOperation: false, affectsData: false });
      });
      return { ok: true, texto: texto.trim() ? texto : '', cursor: !texto.trim() };
    },

    /// Substitui o trecho reservado [id] por [texto] (ou insere no cursor).
    /// Recusa se o trecho mudou desde a reserva ([esperado]).
    aplicar(id, texto, esperado) {
      if (!editor) return { ok: false, motivo: 'O editor não está pronto.' };
      const model = editor.model;
      const marcador = model.markers.get(nomeMarcador(id)) || model.markers.get(nomeCursor(id));
      if (!marcador) return { ok: false, motivo: 'O ponto de edição não existe mais. Selecione o trecho de novo.' };
      const range = marcador.getRange();
      if (esperado && semEspacos(textoModelo(range)) !== semEspacos(esperado)) {
        return { ok: false, motivo: 'O trecho foi alterado depois da consulta. Selecione-o de novo.' };
      }
      const paragrafos = String(texto || '').split(/\n\s*\n/).map((t) => t.trim()).filter(Boolean);
      if (!paragrafos.length) return { ok: false, motivo: 'Texto vazio.' };
      model.change((writer) => {
        if (paragrafos.length === 1) {
          // Mantém a formatação do início do trecho.
          const no = range.start.textNode || range.start.nodeAfter || range.start.nodeBefore;
          const attrs = no && no.is('$text') ? no.getAttributes() : [];
          model.insertContent(writer.createText(paragrafos[0].replace(/\s*\n\s*/g, ' '), attrs), range);
        } else {
          const esc = (t) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
          const bloco = range.start.parent;
          const classe = bloco && bloco.getAttribute && bloco.getAttribute('htmlPAttributes');
          const cls = classe && classe.classes ? ` class="${classe.classes.join(' ')}"` : '';
          const html = paragrafos.map((t) => `<p${cls}>${esc(t).replace(/\n/g, '<br>')}</p>`).join('');
          model.insertContent(toModel(html), range);
        }
        for (const nome of [nomeMarcador(id), nomeCursor(id)]) if (model.markers.has(nome)) writer.removeMarker(nome);
      });
      savedModelRange = null;
      editor.editing.view.focus();
      enviar({ tipo: 'mudou', html: editor.getData() });
      return { ok: true };
    },

    /// Descarta a reserva [id] (caixa fechada sem aceitar).
    liberar(id) {
      if (!editor) return false;
      const model = editor.model;
      model.change((writer) => {
        for (const nome of [nomeMarcador(id), nomeCursor(id)]) if (model.markers.has(nome)) writer.removeMarker(nome);
      });
      return true;
    },

    obter() { return editor ? editor.getData() : ''; },

    foco() { if (editor) editor.editing.view.focus(); },
  };

  enviar({ tipo: 'carregado' });
})();
