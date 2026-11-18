/*
 * Visualizador de PDF dos documentos do processo (Gestor UFU, módulo
 * Parecer / Relato). Usa o pdf.js (Apache 2.0) para mostrar as páginas como
 * no original, com uma camada de texto selecionável e as marcações do
 * relator desenhadas por cima.
 *
 * Âncora de uma marcação: {pagina, inicio, fim} no texto da página, que é a
 * concatenação dos itens de texto do pdf.js (item.str + "\n" se hasEOL).
 *
 * app → página: pdfv.abrir({url, marcacoes, ativa, escala}),
 *   pdfv.definirMarcacoes(lista, ativa), pdfv.irPara({pagina, inicio, fim}),
 *   pdfv.buscar(termo, proxima) (responde {tipo:busca, achou, pagina}), pdfv.zoom(valor)
 * página → app: {tipo:'carregado'}, {tipo:'aberto', paginas, textos},
 *   {tipo:'selecao', pagina, inicio, fim, texto} | {tipo:'selecao', vazio},
 *   {tipo:'acao', acao, pagina, inicio, fim, texto},
 *   {tipo:'marcacao', id, abrir}, {tipo:'escala', escala}, {tipo:'erro', mensagem}
 */
import * as pdfjsLib from './pdf.min.js';

pdfjsLib.GlobalWorkerOptions.workerSrc = './pdf.worker.min.js';

const enviar = (msg) => {
  try { window.chrome.webview.postMessage(msg); } catch (_) { /* fora do app */ }
};
window.addEventListener('error', (e) => enviar({ tipo: 'erro', mensagem: String(e.message || e) }));
window.addEventListener('unhandledrejection', (e) =>
  enviar({ tipo: 'erro', mensagem: String((e.reason && e.reason.message) || e.reason) }));

const area = document.getElementById('area');
const container = document.getElementById('paginas');
const CORES = {
  amarelo: 'rgba(255, 235, 59, .55)', verde: 'rgba(139, 195, 74, .5)', azul: 'rgba(79, 195, 247, .5)',
  rosa: 'rgba(240, 98, 146, .45)', laranja: 'rgba(255, 152, 0, .5)',
};

let doc = null;
let paginas = [];
let escala = 1;
let ajustarLargura = true;
let marcacoes = [];
let ativa = null;
let busca = null;
let geracao = 0;
const indiceSpan = new WeakMap();

// ---------------------------------------------------------------- abrir

async function abrir(o) {
  marcacoes = Array.isArray(o.marcacoes) ? o.marcacoes : [];
  ativa = o.ativa || null;
  try {
    doc = await pdfjsLib.getDocument({
      url: o.url,
      cMapUrl: './cmaps/',
      cMapPacked: true,
      standardFontDataUrl: './standard_fonts/',
    }).promise;
  } catch (e) {
    const msg = e && e.name === 'PasswordException'
      ? 'O PDF é protegido por senha e não pode ser aberto aqui. Use "Abrir original".'
      : 'Não foi possível abrir o PDF: ' + (e && e.message ? e.message : e);
    mostrarErro(msg);
    enviar({ tipo: 'erro', mensagem: msg });
    return;
  }
  paginas = [];
  const textos = [];
  for (let n = 1; n <= doc.numPages; n++) {
    const page = await doc.getPage(n);
    const vp1 = page.getViewport({ scale: 1 });
    const conteudo = await page.getTextContent();
    let texto = '';
    const inicios = [], strs = [];
    for (const item of conteudo.items) {
      if (item.str === undefined) continue;
      inicios.push(texto.length);
      strs.push(item.str);
      texto += item.str;
      if (item.hasEOL) texto += '\n';
    }
    paginas.push({ n, page, vp1, conteudo, texto, inicios, strs, div: null, renderizada: false, tarefa: null, camada: null, spans: [] });
    textos.push(texto);
  }
  if (o.escala && o.escala !== 'largura') { escala = Number(o.escala) || 1; ajustarLargura = false; }
  else { ajustarLargura = true; escala = escalaLargura(); }
  montar();
  enviar({ tipo: 'aberto', paginas: doc.numPages, textos });
  enviar({ tipo: 'escala', escala });
}

