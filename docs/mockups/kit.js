// Ultracam UI mockups: SF Symbol stand-ins, synthetic camera pictures and scopes.
// Pictures are SVG illustrations; scopes are computed from those pictures.

const ICONS = {
  play: '<path d="M7 5.5v13l11-6.5z" fill="currentColor" stroke="none"/>',
  stop: '<rect x="6" y="6" width="12" height="12" rx="2.5" fill="currentColor" stroke="none"/>',
  record: '<circle cx="12" cy="12" r="6.5" fill="currentColor" stroke="none"/>',
  recordring: '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="5" fill="currentColor" stroke="none"/>',
  pause: '<rect x="6.5" y="5.5" width="3.8" height="13" rx="1.2" fill="currentColor" stroke="none"/><rect x="13.7" y="5.5" width="3.8" height="13" rx="1.2" fill="currentColor" stroke="none"/>',
  sidebar: '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M9 5v14"/><path d="M5.5 8.5h1.5M5.5 11h1.5"/>',
  inspector: '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M15 5v14"/><path d="M17 8.5h1.5M17 11h1.5"/>',
  single: '<rect x="3.5" y="6" width="17" height="12" rx="2.5"/>',
  split: '<rect x="3" y="6" width="8" height="12" rx="2"/><rect x="13" y="6" width="8" height="12" rx="2"/>',
  grid: '<rect x="3.5" y="4.5" width="7.5" height="6.5" rx="1.6"/><rect x="13" y="4.5" width="7.5" height="6.5" rx="1.6"/><rect x="3.5" y="13" width="7.5" height="6.5" rx="1.6"/><rect x="13" y="13" width="7.5" height="6.5" rx="1.6"/>',
  video: '<rect x="2.5" y="6.5" width="13" height="11" rx="2.5"/><path d="M15.5 10.5l6-3.5v10l-6-3.5z"/>',
  videofill: '<rect x="2.5" y="6.5" width="13" height="11" rx="2.5" fill="currentColor"/><path d="M15.5 10.5l6-3.5v10l-6-3.5z" fill="currentColor"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2.8v2.4M12 18.8v2.4M2.8 12h2.4M18.8 12h2.4M5.5 5.5l1.7 1.7M16.8 16.8l1.7 1.7M5.5 18.5l1.7-1.7M16.8 7.2l1.7-1.7"/><circle cx="12" cy="12" r="6.6"/>',
  cube: '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M4 7.5l8 4.5 8-4.5M12 12v9"/>',
  folder: '<path d="M3 7.5a2 2 0 012-2h4l2 2h8a2 2 0 012 2V17a2 2 0 01-2 2H5a2 2 0 01-2-2z"/>',
  eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
  freeze: '<path d="M12 3v18M4.2 7.5l15.6 9M4.2 16.5l15.6-9"/><path d="M9.5 4.5L12 6.5l2.5-2M9.5 19.5l2.5-2 2.5 2"/>',
  clean: '<rect x="4" y="5" width="16" height="14" rx="2.5" stroke-dasharray="3 2.5"/>',
  guides: '<rect x="3.5" y="5" width="17" height="14" rx="2"/><path d="M9.2 5v14M14.8 5v14M3.5 9.7h17M3.5 14.3h17"/>',
  zebra: '<rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><path d="M3.5 13l8.5-8.5M3.5 19l14.5-14.5M9 19.5l11.5-11.5M15 19.5l5.5-5.5"/>',
  falsecolor: '<circle cx="12" cy="12" r="8.5"/><path d="M12 3.5v17M12 12l7.4-4.2M12 12l7.4 4.2" />',
  focus: '<path d="M4 8.5V6a2 2 0 012-2h2.5M15.5 4H18a2 2 0 012 2v2.5M20 15.5V18a2 2 0 01-2 2h-2.5M8.5 20H6a2 2 0 01-2-2v-2.5"/><circle cx="12" cy="12" r="2.2" fill="currentColor"/>',
  scope: '<path d="M3.5 19.5h17"/><path d="M4 15c2-6 3.5-9 5-9s2.5 7 4 7 2-4 3.5-4 2.5 3 3.5 5"/>',
  chevud: '<path d="M8.5 9.5L12 6l3.5 3.5M8.5 14.5L12 18l3.5-3.5"/>',
  chevr: '<path d="M10 6.5l5.5 5.5-5.5 5.5"/>',
  chevd: '<path d="M6.5 10l5.5 5.5 5.5-5.5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  ellipsis: '<circle cx="6" cy="12" r="1.5" fill="currentColor"/><circle cx="12" cy="12" r="1.5" fill="currentColor"/><circle cx="18" cy="12" r="1.5" fill="currentColor"/>',
  refresh: '<path d="M19.5 12a7.5 7.5 0 11-2.4-5.5"/><path d="M19.5 4.5v4h-4"/>',
  bypass: '<rect x="3.5" y="3.5" width="17" height="17" rx="3.5"/><path d="M7.5 12h9M13 8.5l3.5 3.5-3.5 3.5"/>',
  program: '<rect x="3" y="4.5" width="18" height="12.5" rx="2.5"/><path d="M8.5 20.5h7M12 17v3.5"/><circle cx="12" cy="10.8" r="2.3" fill="currentColor" stroke="none"/>',
  wave: '<path d="M4 12h1.5M7.5 8v8M11 5v14M14.5 9v6M18 7v10M20.5 12h0"/>',
  clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
  cpu: '<rect x="6.5" y="6.5" width="11" height="11" rx="2"/><path d="M9.5 3.5v3M14.5 3.5v3M9.5 17.5v3M14.5 17.5v3M3.5 9.5h3M3.5 14.5h3M17.5 9.5h3M17.5 14.5h3"/>',
  detach: '<rect x="3.5" y="7" width="12" height="12" rx="2.5"/><path d="M13 3.5h7.5V11M20.5 3.5L11.5 12.5"/>',
  zoom: '<circle cx="10.5" cy="10.5" r="6"/><path d="M15 15l5 5M8 10.5h5M10.5 8v5"/>',
  info: '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5"/><circle cx="12" cy="7.7" r="0.6" fill="currentColor"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  power: '<path d="M12 3.5v8"/><path d="M7 6.5a7.5 7.5 0 1010 0"/>',
  auto: '<path d="M12 3l1.8 4.7L18.5 9.5l-4.7 1.8L12 16l-1.8-4.7L5.5 9.5l4.7-1.8z"/><path d="M18 15l.9 2.1 2.1.9-2.1.9L18 21l-.9-2.1L15 18l2.1-.9z"/>',
  camlink: '<rect x="2.5" y="6.5" width="13" height="11" rx="2.5"/><path d="M15.5 10.5l6-3.5v10l-6-3.5z"/><path d="M6 12l2 2 3.5-4"/>',
  cut: '<path d="M4 7h11M4 17h11"/><path d="M15 4l4 3-4 3M15 14l4 3-4 3"/>',
  sliders: '<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
  mic: '<rect x="9" y="3.5" width="6" height="11" rx="3"/><path d="M6 11.5a6 6 0 0012 0M12 17.5v3"/>',
  xmark: '<path d="M7 7l10 10M17 7L7 17"/>',
  trash: '<path d="M5 7h14M10 4h4M7 7l1 12.5h8L17 7"/>',
  wifi: '<path d="M3 9.5a13 13 0 0118 0M6 12.8a8.5 8.5 0 0112 0M9 16a4 4 0 016 0"/><circle cx="12" cy="19" r="1" fill="currentColor"/>',
  battery: '<rect x="2.5" y="7.5" width="17" height="9" rx="2.5"/><rect x="4.5" y="9.5" width="11" height="5" rx="1" fill="currentColor" stroke="none"/><path d="M21.5 10.5v3"/>',
  cc: '<rect x="3" y="5" width="8" height="5" rx="2.5"/><rect x="13" y="14" width="8" height="5" rx="2.5"/><circle cx="16.5" cy="7.5" r="2.5"/><circle cx="7.5" cy="16.5" r="2.5"/>',
  search: '<circle cx="10.5" cy="10.5" r="6"/><path d="M15 15l5 5"/>',
  link: '<path d="M10 14l4-4"/><path d="M8.5 11l-2 2a3.5 3.5 0 005 5l2-2M15.5 13l2-2a3.5 3.5 0 00-5-5l-2 2"/>',
  layers: '<path d="M12 4l8.5 4.5L12 13 3.5 8.5z"/><path d="M3.5 12.5L12 17l8.5-4.5M3.5 16L12 20.5l8.5-4.5"/>',
};

