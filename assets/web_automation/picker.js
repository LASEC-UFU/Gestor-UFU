() => {
  if (window.__gestorWebPicker) window.__gestorWebPicker.cleanup();
  const state = { result: null };
  const overlay = document.createElement('div');
  overlay.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:3px solid #1976d2;background:#2196f322;border-radius:4px;';
  const note = document.createElement('div');
  note.dataset.gestorWebPicker = 'instructions';
  note.textContent = 'Gestor UFU: clique no campo ou botão desejado. Esc cancela.';
  note.style.cssText = 'position:fixed;top:8px;left:8px;z-index:2147483647;pointer-events:none;background:#12334f;color:white;padding:12px 18px;border-radius:6px;font:15px sans-serif;';
  document.documentElement.append(overlay, note);
  const cssFor = el => {
    if (el.id && document.querySelectorAll('#' + CSS.escape(el.id)).length === 1) return '#' + CSS.escape(el.id);
    if (el.getAttribute('name')) {
      const sel = el.tagName.toLowerCase() + '[name=' + JSON.stringify(el.getAttribute('name')) + ']';
      if (document.querySelectorAll(sel).length === 1) return sel;
    }
    const path = [];
    while (el && el.nodeType === 1) {
      let segment = el.tagName.toLowerCase();
      const siblings = el.parentElement ? [...el.parentElement.children].filter(x => x.tagName === el.tagName) : [];
      if (siblings.length > 1) segment += ':nth-of-type(' + (siblings.indexOf(el) + 1) + ')';
      path.unshift(segment);
      const sel = path.join(' > ');
      if (document.querySelectorAll(sel).length === 1) return sel;
      el = el.parentElement;
    }
    return path.join(' > ');
  };
  const targetFor = event => {
    const raw = event.target;
    return raw.closest('input,textarea,select,button,a,[role="button"],[role="checkbox"],[contenteditable="true"]') || raw;
  };
  const move = e => {
    const r = targetFor(e).getBoundingClientRect();
    Object.assign(overlay.style, {left:r.left+'px',top:r.top+'px',width:r.width+'px',height:r.height+'px'});
  };
  const click = e => {
    e.preventDefault(); e.stopImmediatePropagation();
    const el = targetFor(e);
    state.result = {
      selector: cssFor(el), tag: el.tagName.toLowerCase(), inputType: el.type || '', role: el.getAttribute('role') || '',
      label: (el.labels?.[0]?.innerText || el.getAttribute('aria-label') || el.placeholder || el.getAttribute('name') || el.innerText || el.tagName).trim().slice(0,150),
      options: el.options ? [...el.options].map(o => ({label:o.text, value:o.value})) : []
    };
    state.cleanup();
  };
  const key = e => { if (e.key === 'Escape') { e.preventDefault(); state.result = {cancelled:true}; state.cleanup(); } };
  state.cleanup = () => {
    document.removeEventListener('mousemove', move, true);
    document.removeEventListener('click', click, true);
    document.removeEventListener('keydown', key, true);
    overlay.remove(); note.remove();
  };
  document.addEventListener('mousemove', move, true);
  document.addEventListener('click', click, true);
  document.addEventListener('keydown', key, true);
  window.__gestorWebPicker = state;
}
