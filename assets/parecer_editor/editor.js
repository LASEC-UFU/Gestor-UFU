/*
 * Editor de uma seção do parecer (Gestor UFU). Usa o CKEditor 5 — o mesmo
 * editor do SEI — com os estilos de parágrafo do SEI, para que o HTML
 * produzido aqui seja inserido no SEI sem conversão.
 *
 * Comunicação com o app (WebView2):
 *   app → página: parecer.iniciar({html, css, estilos, dica}),
 *                 parecer.definir(html), parecer.inserir(html), parecer.foco()
 *   página → app: {tipo:'carregado'}, {tipo:'pronto'}, {tipo:'mudou', html},
 *                 {tipo:'erro', mensagem}
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

      let timer = null;
      editor.model.document.on('change:data', () => {
        clearTimeout(timer);
        timer = setTimeout(() => enviar({ tipo: 'mudou', html: editor.getData() }), 400);
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

    obter() { return editor ? editor.getData() : ''; },

    foco() { if (editor) editor.editing.view.focus(); },
  };

  enviar({ tipo: 'carregado' });
})();
