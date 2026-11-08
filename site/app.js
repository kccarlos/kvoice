// KVoice site: links, copy buttons, scroll reveal, and the animated mockups.
// No build step, no dependencies. Every page works without this file: the
// links carry their real URLs and each mockup's markup is its finished frame.

// The public TestFlight link for KVoice for iPhone. Change it here AND in the
// href of every [data-testflight] link (search the site for the same URL);
// Scripts/render_site.py --check fails when the two disagree.
const TESTFLIGHT_URL = 'https://testflight.apple.com/join/WzN5CnG6';

const root = document.documentElement;
const zh = root.lang === 'zh-Hans';
const animated = root.classList.contains('anim');
const CJK = /[\u3400-\u9fff\uff00-\uffef\u3000-\u303f]/;

document.querySelectorAll('[data-testflight]').forEach(a => { a.href = TESTFLIGHT_URL; });

// file:// has no directory index: point page links at index.html.
if (location.protocol === 'file:') {
  document.querySelectorAll('a[href]').forEach(a => {
    const href = a.getAttribute('href');
    if (!/^([a-z][a-z0-9+.-]*:|#|\/)/i.test(href) && (href.endsWith('/') || href === '..')) a.href = href.replace(/\/?$/, '/') + 'index.html';
  });
}

// Copy buttons beside install commands. Hidden until the clipboard is usable.
document.querySelectorAll('.cmd').forEach(box => {
  const button = box.querySelector('button');
  const code = box.querySelector('code');
  if (!button || !code || !navigator.clipboard) return;
  button.hidden = false;
  const label = button.querySelector('span');
  const idle = label.textContent;
  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(code.textContent.trim());
      label.textContent = zh ? '已复制' : 'Copied';
    } catch {
      label.textContent = zh ? '请手动复制' : 'Copy failed';
    }
    setTimeout(() => { label.textContent = idle; }, 1800);
  });
});

matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', () => location.reload());

if (animated) {
  // Scroll reveal.
  const reveal = new IntersectionObserver(entries => entries.forEach(e => {
    if (e.isIntersecting) { e.target.classList.add('in'); reveal.unobserve(e.target); }
  }), { rootMargin: '0px 0px -8% 0px' });
  document.querySelectorAll('.rv').forEach(el => reveal.observe(el));

  // Demo videos play while visible (muted, so autoplay is allowed).
  const videos = new IntersectionObserver(entries => entries.forEach(e => {
    const v = e.target;
    if (e.isIntersecting) { if (v.preload === 'none') v.preload = 'auto'; v.play().catch(() => {}); } else v.pause();
  }), { threshold: 0.4 });
  document.querySelectorAll('video[data-autoplay]').forEach(v => { v.muted = true; videos.observe(v); });

  // Stages.
  const stages = [...document.querySelectorAll('[data-steps]')].map(makeStage);
  const watch = new IntersectionObserver(entries => entries.forEach(e => {
    const stage = stages.find(s => s.el === e.target);
    stage.inView = e.isIntersecting;
    if (e.isIntersecting && !document.hidden) stage.show(); else stage.hide();
  }), { threshold: 0.35 });
  stages.forEach(s => watch.observe(s.el));
  // A background tab pauses every stage; coming back restarts the ones in view.
  document.addEventListener('visibilitychange', () => stages.forEach(s => {
    if (document.hidden) s.hide(); else if (s.inView) s.show();
  }));
}

// "0-3,5" -> Set {0,1,2,3,5}; "*" -> every step.
function parseSteps(text, count) {
  const set = new Set();
  for (const part of text.split(',')) {
    const p = part.trim();
    if (p === '*') { for (let i = 0; i < count; i++) set.add(i); continue; }
    const [a, b] = p.split('-').map(Number);
    for (let i = a; i <= (b === undefined ? a : b); i++) set.add(i);
  }
  return set;
}


// Typing: every character becomes a span; blocks (p, li) stay hidden until
// their first character is typed, so a list bullet never shows before its text.
function splitChars(el) {
  const walk = node => {
    for (const child of [...node.childNodes]) {
      if (child.nodeType === Node.TEXT_NODE) {
        if (!child.textContent.trim() && !child.textContent.includes(' ')) continue;
        const frag = document.createDocumentFragment();
        for (const ch of child.textContent.replace(/\s+/g, ' ')) {
          const s = document.createElement('span');
          s.className = 'tw-c';
          s.textContent = ch;
          frag.append(s);
        }
        child.replaceWith(frag);
      } else if (child.nodeType === Node.ELEMENT_NODE && !child.classList.contains('caret')) walk(child);
    }
  };
  walk(el);
  el.querySelectorAll('p, li, h5, div').forEach(b => b.classList.add('tw-b'));
  return [...el.querySelectorAll('.tw-c')];
}

// Live words: one span per word (per one or two characters in Chinese).
function splitWords(el) {
  const text = el.textContent.trim();
  el.textContent = '';
  const parts = text.match(/[㐀-鿿]{1,2}[，。、？！]?|[^\s㐀-鿿]+\s*|\s+/g) || [];
  return parts.filter(p => p.trim()).map(p => {
    const s = document.createElement('span');
    s.className = 'w';
    s.textContent = CJK.test(p) ? p : p.trimEnd() + ' ';
    el.append(s);
    return s;
  });
}