function injectIcons() {
  const ns = 'http://www.w3.org/2000/svg';
  const sprite = document.createElementNS(ns, 'svg');
  sprite.setAttribute('style', 'display:none');
  sprite.innerHTML = Object.entries(ICONS)
    .map(([k, v]) => `<symbol id="${k}" viewBox="0 0 24 24">${v}</symbol>`).join('');
  document.body.prepend(sprite);
  // <i data-i="name" class="sm"></i> → inline SVG icon
  document.querySelectorAll('i[data-i]').forEach((el) => {
    const s = document.createElementNS(ns, 'svg');
    s.setAttribute('class', 'i ' + (el.className || ''));
    s.innerHTML = `<use href="#${el.dataset.i}"/>`;
    if (el.style.cssText) s.setAttribute('style', el.style.cssText);
    el.replaceWith(s);
  });
}

// ---------- Synthetic pictures ----------

function person(fx, id) {
  const peak = fx.includes('peak');
  const p = `
    <path d="M410 900 C450 700 610 655 800 655 C990 655 1150 700 1190 900 Z" fill="url(#sweater${id})"/>
    <path d="M735 560 h130 v120 c-30 25 -100 25 -130 0z" fill="#a8704f"/>
    <ellipse cx="800" cy="420" rx="148" ry="188" fill="url(#skin${id})"/>
    <ellipse cx="652" cy="440" rx="22" ry="40" fill="#b67b5a"/>
    <ellipse cx="948" cy="440" rx="22" ry="40" fill="#b67b5a"/>
    <path d="M652 400 C640 250 720 205 805 205 C900 205 965 260 950 400 C930 330 880 300 800 300 C730 300 680 320 652 400z" fill="#2a1d16"/>
    <ellipse cx="745" cy="430" rx="15" ry="8" fill="#3b2a22"/><ellipse cx="855" cy="430" rx="15" ry="8" fill="#3b2a22"/>
    <path d="M722 402 q22 -10 46 -2 M832 400 q24 -8 46 2" stroke="#3a281e" stroke-width="7" fill="none" stroke-linecap="round"/>
    <path d="M800 445 q-10 45 -18 60 q16 8 34 0" stroke="#9c6347" stroke-width="5" fill="none" stroke-linecap="round"/>
    <path d="M760 545 q40 18 80 0" stroke="#8d4f3d" stroke-width="7" fill="none" stroke-linecap="round"/>`;
  const edges = peak ? `
    <g stroke="#ff2d2d" stroke-width="3.5" fill="none" stroke-dasharray="6 5 2 6" opacity="0.95">
      <path d="M652 400 C640 250 720 205 805 205 C900 205 965 260 950 400"/>
      <path d="M722 402 q22 -10 46 -2 M832 400 q24 -8 46 2"/>
      <ellipse cx="745" cy="430" rx="17" ry="10"/><ellipse cx="855" cy="430" rx="17" ry="10"/>
      <path d="M760 545 q40 18 80 0"/>
      <path d="M690 300 q20 -40 60 -55 M870 250 q30 20 50 60"/>
    </g>` : '';
  return p + edges;
}