function escalaLargura() {
  const larg = paginas.length ? Math.max(...paginas.slice(0, 5).map((p) => p.vp1.width)) : 600;
  return Math.max(0.4, Math.min(3, (area.clientWidth - 48) / larg));
}

function mostrarErro(msg) {
  const el = document.getElementById('erro');
  el.textContent = msg;
  el.style.display = 'flex';
}

// ------------------------------------------------- montagem e renderização

let observador = null;

function montar() {
  geracao++;
  if (observador) observador.disconnect();
  for (const p of paginas) cancelar(p);
  container.innerHTML = '';
  observador = new IntersectionObserver((entradas) => {
    for (const e of entradas) {
      const p = paginas[Number(e.target.dataset.n) - 1];
      if (e.isIntersecting) renderizar(p);
      else liberar(p);
    }
  }, { root: area, rootMargin: '1200px 0px' });
  for (const p of paginas) {
    const div = document.createElement('div');
    div.className = 'pagina';
    div.dataset.n = p.n;
    div.style.width = Math.floor(p.vp1.width * escala) + 'px';
    div.style.height = Math.floor(p.vp1.height * escala) + 'px';
    div.style.setProperty('--scale-factor', escala);
    div.innerHTML = '<div class="carregando">Página ' + p.n + '</div><div class="rotulo">' + p.n + ' / ' + paginas.length + '</div>';
    container.appendChild(div);
    p.div = div;
    p.renderizada = false;
    observador.observe(div);
  }
}

function cancelar(p) {
  if (p.tarefa) { try { p.tarefa.cancel(); } catch (_) {} p.tarefa = null; }
  if (p.camada) { try { p.camada.cancel(); } catch (_) {} p.camada = null; }
}

function liberar(p) {
  if (!p.renderizada) return;
  cancelar(p);
  p.renderizada = false;
  p.spans = [];
  const rotulo = p.div.querySelector('.rotulo');
  p.div.innerHTML = '<div class="carregando">Página ' + p.n + '</div>';
  if (rotulo) p.div.appendChild(rotulo);
}

async function renderizar(p) {
  if (p.renderizada || p.tarefa) return;
  const minhaGeracao = geracao;
  const vp = p.page.getViewport({ scale: escala });
  const dpr = window.devicePixelRatio || 1;
  const canvas = document.createElement('canvas');
  canvas.width = Math.floor(vp.width * dpr);
  canvas.height = Math.floor(vp.height * dpr);
  canvas.style.width = Math.floor(vp.width) + 'px';
  canvas.style.height = Math.floor(vp.height) + 'px';
  const marcas = document.createElement('div');
  marcas.className = 'marcas';
  const camadaDiv = document.createElement('div');
  camadaDiv.className = 'textLayer';
  try {
    p.tarefa = p.page.render({
      canvasContext: canvas.getContext('2d'),
      viewport: vp,
      transform: dpr !== 1 ? [dpr, 0, 0, dpr, 0, 0] : null,
    });
    await p.tarefa.promise;
    p.tarefa = null;
    if (minhaGeracao !== geracao) return;
    const rotulo = p.div.querySelector('.rotulo');
    p.div.innerHTML = '';
    p.div.append(canvas, marcas, camadaDiv);
    if (rotulo) p.div.appendChild(rotulo);
    p.camada = new pdfjsLib.TextLayer({ textContentSource: p.conteudo, container: camadaDiv, viewport: vp });
    await p.camada.render();
    if (minhaGeracao !== geracao) return;
    p.spans = p.camada.textDivs;
    p.spans.forEach((s, k) => indiceSpan.set(s, { p, k }));
    const fim = document.createElement('div');
    fim.className = 'endOfContent';
    camadaDiv.appendChild(fim);
    p.renderizada = true;
    pintar(p);
  } catch (e) {
    p.tarefa = null;
    if (e && e.name === 'RenderingCancelledException') return;
    if (String(e && e.message).includes('cancelled')) return;
    enviar({ tipo: 'erro', mensagem: 'Falha ao desenhar a página ' + p.n + ': ' + (e && e.message ? e.message : e) });
  }
}