function makeStage(el) {
  const durations = el.dataset.steps.split(',').map(Number);
  const count = durations.length;
  const variants = (el.dataset.variants || '').split(',').filter(Boolean);
  const tabs = el.id ? [...document.querySelectorAll(`[data-for="${el.id}"] [data-vtab]`)] : [];
  const items = [...el.querySelectorAll('[data-show]')].map(e => ({ e, steps: parseSteps(e.dataset.show, count), variant: e.dataset.variant }));
  const classed = [...el.querySelectorAll('[data-cls]')].map(e => ({
    e, rules: e.dataset.cls.split(';').map(r => { const [cls, at] = r.split('@'); return { cls: cls.trim(), steps: parseSteps(at, count) }; })
  }));
  const typers = new Map([...el.querySelectorAll('[data-type]')].map(e => [e, splitChars(e)]));
  const talkers = new Map([...el.querySelectorAll('[data-words]')].map(e => [e, splitWords(e)]));
  const clocks = [...el.querySelectorAll('[data-clock]')];
  let step = 0, variant = 0, timer = 0, visible = false;
  let jobs = [];

  const later = (fn, ms) => { const id = setTimeout(fn, ms); jobs.push(() => clearTimeout(id)); };
  const every = (fn, ms) => { const id = setInterval(fn, ms); jobs.push(() => clearInterval(id)); };
  const stopJobs = () => { jobs.forEach(stop => stop()); jobs = []; };
  const live = e => e.closest('[data-show]') === null || e.closest('[data-show]').classList.contains('on');

  function type(e, chars) {
    const ms = Number(e.dataset.type) || 1200;
    const blocks = [...e.querySelectorAll('.tw-b')];
    chars.forEach(c => c.classList.remove('r'));
    blocks.forEach(b => { b.hidden = true; });
    let i = 0;
    const per = Math.max(8, ms / Math.max(1, chars.length));
    every(() => {
      const n = Math.max(1, Math.round(16 / per));
      for (let k = 0; k < n && i < chars.length; k++, i++) {
        chars[i].classList.add('r');
        for (let b = chars[i].parentElement; b && b !== e; b = b.parentElement) if (b.hidden) b.hidden = false;
      }
    }, Math.max(16, per));
  }

  function talk(e, words) {
    const ms = Number(e.dataset.words) || 2000;
    words.forEach(w => w.classList.remove('r', 'n'));
    let i = 0;
    every(() => {
      if (i >= words.length) return;
      words.forEach(w => w.classList.remove('n'));
      words[i].classList.add('r', 'n');
      if (i > 0) words[i - 1].classList.add('n');
      i++;
      // Keep the newest words in view: older ones leave from the start.
      for (let k = 0; k < i && e.scrollHeight > e.clientHeight + 1; k++) words[k].classList.remove('r');
    }, ms / words.length);
  }

  function tick(e) {
    let s = Number(e.dataset.clock) || 0;
    const show = () => { e.textContent = Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
    show();
    every(() => { s++; show(); }, 1000);
  }

  function apply(n, entering) {
    step = n;
    el.dataset.step = n;
    const v = variants[variant];
    if (v) el.dataset.variant = v;
    tabs.forEach(t => t.classList.toggle('cur', t.dataset.vtab === v));
    for (const it of items) {
      const on = it.steps.has(n) && (!it.variant || !v || it.variant.split(' ').includes(v));
      const was = it.e.classList.contains('on');
      it.e.classList.toggle('on', on);
      if (on && (!was || entering)) start(it.e);
    }
    for (const c of classed) for (const r of c.rules) c.e.classList.toggle(r.cls, r.steps.has(n));
  }

  // Start the timed effects inside an element that just appeared.
  function start(scope) {
    for (const [e, chars] of typers) if ((scope === e || scope.contains(e)) && live(e)) type(e, chars);
    for (const [e, words] of talkers) if ((scope === e || scope.contains(e)) && live(e)) talk(e, words);
    for (const e of clocks) if ((scope === e || scope.contains(e)) && live(e)) tick(e);
  }

  function reset() {
    stopJobs();
    // Typed text from the last loop is invisible but would still take room.
    for (const [, chars] of typers) chars.forEach(c => c.classList.remove('r'));
    for (const [, words] of talkers) words.forEach(w => w.classList.remove('r', 'n'));
    el.classList.add('still');
    for (const it of items) it.e.classList.remove('on');
    apply(0, true);
    void el.offsetWidth;
    el.classList.remove('still', 'out');
  }

  function next() {
    if (step < count - 1) {
      apply(step + 1, false);
      schedule();
      return;
    }
    el.classList.add('out');
    timer = setTimeout(() => {
      if (variants.length) variant = (variant + 1) % variants.length;
      reset();
      schedule();
    }, 420);
  }

  function schedule() {
    clearTimeout(timer);
    if (visible) timer = setTimeout(next, durations[step]);
  }

  return {
    el,
    inView: false,
    show() {
      if (visible) return;
      visible = true;
      el.classList.add('live');
      reset();
      schedule();
    },
    hide() {
      if (!visible) return;
      visible = false;
      clearTimeout(timer);
      stopJobs();
      el.classList.remove('live');
    }
  };
}