function room(variant, id) {
  const book = (x, y, w, h, c) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${c}"/>`;
  let books = '';
  const colors = ['#7d3b33', '#36506b', '#8a7246', '#4e6046', '#5b4060', '#a0643a', '#2f4153'];
  for (let shelf = 0; shelf < 4; shelf++) {
    let x = 1200;
    let i = shelf * 3;
    while (x < 1500) {
      const w = 18 + ((i * 37) % 22);
      const h = 90 + ((i * 53) % 34);
      books += book(x, 150 + shelf * 140 + (124 - h), w, h, colors[i % colors.length]);
      x += w + 3; i++;
    }
  }
  return `
    <rect width="1600" height="900" fill="url(#wall${id})"/>
    <rect x="70" y="80" width="400" height="560" rx="6" fill="#c9d2d6"/>
    <rect x="86" y="96" width="368" height="528" fill="url(#sky${id})"/>
    <path d="M270 96v528M86 360h368" stroke="#b8c0c4" stroke-width="12"/>
    <rect x="1180" y="120" width="350" height="580" fill="#2b221d"/>
    ${books}
    <path d="M1180 274h350M1180 414h350M1180 554h350" stroke="#3a2e26" stroke-width="14"/>
    <ellipse cx="1080" cy="610" rx="70" ry="110" fill="#2e4a2c"/><ellipse cx="1040" cy="560" rx="45" ry="90" fill="#3d5f36"/>
    <rect x="1040" y="680" width="80" height="90" rx="10" fill="#6a4a36"/>
    <rect y="800" width="1600" height="100" fill="#35281f"/>
    <rect x="0" y="0" width="1600" height="900" fill="url(#vignette${id})"/>
    ${variant === 'wide' ? '<rect x="560" y="620" width="520" height="40" rx="8" fill="#1a1512"/>' : ''}`;
}