// --------------------------------------------------------------- marcas

/** Retângulos (relativos à página) do trecho [ini, fim) do texto da página. */
function retangulos(p, ini, fim) {
  const out = [];
  if (!p.renderizada) return out;
  const base = p.div.getBoundingClientRect();
  for (let k = 0; k < p.spans.length; k++) {
    const s0 = p.inicios[k], s1 = s0 + p.strs[k].length;
    if (s1 <= ini || s0 >= fim || !p.strs[k].length) continue;
    const no = p.spans[k].firstChild;
    if (!no || no.nodeType !== 3) continue;
    const a = Math.max(ini, s0) - s0, b = Math.min(fim, s1) - s0;
    const r = document.createRange();
    try { r.setStart(no, Math.min(a, no.length)); r.setEnd(no, Math.min(b, no.length)); } catch (_) { continue; }
    for (const q of r.getClientRects()) {
      if (q.width < 0.5 || q.height < 0.5) continue;
      out.push({ x: q.left - base.left, y: q.top - base.top, w: q.width, h: q.height });
    }
  }
  return out;
}

function pintar(p) {
  if (!p.renderizada) return;
  const camada = p.div.querySelector('.marcas');
  if (!camada) return;
  camada.innerHTML = '';
  const desenhar = (ini, fim, classe, cor, titulo) => {
    for (const r of retangulos(p, ini, fim)) {
      const d = document.createElement('div');
      d.className = 'marca ' + classe;
      if (cor) d.style.background = cor;
      d.style.left = r.x + 'px'; d.style.top = r.y + 'px';
      d.style.width = r.w + 'px'; d.style.height = r.h + 'px';
      if (titulo) d.title = titulo;
      camada.appendChild(d);
    }
  };
  let selecionada = null;
  for (const m of marcacoes) {
    if (m.pagina !== p.n) continue;
    if (m.id === ativa) { selecionada = m; continue; }
    desenhar(m.inicio, m.fim, m.comentario ? 'comentada' : '', cor(m.cor));
  }
  // O trecho do comentário selecionado por cima, com cor e contorno
  // próprios e um marcador na margem (não só a cor).
  if (selecionada) {
    desenhar(selecionada.inicio, selecionada.fim, 'ativa', null);
    const rs = retangulos(p, selecionada.inicio, selecionada.fim);
    if (rs.length) {
      const topo = Math.min(...rs.map((r) => r.y));
      const base = Math.max(...rs.map((r) => r.y + r.h));
      const mk = document.createElement('div');
      mk.className = 'marcador';
      mk.style.top = topo + 'px';
      mk.style.height = (base - topo) + 'px';
      camada.appendChild(mk);
    }
  }
  if (busca && busca.pagina === p.n) desenhar(busca.inicio, busca.fim, 'busca', null);
}