let nextSceneID = 0;

function sceneSVG(kind, tone, fx) {
  const id = `-scene-${++nextSceneID}`;
  let content = room(kind, id);
  if (kind === 'wide') content += `<g transform="translate(560 250) scale(0.55)">${person(fx, id)}</g>`;
  else if (kind === 'ots') content += `<g transform="translate(-150 120) scale(0.95) rotate(-4 800 500)">${person(fx, id)}</g>`;
  else content += person(fx, id);
  if (fx.includes('zebra')) {
    content += `<rect x="86" y="96" width="368" height="528" fill="url(#zeb${id})"/>`;
  }
  if (fx.includes('guides')) {
    content += `<g stroke="#fff" stroke-opacity="0.55" stroke-width="2" fill="none">
      <path d="M533 0v900M1067 0v900M0 300h1600M0 600h1600"/>
      <rect x="80" y="45" width="1440" height="810" stroke-dasharray="10 8"/>
      <path d="M780 450h40M800 430v40"/></g>`;
  }
  const filter =
    fx.includes('false') ? `url(#fc${id})` : tone === 'slog' ? `url(#slog${id})` : 'none';
  // Sony-ish S-Log3: lifted, flat and desaturated. False color: luminance bands.
  const fcBins = [
    [0.55, 0.1, 0.7], [0.1, 0.35, 0.95], [0.22, 0.22, 0.22], [0.28, 0.28, 0.28], [0.34, 0.34, 0.34],
    [0.4, 0.4, 0.4], [0.2, 0.8, 0.25], [0.48, 0.48, 0.48], [0.53, 0.53, 0.53], [1, 0.52, 0.72],
    [0.62, 0.62, 0.62], [0.67, 0.67, 0.67], [0.72, 0.72, 0.72], [1, 0.92, 0.1], [1, 0.15, 0.1], [1, 0.15, 0.1],
  ];
  const t = (c) => fcBins.map((b) => b[c]).join(' ');
  return `<svg class="scene" viewBox="0 0 1600 900" preserveAspectRatio="xMidYMid slice" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <linearGradient id="wall${id}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#7a6553"/><stop offset="1" stop-color="#4a3b31"/></linearGradient>
      <linearGradient id="sky${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f4f8fb"/><stop offset="1" stop-color="#dfe9ee"/></linearGradient>
      <linearGradient id="sweater${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#36557a"/><stop offset="1" stop-color="#1f3149"/></linearGradient>
      <radialGradient id="skin${id}" cx="0.42" cy="0.4" r="0.7"><stop offset="0" stop-color="#e2a582"/><stop offset="0.7" stop-color="#c98e6c"/><stop offset="1" stop-color="#9c6347"/></radialGradient>
      <radialGradient id="vignette${id}" cx="0.5" cy="0.5" r="0.75"><stop offset="0.6" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity="0.45"/></radialGradient>
      <pattern id="zeb${id}" width="22" height="22" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
        <rect width="11" height="22" fill="#000" fill-opacity="0.55"/></pattern>
      <filter id="slog${id}" color-interpolation-filters="sRGB">
        <feColorMatrix type="saturate" values="0.5"/>
        <feComponentTransfer><feFuncR type="linear" slope="0.6" intercept="0.17"/><feFuncG type="linear" slope="0.6" intercept="0.17"/><feFuncB type="linear" slope="0.6" intercept="0.19"/></feComponentTransfer>
      </filter>
      <filter id="fc${id}" color-interpolation-filters="sRGB">
        <feColorMatrix type="matrix" values="0.2126 0.7152 0.0722 0 0  0.2126 0.7152 0.0722 0 0  0.2126 0.7152 0.0722 0 0  0 0 0 1 0"/>
        <feComponentTransfer><feFuncR type="discrete" tableValues="${t(0)}"/><feFuncG type="discrete" tableValues="${t(1)}"/><feFuncB type="discrete" tableValues="${t(2)}"/></feComponentTransfer>
      </filter>
    </defs>
    <g filter="${filter}">${content}</g>
  </svg>`;
}

function renderScenes() {
  document.querySelectorAll('[data-scene]').forEach((el) => {
    const fx = (el.dataset.fx || '').split(',');
    el.insertAdjacentHTML('afterbegin', sceneSVG(el.dataset.scene, el.dataset.tone || '709', fx));
  });
}

// ---------- Scopes computed from the synthetic picture ----------

function loadSceneBitmap(kind, tone) {
  return new Promise((resolve) => {
    const svg = sceneSVG(kind, tone, []).replace('class="scene" ', '').replace('preserveAspectRatio="xMidYMid slice"', 'width="320" height="180"');
    const img = new Image();
    img.onload = () => {
      const c = document.createElement('canvas');
      c.width = 320; c.height = 180;
      const g = c.getContext('2d');
      g.drawImage(img, 0, 0, 320, 180);
      resolve(g.getImageData(0, 0, 320, 180));
    };
    img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  });
}

async function renderScopes() {
  const canvases = [...document.querySelectorAll('canvas[data-scope]')];
  for (const cv of canvases) {
    const data = await loadSceneBitmap(cv.dataset.src || 'mcu', cv.dataset.tone || '709');
    const W = cv.width = cv.clientWidth * 2;
    const H = cv.height = cv.clientHeight * 2;
    const g = cv.getContext('2d');
    g.fillStyle = '#050607';
    g.fillRect(0, 0, W, H);
    // Graticule: −10…110 IRE, every 10 IRE with stronger 0/100.
    const yOf = (ire) => H - ((ire + 10) / 120) * H;
    g.lineWidth = 1;
    for (let ire = 0; ire <= 100; ire += 10) {
      g.strokeStyle = ire % 50 === 0 ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.08)';
      g.beginPath(); g.moveTo(0, yOf(ire)); g.lineTo(W, yOf(ire)); g.stroke();
    }
    g.globalCompositeOperation = 'lighter';
    const parade = cv.dataset.scope === 'parade';
    const lanes = parade ? 3 : 1;
    const laneW = W / lanes;
    const colors = parade ? ['rgba(255,60,50,0.06)', 'rgba(60,255,90,0.06)', 'rgba(60,120,255,0.07)'] : ['rgba(200,255,210,0.05)'];
    const d = data.data;
    for (let lane = 0; lane < lanes; lane++) {
      g.fillStyle = colors[lane];
      for (let y = 0; y < 180; y += 1) {
        for (let x = 0; x < 320; x += 1) {
          const p = (y * 320 + x) * 4;
          const v = parade ? d[p + lane] : 0.2126 * d[p] + 0.7152 * d[p + 1] + 0.0722 * d[p + 2];
          const ire = (v / 255) * 100;
          g.fillRect(lane * laneW + (x / 320) * (laneW - 6) + 3, yOf(ire) + (Math.random() - 0.5) * 2, 2, 2);
        }
      }
    }
    g.globalCompositeOperation = 'source-over';
    if (parade) {
      g.strokeStyle = 'rgba(255,255,255,0.12)';
      for (let lane = 1; lane < 3; lane++) { g.beginPath(); g.moveTo(lane * laneW, 0); g.lineTo(lane * laneW, H); g.stroke(); }
    }
    g.fillStyle = 'rgba(255,255,255,0.45)';
    g.font = `${Math.min(22, Math.round(H / 14))}px -apple-system`;
    [100, 50, 0].forEach((ire) => g.fillText(String(ire), 6, yOf(ire) - 4));
  }
  document.body.dataset.ready = '1';
}

window.addEventListener('DOMContentLoaded', () => {
  injectIcons();
  renderScenes();
  renderScopes();
});