/** Cor da marca: nome antigo ("amarelo") ou "#rrggbb", translúcida. */
function cor(valor) {
  if (CORES[valor]) return CORES[valor];
  const m = /^#([0-9a-f]{6})$/i.exec(String(valor || ''));
  if (!m) return CORES.amarelo;
  const n = parseInt(m[1], 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, .5)`;
}

function pintarTudo() { for (const p of paginas) pintar(p); }

// ------------------------------------------------------------- seleção

/** Converte um ponto do DOM (nó, deslocamento) em {p, o} no texto da página. */
function ponto(no, off) {
  if (!no) return null;
  const el = no.nodeType === 3 ? no.parentElement : no;
  if (!el) return null;
  let info = indiceSpan.get(el);
  if (info) {
    const len = info.p.strs[info.k].length;
    const o = no.nodeType === 3 ? Math.min(off, len) : (off > 0 ? len : 0);
    return { p: info.p, o: info.p.inicios[info.k] + o };
  }
  const pagDiv = el.closest ? el.closest('.pagina') : null;
  if (!pagDiv) return null;
  const p = paginas[Number(pagDiv.dataset.n) - 1];
  if (!p || !p.renderizada) return null;
  const filho = el.childNodes[off] || null;
  if (filho) {
    for (let k = 0; k < p.spans.length; k++) {
      const s = p.spans[k];
      if (s === filho || filho.contains(s) ||
          (filho.compareDocumentPosition(s) & Node.DOCUMENT_POSITION_FOLLOWING)) {
        return { p, o: p.inicios[k] };
      }
    }
  }
  return { p, o: p.texto.length };
}

function selecaoAtual() {
  const s = window.getSelection();
  if (!s || s.rangeCount === 0 || s.isCollapsed) return null;
  const r = s.getRangeAt(0);
  const a = ponto(r.startContainer, r.startOffset);
  const b = ponto(r.endContainer, r.endOffset);
  if (!a) return null;
  const fim = b && b.p === a.p ? b.o : a.p.texto.length;
  const ini = Math.min(a.o, fim), fimOk = Math.max(a.o, fim);
  const texto = a.p.texto.slice(ini, fimOk);
  if (!texto.trim()) return null;
  return { pagina: a.p.n, inicio: ini, fim: fimOk, texto };
}

function marcacaoEm(pagina, o) {
  let achada = null;
  for (const m of marcacoes) {
    if (m.pagina === pagina && o >= m.inicio && o < m.fim) achada = m;
  }
  return achada;
}

function marcacaoNoPonto(x, y) {
  const r = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
  if (!r) return null;
  const pt = ponto(r.startContainer, r.startOffset);
  return pt ? marcacaoEm(pt.p.n, pt.o) : null;
}

area.addEventListener('mouseup', (e) => {
  if (e.button !== 0) return;
  setTimeout(() => {
    const sel = selecaoAtual();
    if (sel) { enviar(Object.assign({ tipo: 'selecao' }, sel)); return; }
    enviar({ tipo: 'selecao', vazio: true });
    const m = marcacaoNoPonto(e.clientX, e.clientY);
    if (m) enviar({ tipo: 'marcacao', id: m.id });
  }, 0);
});

// ----------------------------------------------------------------- menu

function fecharMenu() { const m = document.getElementById('menu'); if (m) m.remove(); }

area.addEventListener('contextmenu', (e) => {
  if (e.shiftKey) return;
  e.preventDefault();
  const sel = selecaoAtual();
  const sobre = marcacaoNoPonto(e.clientX, e.clientY);
  fecharMenu();
  const menu = document.createElement('div');
  menu.id = 'menu';
  const item = (rotulo, acao, ativo = true) => {
    const b = document.createElement('button');
    b.textContent = rotulo; b.disabled = !ativo;
    b.addEventListener('mousedown', (ev) => ev.preventDefault());
    b.addEventListener('click', () => { fecharMenu(); acao(); });
    menu.appendChild(b);
  };
  const acao = (nome) => () => enviar(Object.assign({ tipo: 'acao', acao: nome }, sel));
  item('Marcar', acao('marcar'), !!sel);
  item('Comentar…', acao('comentar'), !!sel);
  item('✦ Perguntar à IA…', acao('perguntar'), !!sel);
  if (sobre) item('Ver o comentário', () => enviar({ tipo: 'marcacao', id: sobre.id }));
  item('Copiar', () => document.execCommand('copy'), !!sel);
  const dica = document.createElement('div');
  dica.className = 'dica';
  dica.textContent = sel ? 'Shift + botão direito: menu padrão' : 'Selecione um trecho do texto';
  menu.appendChild(dica);
  document.body.appendChild(menu);
  const r = menu.getBoundingClientRect();
  menu.style.left = Math.max(4, Math.min(e.clientX, innerWidth - r.width - 4)) + 'px';
  menu.style.top = Math.max(4, Math.min(e.clientY, innerHeight - r.height - 4)) + 'px';
});
document.addEventListener('mousedown', (e) => { if (!e.target.closest || !e.target.closest('#menu')) fecharMenu(); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') fecharMenu(); });
area.addEventListener('scroll', fecharMenu);

// ------------------------------------------------------- zoom e navegação

function zoom(valor) {
  if (!doc) return escala;
  const antes = area.scrollTop / Math.max(1, area.scrollHeight);
  if (valor === 'largura') { ajustarLargura = true; escala = escalaLargura(); }
  else if (valor === '+') { ajustarLargura = false; escala = Math.min(4, escala * 1.2); }
  else if (valor === '-') { ajustarLargura = false; escala = Math.max(0.3, escala / 1.2); }
  else { ajustarLargura = false; escala = Math.max(0.3, Math.min(4, Number(valor) || 1)); }
  montar();
  area.scrollTop = antes * area.scrollHeight;
  enviar({ tipo: 'escala', escala });
  return escala;
}

area.addEventListener('wheel', (e) => {
  if (!e.ctrlKey) return;
  e.preventDefault();
  zoom(e.deltaY < 0 ? '+' : '-');
}, { passive: false });

let redimensionar = null;
window.addEventListener('resize', () => {
  if (!ajustarLargura || !doc) return;
  clearTimeout(redimensionar);
  redimensionar = setTimeout(() => zoom('largura'), 200);
});

/** Rola até o trecho; true se ele foi encontrado na página. */
async function irPara(alvo) {
  if (!alvo || !paginas.length) return false;
  const n = Number(alvo.pagina) || 0;
  if (n < 1 || n > paginas.length) return false;
  const p = paginas[n - 1];
  area.scrollTop = p.div.offsetTop - 12;
  renderizar(p);
  // Espera a página (que pode estar sendo desenhada) ficar pronta.
  for (let i = 0; i < 60 && !p.renderizada; i++) {
    await new Promise((r) => setTimeout(r, 50));
  }
  if (!(alvo.fim > alvo.inicio)) return p.renderizada;
  const rs = retangulos(p, alvo.inicio, alvo.fim);
  if (!rs.length) return false;
  area.scrollTop = p.div.offsetTop + rs[0].y - area.clientHeight * 0.3;
  return true;
}

// ------------------------------------------------------------------ busca

const normalizarChar = (c) => {
  const n = c.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  return n.length ? n[0] : c;
};
const normalizar = (t) => Array.from(t, normalizarChar).join('').replace(/\s/g, ' ');

async function buscar(termo, proxima = true) {
  const alvo = normalizar(String(termo || '').trim());
  if (!alvo || !paginas.length) return { achou: false };
  const n = paginas.length;
  const atualPag = busca ? busca.pagina : 1;
  const atualPos = busca ? busca.inicio : -1;
  for (let passo = 0; passo <= n; passo++) {
    const idx = proxima ? ((atualPag - 1 + passo) % n) : ((atualPag - 1 - passo + n * 2) % n);
    const p = paginas[idx];
    const texto = normalizar(p.texto);
    let pos = -1;
    if (proxima) {
      pos = texto.indexOf(alvo, passo === 0 ? atualPos + 1 : 0);
    } else {
      const limite = passo === 0 ? atualPos - 1 : texto.length;
      pos = limite < 0 ? -1 : texto.lastIndexOf(alvo, limite);
    }
    if (pos >= 0) {
      const anterior = busca && busca.pagina;
      busca = { pagina: p.n, inicio: pos, fim: pos + alvo.length };
      if (anterior && anterior !== p.n) pintar(paginas[anterior - 1]);
      await irPara(busca);
      pintar(p);
      return { achou: true, pagina: p.n };
    }
  }
  return { achou: false };
}

// --------------------------------------------------------------- API

window.pdfv = {
  abrir(o) { abrir(o || {}); return true; },
  definirMarcacoes(lista, idAtiva) {
    marcacoes = Array.isArray(lista) ? lista : [];
    ativa = idAtiva || null;
    pintarTudo();
    return true;
  },
  irPara(alvo) {
    irPara(alvo).then((ok) => {
      if (alvo && alvo.pedido !== undefined) enviar({ tipo: 'navegou', pedido: alvo.pedido, ok });
    });
    return true;
  },
  buscar(termo, proxima) {
    buscar(termo, proxima !== false).then((r) => enviar(Object.assign({ tipo: 'busca', termo }, r)));
    return true;
  },
  limparBusca() { const pag = busca && busca.pagina; busca = null; if (pag) pintar(paginas[pag - 1]); return true; },
  zoom(valor) { return zoom(valor); },
};

enviar({ tipo: 'carregado' });
