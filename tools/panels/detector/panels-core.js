// Detector de viñetas (sin dependencias, sirve en Worker y en el hilo principal).
//
// Hay dos estilos de maquetación y cada uno necesita un método distinto:
//
//   clean → «márgenes claros»: viñetas con marco sobre fondo de papel y calles anchas
//           (cómic americano en color, europeo…). Se construye una máscara de "tinta"
//           (todo lo que no es fondo) y se corta por las filas/columnas sin tinta.
//   dense → «arte a sangre»: dibujo denso hasta el borde de la página, sin marcos, con
//           calles que son líneas finas de papel blanco (blanco y negro pintado, mangas
//           modernos, Savage Sword…). Aquí toda la página es "tinta"; se buscan líneas
//           finas casi totalmente blancas y se corta por ellas.
//
// En modo automático se ejecutan los dos y se elige el que mejor explica la página
// (ver `choose`). Devuelve { kind, style, panels } con rectángulos normalizados (0..1)
// en orden de lectura.
//   kind:  'comic' (dos o más viñetas) · 'single' (una sola / ilustración) · 'text'
//   style: 'clean' | 'dense' | 'framed' | 'dark' | 'black'
// Los estilos «calles oscuras» (dark) y «marco negro» (black) tienen sus propios métodos.

export const DETECT_MAX = 900; // lado mayor de la imagen reducida que se analiza
export const FULL_PAGE = Object.freeze({ x: 0, y: 0, w: 1, h: 1 });

const TOL = 40; // diferencia máxima por canal para considerar un píxel "fondo"
// Límites del método con marco: pares arriba×abajo (o izquierda×derecha) que se
// admiten (una página con marcos no pasa de ~1500) y tiempo máximo del emparejado.
const DARK_INK = 60; // luminancia a partir de la cual un píxel es dibujo sobre fondo negro
const DARK_CUT_LOW = 0.05; // calle oscura limpia: dibujo que la cruza (esquirlas, una punta de dedo)
const DARK_CUT_HIGH = 0.15; // calle oscura como valle: tinta máxima, y además ≤ la mitad de la de ambos lados
const FRAMED_MAX_SEGS = 250; // bordes brutos por dirección (una página con marcos: < 100)
const FRAMED_MAX_PAIRS = 6000;
const FRAMED_BUDGET_MS = 1500;
const PAPER = 210; // luminancia mínima del papel blanco (calles del estilo denso)
// Parámetros ajustables desde el banco de pruebas.
export const TUNE = {
  darkPage: 0.3, // fracción de píxeles casi negros (luminancia < 50): página oscura en blanco y negro
  darkColorPage: 0.12, // ídem para una página en color (las calles negras ocupan menos)
  paperCap: PAPER,
  paperDrop: 25,
  framedCap: 235,
  framedDrop: 20,
};

// `hi`, opcional: "luminancia de papel" de la página a doble resolución (2w × 2h; 0 en
// los píxeles con color). Con ella las calles finas, que al reducir a `w` se mezclan con
// el dibujo y salen grises, siguen contando como papel en el estilo «arte a sangre».
export function detectPanels(
  data,
  w,
  h,
  { rtl = false, style = "auto", debug = null, hi = null, hiLuma = null, neg = null } = {},
) {
  const norm = (r) => ({
    x: r.x0 / w,
    y: r.y0 / h,
    w: (r.x1 - r.x0) / w,
    h: (r.y1 - r.y0) / h,
  });
  let clean = detectClean(data, w, h, rtl);
  // Si calles claras ya reparte la página en viñetas con marco que cubren el dibujo, arte a
  // sangre solo puede partirlas más por calles de verdad (strict), no por el borde de un
  // cielo: dentro de un marco no hay calles que no se vean desde fuera.
  const strict =
    clean.rects.length >= 2 && coverage(clean.rects, clean.bbox) >= 0.7 && framedShare(clean.rects, data, w, h) >= 0.6;
  let dense =
    style === "clean" || style === "framed"
      ? null
      : detectDense(data, w, h, rtl, clean.bbox, debug, hi, strict);
  // Bocadillos que tapan una calle: se prueba otra vez sin ellos, y si así salen más viñetas
  // se usa ese resultado. Al final, cada uno vuelve entero a una de sus viñetas.
  let gutterBalloons = null;
  if (!clean.text && style !== "black") {
    const nb = withoutGutterBalloons(data, w, h, hi);
    if (nb) {
      gutterBalloons = nb.balloons;
      const c2 = style === "framed" ? clean : detectClean(nb.data, w, h, rtl);
      if (!c2.text && c2.rects.length > clean.rects.length && coverage(c2.rects, c2.bbox || clean.bbox) >= 0.7) clean = c2;
      if (dense && style !== "framed") {
        const d2 = detectDense(nb.data, w, h, rtl, clean.bbox, null, nb.hi, strict);
        if (d2.rects.length > dense.rects.length) dense = d2;
      }
      if (debug) debug.gutterBalloons = nb.balloons;
    }
  }
  // Las viñetas sin marco se recuperan de lo que ven los otros dos métodos.
  const others = [...clean.rects, ...(dense ? dense.rects : [])];
  const framed = style === 'clean' || style === 'dense' ? null : detectFramed(data, w, h, rtl, clean.bbox, debug, hi, hiLuma, others);
  for (const r of [clean, dense, framed])
    if (r) r.rects = mergeFlat(r.rects, data, w, h);
  let pick =
    style === "auto" || style === "black"
      ? choose(clean, dense, framed)
      : { dense, framed, clean }[style] || clean;
  // Marco negro: solo si el usuario lo elige. Si en la página no hay al menos dos viñetas con
  // marco (una portada, una página de calles negras), se hace como en el modo automático.
  if (style === "black") {
    const black = hiLuma
      ? detectBlack(hiLuma, 2 * w, 2 * h).map((r) => ({ x0: r.x0 / 2, y0: r.y0 / 2, x1: r.x1 / 2, y1: r.y1 / 2 }))
      : [];
    if (black.length < 2) return detectPanels(data, w, h, { rtl, style: "auto", debug, hi, hiLuma, neg });
    pick = { style: "black", rects: black };
  }
  // Página oscura (fondo negro): las calles son negras y los tres métodos, que buscan
  // papel claro, no las ven. El método de calles oscuras gana si encuentra más viñetas.
  // Calles negras. `neg` es la página en negativo (solo si tiene bastante negro). En una
  // página en color sobre negro los tres métodos normales ven las calles en el negativo
  // como si fueran papel; en una en blanco y negro (dibujo rayado sobre negro) el negativo
  // los confunde y se usa el método de valles, que solo se aplica si el usuario fuerza el
  // estilo «calles oscuras» (en automático parte las ilustraciones a página completa). En
  // una página de texto sobre negro no hay viñetas que buscar.
  if ((style === "auto" || style === "dark") && neg && !clean.text) {
    let dark;
    // Con dibujo en color el negativo también forma trozos en una página de papel blanco
    // con mucho negro, así que solo se prueba cuando los métodos normales dejan la página
    // entera (o casi: una sola viñeta con más del 80 % de la página).
    const wholeish = pick.rects.length < 2 || pick.rects.some((r) => area(r) >= w * h * 0.8);
    if (neg.color && !wholeish) dark = { rects: [] };
    else if (!neg.color && style !== "dark") dark = { rects: [] }; // en blanco y negro, solo si se fuerza
    else if (neg.color) {
      const nClean = detectClean(neg.data, w, h, rtl);
      const nDense = detectDense(neg.data, w, h, rtl, nClean.bbox, null, neg.hi);
      const negFramed = detectFramed(neg.data, w, h, rtl, nClean.bbox, null, neg.hi, neg.hiLuma, [...nClean.rects, ...nDense.rects]);
      for (const r of [nClean, nDense, negFramed]) r.rects = mergeFlat(r.rects, neg.data, w, h);
      dark = { ...choose(nClean, nDense, negFramed), style: "dark" };
      dark.rects = dark.rects.filter((r) => r.x1 - r.x0 >= w * 0.1 && r.y1 - r.y0 >= h * 0.08); // sin tiras finas
      // Sin las garantías de las calles de papel, solo vale un resultado que reparte casi
      // toda la página en pocas viñetas y cuyas viñetas están rodeadas de calles oscuras
      // (en una página de papel blanco con mucho negro el negativo también forma trozos).
      if (
        dark.rects.length > 12 ||
        coverage(dark.rects, { x0: 0, y0: 0, x1: w, y1: h }) < 0.5 ||
        gapDarkness(dark.rects, data, w, h) < 0.6
      )
        dark.rects = [];
      if (debug) {
        const ch = choose(nClean, nDense, negFramed);
        debug.dark = {
          color: true,
          rects: dark.rects,
          counts: `clean ${nClean.rects.length} dense ${nDense.rects.length} framed ${negFramed.rects.length} (marcos ${negFramed.framedCount}) elegido ${ch.style} ${ch.rects.length} cobertura ${coverage(ch.rects, { x0: 0, y0: 0, x1: w, y1: h }).toFixed(2)} calles oscuras ${gapDarkness(ch.rects, data, w, h).toFixed(2)}`,
        };
      }
    } else {
      const negFramed = detectFramed(neg.data, w, h, rtl, null, null, neg.hi, neg.hiLuma, []);
      const frames = negFramed.rects.filter((r) => r.frame >= 0.6);
      dark = detectDark(data, w, h, rtl, debug ? (debug.dark = {}) : null, frames, hiLuma);
    }
    // En una página en color el negativo solo se ha probado si la página quedaba entera;
    // en blanco y negro los métodos normales toman el negro por tinta y no son de fiar.
    if (dark.rects.length >= 2 && (style === "dark" || !neg.color || dark.rects.length > pick.rects.length)) pick = dark;
    else if (style === "dark") pick = { ...clean, rects: [] };
  } else if (style === "dark") pick = { ...clean, rects: [] };
  // Viñetas encajadas sobre una ilustración de fondo, con marco negro y el dibujo del fondo
  // entre ellas: sin calles de papel, nada de lo anterior las ve. Solo se buscan si la
  // página sigue entera; se presentan con el estilo «marco negro».
  if (
    style === "auto" &&
    hiLuma &&
    !clean.text &&
    (pick.rects.length < 2 || pick.rects.some((r) => area(r) >= w * h * 0.8))
  ) {
    const insets = detectInsets(hiLuma, 2 * w, 2 * h).map((r) => ({ x0: r.x0 / 2, y0: r.y0 / 2, x1: r.x1 / 2, y1: r.y1 / 2 }));
    if (insets.length >= 2) pick = { style: "black", rects: insets };
  }
  if (gutterBalloons && pick.rects.length >= 2 && pick.style !== "dark")
    pick = { ...pick, rects: reattachBalloons(pick.rects, gutterBalloons) };
  // Alternativas: lo que vio cada método (para el estilo por cómic del lector, que puede
  // preferir otro método sin volver a procesar la página) y grado de seguridad de la
  // elección automática, con su motivo.
  const alt = (r) =>
    r && r.rects.length >= 2
      ? { panels: orderRects(r.rects, false).map(norm), panelsRtl: orderRects(r.rects, true).map(norm) }
      : null;
  const alternatives = { clean: alt(clean), dense: alt(dense), framed: alt(framed) };
  if (pick.style === "dark" || pick.style === "black") alternatives[pick.style] = alt(pick);
  let doubt = null;
  if (style === "auto" && pick.rects.length >= 2) {
    const nc = clean.rects.length;
    const nd = dense ? dense.rects.length : 0;
    if (pick.rects.some((r) => area(r) >= w * h * 0.85)) doubt = "whole";
    else if (coverage(pick.rects, clean.bbox) < 0.5) doubt = "coverage";
    void nc;
    void nd;
  }
  const extra = {
    gutter: dense?.gutter,
    alternatives,
    sure: !doubt,
    doubt,
    counts: { clean: clean.rects.length, dense: dense ? dense.rects.length : 0, framed: framed ? framed.rects.length : 0, frames: framed ? framed.framedCount : 0 },
  };

  const rtlRects =
    pick.rects.length >= 2 ? orderRects(pick.rects, true).map(norm) : null; // sentido manga
  pick = { ...pick, rects: orderRects(pick.rects, rtl) };

  if (clean.text && pick.rects.length < 2)
    return {
      kind: "text",
      style: "clean",
      panels: [FULL_PAGE],
      ...extra,
    };
  if (pick.rects.length >= 2) {
    return {
      kind: "comic",
      style: pick.style,
      panels: pick.rects.map(norm),
      panelsRtl: rtlRects,
      ...extra,
    };
  }
  // Página con una sola viñeta rodeada de margen: encuadramos esa viñeta.
  const one = pick.rects.length === 1 ? pick.rects[0] : clean.bbox;
  if (one && area(one) < w * h * 0.8) {
    return {
      kind: "single",
      style: pick.style,
      panels: [norm(one)],
      ...extra,
    };
  }
  return {
    kind: "single",
    style: pick.style,
    panels: [FULL_PAGE],
    ...extra,
  };
}

// Parte de los recuadros que llevan marco: una línea oscura fina (luminancia < 100, con algo
// más claro justo por dentro) a lo largo de al menos tres de sus lados, justo por dentro del
// borde. El dibujo oscuro que llega hasta el borde no es un marco.
function framedShare(rects, data, w, h) {
  const luma = (x, y) => {
    if (x < 0 || y < 0 || x >= w || y >= h) return 255;
    const i = (y * w + x) * 4;
    return 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
  };
  const IN = 5; // el marco está a lo sumo a estos píxeles por dentro del borde
  // Fracción del lado con una línea oscura a la distancia `d` del borde y algo más claro
  // (al menos 60 de luminancia más) tres píxeles más adentro.
  const side = (len, at) => {
    let best = 0;
    for (let d = 0; d < IN; d++) {
      let n = 0;
      let m = 0;
      for (let k = 0; k < len; k += 2, m++) {
        const l = at(k, d);
        if (l < 100 && at(k, d + 3) > l + 60) n++;
      }
      if (m && n / m > best) best = n / m;
    }
    return best;
  };
  let framed = 0;
  for (const r of rects) {
    const sides = [
      side(r.x1 - r.x0, (k, d) => luma(r.x0 + k, r.y0 + d)),
      side(r.x1 - r.x0, (k, d) => luma(r.x0 + k, r.y1 - 1 - d)),
      side(r.y1 - r.y0, (k, d) => luma(r.x0 + d, r.y0 + k)),
      side(r.y1 - r.y0, (k, d) => luma(r.x1 - 1 - d, r.y0 + k)),
    ];
    if (sides.filter((v) => v >= 0.6).length >= 3) framed++;
  }
  return rects.length ? framed / rects.length : 0;
}

// Elige entre los dos resultados. Cada uno tiene sus propias garantías (el limpio
// exige que las viñetas cubran casi todo el dibujo; el denso comprueba cada corte), así
// que gana el que encuentra más viñetas: cuando ambos ven las mismas calles dan el mismo
// número, y el que ve una calle más es el que ha entendido mejor la página. En caso de
// empate se prefiere el limpio, cuyos recuadros vienen de la máscara de tinta.
function choose(clean, dense, framed) {
  // Los marcos son la señal más fiable: si se han encontrado marcos que cubren la mayor
  // parte del dibujo, esa es la maquetación de la página.
  if (
    framed &&
    framed.framedCount >= 2 &&
    framed.framedCount >= 0.6 * framed.rects.length &&
    coverage(framed.rects, clean.bbox) >= 0.5
  ) {
    return framed;
  }
  const c = clean.rects.length >= 2 && coverage(clean.rects, clean.bbox) >= 0.7;
  const d = dense.rects.length >= 2;
  if (c && d) return dense.rects.length > clean.rects.length ? dense : clean;
  if (d) return dense;
  if (c) return clean;
  // Ninguno convence: una sola viñeta (el recuadro del dibujo) o nada.
  return { ...clean, rects: clean.rects.length === 1 ? clean.rects : [] };
}

// Un título en letras grandes (cada letra, un recuadro) no son viñetas: los recuadros
// «planos» (casi sin cambios de tono en su interior y con bastante papel) que se
// tocan en fila o en columna se funden en uno solo.
function mergeFlat(rects, data, w, h) {
  if (rects.length < 2) return rects;
  const ref = paperRef(data, w, h);
  const flat = (r) => {
    // Pocos cambios de tono, bastante papel y una sola tinta (poca dispersión de
    // luminancia fuera del papel): una letra grande, no un dibujo.
    let edges = 0;
    let paper = 0;
    let n = 0;
    let m = 0;
    let sum = 0;
    let sum2 = 0;
    for (
      let y = Math.max(0, Math.round(r.y0));
      y < Math.min(h, Math.round(r.y1));
      y++
    ) {
      for (
        let x = Math.max(0, Math.round(r.x0));
        x < Math.min(w, Math.round(r.x1)) - 1;
        x++
      ) {
        const i = (y * w + x) * 4;
        const l = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
        const l2 =
          0.299 * data[i + 4] + 0.587 * data[i + 5] + 0.114 * data[i + 6];
        if (Math.abs(l - l2) > 30) edges++;
        if (paperLuma(data[i], data[i + 1], data[i + 2], ref) >= PAPER) paper++;
        else {
          m++;
          sum += l;
          sum2 += l * l;
        }
        n++;
      }
    }
    const mean = sum / Math.max(1, m);
    const sd = Math.sqrt(Math.max(0, sum2 / Math.max(1, m) - mean * mean));
    return n > 0 && edges / n < 0.12 && paper / n >= 0.3 && sd < 22;
  };
  const list = rects.map((r) => ({ ...r, flat: flat(r) }));
  if (list.filter((r) => r.flat).length < 2) return rects;
  for (let changed = true; changed;) {
    changed = false;
    outer: for (let i = 0; i < list.length; i++) {
      for (let j = i + 1; j < list.length; j++) {
        const a = list[i];
        const b = list[j];
        if (!a.flat || !b.flat) continue;
        const yo = Math.min(a.y1, b.y1) - Math.max(a.y0, b.y0);
        const xo = Math.min(a.x1, b.x1) - Math.max(a.x0, b.x0);
        const row =
          yo >= 0.5 * Math.min(a.y1 - a.y0, b.y1 - b.y0) && -xo <= 0.06 * w;
        const col =
          xo >= 0.5 * Math.min(a.x1 - a.x0, b.x1 - b.x0) && -yo <= 0.06 * h;
        if (!row && !col) continue;
        list[i] = {
          ...a,
          x0: Math.min(a.x0, b.x0),
          y0: Math.min(a.y0, b.y0),
          x1: Math.max(a.x1, b.x1),
          y1: Math.max(a.y1, b.y1),
          flat: true,
        };
        list.splice(j, 1);
        changed = true;
        break outer;
      }
    }
  }
  return list.map(({ flat: _f, ...r }) => r);
}

function coverage(rects, bbox) {
  if (!bbox) return 0;
  return rects.reduce((s, r) => s + area(r), 0) / Math.max(1, area(bbox));
}

// ---------- estilo «marco negro» ----------
//
// Viñetas con un marco negro fino, aunque estén giradas o no sean rectángulos (se toma el
// recuadro de sus puntos más alejados, aunque coja trocitos de las vecinas). Solo se usa si
// el usuario elige el estilo. Trabaja sobre la luminancia a doble resolución (`hiLuma`, 2w×2h),
// donde el marco fino sigue siendo negro:
//   1. muros: líneas oscuras finas y largas (el marco), horizontales o verticales; una línea
//      algo inclinada son tramos cortos escalonados;
//   2. papel: se rellena desde el borde de la página todo lo claro que no cruza un muro; las
//      calles claras estrechas que quedan encerradas también cuentan como papel;
//   3. lo que queda encerrado son las viñetas; un bloque que junta varias (un bocadillo que
//      cruza la calle, dibujos que se solapan) se parte por la recta más parecida a una calle,
//      o, si no la hay, por la que sigue casi de lado a lado un marco fino (una viñeta pegada
//      a un dibujo sin marco).
const BLACK = {
  ink: 80, // luminancia máxima del marco
  run: 0.04, // largo mínimo de un tramo de muro (fracción del ancho)
  side: 5, // a esta distancia del muro, a un lado al menos, ya no hay tinta (el marco es fino)
  strip: 0.012, // media anchura máxima de una calle encerrada (fracción del ancho)
  cut: 0.6, // separación mínima de un corte (papel o muro 1, tinta oscura ½)
  strong: 0.3, // parte mínima del corte que pasa por papel o muro
  merge: 0.25, // solape a partir del cual dos recuadros son la misma viñeta
  ridge: 20, // contraste de una cresta (línea fina más oscura que ambos lados)
  lineAny: 0.92, // corte por línea fina: parte mínima que es papel, muro, cresta o tinta…
  lineThin: 0.5, // …y parte mínima que es papel, muro o cresta
  lineMinW: 0.15, // …dejando a cada lado al menos este ancho (corte vertical)…
  lineMinH: 0.1, // …o este alto (corte horizontal)
};
const BLACK_SLOPES = [-0.05, -0.035, -0.02, -0.01, 0, 0.01, 0.02, 0.035, 0.05];
const INSET_SLOPES = [-0.02, -0.01, 0, 0.01, 0.02]; // viñetas encajadas: marcos algo torcidos

// Componentes 4-conexas de mask: etiqueta de cada píxel y { id, x0, y0, x1, y1, area }.
function blackComponents(mask, W, H) {
  const n = W * H;
  const lab = new Int32Array(n);
  const q = new Int32Array(n);
  const comps = [];
  for (let s = 0; s < n; s++) {
    if (!mask[s] || lab[s]) continue;
    const id = comps.length + 1;
    let x0 = W;
    let y0 = H;
    let x1 = 0;
    let y1 = 0;
    let area = 0;
    let qh = 0;
    let qt = 0;
    q[qt++] = s;
    lab[s] = id;
    while (qh < qt) {
      const p = q[qh++];
      const x = p % W;
      const y = (p - x) / W;
      area++;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
      if (x > 0 && mask[p - 1] && !lab[p - 1]) (lab[p - 1] = id), (q[qt++] = p - 1);
      if (x < W - 1 && mask[p + 1] && !lab[p + 1]) (lab[p + 1] = id), (q[qt++] = p + 1);
      if (p >= W && mask[p - W] && !lab[p - W]) (lab[p - W] = id), (q[qt++] = p - W);
      if (p < n - W && mask[p + W] && !lab[p + W]) (lab[p + W] = id), (q[qt++] = p + W);
    }
    comps.push({ id, x0, y0, x1: x1 + 1, y1: y1 + 1, area });
  }
  return { lab, comps };
}

// Distancia de chaflán 3-4 (×3) de cada píxel de mask al más cercano fuera de ella (el borde
// de la imagen cuenta como fuera).
function blackDistance(mask, W, H) {
  const n = W * H;
  const d = new Uint16Array(n);
  for (let p = 0; p < n; p++) d[p] = mask[p] ? 60000 : 0;
  for (let y = 0; y < H; y++)
    for (let x = 0; x < W; x++) {
      const p = y * W + x;
      if (!d[p]) continue;
      let v = Math.min(d[p], x > 0 ? d[p - 1] + 3 : 3);
      if (y > 0) {
        v = Math.min(v, d[p - W] + 3);
        if (x > 0) v = Math.min(v, d[p - W - 1] + 4);
        if (x < W - 1) v = Math.min(v, d[p - W + 1] + 4);
      } else v = Math.min(v, 3);
      d[p] = v;
    }
  for (let y = H - 1; y >= 0; y--)
    for (let x = W - 1; x >= 0; x--) {
      const p = y * W + x;
      if (!d[p]) continue;
      let v = Math.min(d[p], x < W - 1 ? d[p + 1] + 3 : 3);
      if (y < H - 1) {
        v = Math.min(v, d[p + W] + 3);
        if (x < W - 1) v = Math.min(v, d[p + W + 1] + 4);
        if (x > 0) v = Math.min(v, d[p + W - 1] + 4);
      } else v = Math.min(v, 3);
      d[p] = v;
    }
  return d;
}

// Viñetas con marco negro sobre la luminancia L (W×H). Devuelve recuadros en esa escala.
// Nivel del papel de una página por su luminancia: percentil 90; lo claro a partir del
// umbral devuelto es papel posible.
function blackPaperLevel(L) {
  const n = L.length;
  const hist = new Uint32Array(256);
  for (let p = 0; p < n; p++) hist[L[p]]++;
  let paper = 255;
  for (let v = 255, acc = 0; v >= 0; v--) {
    acc += hist[v];
    if (acc >= n * 0.1) {
      paper = v;
      break;
    }
  }
  return Math.max(120, Math.min(200, paper - 60));
}

// Muros: tramos oscuros (luminancia < BLACK.ink) largos (al menos BLACK.run del ancho) y
// finos (a BLACK.side píxeles, a un lado al menos, ya no hay tinta, o con `relative` hay
// algo bastante más claro que el muro: un marco entre dos zonas oscuras), horizontales o
// verticales. Devuelve su máscara y, si se pasa `segs`, añade cada tramo como
// { horizontal, o, from, to } (o = fila o columna).
function blackWalls(L, W, H, segs = null, relative = false) {
  const n = W * H;
  const D = BLACK.ink;
  const wall = new Uint8Array(n);
  const minRun = Math.round(W * BLACK.run);
  const sd = BLACK.side;
  const scan = (horizontal) => {
    const A = horizontal ? H : W;
    const B = horizontal ? W : H;
    const at = horizontal ? (a, b) => a * W + b : (a, b) => b * W + a;
    const side = horizontal ? sd * W : sd;
    for (let a = sd; a < A - sd; a++) {
      let b = 0;
      while (b < B) {
        if (L[at(a, b)] >= D) {
          b++;
          continue;
        }
        let e = b;
        let thin = 0;
        while (e < B && L[at(a, e)] < D) {
          const p = at(a, e);
          const lit = relative ? L[p] + 40 : D + 40;
          if (L[p - side] >= lit || L[p + side] >= lit) thin++;
          e++;
        }
        if (e - b >= minRun && thin >= 0.8 * (e - b)) {
          for (let k = b; k < e; k++) wall[at(a, k)] = 1;
          if (segs) segs.push({ horizontal, o: a, from: b, to: e });
        }
        b = e;
      }
    }
  };
  scan(true);
  scan(false);
  return wall;
}

// ---------- viñetas encajadas sobre una ilustración ----------

// Página con una ilustración de fondo y viñetas encima, cada una con un marco negro fino y
// el dibujo del fondo asomando entre ellas (*El Caballero Negro*): sin calles de papel, los
// métodos normales la dejan entera. Trabaja sobre la luminancia a doble resolución.
//   1. Un marco es un rectángulo cuyos lados son muros (los de «marco negro») o el borde de
//      la página, con al menos dos lados de muro; cada lado ha de estar cubierto de muro
//      casi entero (uno puede estar tapado a medias por un bocadillo).
//   2. Un rectángulo con una calle dentro (dos líneas paralelas cercanas que lo cruzan, con
//      una franja sin muro entre ellas: los marcos de dos viñetas apiladas y el fondo que
//      asoma) no es una viñeta sino dos; una línea suelta que cruza la viñeta (un horizonte)
//      no la parte. Entre los que se pisan gana el de mejor marco.
//   3. Lo que queda de la ilustración de fondo, si tiene tamaño de viñeta y dibujo, es otra
//      viñeta: el mayor rectángulo libre de cada trozo.
// Devuelve [] si no hay al menos dos marcos.
function detectInsets(L, W, H) {
  const n = W * H;
  const segs = [];
  const wall = blackWalls(L, W, H, segs, true);
  const dim = Math.min(W, H);
  const tol = Math.max(4, Math.round(dim * 0.012)); // tolerancia de un marco algo torcido
  const T = blackPaperLevel(L);
  const minW = Math.round(W * 0.1);
  const minH = Math.round(H * 0.08);

  // 1) Líneas: los tramos de filas (o columnas) vecinas que se solapan son la misma línea, de
  // varios píxeles de grosor; los tramos de una misma línea separados por un hueco corto (un
  // bocadillo que la tapa) también.
  const thick = Math.max(3, Math.round(dim * 0.006)); // grosor de un marco
  const lines = (horizontal) => {
    const out = [];
    for (const s of segs) {
      if (s.horizontal !== horizontal) continue;
      const m = out.find((t) => Math.abs(t.o - s.o) <= thick && s.from < t.to + thick && s.to > t.from - thick);
      if (m) {
        m.o = (m.o * m.n + s.o) / (m.n + 1);
        m.n++;
        m.from = Math.min(m.from, s.from);
        m.to = Math.max(m.to, s.to);
      } else out.push({ o: s.o, from: s.from, to: s.to, n: 1, edge: false });
    }
    // Dos tramos a la misma altura (± un grosor, que un marco largo escaneado algo torcido se
    // desplaza) que apenas se solapan y están a menos de un cuarto de página son la misma
    // línea con un hueco (un bocadillo que la tapa).
    const gap = Math.round((horizontal ? W : H) * 0.25);
    for (let changed = true; changed; ) {
      changed = false;
      for (let i = 0; i < out.length && !changed; i++)
        for (let j = i + 1; j < out.length; j++) {
          const a = out[i];
          const b = out[j];
          if (Math.abs(a.o - b.o) > 2 * thick) continue;
          const d = Math.max(a.from, b.from) - Math.min(a.to, b.to); // hueco (negativo: solape)
          if (d > gap || d < -2 * thick) continue;
          const la = a.to - a.from;
          const lb = b.to - b.from;
          a.o = (a.o * la + b.o * lb) / (la + lb);
          a.from = Math.min(a.from, b.from);
          a.to = Math.max(a.to, b.to);
          out.splice(j, 1);
          changed = true;
          break;
        }
    }
    return out;
  };
  const Hs = lines(true);
  const Vs = lines(false);
  if (Hs.length > 120 || Vs.length > 120) return []; // dibujo lleno de rayas: no es esto
  Hs.push({ o: 0, from: 0, to: W, edge: true }, { o: H - 1, from: 0, to: W, edge: true });
  Vs.push({ o: 0, from: 0, to: H, edge: true }, { o: W - 1, from: 0, to: H, edge: true });

  // Muro a ±tol de una recta: engordado en vertical (lados horizontales) y en horizontal.
  const fatV = new Uint8Array(n);
  const fatH = new Uint8Array(n);
  for (let p = 0; p < n; p++) {
    if (!wall[p]) continue;
    const x = p % W;
    const y = (p - x) / W;
    for (let d = -tol; d <= tol; d++) {
      if (y + d >= 0 && y + d < H) fatV[p + d * W] = 1;
      if (x + d >= 0 && x + d < W) fatH[p + d] = 1;
    }
  }
  // Cobertura de muro de un lado y, de lo que no cubre, cuánto es claro (un bocadillo que
  // tapa el marco es claro; una línea que flota dentro del dibujo tiene dibujo a continuación).
  // Se prueba con varias inclinaciones (hasta un 2 %) y vale la mejor: un marco escaneado
  // algo torcido se desplaza varios píxeles de un extremo al otro.
  const cover = (horizontal, o, from, to, want = null) => {
    const lim = (horizontal ? H : W) - 1;
    const mid = (from + to) / 2;
    let best = 0;
    let bestLit = 1;
    for (const k of INSET_SLOPES) {
      let hit = 0;
      let lit = 0;
      let m = 0;
      for (let i = from; i < to; i += 2, m++) {
        const oo = Math.max(0, Math.min(lim, Math.round(o + k * (i - mid))));
        const p = horizontal ? oo * W + i : i * W + oo;
        if (horizontal ? fatV[p] : fatH[p]) hit++;
        else if (L[p] >= T) lit++;
      }
      const c = m ? hit / m : 0;
      if (c > best) {
        best = c;
        bestLit = m > hit ? lit / (m - hit) : 1;
      }
    }
    if (want) want.lit = bestLit;
    return best;
  };
  const span = (a0, a1, b0, b1) => Math.min(a1, b1) - Math.max(a0, b0);

  // 2) Rectángulos: dos líneas horizontales y dos verticales que se cruzan.
  const found = [];
  for (const Tl of Hs)
    for (const B of Hs) {
      if (B.o - Tl.o < minH) continue;
      const lo = Math.min(Tl.from, B.from);
      const hi = Math.max(Tl.to, B.to);
      for (const Lv of Vs) {
        if (Lv.o < lo - tol || Lv.o > hi - minW || span(Lv.from, Lv.to, Tl.o, B.o) < 0.4 * (B.o - Tl.o)) continue;
        for (const Rv of Vs) {
          if (Rv.o - Lv.o < minW || Rv.o > hi + tol || span(Rv.from, Rv.to, Tl.o, B.o) < 0.4 * (B.o - Tl.o)) continue;
          if (span(Tl.from, Tl.to, Lv.o, Rv.o) < 0.4 * (Rv.o - Lv.o) || span(B.from, B.to, Lv.o, Rv.o) < 0.4 * (Rv.o - Lv.o)) continue;
          if ([Tl, B, Lv, Rv].filter((s) => !s.edge).length < 2) continue;
          const r = { x0: Math.round(Lv.o), y0: Math.round(Tl.o), x1: Math.round(Rv.o), y1: Math.round(B.o) };
          const lit = [{}, {}, {}, {}];
          const c = [
            Tl.edge ? 1 : cover(true, r.y0, r.x0, r.x1, lit[0]),
            B.edge ? 1 : cover(true, r.y1, r.x0, r.x1, lit[1]),
            Lv.edge ? 1 : cover(false, r.x0, r.y0, r.y1, lit[2]),
            Rv.edge ? 1 : cover(false, r.x1, r.y0, r.y1, lit[3]),
          ];
          // Cuentan los lados de muro: al menos dos buenos y como mucho uno flojo (el borde
          // de la página no dice nada).
          const sides = [Tl, B, Lv, Rv];
          const real = [0, 1, 2, 3].filter((i) => !sides[i].edge);
          const good = real.filter((i) => c[i] >= 0.8).length;
          if (good < 2 || real.length - good > 1 || Math.min(...c) < 0.4) continue;
          // El lado tapado a medias lo tapa algo claro (un bocadillo) o su línea llega al
          // menos a una esquina; una línea que flota dentro del dibujo, ni lo uno ni lo otro.
          const corner = (l, a0, a1) => l.from <= a0 + 2 * tol || l.to >= a1 - 2 * tol;
          const along = [r.x0, r.x0, r.y0, r.y0];
          const until = [r.x1, r.x1, r.y1, r.y1];
          if (c.some((v, i) => v < 0.8 && lit[i].lit < 0.7 && !corner(sides[i], along[i], until[i]))) continue;
          found.push({ ...r, good, score: real.reduce((t, i) => t + c[i], 0) / real.length });
        }
      }
    }
  found.sort((a, b) => b.good - a.good || b.score - a.score || area(b) - area(a));

  // 3) Un rectángulo con una calle dentro (dos líneas paralelas cercanas que lo cruzan, con
  // una franja sin muro entre ellas: los marcos de dos viñetas apiladas y el fondo que asoma)
  // no es una viñeta sino dos. Entre los que se pisan gana el de mejor marco.
  const clearBand = (horizontal, o, from, to) => {
    let hit = 0;
    let m = 0;
    for (let i = from; i < to; i += 2, m++) hit += horizontal ? wall[o * W + i] : wall[i * W + o];
    return !m || hit < 0.5 * m;
  };
  const maxGap = Math.round(dim * 0.03); // calle más ancha entre dos marcos
  const twin = (r) => {
    for (const horizontal of [true, false]) {
      const list = horizontal ? Hs : Vs;
      const a0 = horizontal ? r.y0 : r.x0;
      const a1 = horizontal ? r.y1 : r.x1;
      const b0 = horizontal ? r.x0 : r.y0;
      const b1 = horizontal ? r.x1 : r.y1;
      const across = (l) => !l.edge && span(l.from, l.to, b0, b1) >= 0.5 * (b1 - b0);
      for (const l1 of list) {
        if (l1.o <= a0 + tol || l1.o >= a1 - tol || !across(l1)) continue;
        // Una sola línea de muro casi de lado a lado (el marco de una viñeta encajada en el
        // fondo, sin hueco) también lo parte.
        if (
          span(l1.from, l1.to, b0, b1) >= 0.85 * (b1 - b0) &&
          cover(horizontal, Math.round(l1.o), b0, b1) >= 0.9 &&
          Math.min(l1.o - a0, a1 - l1.o) >= (horizontal ? minH : minW)
        ) {
          return true;
        }
        for (const l2 of list) {
          const d = Math.abs(l2.o - l1.o);
          if (l2 === l1 || d < 3 || d > maxGap || l2.o < a0 - tol || l2.o > a1 + tol || !across(l2)) continue;
          const from = Math.max(b0, l1.from, l2.from);
          const to = Math.min(b1, l1.to, l2.to);
          const mid = Math.round((l1.o + l2.o) / 2);
          // La franja sigue fuera del rectángulo al menos por un extremo (el fondo que
          // rodea las viñetas); una línea del dibujo junto al marco deja una franja cerrada
          // por los marcos perpendiculares.
          const open = (b) => {
            const bb = Math.max(0, Math.min((horizontal ? W : H) - 1, b));
            return !(horizontal ? fatH[mid * W + bb] : fatV[bb * W + mid]);
          };
          if (clearBand(horizontal, mid, from, to) && (open(b0) || open(b1))) {
            return true;
          }
        }
      }
    }
    return false;
  };
  const kept = [];
  for (const r of found) {
    if (twin(r)) continue;
    if (!kept.some((k) => overlap(k, r) >= 0.8 * Math.max(area(k), area(r)))) kept.push(r);
  }
  // Con dibujo dentro: bastante tinta y bastante textura (un margen negro o un papel vacío
  // tienen una cosa o la otra, no las dos).
  const drawn = (r) => {
    let ink = 0;
    let edges = 0;
    let m = 0;
    for (let y = r.y0; y < r.y1; y += 2)
      for (let x = r.x0; x < r.x1 - 2; x += 2, m++) {
        const p = y * W + x;
        if (L[p] < T) ink++;
        if (Math.abs(L[p] - L[p + 2]) > 16) edges++;
      }
    return ink >= 0.4 * m && edges >= 0.08 * m;
  };
  const insets = [];
  for (const r of kept) if (drawn(r) && !insets.some((k) => overlap(k, r) > 0.2 * Math.min(area(k), area(r)))) insets.push(r);
  if (insets.length < 2) return [];

  // 4) El fondo que queda: el mayor rectángulo libre de cada trozo grande con dibujo.
  const free = new Uint8Array(n).fill(1);
  for (const r of insets)
    for (let y = Math.max(0, r.y0 - tol); y < Math.min(H, r.y1 + tol); y++)
      free.fill(0, y * W + Math.max(0, r.x0 - tol), y * W + Math.min(W, r.x1 + tol));
  const { lab, comps } = blackComponents(free, W, H);
  const rest = [];
  for (const c of comps) {
    if (c.area < n * 0.08) continue;
    // Un trozo en L (la ilustración rodea las viñetas) da varios rectángulos: el mayor, y
    // luego el mayor de lo que queda.
    for (let k = 0; k < 4; k++) {
      const r = largestRect(lab, c.id, W, H);
      if (!r || r.x1 - r.x0 < minW || r.y1 - r.y0 < minH || area(r) < n * 0.06) break;
      if (drawn(r)) rest.push(r);
      for (let y = r.y0; y < r.y1; y++) lab.fill(0, y * W + r.x0, y * W + r.x1);
    }
  }
  return [...insets, ...rest].map(({ x0, y0, x1, y1 }) => ({ x0, y0, x1, y1 }));
}

// Mayor rectángulo formado solo por píxeles con la etiqueta `id` (histograma por filas y pila).
function largestRect(lab, id, W, H) {
  const height = new Int32Array(W);
  const stack = new Int32Array(W + 1);
  let best = null;
  let bestArea = 0;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) height[x] = lab[y * W + x] === id ? height[x] + 1 : 0;
    let top = 0;
    for (let x = 0; x <= W; x++) {
      const hx = x < W ? height[x] : 0;
      while (top > 0 && height[stack[top - 1]] >= hx) {
        const h = height[stack[--top]];
        const x0 = top > 0 ? stack[top - 1] + 1 : 0;
        const a = h * (x - x0);
        if (a > bestArea) {
          bestArea = a;
          best = { x0, y0: y - h + 1, x1: x, y1: y + 1 };
        }
      }
      stack[top++] = x;
    }
  }
  return best;
}

function detectBlack(L, W, H) {
  const n = W * H;
  const T = blackPaperLevel(L);
  const D = BLACK.ink;

  // 1. Muros.
  const wall = blackWalls(L, W, H);
  // Un píxel más de grosor, para que un muro escalonado no deje pasar el relleno.
  const block = wall.slice();
  for (let p = 0; p < n; p++) {
    if (!wall[p]) continue;
    const x = p % W;
    if (x > 0) block[p - 1] = 1;
    if (x < W - 1) block[p + 1] = 1;
    if (p >= W) block[p - W] = 1;
    if (p < n - W) block[p + W] = 1;
  }

  // 2. Papel: relleno desde el borde de la página.
  const out = new Uint8Array(n);
  const q = new Int32Array(n);
  let qh = 0;
  let qt = 0;
  const push = (p) => {
    if (!out[p] && L[p] >= T && !block[p]) (out[p] = 1), (q[qt++] = p);
  };
  for (let x = 0; x < W; x++) push(x), push((H - 1) * W + x);
  for (let y = 0; y < H; y++) push(y * W), push(y * W + W - 1);
  while (qh < qt) {
    const p = q[qh++];
    const x = p % W;
    if (x > 0) push(p - 1);
    if (x < W - 1) push(p + 1);
    if (p >= W) push(p - W);
    if (p < n - W) push(p + W);
  }
  // Calles encerradas (entre un dibujo a sangre y un marco): zonas claras estrechas y largas.
  const lightIn = new Uint8Array(n);
  for (let p = 0; p < n; p++) lightIn[p] = !out[p] && !block[p] && L[p] >= T ? 1 : 0;
  const dist = blackDistance(lightIn, W, H);
  const { lab: lLab, comps: lComps } = blackComponents(lightIn, W, H);
  const maxD = new Uint16Array(lComps.length + 1);
  for (let p = 0; p < n; p++) if (lLab[p] && dist[p] > maxD[lLab[p]]) maxD[lLab[p]] = dist[p];
  const strip = new Uint8Array(lComps.length + 1);
  let strips = 0;
  for (const c of lComps)
    if (maxD[c.id] <= BLACK.strip * W * 3 && Math.max(c.x1 - c.x0, c.y1 - c.y0) >= 0.06 * Math.max(W, H)) {
      strip[c.id] = 1;
      strips++;
    }
  if (strips) for (let p = 0; p < n; p++) if (strip[lLab[p]]) out[p] = 1;

  // 3. Lo encerrado: las viñetas (sin las zonas que son casi todo papel).
  const inside = new Uint8Array(n);
  for (let p = 0; p < n; p++) inside[p] = !out[p] && !block[p] ? 1 : 0;
  const { lab, comps } = blackComponents(inside, W, H);
  const lightCount = new Uint32Array(comps.length + 1);
  for (let p = 0; p < n; p++) if (lab[p] && L[p] >= T) lightCount[lab[p]]++;
  const sizeable = (c) => c.x1 - c.x0 >= W * 0.08 && c.y1 - c.y0 >= H * 0.05 && c.area >= n * 0.008;
  // Peso de cada píxel como separador: papel o muro 2, tinta oscura 1 (un marco entre dibujo
  // oscuro por los dos lados), el resto 0.
  const sep = new Uint8Array(n);
  for (let p = 0; p < n; p++) sep[p] = out[p] || block[p] ? 2 : L[p] < D ? 1 : 0;
  // Crestas: línea fina (hasta 3 píxeles) más oscura que lo que tiene a ambos lados, aunque no
  // sea negra (un marco fino queda gris al reducir); una para cortes horizontales (se mira
  // arriba y abajo) y otra para verticales, con un píxel de margen para no perderla al
  // redondear la recta.
  const ridgeH = new Uint8Array(n);
  const ridgeV = new Uint8Array(n);
  for (let y = 4; y < H - 4; y++)
    for (let x = 4; x < W - 4; x++) {
      const p = y * W + x;
      if (Math.min(L[p - W], L[p], L[p + W]) + BLACK.ridge < Math.min(L[p - 4 * W], L[p + 4 * W])) ridgeH[p] = 1;
      if (Math.min(L[p - 1], L[p], L[p + 1]) + BLACK.ridge < Math.min(L[p - 4], L[p + 4])) ridgeV[p] = 1;
    }
  const thickH = ridgeH.slice();
  const thickV = ridgeV.slice();
  for (let p = W; p < n - W; p++) {
    if (ridgeH[p - W] || ridgeH[p + W]) thickH[p] = 1;
    if (ridgeV[p - 1] || ridgeV[p + 1]) thickV[p] = 1;
  }
  const split = (pixels, depth) => {
    let x0 = W;
    let y0 = H;
    let x1 = 0;
    let y1 = 0;
    for (const p of pixels) {
      const x = p % W;
      const y = (p - x) / W;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
    const piece = { x0, y0, x1: x1 + 1, y1: y1 + 1, area: pixels.length };
    if (depth >= 6) return [piece];
    // La recta (horizontal o vertical, con algo de inclinación) que más separa; tiene que
    // pasar en parte por papel o por un muro: solo tinta oscura es dibujo oscuro. Si no hay
    // ninguna, la que sigue casi de lado a lado una línea (papel, muro, cresta o tinta) con
    // buena parte fina, si deja a cada lado un trozo de tamaño de viñeta.
    let best = null;
    for (const horizontal of [true, false]) {
      const A0 = horizontal ? piece.y0 : piece.x0;
      const A1 = horizontal ? piece.y1 : piece.x1;
      const B0 = horizontal ? piece.x0 : piece.y0;
      const B1 = horizontal ? piece.x1 : piece.y1;
      const lim = horizontal ? H : W;
      const mid = (B0 + B1) / 2;
      const minPart = horizontal ? H * 0.05 : W * 0.08;
      const minLine = horizontal ? H * BLACK.lineMinH : W * BLACK.lineMinW;
      const ridge = horizontal ? thickH : thickV;
      for (const k of BLACK_SLOPES) {
        for (let a = A0 + minPart; a < A1 - minPart; a += 2) {
          let hit = 0;
          let strong = 0;
          let line = 0; // papel, muro o cresta
          let any = 0; // además, tinta oscura
          let m = 0;
          for (let b = B0; b < B1; b += 2, m++) {
            const c = Math.round(a + k * (b - mid));
            if (c < 0 || c >= lim) continue;
            const p = horizontal ? c * W + b : b * W + c;
            const v = sep[p];
            hit += v;
            if (v === 2) strong++;
            if (v === 2 || ridge[p]) line++;
            if (v || ridge[p]) any++;
          }
          const frac = hit / (2 * m);
          const normal = frac >= BLACK.cut && strong >= BLACK.strong * m;
          const thin =
            !normal &&
            any >= BLACK.lineAny * m &&
            line >= BLACK.lineThin * m &&
            a - A0 >= minLine &&
            A1 - a >= minLine;
          const score = frac + (any + line) / (4 * m);
          if (normal && (!best || !best.normal || frac > best.frac)) best = { horizontal, k, a, mid, frac, normal };
          else if (thin && (!best || (!best.normal && score > best.score)))
            best = { horizontal, k, a, mid, frac, score, normal: false };
        }
      }
    }
    if (!best) return [piece];
    const A = [];
    const B = [];
    for (const p of pixels) {
      const x = p % W;
      const y = (p - x) / W;
      const s = best.horizontal ? y - (best.a + best.k * (x - best.mid)) : x - (best.a + best.k * (y - best.mid));
      (s < 0 ? A : B).push(p);
    }
    if (A.length < n * 0.008 || B.length < n * 0.008) return [piece];
    return [...split(A, depth + 1), ...split(B, depth + 1)];
  };
  const pixelsOf = new Map(
    comps.filter((c) => sizeable(c) && lightCount[c.id] < 0.85 * c.area).map((c) => [c.id, []]),
  );
  for (let p = 0; p < n; p++) pixelsOf.get(lab[p])?.push(p);
  let found = [];
  for (const list of pixelsOf.values()) found.push(...split(list, 0));
  found = found.filter(sizeable);
  // Trozos de una misma viñeta (una zona clara que toca el borde la parte): sus recuadros se
  // solapan mucho; los de viñetas distintas, poco.
  for (let changed = true; changed; ) {
    changed = false;
    outer: for (let i = 0; i < found.length; i++)
      for (let j = i + 1; j < found.length; j++) {
        const a = found[i];
        const b = found[j];
        const ow = Math.min(a.x1, b.x1) - Math.max(a.x0, b.x0);
        const oh = Math.min(a.y1, b.y1) - Math.max(a.y0, b.y0);
        if (ow <= 0 || oh <= 0) continue;
        if (ow * oh < BLACK.merge * Math.min(area(a), area(b))) continue;
        found[i] = {
          x0: Math.min(a.x0, b.x0),
          y0: Math.min(a.y0, b.y0),
          x1: Math.max(a.x1, b.x1),
          y1: Math.max(a.y1, b.y1),
          area: a.area + b.area,
        };
        found.splice(j, 1);
        changed = true;
        break outer;
      }
  }
  return found.map(({ x0, y0, x1, y1 }) => ({ x0, y0, x1, y1 }));
}

// ---------- estilo «márgenes claros» ----------

function detectClean(data, w, h, rtl) {
  const border = estimateBackground(data, w, h);
  // Si el borde de la página es mayoritariamente de un color, ese es el fondo.
  // Si no (páginas a sangre), probamos con los fondos típicos: blanco y negro.
  const candidates =
    border.ratio >= 0.5
      ? [border.color]
      : [
          [255, 255, 255],
          [0, 0, 0],
        ];
  let best = null;
  for (const bg of candidates) {
    const r = segment(data, w, h, bg, rtl);
    if (!best || r.rects.length > best.rects.length) best = r;
  }
  best.style = "clean";
  return best;
}

// Crea la máscara para un color de fondo y la trocea en viñetas.
function segment(data, w, h, bg, rtl) {
  const mask = removeSpecks(buildMask(data, w, h, bg), w, h);
  const c = {
    mask,
    w,
    h,
    rtl,
    minGapX: Math.max(2, Math.round(w * 0.0035)),
    minGapY: Math.max(2, Math.round(h * 0.0035)),
  };
  const out = { rects: [], text: false, bbox: null };

  let inkPixels = 0;
  for (let i = 0; i < mask.length; i++) inkPixels += mask[i];
  const ink = inkPixels / (w * h);
  if (ink < 0.01) {
    out.text = true; // página en blanco o casi
    return out;
  }

  // Página de texto corrido: muchas franjas finas y parecidas (las líneas).
  const { rows, cols } = profiles(c, 0, 0, w, h);
  const ry = span(rows, noiseLevel(w));
  const rx = span(cols, noiseLevel(h));
  if (ry && rx) out.bbox = { x0: rx[0], y0: ry[0], x1: rx[1], y1: ry[1] };
  const pageBands = runs(rows, noiseLevel(w), 1);
  if (pageBands.length >= 6 && looksLikeLines(pageBands, h)) out.text = true;

  const leaves = [];
  xyCut(c, 0, 0, w, h, 0, leaves);

  const pageArea = w * h;
  const rects = [];
  let textArea = 0;
  for (const r of leaves) {
    if (looksLikeText(c, r)) {
      // Los bloques de texto no cuentan como viñetas; si ocupan buena parte de la
      // página, es una página de texto (un pie o un rótulo sueltos no la convierten).
      textArea += area(r);
      continue;
    }
    if (area(r) >= pageArea * 0.08) {
      const parts = splitByComponents(c, r);
      if (parts) {
        rects.push(...parts);
        continue;
      }
    }
    rects.push(r);
  }

  if (textArea >= pageArea * 0.2) out.text = true;
  out.rects = rects.filter(isPanelSized(w, h));
  // Poca tinta y sin viñetas claras: créditos, dedicatoria, logotipo…
  if (ink < 0.04 && out.rects.length < 2) out.text = true;
  // Página de texto: la tinta está casi toda en manchas pequeñas (letras).
  if (!out.text && ink < 0.3 && looksLikeGlyphs(mask, w, h, inkPixels))
    out.text = true;
  return out;
}

// Etiqueta las manchas de tinta y mide cuánta tinta está en manchas del tamaño de una
// letra (alto ≤ 2,5 % de la página). Una página de texto tiene cientos de ellas y casi
// toda su tinta es así; en una página de cómic la tinta está en manchas grandes.
function looksLikeGlyphs(mask, w, h, inkPixels) {
  const maxGlyph = Math.max(4, Math.round(h * 0.025));
  const labels = new Uint8Array(w * h);
  const stack = new Int32Array(w * h);
  let small = 0;
  let smallInk = 0;
  for (let p0 = 0; p0 < mask.length; p0++) {
    if (labels[p0] || !mask[p0]) continue;
    let sp = 0;
    stack[sp++] = p0;
    labels[p0] = 1;
    let n = 0;
    let y0 = h;
    let y1 = 0;
    let x0 = w;
    let x1 = 0;
    while (sp) {
      const cur = stack[--sp];
      const cx = cur % w;
      const cy = (cur / w) | 0;
      n++;
      if (cy < y0) y0 = cy;
      if (cy > y1) y1 = cy;
      if (cx < x0) x0 = cx;
      if (cx > x1) x1 = cx;
      if (cx > 0 && mask[cur - 1] && !labels[cur - 1]) {
        labels[cur - 1] = 1;
        stack[sp++] = cur - 1;
      }
      if (cx < w - 1 && mask[cur + 1] && !labels[cur + 1]) {
        labels[cur + 1] = 1;
        stack[sp++] = cur + 1;
      }
      if (cy > 0 && mask[cur - w] && !labels[cur - w]) {
        labels[cur - w] = 1;
        stack[sp++] = cur - w;
      }
      if (cy < h - 1 && mask[cur + w] && !labels[cur + w]) {
        labels[cur + w] = 1;
        stack[sp++] = cur + w;
      }
    }
    // letra suelta o línea de texto (las letras se tocan al reducir la página)
    if (y1 - y0 < maxGlyph && x1 - x0 < w * 0.4) {
      small++;
      smallInk += n;
    }
  }
  return small >= 60 && smallInk >= inkPixels * 0.55;
}

// Fuera números de página, motas y rayas sueltas.
const isPanelSized = (w, h) => (r) =>
  area(r) >= w * h * 0.012 &&
  r.x1 - r.x0 >= w * 0.06 &&
  r.y1 - r.y0 >= h * 0.04;

// ---------- estilo «calles oscuras» ----------
//
// Página de fondo negro: las viñetas son dibujo claro (a menudo rayado en blanco) sobre
// negro, sin marco, y las calles son el propio fondo. Entre las viñetas flotan rótulos
// (cajas blancas de texto) y motas o esquirlas dibujadas que impiden cortar por filas
// vacías. El método:
//   1) marca como dibujo todo lo que no es casi negro;
//   2) etiqueta las manchas conexas (sobre la máscara dilatada, para que los trazos de un
//      rayado se toquen) y aparta las bajas (rótulos, motas, líneas de texto);
//   3) corta por filas y columnas sin dibujo (XY-cut) lo que queda: las viñetas;
//   4) devuelve cada mancha apartada a la viñeta más cercana, ampliándola, salvo que
//      con ello invadiera otra viñeta.

export function darkFraction(data) {
  let k = 0;
  for (let i = 0; i < data.length; i += 4)
    if (0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2] < 50) k++;
  return k / (data.length / 4);
}

export function detectDark(data, w, h, rtl, debug = null, frames = [], hiLuma = null) {
  const n = w * h;
  const mask = new Uint8Array(n);
  for (let p = 0, i = 0; p < n; p++, i += 4)
    if (0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2] >= DARK_INK) mask[p] = 1;
  const out = { rects: [], text: false, bbox: null, style: "dark" };

  // Manchas conexas sobre la máscara dilatada dos veces (los trazos de un rayado se
  // unen); las bajas y no muy anchas son rótulos, motas o esquirlas: se apartan.
  const grown = dilate(dilate(mask, w, h), w, h);
  const labels = new Int32Array(n);
  const stack = new Int32Array(n);
  const maxSmallH = Math.max(4, Math.round(h * 0.045)); // hasta un rótulo de cuatro líneas
  const small = [];
  let id = 0;
  let biggest = 0;
  for (let p0 = 0; p0 < n; p0++) {
    if (labels[p0] || !grown[p0]) continue;
    id++;
    let sp = 0;
    stack[sp++] = p0;
    labels[p0] = id;
    let x0 = w, x1 = 0, y0 = h, y1 = 0;
    let px = 0;
    while (sp) {
      const cur = stack[--sp];
      const cx = cur % w;
      const cy = (cur / w) | 0;
      px++;
      if (cx < x0) x0 = cx;
      if (cx > x1) x1 = cx;
      if (cy < y0) y0 = cy;
      if (cy > y1) y1 = cy;
      if (cx > 0 && grown[cur - 1] && !labels[cur - 1]) { labels[cur - 1] = id; stack[sp++] = cur - 1; }
      if (cx < w - 1 && grown[cur + 1] && !labels[cur + 1]) { labels[cur + 1] = id; stack[sp++] = cur + 1; }
      if (cy > 0 && grown[cur - w] && !labels[cur - w]) { labels[cur - w] = id; stack[sp++] = cur - w; }
      if (cy < h - 1 && grown[cur + w] && !labels[cur + w]) { labels[cur + w] = id; stack[sp++] = cur + w; }
    }
    if (px > biggest) biggest = px;
    const bw = x1 - x0 + 1;
    const bh = y1 - y0 + 1;
    // Rótulo (bajo y no muy ancho) o esquirla/mota (caja pequeña): se aparta.
    if ((bh <= maxSmallH && bw <= w * 0.5) || (bw * bh <= n * 0.008 && bh <= h * 0.12))
      small.push({ id, x0, y0, x1: x1 + 1, y1: y1 + 1 });
  }
  // Una sola mancha con más de la mitad de la página es una ilustración, no viñetas: los
  // valles que tenga por dentro no son calles.
  if (biggest >= n * 0.6) return out;
  const isSmall = new Uint8Array(id + 1);
  for (const s of small) isSmall[s.id] = 1;
  const art = new Uint8Array(n);
  let ink = 0;
  for (let p = 0; p < n; p++) if (mask[p] && !isSmall[labels[p]]) { art[p] = 1; ink++; }
  if (ink < n * 0.02) return out;

  const c = {
    mask: art,
    labels,
    w,
    h,
    rtl,
    minGapX: Math.max(2, Math.round(w * 0.004)),
    minGapY: Math.max(2, Math.round(h * 0.004)),
    cleanCuts: 0,
  };
  const { rows, cols } = profiles(c, 0, 0, w, h);
  const ry = span(rows, noiseLevel(w));
  const rx = span(cols, noiseLevel(h));
  if (ry && rx) out.bbox = { x0: rx[0], y0: ry[0], x1: rx[1], y1: ry[1] };
  const leaves = [];
  valleyCut(c, 0, 0, w, h, 0, leaves);
  // Viñetas encajadas (con marco) sobre un fondo dibujado: el corte no las separa del
  // fondo, pero el método de marcos sobre el negativo las ve. Se sacan de su hoja y el
  // resto de la hoja se vuelve a cortar sin ellas.
  const sized = isPanelSized(w, h);
  // Un marco del negativo solo vale si es una viñeta encajada de verdad: tamaño de
  // viñeta y fondo negro pegado a al menos dos de sus lados (las tiras de lluvia de un
  // dibujo rayado también forman rectángulos, pero rodeados de dibujo).
  const candidates = frames.filter((f) => sized(f) && f.x1 - f.x0 >= w * 0.1 && f.y1 - f.y0 >= h * 0.08);
  const inOther = (f, x, y) => candidates.some((g) => g !== f && x >= g.x0 && x < g.x1 && y >= g.y0 && y < g.y1);
  const ringFree = (f, side) => {
    let n0 = 0;
    let free = 0;
    for (let d = 2; d <= 4; d++) {
      if (side === "top" || side === "bottom") {
        const y = side === "top" ? f.y0 - d : f.y1 - 1 + d;
        if (y < 0 || y >= h) return true; // borde de la página
        for (let x = Math.max(0, f.x0); x < Math.min(w, f.x1); x++) {
          n0++;
          if (!art[y * w + x] || inOther(f, x, y)) free++; // fondo o la viñeta vecina
        }
      } else {
        const x = side === "left" ? f.x0 - d : f.x1 - 1 + d;
        if (x < 0 || x >= w) return true;
        for (let y = Math.max(0, f.y0); y < Math.min(h, f.y1); y++) {
          n0++;
          if (!art[y * w + x] || inOther(f, x, y)) free++;
        }
      }
    }
    return free >= n0 * 0.7;
  };
  const goodFrames = candidates.filter(
    (f) => ["top", "bottom", "left", "right"].filter((s) => ringFree(f, s)).length >= 2,
  );
  const pieces = [];
  for (const L of leaves) {
    const inner = goodFrames.filter((f) => overlap(f, L) >= area(f) * 0.9);
    const innerArea = inner.reduce((s, f) => s + area(f), 0);
    // Marcos que se pisan entre sí no son viñetas encajadas (son trozos de un rayado), y
    // uno solo tampoco suele serlo.
    const tangled = inner.some((f, i) => inner.some((g, j) => j > i && overlap(f, g) > Math.min(area(f), area(g)) * 0.02));
    if (inner.length < 2 || tangled || innerArea > area(L) * 0.9) {
      pieces.push(L);
      continue;
    }
    const erased = { ...c, mask: art.slice() };
    for (const f of inner)
      for (let y = Math.max(0, f.y0); y < Math.min(h, f.y1); y++)
        erased.mask.fill(0, y * w + Math.max(0, f.x0), y * w + Math.min(w, f.x1));
    const rest = [];
    valleyCut(erased, L.x0, L.y0, L.x1, L.y1, 0, rest);
    // El resto que aún abarca las viñetas encajadas es el fondo que asoma a sus lados:
    // se queda con el mayor trozo libre de ellas (encima, debajo, a la izquierda o a la
    // derecha del bloque que forman).
    const box = inner.reduce(
      (b, f) => ({ x0: Math.min(b.x0, f.x0), y0: Math.min(b.y0, f.y0), x1: Math.max(b.x1, f.x1), y1: Math.max(b.y1, f.y1) }),
      { x0: w, y0: h, x1: 0, y1: 0 },
    );
    for (const R of rest) {
      if (!overlap(R, box)) {
        pieces.push(R);
        continue;
      }
      const options = [
        { ...R, y1: Math.min(R.y1, box.y0) },
        { ...R, y0: Math.max(R.y0, box.y1) },
        { ...R, x1: Math.min(R.x1, box.x0) },
        { ...R, x0: Math.max(R.x0, box.x1) },
      ].filter((q) => q.x1 > q.x0 && q.y1 > q.y0 && sized(q));
      if (options.length) pieces.push(options.sort((a, b) => area(b) - area(a))[0]);
    }
    pieces.push(...inner.map((f) => ({ x0: f.x0, y0: f.y0, x1: f.x1, y1: f.y1 })));
    c.cleanCuts++;
  }
  // Viñetas encajadas sin marco reconocible (o que el método de marcos no ve): entre
  // ellas quedan huecos negros que arrancan en un borde de la hoja y llegan todos a la
  // misma altura, la del fondo dibujado que las cubre. Se corta ahí y luego por los huecos.
  const anchored = [];
  if (debug) c.log = debug.log = [];
  for (const L of pieces) {
    if (area(L) < n * 0.2) {
      anchored.push(L);
      continue;
    }
    const split = insetRow(art, w, h, L, c, hiLuma);
    if (split) c.cleanCuts++;
    anchored.push(...(split || [L]));
  }
  // En una página negra no hay viñetas muy estrechas: los restos finos (el fondo que
  // asoma por un lado) se descartan. Y si una viñeta es casi toda la página, es una
  // ilustración: se muestra entera.
  let rects = anchored.filter((r) => sized(r) && r.x1 - r.x0 >= w * 0.1 && r.y1 - r.y0 >= h * 0.06);
  // Un trozo estrecho pegado a una viñeta por un lado largo (el fondo de una splash que
  // asoma junto a las viñetas encajadas) se funde con ella si la unión no pisa a otra.
  if (debug) debug.beforeMerge = rects.map((r) => ({ ...r }));
  const slim = (r) => r.x1 - r.x0 < w * 0.16 || r.y1 - r.y0 < h * 0.1;
  const touch = Math.round(Math.min(w, h) * 0.05);
  for (let changed = true; changed; ) {
    changed = false;
    for (const r of rects.filter(slim)) {
      for (const o of rects) {
        if (o === r) continue;
        const sx = Math.min(r.x1, o.x1) - Math.max(r.x0, o.x0);
        const sy = Math.min(r.y1, o.y1) - Math.max(r.y0, o.y0);
        const beside = sy >= (r.y1 - r.y0) * 0.6 && (Math.abs(r.x1 - o.x0) <= touch || Math.abs(o.x1 - r.x0) <= touch);
        const stacked = sx >= (r.x1 - r.x0) * 0.6 && (Math.abs(r.y1 - o.y0) <= touch || Math.abs(o.y1 - r.y0) <= touch);
        if (!beside && !stacked) continue;
        const u = { x0: Math.min(r.x0, o.x0), y0: Math.min(r.y0, o.y0), x1: Math.max(r.x1, o.x1), y1: Math.max(r.y1, o.y1) };
        if (rects.some((q) => q !== r && q !== o && overlap(u, q) > area(q) * 0.02)) continue;
        Object.assign(o, u);
        rects = rects.filter((q) => q !== r);
        changed = true;
        break;
      }
      if (changed) break;
    }
  }
  // Una ilustración a página completa también tiene surcos oscuros entre sus zonas
  // claras: si ninguna separación es una calle limpia (ni un grupo de viñetas encajadas
  // ni una fila anclada), la página se muestra entera.
  if (rects.some((r) => area(r) >= n * 0.85) || !c.cleanCuts) rects = [];
  if (debug) Object.assign(debug, { mask, art, small, leaves: leaves.map((r) => ({ ...r })), frames, goodFrames, pieces, ink: ink / n });
  if (rects.length < 2) {
    out.rects = rects;
    return out;
  }

  // Los rótulos y motas vuelven a la viñeta más cercana (a menos de un 6 % de la página),
  // que crece para incluirlos si no pisa a otra.
  const reach = Math.round(Math.min(w, h) * 0.06);
  const dist = (a, b) =>
    Math.max(0, b.x0 - a.x1, a.x0 - b.x1) + Math.max(0, b.y0 - a.y1, a.y0 - b.y1);
  for (const s of small.sort((a, b) => area(b) - area(a))) {
    let best = null;
    let bd = Infinity;
    for (const r of rects) {
      const d = dist(r, s);
      if (d < bd) { bd = d; best = r; }
    }
    if (!best || bd > reach) continue;
    const grownRect = {
      x0: Math.min(best.x0, s.x0),
      y0: Math.min(best.y0, s.y0),
      x1: Math.max(best.x1, s.x1),
      y1: Math.max(best.y1, s.y1),
    };
    if (rects.some((o) => o !== best && overlap(grownRect, o))) continue;
    Object.assign(best, grownRect);
  }
  out.rects = rects;
  return out;
}

// Bandas con dibujo de un perfil (tinta por fila o columna) separadas por calles
// oscuras. Una calle es un tramo de al menos `minGap` líneas casi vacías (≤ DARK_CUT_LOW:
// solo esquirlas o una punta de dedo la cruzan) o un valle de al menos dos líneas con
// poca tinta (≤ DARK_CUT_HIGH) y bastante menos que lo que hay a ambos lados, porque dos
// viñetas que se tocan solo dejan un surco. En un valle se corta por la línea de menos
// tinta.
function darkBands(p, len, minGap, valid = null, onClean = null) {
  const n = p.length;
  const low = Math.max(noiseLevel(len), Math.floor(len * DARK_CUT_LOW));
  const high = Math.floor(len * DARK_CUT_HIGH);
  const win = Math.max(12, Math.round(n * 0.06));
  const median = (a, b) => {
    const arr = [];
    for (let i = Math.max(0, a); i < Math.min(n, b); i++) arr.push(p[i]);
    if (!arr.length) return 0;
    arr.sort((x, y) => x - y);
    return arr[arr.length >> 1];
  };
  const cuts = []; // [a, b): líneas de calle
  let i = 0;
  while (i < n) {
    if (p[i] > high) {
      i++;
      continue;
    }
    let j = i;
    while (j < n && p[j] <= high) j++;
    // Dentro del tramo ≤ high, ¿hay una calle limpia?
    let a = -1;
    let found = false;
    for (let k = i; k <= j; k++) {
      const ok = k < j && p[k] <= low;
      if (ok && a < 0) a = k;
      if (!ok && a >= 0) {
        if (k - a >= minGap) {
          cuts.push([a, k]);
          found = true;
          onClean?.();
        }
        a = -1;
      }
    }
    if (!found && j - i >= 2 && i > 0 && j < n) {
      let mn = Infinity;
      let at = i;
      for (let k = i; k < j; k++) {
        if (p[k] < mn) {
          mn = p[k];
          at = k;
        }
      }
      const sides = Math.min(median(i - win, i), median(j, j + win));
      // Solo un valle profundo entre dos zonas bien dibujadas: dentro de una ilustración
      // también hay surcos, pero poco marcados.
      if (mn <= sides * 0.5 && sides >= len * 0.25 && (!valid || valid(at))) cuts.push([at, at + 1]);
    }
    i = j;
  }
  // Bandas con contenido entre calles, recortadas a sus líneas con tinta.
  const bands = [];
  let s = 0;
  for (const [a, b] of cuts) {
    if (a > s) bands.push([s, a]);
    s = b;
  }
  if (s < n) bands.push([s, n]);
  const noise = noiseLevel(len);
  return bands
    .map(([a, b]) => {
      while (a < b && p[a] <= noise) a++;
      while (b > a && p[b - 1] <= noise) b--;
      return [a, b];
    })
    .filter(([a, b]) => b > a);
}

// Fila de viñetas encajadas en una hoja: huecos negros verticales que arrancan en el
// borde inferior (o superior) de la hoja y suben todos hasta la misma altura. Devuelve
// las piezas (la parte de arriba y las viñetas de la fila) o null si no hay tal fila.
function insetRow(art, w, h, L, c, hiLuma = null) {
  const width = L.x1 - L.x0;
  const height = L.y1 - L.y0;
  const minRun = Math.round(h * 0.1);
  const tol = Math.round(h * 0.03);
  // Los huecos entre viñetas encajadas son de pocos píxeles: si hay luminancia a doble
  // resolución, el recorrido se mide en ella (un píxel de 2× es dibujo si es claro y su
  // píxel de 1× no se apartó como mota o rótulo).
  const s = hiLuma && hiLuma.length === 4 * w * h ? 2 : 1;
  const W = s * w;
  const isArt = (x, y) => (s === 1 ? art[y * w + x] : hiLuma[y * W + x] >= DARK_INK && art[(y >> 1) * w + (x >> 1)]);
  for (const fromBottom of [true, false]) {
    // Recorrido negro de cada columna desde el borde elegido (se toleran motas sueltas:
    // dos filas con dibujo seguidas cortan el recorrido).
    const run = new Int32Array(width);
    for (let x = L.x0; x < L.x1; x++) {
      let best = 0;
      for (let sx = s * x; sx < s * x + s; sx++) {
        let k = 0;
        let hits = 0;
        for (let i = 0; i < s * height; i++) {
          const y = fromBottom ? s * L.y1 - 1 - i : s * L.y0 + i;
          if (isArt(sx, y)) {
            if (++hits >= s + 1) break;
          } else hits = 0;
          k = i + 1;
        }
        best = Math.max(best, Math.floor(k / s));
      }
      run[x - L.x0] = best;
    }
    // Huecos: tramos de columnas contiguas con recorrido largo (pero no toda la hoja).
    const gaps = [];
    let a = -1;
    for (let i = 0; i <= width; i++) {
      const ok = i < width && run[i] >= minRun && run[i] < height - Math.round(h * 0.04);
      if (ok && a < 0) a = i;
      if (!ok && a >= 0) {
        if (i - a >= c.minGapX) {
          const rs = Array.from(run.subarray(a, i)).sort((p, q) => p - q);
          gaps.push({ a, b: i, run: rs[rs.length >> 1] });
        }
        a = -1;
      }
    }
    c.log?.push(`hoja (${L.x0},${L.y0})-(${L.x1},${L.y1}) ${fromBottom ? "abajo" : "arriba"}: huecos ${gaps.map((g) => `x${L.x0 + g.a}-${L.x0 + g.b} run ${g.run}`).join(" ") || "-"}`);
    if (gaps.length < 2) continue;
    // Todos a la misma altura (la mediana), o al menos dos de ellos.
    const runs = gaps.map((g) => g.run).sort((p, q) => p - q);
    const depth = runs[runs.length >> 1];
    const same = gaps.filter((g) => Math.abs(g.run - depth) <= tol);
    if (same.length < 2) continue;
    const cutY = fromBottom ? L.y1 - depth : L.y0 + depth;
    const top = fromBottom ? { x0: L.x0, y0: L.y0, x1: L.x1, y1: cutY } : { x0: L.x0, y0: cutY, x1: L.x1, y1: L.y1 };
    const rowY0 = fromBottom ? cutY : L.y0;
    const rowY1 = fromBottom ? L.y1 : cutY;
    // La fila se parte por los huecos; cada trozo se ajusta a su dibujo.
    const bounds = [L.x0, ...same.flatMap((g) => [L.x0 + g.a, L.x0 + g.b]), L.x1];
    const cells = [];
    for (let i = 0; i < bounds.length; i += 2) {
      const cell = shrink(art, w, { x0: bounds[i], y0: rowY0, x1: bounds[i + 1], y1: rowY1 });
      if (cell) cells.push(cell);
    }
    const sized = isPanelSized(w, h);
    if (cells.filter(sized).length < 1 || !sized(top)) continue;
    return [shrink(art, w, top) || top, ...cells];
  }
  return null;
}

// Rectángulo ajustado al dibujo que contiene (null si no hay).
function shrink(art, w, r) {
  let x0 = r.x1;
  let x1 = r.x0;
  let y0 = r.y1;
  let y1 = r.y0;
  for (let y = r.y0; y < r.y1; y++)
    for (let x = r.x0; x < r.x1; x++)
      if (art[y * w + x]) {
        if (x < x0) x0 = x;
        if (x >= x1) x1 = x + 1;
        if (y < y0) y0 = y;
        if (y >= y1) y1 = y + 1;
      }
  return x1 > x0 && y1 > y0 ? { x0, y0, x1, y1 } : null;
}

// ¿La línea (fila `line` si horizontal, columna si no) parte alguna mancha de dibujo con al
// menos un cuarto de sus píxeles a cada lado dentro del rectángulo?
function splitsBlob(c, horizontal, line, x0, y0, x1, y1) {
  const { labels, w, h } = c;
  if (!labels) return false;
  const touching = new Set();
  for (let d = -2; d <= 2; d++) {
    if (horizontal) {
      const y = line + d;
      if (y < y0 || y >= y1) continue;
      for (let x = x0; x < x1; x++) if (labels[y * w + x]) touching.add(labels[y * w + x]);
    } else {
      const x = line + d;
      if (x < x0 || x >= x1) continue;
      for (let y = y0; y < y1; y++) if (labels[y * w + x]) touching.add(labels[y * w + x]);
    }
  }
  if (!touching.size) return false;
  const before = new Map();
  const after = new Map();
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const l = labels[y * w + x];
      if (!l || !touching.has(l)) continue;
      const side = (horizontal ? y : x) < line ? before : after;
      side.set(l, (side.get(l) || 0) + 1);
    }
  }
  for (const l of touching) {
    const a = before.get(l) || 0;
    const b = after.get(l) || 0;
    if (a + b >= w * h * 0.01 && Math.min(a, b) >= (a + b) * 0.25) return true;
  }
  return false;
}

// XY-cut para páginas oscuras: filas y luego columnas, con las calles de `darkBands`.
function valleyCut(c, x0, y0, x1, y1, depth, out) {
  const { rows, cols } = profiles(c, x0, y0, x1, y1);
  const ry = span(rows, noiseLevel(x1 - x0));
  const rx = span(cols, noiseLevel(y1 - y0));
  if (!ry || !rx) return;
  const nx0 = x0 + rx[0];
  const nx1 = x0 + rx[1];
  const ny0 = y0 + ry[0];
  const ny1 = y0 + ry[1];
  if (depth < 12) {
    // Un valle que parte una misma mancha de dibujo (una banda oscura dentro de una
    // viñeta) no es una calle: solo valen los valles entre manchas distintas.
    const clean = () => c.cleanCuts++;
    const bands = darkBands(rows.subarray(ry[0], ry[1]), x1 - x0, c.minGapY, (at) => !splitsBlob(c, true, ny0 + at, nx0, ny0, nx1, ny1), clean);
    if (bands.length > 1) {
      for (const [a, b] of bands) valleyCut(c, nx0, ny0 + a, nx1, ny0 + b, depth + 1, out);
      return;
    }
    const strips = darkBands(cols.subarray(rx[0], rx[1]), y1 - y0, c.minGapX, (at) => !splitsBlob(c, false, nx0 + at, nx0, ny0, nx1, ny1), clean);
    if (strips.length > 1) {
      if (c.rtl) strips.reverse();
      for (const [a, b] of strips) valleyCut(c, nx0 + a, ny0, nx0 + b, ny1, depth + 1, out);
      return;
    }
  }
  out.push({ x0: nx0, y0: ny0, x1: nx1, y1: ny1 });
}

// ---------- estilo «arte a sangre» ----------
//
// En estas páginas las calles no atraviesan la página de lado a lado (las filas van
// desplazadas unas respecto a otras) y dentro de las viñetas hay zonas claras que se
// funden con las calles, así que no vale cortar por filas sin tinta ni buscar manchas
// oscuras. Lo que sí define cada viñeta es su contorno: un borde recto y largo donde el
// dibujo termina y empieza el papel. El método:
//   1) localiza esos bordes rectos (horizontales y verticales) y los prolonga hasta el
//      borde vecino o el borde del dibujo, para cerrar esquinas y lados que dan a una
//      zona clara;
//   2) funde los bordes alineados en segmentos largos;
//   3) trocea la página como una guillotina: un segmento que atraviesa (casi) todo un
//      rectángulo lo parte en dos; se repite dentro de cada mitad. Así las filas
//      desplazadas se resuelven dentro de su propia mitad;
//   4) cada rectángulo final se ajusta al dibujo que contiene.
//
// Devuelve además `gutter`, el grosor típico de las calles relativo a la página, que
// sirve para decidir el estilo de la página.

// Con luminancia a doble resolución (`hi`) la máscara de papel se construye por mayoría
// en bloques 2×2: una calle de 2 subpíxeles de ancho sobrevive a la reducción, mientras que
// la trama de puntos de una zona gris (huecos blancos dispersos) no llega a papel.
function detectDense(data, w, h, rtl, bbox, debug = null, hi = null, strict = false) {
  const n = w * h;
  const paper = new Uint8Array(n);
  let level;
  if (hi && hi.length === 4 * n) {
    level = paperLevel(hi);
    const W = 2 * w;
    for (let y = 0; y < h; y++) {
      const a = 2 * y * W;
      const b = a + W;
      for (let x = 0; x < w; x++) {
        const i = a + 2 * x;
        const j = b + 2 * x;
        const c =
          (hi[i] >= level) +
          (hi[i + 1] >= level) +
          (hi[j] >= level) +
          (hi[j + 1] >= level);
        if (c >= 2) paper[y * w + x] = 1;
      }
    }
  } else {
    const luma = new Uint8Array(n);
    const ref = paperRef(data, w, h);
    for (let p = 0, i = 0; p < n; p++, i += 4)
      luma[p] = paperLuma(data[i], data[i + 1], data[i + 2], ref);
    level = paperLevel(luma);
    for (let p = 0; p < n; p++) if (luma[p] >= level) paper[p] = 1;
  }
  return detectDenseAt(paper, level, w, h, rtl, bbox, debug, strict);
}

function detectDenseAt(paper, level, w, h, rtl, bbox, debug = null, strict = false) {
  const t0 = debug ? performance.now() : 0;
  const times = [];
  const lap = (name) =>
    debug && times.push(`${name} ${Math.round(performance.now() - t0)}`);
  const n = w * h;

  const start = bbox || { x0: 0, y0: 0, x1: w, y1: h };
  const dim = Math.min(w, h);
  const maxGap = Math.max(3, Math.round(dim * 0.04));

  // 1) bordes rectos, prolongados
  const walls = new Uint8Array(n);
  const gaps = [];
  const segs = [];
  straightEdges(
    paper,
    w,
    h,
    true,
    Math.round(w * 0.1),
    maxGap,
    walls,
    gaps,
    segs,
  );
  straightEdges(
    paper,
    w,
    h,
    false,
    Math.round(h * 0.1),
    maxGap,
    walls,
    gaps,
    segs,
  );
  lap("bordes");
  if (debug) debug.rawSegs = segs.map((q) => ({ ...q }));
  extendWalls(
    segs,
    walls,
    paper,
    w,
    h,
    start,
    Math.round(dim * 0.06),
    Math.round(dim * 0.12),
    Math.round(dim * 0.45),
  );
  lap("prolongar");

  let gutter = null;
  if (gaps.length >= 20) {
    gaps.sort((a, b) => a - b);
    gutter = gaps[gaps.length >> 1] / dim;
  }

  // 2) segmentos alineados (a la misma altura ± 1,5 %, con huecos de hasta una calle)
  const tol = Math.max(3, Math.round(dim * 0.015));
  // (dos trozos de la misma línea separados por un hueco de hasta un 12 % son la misma
  // calle interrumpida por el dibujo)
  // Dos tramos en líneas parecidas separados por un hueco se unen si el hueco es papel
  // (la calle sigue, aunque a un lado tenga cielo blanco y no haya borde). Así también se
  // unen los dos lados de una misma calle cuando cada uno se detecta en un tramo distinto.
  const paperRun = (horizontal, o, from, to) => {
    const outer = horizontal ? h : w;
    let n = 0;
    for (let i = from; i < to; i++) {
      for (let d = -maxGap; d <= maxGap; d++) {
        const oo = o + d;
        if (oo < 0 || oo >= outer) continue;
        if (paper[horizontal ? oo * w + i : i * w + oo]) {
          n++;
          break;
        }
      }
    }
    return n / Math.max(1, to - from);
  };
  const hSegs = mergeCollinear(
    segs.filter((s) => s.horizontal),
    maxGap,
    3 * maxGap,
    (o, a, b) => paperRun(true, o, a, b),
  );
  const vSegs = mergeCollinear(
    segs.filter((s) => !s.horizontal),
    maxGap,
    3 * maxGap,
    (o, a, b) => paperRun(false, o, a, b),
  );

  // 3) guillotina
  const leaves = [];
  const ctx = {
    paper,
    maxGap,
    strict,
    w,
    h,
    hSegs,
    vSegs,
    minPiece: Math.round(dim * 0.09),
    captionMax: Math.round(dim * 0.12),
    near: Math.max(3, Math.round(dim * 0.02)),
    log: debug ? [] : null,
  };
  guillotine(start, ctx, 0, leaves);
  lap("guillotina");

  // 4) ajuste al dibujo
  let rects = leaves.map((r) => shrinkToInk(paper, w, r)).filter(Boolean);
  rects = rects.filter(isPanelSized(w, h));
  const valid = rects.length >= 2;
  lap("ajuste");
  if (debug)
    Object.assign(debug, {
      paper,
      walls: dilate(walls, w, h),
      hSegs,
      vSegs,
      leaves,
      rects,
      start,
      log: ctx.log,
      times,
      w,
      h,
      level,
    });
  return {
    rects: valid ? rects : [],
    bbox: start,
    text: false,
    style: "dense",
    gutter,
  };
}

// Luminancia "de papel" de un píxel: su luminancia si es neutro, 0 si tiene color
// (un cielo azul pálido es claro pero no es papel).
// `ref`, opcional: color del papel de la página (estimado en su borde); un píxel cercano a
// ese color cuenta como papel aunque tenga tinte (papel amarillento, rosado…).
export function paperLuma(r, g, b, ref = null) {
  const near =
    ref &&
    Math.abs(r - ref[0]) <= 45 &&
    Math.abs(g - ref[1]) <= 45 &&
    Math.abs(b - ref[2]) <= 45;
  return near || Math.max(r, g, b) - Math.min(r, g, b) <= 28
    ? 0.299 * r + 0.587 * g + 0.114 * b
    : 0;
}

// Color del papel de una página (RGBA): el color dominante del borde si es claro y
// mayoritario; si no, null.
export function paperRef(data, w, h) {
  const bg = estimateBackground(data, w, h);
  const luma = 0.299 * bg.color[0] + 0.587 * bg.color[1] + 0.114 * bg.color[2];
  return bg.ratio >= 0.5 && luma >= 150 ? bg.color : null;
}

// Umbral de "papel": el tono claro más frecuente de la página (el papel de un escaneo
// puede ser grisáceo), con margen para el ruido. Si la página apenas tiene claros, PAPER.
function paperLevel(luma, cap = TUNE.paperCap, drop = TUNE.paperDrop) {
  const hist = new Uint32Array(256);
  for (let p = 0; p < luma.length; p++) hist[luma[p]]++;
  let best = -1;
  let bestN = 0;
  for (let v = 160; v < 256; v++) {
    if (hist[v] > bestN) {
      bestN = hist[v];
      best = v;
    }
  }
  if (best < 180 || bestN < luma.length * 0.002) return cap;
  return Math.min(cap, best - drop);
}

// Localiza tramos rectos donde el papel linda con dibujo; los marca en `walls` y los
// añade a `segs` como { o, from, to, horizontal } (o = fila o columna del borde).
// horizontal=true: recorre filas (bordes horizontales); false: columnas.
// Para cada tramo mide, cuando existe, el grosor de la calle (distancia hasta el
// siguiente dibujo al otro lado) y lo añade a `gaps`.
function straightEdges(
  paper,
  w,
  h,
  horizontal,
  minLen,
  maxGap,
  walls,
  gaps,
  segs,
) {
  const outer = horizontal ? h : w; // índice de la línea recorrida
  const inner = horizontal ? w : h; // posición a lo largo de la línea
  const step = horizontal ? 1 : w; // avance a lo largo de la línea
  const jump = horizontal ? w : 1; // avance entre líneas
  const n = w * h;

  for (const side of [-1, 1]) {
    // E[p] = 1 si p es papel y el vecino del lado `side` es dibujo.
    const E = new Uint8Array(n);
    for (let o = 0; o < outer; o++) {
      const oo = o + side;
      if (oo < 0 || oo >= outer) continue;
      let p = o * jump;
      let q = oo * jump;
      for (let i = 0; i < inner; i++, p += step, q += step) {
        if (paper[p] === 1 && paper[q] === 0) E[p] = 1;
      }
    }
    for (let o = 0; o < outer; o++) {
      const base = o * jump;
      const hasPrev = o > 0;
      const hasNext = o < outer - 1;
      let run = 0;
      let missed = 0;
      let startI = -1;
      for (let i = 0; i <= inner; i++) {
        let on = false;
        if (i < inner) {
          const p = base + i * step;
          // se admite que el borde esté una línea más arriba o más abajo (escaneos girados)
          on =
            E[p] === 1 ||
            (hasPrev && E[p - jump] === 1) ||
            (hasNext && E[p + jump] === 1);
        }
        if (on) {
          if (startI < 0) startI = i;
          run++;
          missed = 0;
        } else if (startI >= 0 && missed < 4 && i < inner) {
          missed++; // uno o dos píxeles sueltos no rompen el borde
        } else {
          if (run >= minLen) {
            const end = i - missed;
            for (let k = startI; k < end; k++) walls[base + k * step] = 1;
            segs.push({ o, from: startI, to: end, horizontal });
            // grosor de la calle: desde el borde hacia el papel hasta el próximo dibujo
            for (let k = startI; k < end; k += 4) {
              let d = 1;
              let oo = o - side;
              while (
                d <= 2 * maxGap &&
                oo >= 0 &&
                oo < outer &&
                paper[oo * jump + k * step]
              ) {
                d++;
                oo -= side;
              }
              if (d <= 2 * maxGap) gaps.push(d);
            }
          }
          run = 0;
          missed = 0;
          startI = -1;
        }
      }
    }
  }
}

// Prolonga cada segmento por sus dos extremos, a lo largo de su línea, hasta topar con
// otro muro (a menos de `maxExt`) o con el borde del recuadro (a menos de `maxEdge`).
// Mientras la línea siga siendo papel (la calle continúa aunque a ambos lados haya blanco,
// por ejemplo un bocadillo pegado al borde) se puede prolongar mucho más (`maxPaper`).
// Actualiza `from`/`to` del segmento y pinta la prolongación en `walls`.
function extendWalls(segs, walls, paper, w, h, r, maxExt, maxEdge, maxPaper) {
  for (const seg of segs) {
    const { o, horizontal } = seg;
    const at = horizontal ? (oo, i) => oo * w + i : (oo, i) => i * w + oo;
    const outer = horizontal ? h : w;
    const lo = horizontal ? r.x0 : r.y0;
    const hi = horizontal ? r.x1 : r.y1;
    // muro en la línea o en las dos vecinas (los muros no siempre se tocan al píxel)
    const wallNear = (i) =>
      walls[at(o, i)] ||
      (o > 0 && walls[at(o - 1, i)]) ||
      (o < outer - 1 && walls[at(o + 1, i)]);
    const paperNear = (i) =>
      paper[at(o, i)] ||
      (o > 0 && paper[at(o - 1, i)]) ||
      (o < outer - 1 && paper[at(o + 1, i)]);
    for (const dir of [-1, 1]) {
      let i = dir < 0 ? seg.from - 1 : seg.to;
      const path = [];
      let hit = false;
      let onPaper = true; // la prolongación va toda por papel
      let gap = 0; // píxeles seguidos sin papel (el contorno de un bocadillo mide 2-3)
      while (path.length < maxPaper) {
        if (i < lo || i >= hi) {
          hit = onPaper || path.length < maxEdge; // borde del recuadro
          break;
        }
        if (wallNear(i) && (onPaper || path.length < maxExt)) {
          hit = true;
          break;
        }
        gap = paperNear(i) ? 0 : gap + 1;
        if (gap > 3) onPaper = false;
        if (!onPaper && path.length >= maxEdge) break;
        path.push(i);
        i += dir;
      }
      if (hit && path.length) {
        for (const k of path) walls[at(o, k)] = 1;
        if (dir < 0) seg.from = path[path.length - 1];
        else seg.to = path[path.length - 1] + 1;
      }
    }
  }
}

// Une segmentos de la misma orientación que están en líneas casi iguales (± tol) y se
// solapan, distan menos de `gap`, o cuyo hueco es papel según `paperBetween(o, a, b)`.
// Devuelve { o, from, to } con `o` promediado.
function mergeCollinear(segs, tol, gap, paperBetween) {
  const list = segs
    .map((s) => ({
      o: s.o,
      from: s.from,
      to: s.to,
      n: 1,
      parts: [[s.from, s.to]],
    }))
    .sort((a, b) => a.o - b.o || a.from - b.from);
  for (let changed = true; changed;) {
    changed = false;
    outer: for (let i = 0; i < list.length; i++) {
      for (let j = i + 1; j < list.length; j++) {
        const a = list[i];
        const b = list[j];
        if (Math.abs(a.o - b.o) > tol) continue;
        // Dos tramos que se solapan en longitud a distinta altura son líneas paralelas
        // (marco doble, un rótulo dentro de la viñeta), no una misma línea torcida.
        const overlapLen = Math.min(a.to, b.to) - Math.max(a.from, b.from);
        if (Math.abs(a.o - b.o) > 3 && overlapLen > Math.max(8, 0.1 * Math.min(a.to - a.from, b.to - b.from))) continue;
        const hole = -overlapLen; // negativo si se solapan
        if (hole > gap) {
          const o = Math.round((a.o + b.o) / 2);
          if (
            !paperBetween ||
            paperBetween(o, Math.min(a.to, b.to), Math.max(a.from, b.from)) <
              0.85
          )
            continue;
        }
        list[i] = {
          o: (a.o * a.n + b.o * b.n) / (a.n + b.n),
          from: Math.min(a.from, b.from),
          to: Math.max(a.to, b.to),
          n: a.n + b.n,
          parts: coalesce([...a.parts, ...b.parts]),
        };
        list.splice(j, 1);
        changed = true;
        break outer;
      }
    }
  }
  return list.map((s) => ({
    o: Math.round(s.o),
    from: s.from,
    to: s.to,
    parts: s.parts,
  }));
}

// Une intervalos [a,b] que se solapan o se tocan.
function coalesce(parts) {
  const sorted = parts.slice().sort((p, q) => p[0] - q[0]);
  const out = [];
  for (const [a, b] of sorted) {
    const last = out[out.length - 1];
    if (last && a <= last[1]) last[1] = Math.max(last[1], b);
    else out.push([a, b]);
  }
  return out;
}

// Fracción de [a,b] cubierta por los tramos reales de la línea `l` (una línea fundida
// a través de papel cubre solo sus tramos, no el hueco).
function covered(l, a, b) {
  let total = 0;
  for (const [s, e] of l.parts || [[l.from, l.to]]) {
    const x0 = Math.max(a, s);
    const x1 = Math.min(b, e);
    if (x1 > x0) total += x1 - x0;
  }
  return total / Math.max(1, b - a);
}

// Parte el rectángulo por el segmento que mejor lo atraviesa y repite en cada mitad.
// Primero horizontales (filas), luego verticales (columnas).
function guillotine(r, ctx, depth, out) {
  if (depth < 12) {
    const cut = bestCut(r, ctx, true) || bestCut(r, ctx, false);
    if (cut) {
      guillotine(cut[0], ctx, depth + 1, out);
      guillotine(cut[1], ctx, depth + 1, out);
      return;
    }
  }
  out.push(r);
}

// Un segmento vale como corte si atraviesa el rectángulo casi entero (≥ 75 %), o algo
// menos si sus extremos están «anclados» en el borde del rectángulo o en un segmento
// perpendicular (así se admiten calles invadidas por el dibujo). Además, los dos trozos
// resultantes tienen que ser viñetas plausibles (ver pieceOk).
function bestCut(r, ctx, horizontal) {
  const segs = horizontal ? ctx.hSegs : ctx.vSegs;
  const perp = horizontal ? ctx.vSegs : ctx.hSegs;
  const lo = horizontal ? r.y0 : r.x0; // eje perpendicular al segmento
  const hi = horizontal ? r.y1 : r.x1;
  const spanLo = horizontal ? r.x0 : r.y0; // eje a lo largo del segmento
  const spanHi = horizontal ? r.x1 : r.y1;
  const span = spanHi - spanLo;
  const { near } = ctx;
  const anchored = (s, end) =>
    Math.abs(end - spanLo) <= near ||
    Math.abs(end - spanHi) <= near ||
    perp.some(
      (q) =>
        Math.abs(q.o - end) <= near &&
        q.from - near <= s.o &&
        q.to + near >= s.o,
    );

  const candidates = [];
  for (const s of segs) {
    if (s.o <= lo + 2 || s.o >= hi - 2) continue;
    const cov = (Math.min(s.to, spanHi) - Math.max(s.from, spanLo)) / span;
    if (cov <= 0) continue;
    const anchors = (anchored(s, s.from) ? 1 : 0) + (anchored(s, s.to) ? 1 : 0);
    // Con `strict` (cuando el método de calles claras ya ve bien la página), un corte solo
    // vale si es una calle de verdad: junto al borde, una línea (fila o columna) casi toda
    // de papel a lo largo del tramo, con dibujo a los dos lados. El borde entre el cielo de
    // una viñeta y su dibujo tiene papel (o cielo tramado) a un lado y dibujo solo al otro.
    const { paper, maxGap } = ctx;
    const from = Math.max(s.from, spanLo);
    const to = Math.min(s.to, spanHi);
    const prof = [];
    for (let d = -maxGap; d <= maxGap; d++) {
      const oo = s.o + d;
      if (oo < 0 || oo >= (horizontal ? ctx.h : ctx.w)) {
        prof.push(-1);
        continue;
      }
      let hits = 0;
      let m = 0;
      for (let i = from; i < to; i += 2, m++) if (paper[horizontal ? oo * ctx.w + i : i * ctx.w + oo]) hits++;
      prof.push(m ? hits / m : 0);
    }
    let peak = 0;
    let at = -1;
    prof.forEach((v, k) => {
      if (v > peak) (peak = v), (at = k);
    });
    let leftMin = 1;
    let rightMin = 1;
    for (let k = 0; k < at; k++) if (prof[k] >= 0 && prof[k] < leftMin) leftMin = prof[k];
    for (let k = at + 1; k < prof.length; k++) if (prof[k] >= 0 && prof[k] < rightMin) rightMin = prof[k];
    const real = !ctx.strict || (peak >= 0.85 && leftMin <= 0.35 && rightMin <= 0.35);
    // Sin tinta cerca a ningún lado la línea va por un claro del dibujo (un cielo, el borde de
    // unos rótulos): no es una calle salvo que uno de los trozos sea margen vacío.
    const bare = leftMin > 0.35 && rightMin > 0.35;
    if (ctx.log && cov >= 0.6) ctx.log.push(`    perfil ${horizontal ? 'y' : 'x'}${s.o}: pico ${peak.toFixed(2)} izq ${leftMin.toFixed(2)} der ${rightMin.toFixed(2)}${real ? '' : ' NO ES CALLE'}`);
    const ok =
      real &&
      (cov >= 0.9 ||
        (cov >= 0.7 && anchors >= 1) ||
        (cov >= 0.6 && anchors === 2));
    ctx.log?.push(
      `${horizontal ? "y" : "x"}${s.o}[${s.from}-${s.to}] en (${r.x0},${r.y0})-(${r.x1},${r.y1}): cov ${cov.toFixed(2)} anclas ${anchors} ${ok ? "candidato" : "no"}`,
    );
    if (ok) candidates.push({ s, cov, bare });
  }
  candidates.sort((a, b) => b.cov - a.cov);
  for (const { s, bare } of candidates) {
    const pieces = horizontal
      ? [
          { x0: r.x0, y0: r.y0, x1: r.x1, y1: s.o },
          { x0: r.x0, y0: s.o, x1: r.x1, y1: r.y1 },
        ]
      : [
          { x0: r.x0, y0: r.y0, x1: s.o, y1: r.y1 },
          { x0: s.o, y0: r.y0, x1: r.x1, y1: r.y1 },
        ];
    const oks = pieces.map((p) => pieceOk(p, ctx, horizontal));
    ctx.log?.push(
      `  corte ${horizontal ? "y" : "x"}${s.o}: trozos ${oks.join("/")}`,
    );
    if (bare && pieces.every((p) => !isEmptyPiece(p, ctx))) continue;
    if (oks.every(Boolean)) return pieces;
  }
  return null;
}

function isEmptyPiece(p, { paper, w }) {
  let ink = 0;
  for (let y = p.y0; y < p.y1; y++) {
    for (let x = p.x0; x < p.x1; x++) if (!paper[y * w + x]) ink++;
  }
  return ink < (p.x1 - p.x0) * (p.y1 - p.y0) * 0.15;
}

// Un trozo es plausible si está vacío (margen o calle, se descartará) o si contiene
// dibujo que ocupa la mayor parte de su anchura y altura y no es una tira estrecha
// (una tira con dibujo en una esquina es un rótulo o un desbordamiento, no una viñeta).
function pieceOk(p, ctx, horizontal) {
  const { paper, w } = ctx;
  const pw = p.x1 - p.x0;
  const ph = p.y1 - p.y0;
  // Columnas y filas con una cantidad apreciable de dibujo.
  const colInk = new Uint32Array(pw);
  const rowInk = new Uint32Array(ph);
  let ink = 0;
  for (let y = p.y0; y < p.y1; y++) {
    for (let x = p.x0; x < p.x1; x++) {
      if (paper[y * w + x]) continue;
      ink++;
      colInk[x - p.x0]++;
      rowInk[y - p.y0]++;
    }
  }
  if (ink < pw * ph * 0.15) return true; // vacío: margen o calle
  const thick = horizontal ? ph : pw;
  let cols = 0;
  for (const v of colInk) if (v >= ph * 0.1) cols++;
  let rows = 0;
  for (const v of rowInk) if (v >= pw * 0.1) rows++;
  // Un trozo horizontal fino y casi todo tinta es una caja de texto (rótulo) pegada a su
  // viñeta, no una viñeta. En vertical, un trozo fino puede ser una viñeta estrecha.
  const caption = horizontal && thick < ctx.captionMax && ink >= 0.8 * pw * ph;
  // Una franja fina casi negra pegada al borde de la página es el sangrado del fondo, no
  // una viñeta.
  const atEdge =
    p.x0 <= 1 || p.y0 <= 1 || p.x1 >= ctx.w - 1 || p.y1 >= ctx.h - 1;
  const bleed = atEdge && thick < ctx.captionMax && ink >= 0.9 * pw * ph;
  const ok =
    thick >= ctx.minPiece &&
    !caption &&
    !bleed &&
    cols >= 0.6 * pw &&
    rows >= 0.6 * ph;
  ctx.log?.push(
    `    trozo (${p.x0},${p.y0})-(${p.x1},${p.y1}): grosor ${thick} tinta ${(ink / (pw * ph)).toFixed(2)} cols ${(cols / pw).toFixed(2)} filas ${(rows / ph).toFixed(2)} → ${ok}`,
  );
  return ok;
}

// Encoge el rectángulo al recuadro de su dibujo (quita calles y márgenes). Devuelve
// null si casi no hay dibujo (un trozo de margen o de zona clara).
function shrinkToInk(paper, w, r) {
  let x0 = r.x1;
  let y0 = r.y1;
  let x1 = r.x0;
  let y1 = r.y0;
  let ink = 0;
  for (let y = r.y0; y < r.y1; y++) {
    for (let x = r.x0; x < r.x1; x++) {
      if (paper[y * w + x]) continue;
      ink++;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  if (ink < area(r) * 0.15) return null;
  return { x0, y0, x1: x1 + 1, y1: y1 + 1 };
}

function dilate(mask, w, h) {
  const out = mask.slice();
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = y * w + x;
      if (mask[i]) continue;
      if (
        (x > 0 && mask[i - 1]) ||
        (x < w - 1 && mask[i + 1]) ||
        (y > 0 && mask[i - w]) ||
        (y < h - 1 && mask[i + w])
      ) {
        out[i] = 1;
      }
    }
  }
  return out;
}

// ---------- estilo «viñetas con marco» ----------
//
// Cómic clásico europeo (Bruguera, franco-belga): cada viñeta lleva un marco de tinta
// negra sobre papel claro, con calles de papel entre ellas. Aquí la señal fiable es el
// propio marco: se localizan las líneas rectas finas de tinta (horizontales y
// verticales) que tienen papel a un lado, y las viñetas son los rectángulos que forman.
// Da igual que dentro haya blancos (nieve, cielo) o que un bocadillo cruce la calle:
// mientras quede la mayor parte del marco, el rectángulo se reconoce.
//
// Los rótulos sueltos encima de una viñeta (Superlópez los pone fuera del marco) se
// anexan a la viñeta de debajo.

// Los marcos son líneas de 1-2 px: a 900 px se difuminan con el papel, así que cuando hay
// luminancia a doble resolución (`hiLuma`, `hi`) se trabaja a 2× y se reducen los
// resultados.
function detectFramed(
  data,
  w,
  h,
  rtl,
  bbox,
  debug = null,
  hi = null,
  hiLuma = null,
  cleanRects = [],
) {
  if (hi && hiLuma && hi.length === 4 * w * h && hiLuma.length === 4 * w * h) {
    const dbl = (q) => ({
      x0: 2 * q.x0,
      y0: 2 * q.y0,
      x1: 2 * q.x1,
      y1: 2 * q.y1,
    });
    const big = bbox ? dbl(bbox) : null;
    const r = detectFramedAt(
      hiLuma,
      hi,
      2 * w,
      2 * h,
      rtl,
      big,
      debug,
      cleanRects.map(dbl),
    );
    const half = (q) => ({
      ...q,
      x0: Math.round(q.x0 / 2),
      y0: Math.round(q.y0 / 2),
      x1: Math.round(q.x1 / 2),
      y1: Math.round(q.y1 / 2),
    });
    r.rects = r.rects.map(half);
    r.bbox = half(r.bbox);
    if (debug?.framed) debug.framed.scale = 2;
    return r;
  }
  const n = w * h;
  const luma = new Uint8Array(n);
  const pl = new Uint8Array(n);
  const ref = paperRef(data, w, h);
  for (let p = 0, i = 0; p < n; p++, i += 4) {
    luma[p] = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
    pl[p] = paperLuma(data[i], data[i + 1], data[i + 2], ref);
  }
  return detectFramedAt(luma, pl, w, h, rtl, bbox, debug, cleanRects);
}

// `luma`: luminancia; `pl`: luminancia de papel (0 en píxeles con color).
// `pl`: luminancia de papel (0 en píxeles con color). Los marcos no se buscan como
// líneas de tinta (en un escaneo viejo son grises y se confunden con el dibujo) sino como
// los bordes rectos entre papel y no-papel: el borde superior de una viñeta tiene papel
// encima y dibujo debajo, etc. Cada borde se etiqueta por el lado del papel.
function detectFramedAt(
  luma,
  pl,
  w,
  h,
  rtl,
  bbox,
  debug = null,
  cleanRects = [],
) {
  const t0 = debug ? performance.now() : 0;
  const times = [];
  const lap = (name) =>
    debug && times.push(`${name} ${Math.round(performance.now() - t0)}`);
  const n = w * h;
  // Umbral más estricto que en el estilo denso: el papel de las calles es el de la
  // página; los claros del dibujo (azulejos, cielos pálidos) quedan fuera.
  const level = paperLevel(pl, TUNE.framedCap, TUNE.framedDrop);
  const paper = new Uint8Array(n);
  for (let p = 0; p < n; p++) if (pl[p] >= level) paper[p] = 1;

  const dim = Math.min(w, h);
  const minLen = Math.round(dim * 0.08);
  const tol = Math.max(3, Math.round(dim * 0.02));
  const maxGap = Math.max(3, Math.round(dim * 0.04));
  const start = bbox || { x0: 0, y0: 0, x1: w, y1: h };

  const paperRun = (horizontal, o, from, to) => {
    const outer = horizontal ? h : w;
    let k = 0;
    for (let i = from; i < to; i++) {
      for (let d = -maxGap; d <= maxGap; d++) {
        const oo = o + d;
        if (
          oo >= 0 &&
          oo < outer &&
          paper[horizontal ? oo * w + i : i * w + oo]
        ) {
          k++;
          break;
        }
      }
    }
    return k / Math.max(1, to - from);
  };
  // Una ilustración tramada (medios tonos) produce cientos de bordes cortos entre los
  // puntos claros; fusionarlos y emparejarlos tardaría minutos y no hay marcos que
  // encontrar. Con demasiados bordes en cualquier dirección el método se rinde.
  let overflow = false;
  const edges = (horizontal, side) => {
    const segs = paperEdges(paper, w, h, horizontal, side, minLen);
    if (segs.length > FRAMED_MAX_SEGS) {
      overflow = true;
      return [];
    }
    return mergeCollinear(segs, tol, 3 * maxGap, (o, a, b) =>
      paperRun(horizontal, o, a, b),
    );
  };
  // side=+1: papel en o y dibujo en o+1 → borde superior (o izquierdo) de la viñeta.
  const topsOwn = edges(true, 1);
  const bottomsOwn = edges(true, -1);
  lap("bordes h");
  const leftsOwn = edges(false, 1);
  const rightsOwn = edges(false, -1);
  lap("bordes v");
  // Un lado sin borde propio (bocadillo que lo tapa, marco muy claro) se toma del
  // vecino: el borde izquierdo del panel de al lado, un poco antes, hace de borde derecho.
  const gutter = Math.max(2, Math.round(dim * 0.008));
  const minGutter = Math.max(3, Math.round(dim * 0.006)); // más ancho que las juntas de un azulejo
  const tops = [
    ...topsOwn,
    ...bottomsOwn.map((l) => ({ ...l, o: l.o + gutter, borrowed: true })),
  ];
  const bottoms = [
    ...bottomsOwn,
    ...topsOwn.map((l) => ({ ...l, o: l.o - gutter, borrowed: true })),
  ];
  const lefts = [
    ...leftsOwn,
    ...rightsOwn.map((l) => ({ ...l, o: l.o + gutter, borrowed: true })),
  ].sort((a, b) => a.o - b.o);
  const rights = [
    ...rightsOwn,
    ...leftsOwn.map((l) => ({ ...l, o: l.o - gutter, borrowed: true })),
  ].sort((a, b) => a.o - b.o);
  // Una página con marcos tiene unas pocas decenas de líneas por dirección; el
  // emparejado de abajo crece con la cuarta potencia, así que con más se devuelve la
  // página sin recuadros.
  if (
    overflow ||
    tops.length * bottoms.length > FRAMED_MAX_PAIRS ||
    lefts.length * rights.length > FRAMED_MAX_PAIRS
  ) {
    lap("demasiadas líneas");
    if (debug)
      Object.assign(debug, {
        framed: { hLines: [], vLines: [], found: [], rects: [], leftovers: [], level, log: [], times, tops: tops.length, bottoms: bottoms.length, lefts: lefts.length, rights: rights.length },
      });
    return { rects: [], framedCount: 0, bbox: start, text: false, style: "framed" };
  }
  const hLines = [
    ...topsOwn.map((l) => ({ ...l, paperA: true })),
    ...bottomsOwn.map((l) => ({ ...l, paperB: true })),
  ];
  const vLines = [
    ...leftsOwn.map((l) => ({ ...l, paperA: true })),
    ...rightsOwn.map((l) => ({ ...l, paperB: true })),
  ];

  const minW = Math.round(w * 0.08);
  const minH = Math.round(h * 0.06);

  // Cobertura de un tramo [a,b] por las líneas de `lines` situadas en `o` ± tol.
  const cover = (lines, o, a, b) => {
    const parts = [];
    for (const l of lines) {
      if (Math.abs(l.o - o) > tol) continue;
      for (const [f, t] of l.parts || [[l.from, l.to]]) {
        const s = Math.max(a, f);
        const e = Math.min(b, t);
        if (e > s) parts.push([s, e]);
      }
    }
    parts.sort((p, q) => p[0] - q[0]);
    let total = 0;
    let end = -Infinity;
    for (const [s, e] of parts) {
      if (e <= end) continue;
      total += e - Math.max(s, end);
      end = e;
    }
    return total / Math.max(1, b - a);
  };
  const spans = (l, a, b) =>
    (Math.min(l.to, b) - Math.max(l.from, a)) / Math.max(1, b - a);

  const inkFrac = (r) => {
    let k = 0;
    for (let y = Math.max(0, r.y0); y < Math.min(h, r.y1); y++) {
      for (let x = Math.max(0, r.x0); x < Math.min(w, r.x1); x++)
        if (!paper[y * w + x]) k++;
    }
    return k / Math.max(1, area(r));
  };
  // Calle de papel pegada a una línea: fracción de las columnas (o filas) de [a,b] en
  // las que, desde `o` hacia `dir`, hay entre minGutter y maxGap píxeles seguidos de
  // papel antes del siguiente dibujo. Una calle de verdad la tiene casi a lo largo (los
  // bocadillos la interrumpen); una línea suelta dentro del dibujo (azulejos, el borde
  // de una mesa) tiene papel de sobra o casi nada.
  // Con `orEdge`, también vale una banda de papel que llega hasta el borde de la página
  // (el margen): sirve para los lados exteriores de las viñetas.
  const paperBand = (horizontal, o, dir, a, b, orEdge = false) => {
    const outer = horizontal ? h : w;
    let k = 0;
    for (let i = a; i < b; i++) {
      // La línea fundida puede quedar un par de píxeles dentro del dibujo (escaneo
      // torcido): se admiten hasta 3 píxeles de dibujo antes de empezar a contar.
      let oo = o;
      for (let skip = 0; skip < 3 && oo >= 0 && oo < outer && !paper[horizontal ? oo * w + i : i * w + oo]; skip++) oo += dir;
      let n = 0;
      for (; oo >= 0 && oo < outer && (n <= maxGap || orEdge); oo += dir) {
        if (!paper[horizontal ? oo * w + i : i * w + oo]) break;
        n++;
      }
      if (n >= minGutter && (n <= maxGap || (orEdge && (oo < 0 || oo >= outer)))) k++;
      else if (orEdge && (o + dir * 3 < 0 || o + dir * 3 >= outer)) k++;
    }
    return k / Math.max(1, b - a);
  };
  // Calle en un lado de un rectángulo: 2 si es el margen de la página o hay una banda de
  // papel cerrada por el borde de la viñeta vecina (una línea propia del otro tipo a
  // menos de una calle); 1 si solo hay banda de papel (un cielo blanco dentro del
  // dibujo también la da); 0 si no.
  const sideGutter = (horizontal, o, dir, a, b, farLines) => {
    const outer = horizontal ? h : w;
    if (o + dir * 3 < 0 || o + dir * 3 >= outer) return 2;
    if (paperBand(horizontal, o, dir, a, b, true) < 0.6) return 0;
    if (paperBand(horizontal, o, dir, a, b, false) < 0.6) return 2; // llega al borde: margen
    const paired = farLines.some((m) => (m.o - o) * dir > 0 && (m.o - o) * dir <= maxGap + tol && covered(m, a, b) >= 0.5);
    return paired ? 2 : 1;
  };
  const gutterSides = (r) => {
    const g = [
      sideGutter(true, r.y0, -1, r.x0, r.x1, bottomsOwn),
      sideGutter(true, r.y1, 1, r.x0, r.x1, topsOwn),
      sideGutter(false, r.x0, -1, r.y0, r.y1, rightsOwn),
      sideGutter(false, r.x1, 1, r.y0, r.y1, leftsOwn),
    ];
    if (debug) r.gutterDetail = g.join('');
    return g[0] + g[1] + g[2] + g[3];
  };
  // Línea de calle: borde propio que cubre [a,b] al menos al 60 % y con calle de papel
  // al lado del papel. `lines` es bottomsOwn (calle debajo) o topsOwn (calle encima), o
  // rightsOwn / leftsOwn para calles verticales.
  const gutterLine = (lines, horizontal, dir, near, a, b) =>
    lines.some((m) => Math.abs(m.o - near) <= tol && covered(m, a, b) >= 0.6 && paperBand(horizontal, m.o, dir, a, b) >= 0.6);

  const found = [];
  const log = debug ? [] : null;
  const fmtL = (l) => `${l.o}${l.borrowed ? "'" : ""}[${l.from}-${l.to}]`;
  // Red de seguridad: si el emparejado se alarga (una página rara que pasa la guardia
  // de arriba), se corta y se sigue con los candidatos encontrados hasta entonces.
  const deadline = performance.now() + FRAMED_BUDGET_MS;
  let timedOut = false;
  for (const t of tops) {
    if (timedOut) break;
    for (const bt of bottoms) {
      if (performance.now() > deadline) {
        timedOut = true;
        log?.push(`tiempo agotado tras ${found.length} candidatos`);
        break;
      }
      if (bt.o - t.o < minH) continue;
      // Los lados pueden quedar algo más allá del tramo común (un borde prestado del
      // vecino está a una calle de distancia).
      const X0 = Math.min(t.from, bt.from) - tol - maxGap;
      const X1 = Math.max(t.to, bt.to) + tol + maxGap;
      if (X1 - X0 < minW) continue;
      const ls = lefts.filter(
        (l) => l.o >= X0 && l.o <= X1 - minW && spans(l, t.o, bt.o) >= 0.6,
      );
      const rs = rights.filter(
        (l) => l.o >= X0 + minW && l.o <= X1 && spans(l, t.o, bt.o) >= 0.6,
      );
      log?.push(
        `T${fmtL(t)} B${fmtL(bt)} X[${X0}-${X1}] L:${ls.map(fmtL).join(",")} R:${rs.map(fmtL).join(",")}`,
      );
      for (const l of ls) {
        const first = rs.find((q) => q.o - l.o >= minW);
        if (!first) continue;
        // El lado derecho más cercano y sus dobles (línea propia y prestada casi en el
        // mismo sitio): el filtro de duplicados se queda luego con el mejor.
        for (const r of rs.filter(
          (q) => q.o - l.o >= minW && q.o - first.o <= tol,
        )) {
          const own =
            (t.borrowed ? 0 : 1) +
            (bt.borrowed ? 0 : 1) +
            (l.borrowed ? 0 : 1) +
            (r.borrowed ? 0 : 1);
          if (
            own < 1 ||
            (own < 2 && inkFrac({ x0: l.o, y0: t.o, x1: r.o, y1: bt.o }) < 0.25)
          ) {
            log?.push(`  L${fmtL(l)} R${fmtL(r)}: solo ${own} lados propios`);
            continue;
          }
          const ct = cover(tops, t.o, l.o, r.o);
          const cb = cover(bottoms, bt.o, l.o, r.o);
          if (ct < 0.6 || cb < 0.6) {
            log?.push(
              `  L${fmtL(l)} R${fmtL(r)}: cobertura arriba ${ct.toFixed(2)} abajo ${cb.toFixed(2)}`,
            );
            continue;
          }
          // Una calle que atraviesa el candidato lo parte en dos: no es una viñeta sino dos
          // apiladas. La calle es un borde inferior con calle de papel debajo (o uno
          // superior con calle encima) a lo ancho del candidato. Una línea suelta dentro
          // del dibujo (azulejos, una mesa) no tiene calle.
          // También parte una pareja de bordes (inferior y, una calle más abajo, superior)
          // a lo ancho del candidato aunque la calle no sea de papel limpio (calles
          // grises o torcidas de un cómic digital).
          const inner = (m) => m.o > t.o + tol && m.o < bt.o - tol;
          const split =
            bottomsOwn.some((m) => inner(m) && covered(m, l.o, r.o) >= 0.6 && paperBand(true, m.o, 1, l.o, r.o) >= 0.6) ||
            topsOwn.some((m) => inner(m) && covered(m, l.o, r.o) >= 0.6 && paperBand(true, m.o, -1, l.o, r.o) >= 0.6) ||
            bottomsOwn.some(
              (m) =>
                inner(m) &&
                covered(m, l.o, r.o) >= 0.6 &&
                topsOwn.some((q) => q.o - m.o >= minGutter && q.o - m.o <= maxGap && covered(q, l.o, r.o) >= 0.6),
            );
          if (split) {
            log?.push(
              `  L${fmtL(l)} R${fmtL(r)}: partido por una línea intermedia`,
            );
            continue;
          }
          log?.push(`  L${fmtL(l)} R${fmtL(r)}: candidato (${own} propios)`);
          found.push({ x0: l.o, y0: t.o, x1: r.o, y1: bt.o, own });
        }
      }
    }
  }

  // Solo cuentan como marcos los rectángulos con una línea oscura a lo largo de sus
  // cuatro lados (un bocadillo puede tapar parte de un lado). En un dibujo denso sin
  // marcos los bordes papel→dibujo también forman rectángulos, pero sin esa línea.
  const dark = Math.min(170, level - 40);
  const reach = Math.max(6, Math.round(dim * 0.008));
  const frameScore = (r) => {
    // Fracción del lado con un píxel oscuro en la línea o ± 1, probando desplazamientos
    // de hasta `reach` (el borde papel→dibujo puede quedar unos píxeles fuera de la
    // línea). El lado se mide por tramos, cada uno con su mejor desplazamiento: un
    // escaneo algo torcido desvía la línea varios píxeles de punta a punta.
    const chunk = Math.max(20, Math.round(dim * 0.1));
    const side = (horizontal, o, from, to) => {
      const outer = horizontal ? h : w;
      let total = 0;
      for (let a = from; a < to; a += chunk) {
        const b = Math.min(to, a + chunk);
        let best = 0;
        for (let d0 = -reach; d0 <= reach; d0++) {
          let hit = 0;
          for (let i = a; i < b; i++) {
            let any = false;
            for (let d = d0 - 1; d <= d0 + 1 && !any; d++) {
              const oo = o + d;
              if (oo >= 0 && oo < outer && luma[horizontal ? oo * w + i : i * w + oo] < dark) any = true;
            }
            if (any) hit++;
          }
          if (hit > best) best = hit;
        }
        total += best;
      }
      return total / Math.max(1, to - from);
    };
    const x0 = Math.max(0, r.x0);
    const x1 = Math.min(w, r.x1);
    const y0 = Math.max(0, r.y0);
    const y1 = Math.min(h, r.y1);
    // Vale con tres lados: un rótulo o un bocadillo puede tapar casi todo un lado.
    return [
      side(true, y0, x0, x1),
      side(true, y1, x0, x1),
      side(false, x0, y0, y1),
      side(false, x1, y0, y1),
    ].sort((p, q) => p - q)[1];
  };
  // Calle de verdad entre dos rectángulos vecinos: una línea de calle en el borde
  // inferior (o derecho) del primero o en el superior (o izquierdo) del segundo. Un
  // rótulo dentro de la viñeta también forma rectángulos vecinos, pero entre ellos no
  // hay calle.
  const realGutter = (a, b) => {
    const xo0 = Math.max(a.x0, b.x0);
    const xo1 = Math.min(a.x1, b.x1);
    if (xo1 - xo0 >= minW && b.y0 - a.y1 >= -tol && b.y0 - a.y1 <= maxGap + tol) {
      return gutterLine(bottomsOwn, true, 1, a.y1, xo0, xo1) || gutterLine(topsOwn, true, -1, b.y0, xo0, xo1);
    }
    const yo0 = Math.max(a.y0, b.y0);
    const yo1 = Math.min(a.y1, b.y1);
    if (yo1 - yo0 >= minH && b.x0 - a.x1 >= -tol && b.x0 - a.x1 <= maxGap + tol) {
      return gutterLine(rightsOwn, false, 1, a.x1, yo0, yo1) || gutterLine(leftsOwn, false, -1, b.x0, yo0, yo1);
    }
    return false;
  };
  // Contenedores: un candidato que contiene otros cede ante ellos si son al menos dos,
  // separados entre sí por calles de verdad, y lo cubren al menos a la mitad (era una
  // cuadrícula de viñetas, o dos apiladas con un bocadillo sobre la calle). Si no, los
  // contenidos son detalle interior (rótulos, azulejos, un recuadro dentro del dibujo):
  // se descartan ya si el contenedor está rodeado de calles y tiene marco, y si no, solo
  // cuando el contenedor acaba elegido (más abajo).
  const dropped = new Set();
  const inside = (a, b) =>
    overlap(a, b) >= 0.9 * area(a) && area(a) < 0.9 * area(b);
  for (const c of [...found].sort((a, b) => area(b) - area(a))) {
    if (dropped.has(c)) continue;
    const inners = found
      .filter((o) => !dropped.has(o) && o !== c && inside(o, c))
      .sort((a, b) => area(b) - area(a));
    if (inners.length < 2) continue;
    const taken = [];
    for (const o of inners)
      if (!taken.some((k) => overlap(k, o) > 0.3 * Math.min(area(k), area(o))))
        taken.push(o);
    const tiles = taken.filter((o) =>
      taken.some((q) => q !== o && (realGutter(o, q) || realGutter(q, o))),
    );
    const coveredArea = tiles.reduce((sum, o) => sum + area(o), 0);
    if (tiles.length >= 2 && coveredArea >= 0.5 * area(c)) {
      dropped.add(c);
      log?.push(`contenedor (${c.x0},${c.y0})-(${c.x1},${c.y1}) cede ante ${tiles.length} interiores`);
    } else if (gutterSides(c) === 8 && frameScore(c) >= 0.5) {
      // Una viñeta rodeada de calles (o margen) por los cuatro lados y con marco: lo de
      // dentro que apenas tiene calles alrededor (azulejos, rótulos, un cuadro en la
      // pared) no son viñetas. Los interiores bien delimitados se dejan competir.
      const weak = inners.filter((o) => gutterSides(o) <= 4);
      for (const o of weak) dropped.add(o);
      if (weak.length) log?.push(`contenedor (${c.x0},${c.y0})-(${c.x1},${c.y1}) absorbe ${weak.length} interiores`);
    }
  }
  lap('candidatos');
  // Duplicados (misma viñeta por líneas dobles, o un recuadro algo distinto que toma el
  // borde de un rótulo como lado): gana el de mejor marco; a igualdad, el de más lados
  // propios y, después, el mayor (el que incluye el rótulo adosado). Dos marcos no se
  // solapan: un candidato que pisa uno ya elegido se descarta.
  const straddles = (c) =>
    cleanRects.some((o) => {
      const ov = overlap(c, o);
      return ov >= 0.15 * area(c) && ov <= 0.85 * area(c) && ov <= 0.85 * area(o);
    });
  const scored = found
    .filter((c) => !dropped.has(c) && isPanelSized(w, h)(c))
    .map((c) => {
      const gutters = gutterSides(c);
      return { ...c, frame: frameScore(c), gutters, straddles: straddles(c) ? 1 : 0 };
    });
  // Gana el marco más oscuro; a igualdad, el que no cruza el borde de una viñeta vista
  // por los otros métodos (un recuadro que empieza dentro de la viñeta de arriba, en una
  // fila de edificios bajo el cielo, la cruza), el que tiene más calles (o margen)
  // alrededor, más lados propios y mayor tamaño.

  scored.sort(
    (a, b) =>
      Math.round(10 * b.frame) - Math.round(10 * a.frame) ||
      a.straddles - b.straddles ||
      b.gutters - a.gutters ||
      b.own - a.own ||
      area(b) - area(a),
  );
  if (debug) debug.scored = scored;
  const sized = [];
  const swallowed = new Set();
  for (const c of scored) {
    if (swallowed.has(c)) continue;
    if (sized.some((k) => overlap(k, c) > 0.05 * Math.min(area(k), area(c))))
      continue;
    sized.push(c);
    for (const o of scored)
      if (o !== c && !swallowed.has(o) && inside(o, c)) swallowed.add(o);
  }
  lap("puntuación");

  // Rótulos sueltos encima de cada viñeta: filas con tinta (texto, o una caja de texto
  // rellena) justo por encima del marco, hasta la viñeta anterior o una calle de papel.
  for (const r of sized) {
    // Tope: la viñeta anterior (marco o vista por los otros métodos, que no contenga a
    // esta): el rótulo no puede invadirla.
    const above = [...sized, ...cleanRects].filter(
      (q) => q !== r && q.y1 <= r.y0 + tol && q.x1 > r.x0 && q.x0 < r.x1,
    );
    const limit = above.reduce((m, q) => Math.max(m, q.y1), start.y0);
    let y = r.y0 - 2;
    let gap = 0;
    let top = r.y0;
    while (y > limit && gap <= Math.round(h * 0.012)) {
      let inkN = 0;
      for (let x = r.x0 + 2; x < r.x1 - 2; x++) if (!paper[y * w + x]) inkN++;
      const frac = inkN / Math.max(1, r.x1 - r.x0 - 4);
      if (frac > 0.015 && frac < 0.98) {
        top = y;
        gap = 0;
      } else gap++;
      y--;
    }
    if (r.y0 - top <= h * 0.09) r.y0 = top;
  }
  // …y debajo (rótulos adosados bajo el marco), hasta la viñeta siguiente.
  for (const r of sized) {
    const below = [...sized, ...cleanRects].filter(
      (q) => q !== r && q.y0 >= r.y1 - tol && q.x1 > r.x0 && q.x0 < r.x1,
    );
    const limit = below.reduce((m, q) => Math.min(m, q.y0), start.y1);
    let y = r.y1 + 1;
    let gap = 0;
    let bottom = r.y1;
    while (y < limit && gap <= Math.round(h * 0.012)) {
      let inkN = 0;
      for (let x = r.x0 + 2; x < r.x1 - 2; x++) if (!paper[y * w + x]) inkN++;
      const frac = inkN / Math.max(1, r.x1 - r.x0 - 4);
      if (frac > 0.03 && frac < 0.98) {
        bottom = y + 1;
        gap = 0;
      } else gap++;
      y++;
    }
    if (bottom - r.y1 <= h * 0.09) r.y1 = bottom;
  }

  // Viñetas sin marco (o con marco no reconocido): lo que queda de las viñetas del método
  // limpio al restarles los marcos encontrados, si tiene dibujo.
  const leftovers = [];
  for (const c of cleanRects) {
    let pieces = [c];
    for (const f of sized) {
      const next = [];
      for (const q of pieces) {
        if (overlap(q, f) === 0) {
          next.push(q);
          continue;
        }
        if (f.y0 > q.y0) next.push({ x0: q.x0, y0: q.y0, x1: q.x1, y1: f.y0 });
        if (f.y1 < q.y1) next.push({ x0: q.x0, y0: f.y1, x1: q.x1, y1: q.y1 });
        const yy0 = Math.max(q.y0, f.y0);
        const yy1 = Math.min(q.y1, f.y1);
        if (f.x0 > q.x0) next.push({ x0: q.x0, y0: yy0, x1: f.x0, y1: yy1 });
        if (f.x1 < q.x1) next.push({ x0: f.x1, y0: yy0, x1: q.x1, y1: yy1 });
      }
      pieces = next.filter((q) => q.x1 - q.x0 >= minW && q.y1 - q.y0 >= minH);
    }
    for (const q of pieces) {
      const t = shrinkToInk(paper, w, q);
      if (
        t &&
        isPanelSized(w, h)(t) &&
        inkFrac(t) >= 0.25 &&
        !leftovers.some((o) => overlap(o, t) > 0.3 * Math.min(area(o), area(t)))
      )
        leftovers.push(t);
    }
  }

  lap("sobrantes");

  // Cajas de texto con marco pegadas a una viñeta (rótulos medio dentro, medio fuera del
  // marco, o adosados a él): se funden con la viñeta que tocan. Una caja de texto es un
  // recuadro bajo, con marco (aunque un lado quede tapado) y con más papel que tinta; se
  // le asigna la viñeta más cercana que la solape en anchura (o en altura, si está a un
  // lado) a menos de una calle.
  const all = [...sized, ...leftovers];
  const inkCache = new Map();
  // Una franja sin marco (sobrante) tan baja como un rótulo también cuenta, sea texto o
  // dibujo: si está pegada a una viñeta y no sobresale de su anchura, es parte de ella.
  // Una viñeta ancha y baja (una tira a lo ancho de la página) no es un rótulo.
  const wideStrip = (r) => r.x1 - r.x0 > 0.5 * w && r.y1 - r.y0 > 0.08 * h;
  const isStrip = (r) => r.frame == null && r.y1 - r.y0 <= 0.15 * h && !wideStrip(r);
  const isTextBox = (r) => {
    if (isStrip(r)) return true;
    if (r.y1 - r.y0 > 0.15 * h || !(r.frame >= 0.4) || wideStrip(r)) return false;
    if (!inkCache.has(r)) inkCache.set(r, inkFrac(r));
    return inkCache.get(r) <= 0.6;
  };
  for (const box of all.filter(isTextBox).sort((a, b) => a.y0 - b.y0)) {
    let best = null;
    for (const host of all) {
      if (host === box || isTextBox(host)) continue;
      const gx = Math.max(box.x0, host.x0) - Math.min(box.x1, host.x1);
      const gy = Math.max(box.y0, host.y0) - Math.min(box.y1, host.y1);
      let gap = null;
      if (-gx >= 0.6 * (box.x1 - box.x0) && gy <= maxGap) gap = Math.max(0, gy);
      else if (-gy >= 0.6 * (box.y1 - box.y0) && gx <= maxGap)
        gap = Math.max(0, gx);
      if (gap === null) continue;
      if (isStrip(box) && (gy > maxGap || box.x0 < host.x0 - tol || box.x1 > host.x1 + tol)) continue;
      if (
        !best ||
        gap < best.gap ||
        (gap === best.gap && area(host) > area(best.host))
      )
        best = { host, gap };
    }
    if (!best) continue;
    const k = best.host;
    log?.push(
      `caja de texto (${box.x0},${box.y0})-(${box.x1},${box.y1}) → viñeta (${k.x0},${k.y0})-(${k.x1},${k.y1})`,
    );
    k.x0 = Math.min(k.x0, box.x0);
    k.y0 = Math.min(k.y0, box.y0);
    k.x1 = Math.max(k.x1, box.x1);
    k.y1 = Math.max(k.y1, box.y1);
    inkCache.delete(k);
    all.splice(all.indexOf(box), 1);
  }
  lap("cajas");
  const framedCount = all.filter((r) => r.frame >= 0.6).length;
  if (debug)
    Object.assign(debug, {
      framed: {
        hLines,
        vLines,
        found,
        rects: all.filter((r) => r.frame != null),
        leftovers: all.filter((r) => r.frame == null),
        level,
        log,
        times,
        tops: tops.length,
        bottoms: bottoms.length,
        lefts: lefts.length,
        rights: rights.length,
      },
    });
  return { rects: all, framedCount, bbox: start, text: false, style: "framed" };
}

// Tramos rectos donde el papel (en la línea o) linda con dibujo (en o+side). Se admite
// que el borde esté una línea más arriba o más abajo (escaneos algo girados) y huecos de
// hasta 3 píxeles. Devuelve { o, from, to } con `o` en la línea de papel.
function paperEdges(paper, w, h, horizontal, side, minLen) {
  const outer = horizontal ? h : w;
  const inner = horizontal ? w : h;
  const step = horizontal ? 1 : w;
  const jump = horizontal ? w : 1;
  const E = new Uint8Array(w * h);
  for (let o = 0; o < outer; o++) {
    const oo = o + side;
    if (oo < 0 || oo >= outer) continue;
    let p = o * jump;
    let q = oo * jump;
    for (let i = 0; i < inner; i++, p += step, q += step)
      if (paper[p] === 1 && paper[q] === 0) E[p] = 1;
  }
  // Fracción de las columnas del tramo con dibujo justo al lado del papel (en la
  // línea o en las dos siguientes, por la tolerancia a la inclinación). Una línea de
  // texto sobre papel también forma un borde, pero solo a trozos: se descarta.
  const inkAt = (oo, i) =>
    oo >= 0 && oo < outer && paper[oo * jump + i * step] === 0;
  const solid = (o, from, to) => {
    let k = 0;
    for (let i = from; i < to; i++)
      if (inkAt(o, i) || inkAt(o + side, i) || inkAt(o + 2 * side, i)) k++;
    return k / Math.max(1, to - from);
  };
  const segs = [];
  for (let o = 0; o < outer; o++) {
    const base = o * jump;
    let run = 0;
    let missed = 0;
    let startI = -1;
    for (let i = 0; i <= inner; i++) {
      let on = false;
      if (i < inner) {
        const p = base + i * step;
        on =
          E[p] === 1 ||
          (o > 0 && E[p - jump] === 1) ||
          (o < outer - 1 && E[p + jump] === 1);
      }
      if (on) {
        if (startI < 0) startI = i;
        run++;
        missed = 0;
      } else if (startI >= 0 && missed < 4 && i < inner) {
        missed++;
      } else {
        if (run >= minLen && solid(o, startI, i - missed) >= 0.8)
          segs.push({ o, from: startI, to: i - missed });
        run = 0;
        missed = 0;
        startI = -1;
      }
    }
  }
  return segs;
}

// Orden de lectura de un conjunto de rectángulos: se parte por una línea horizontal
// que no cruce ninguno (filas, de arriba abajo); si no la hay, por una vertical
// (columnas, de izquierda a derecha o al revés en manga), y se repite en cada trozo.
// Así un panel alto con una cuadrícula al lado se lee bien: alto, y luego la cuadrícula
// fila a fila. Se tolera un pequeño solape (páginas escaneadas torcidas) y, si nada
// corta, se agrupa por filas según el solape vertical.
export function orderRects(rects, rtl) {
  if (rects.length <= 1) return rects.slice();
  const medH = [...rects].map((r) => r.y1 - r.y0).sort((a, b) => a - b)[
    rects.length >> 1
  ];
  const medW = [...rects].map((r) => r.x1 - r.x0).sort((a, b) => a - b)[
    rects.length >> 1
  ];
  const cutAt = (key0, key1, slack) => {
    const sorted = [...rects].sort((a, b) => a[key0] - b[key0]);
    let end = sorted[0][key1];
    for (let i = 1; i < sorted.length; i++) {
      if (sorted[i][key0] >= end - slack)
        return (sorted[i][key0] + Math.min(end, sorted[i][key0])) / 2;
      end = Math.max(end, sorted[i][key1]);
    }
    return null;
  };
  const y = cutAt("y0", "y1", 0.2 * medH);
  if (y !== null) {
    const top = rects.filter((r) => (r.y0 + r.y1) / 2 < y);
    const bottom = rects.filter((r) => (r.y0 + r.y1) / 2 >= y);
    if (top.length && bottom.length)
      return [...orderRects(top, rtl), ...orderRects(bottom, rtl)];
  }
  const x = cutAt("x0", "x1", 0.2 * medW);
  if (x !== null) {
    const left = rects.filter((r) => (r.x0 + r.x1) / 2 < x);
    const right = rects.filter((r) => (r.x0 + r.x1) / 2 >= x);
    if (left.length && right.length) {
      return rtl
        ? [...orderRects(right, rtl), ...orderRects(left, rtl)]
        : [...orderRects(left, rtl), ...orderRects(right, rtl)];
    }
  }
  return readingOrder(rects, rtl);
}

function estimateBackground(d, w, h) {
  const t = Math.max(2, Math.round(Math.min(w, h) * 0.015));
  const bins = new Map();
  const samples = [];
  const sample = (x, y) => {
    const i = (y * w + x) * 4;
    samples.push(i);
    const key = ((d[i] >> 5) << 6) | ((d[i + 1] >> 5) << 3) | (d[i + 2] >> 5);
    let b = bins.get(key);
    if (!b) bins.set(key, (b = [0, 0, 0, 0]));
    b[0]++;
    b[1] += d[i];
    b[2] += d[i + 1];
    b[3] += d[i + 2];
  };
  for (let y = 0; y < t; y++) {
    for (let x = 0; x < w; x += 2) {
      sample(x, y);
      sample(x, h - 1 - y);
    }
  }
  for (let x = 0; x < t; x++) {
    for (let y = t; y < h - t; y += 2) {
      sample(x, y);
      sample(w - 1 - x, y);
    }
  }

  let top = null;
  for (const b of bins.values()) if (!top || b[0] > top[0]) top = b;
  const color = [top[1] / top[0], top[2] / top[0], top[3] / top[0]];

  let near = 0;
  for (const i of samples) {
    if (
      Math.abs(d[i] - color[0]) <= TOL &&
      Math.abs(d[i + 1] - color[1]) <= TOL &&
      Math.abs(d[i + 2] - color[2]) <= TOL
    ) {
      near++;
    }
  }
  return { color, ratio: near / samples.length };
}

function buildMask(d, w, h, [br, bg, bb]) {
  const m = new Uint8Array(w * h);
  for (let p = 0, i = 0; p < m.length; p++, i += 4) {
    if (
      Math.abs(d[i] - br) > TOL ||
      Math.abs(d[i + 1] - bg) > TOL ||
      Math.abs(d[i + 2] - bb) > TOL
    ) {
      m[p] = 1;
    }
  }
  return m;
}

// Quita píxeles de tinta aislados (polvo de escaneo, ruido JPEG).
function removeSpecks(m, w, h) {
  const out = m.slice();
  for (let y = 1; y < h - 1; y++) {
    for (let x = 1, i = y * w + 1; x < w - 1; x++, i++) {
      if (
        m[i] &&
        !(
          m[i - 1] |
          m[i + 1] |
          m[i - w] |
          m[i + w] |
          m[i - w - 1] |
          m[i - w + 1] |
          m[i + w - 1] |
          m[i + w + 1]
        )
      ) {
        out[i] = 0;
      }
    }
  }
  return out;
}

function xyCut(c, x0, y0, x1, y1, depth, out) {
  const { rows, cols } = profiles(c, x0, y0, x1, y1);
  const rowNoise = noiseLevel(x1 - x0);
  const colNoise = noiseLevel(y1 - y0);
  const ry = span(rows, rowNoise);
  const rx = span(cols, colNoise);
  if (!ry || !rx) return;

  const nx0 = x0 + rx[0];
  const nx1 = x0 + rx[1];
  const ny0 = y0 + ry[0];
  const ny1 = y0 + ry[1];

  if (depth < 12) {
    const bands = runs(rows.subarray(ry[0], ry[1]), rowNoise, c.minGapY);
    if (bands.length > 1) {
      for (const [a, b] of bands)
        xyCut(c, nx0, ny0 + a, nx1, ny0 + b, depth + 1, out);
      return;
    }
    const strips = runs(cols.subarray(rx[0], rx[1]), colNoise, c.minGapX);
    if (strips.length > 1) {
      if (c.rtl) strips.reverse();
      for (const [a, b] of strips)
        xyCut(c, nx0 + a, ny0, nx0 + b, ny1, depth + 1, out);
      return;
    }
  }
  out.push({ x0: nx0, y0: ny0, x1: nx1, y1: ny1 });
}

function profiles({ mask, w }, x0, y0, x1, y1) {
  const rows = new Uint32Array(y1 - y0);
  const cols = new Uint32Array(x1 - x0);
  for (let y = y0; y < y1; y++) {
    const o = y * w;
    let n = 0;
    for (let x = x0; x < x1; x++) {
      if (mask[o + x]) {
        n++;
        cols[x - x0]++;
      }
    }
    rows[y - y0] = n;
  }
  return { rows, cols };
}

// Una línea cuenta como "calle" si casi no tiene tinta.
const noiseLevel = (len) => Math.max(1, Math.floor(len * 0.002));

function span(p, noise) {
  let a = -1;
  let b = -1;
  for (let i = 0; i < p.length; i++) {
    if (p[i] > noise) {
      if (a < 0) a = i;
      b = i;
    }
  }
  return a < 0 ? null : [a, b + 1];
}

// Tramos con tinta separados por calles de al menos `minGap` líneas.
function runs(p, noise, minGap) {
  const out = [];
  let start = -1;
  let last = -1;
  for (let i = 0; i < p.length; i++) {
    if (p[i] <= noise) continue;
    if (start < 0) start = i;
    else if (i - last - 1 >= minGap) {
      out.push([start, last + 1]);
      start = i;
    }
    last = i;
  }
  if (start >= 0) out.push([start, last + 1]);
  return out;
}

// Un bloque de texto suelto se ve como franjas finas de altura parecida separadas
// por huecos de una o dos líneas. Una viñeta con marco es una única franja.
function looksLikeText(c, r) {
  const rw = r.x1 - r.x0;
  const rh = r.y1 - r.y0;
  const { rows } = profiles(c, r.x0, r.y0, r.x1, r.y1);
  let ink = 0;
  for (const v of rows) ink += v;
  if (ink / (rw * rh) > 0.45) return false; // demasiado denso para ser texto
  return looksLikeLines(runs(rows, noiseLevel(rw), 1), c.h);
}

function looksLikeLines(bands, pageH) {
  if (bands.length < 3) return false;
  const heights = bands.map(([a, b]) => b - a).sort((a, b) => a - b);
  const med = heights[heights.length >> 1];
  if (med < 2 || med > pageH * 0.035) return false;
  const similar = heights.filter(
    (x) => x >= med * 0.4 && x <= med * 2.2,
  ).length;
  return similar / heights.length >= 0.75;
}

// Para bloques que el XY-cut no separa (calles inclinadas): cada viñeta con marco
// forma su propia mancha conexa.
function splitByComponents(c, r) {
  const { mask, w, h } = c;
  const rw = r.x1 - r.x0;
  const rh = r.y1 - r.y0;
  const labels = new Uint8Array(rw * rh);
  const stack = new Int32Array(rw * rh);
  const minArea = w * h * 0.04;
  const comps = [];

  for (let y = 0; y < rh; y++) {
    for (let x = 0; x < rw; x++) {
      const li = y * rw + x;
      if (labels[li] || !mask[(y + r.y0) * w + x + r.x0]) continue;
      let sp = 0;
      stack[sp++] = li;
      labels[li] = 1;
      let bx0 = x;
      let bx1 = x;
      let by0 = y;
      let by1 = y;
      while (sp) {
        const cur = stack[--sp];
        const cx = cur % rw;
        const cy = (cur / rw) | 0;
        if (cx < bx0) bx0 = cx;
        if (cx > bx1) bx1 = cx;
        if (cy < by0) by0 = cy;
        if (cy > by1) by1 = cy;
        for (let dy = -1; dy <= 1; dy++) {
          const ny = cy + dy;
          if (ny < 0 || ny >= rh) continue;
          for (let dx = -1; dx <= 1; dx++) {
            const nx = cx + dx;
            if (nx < 0 || nx >= rw) continue;
            const ni = ny * rw + nx;
            if (labels[ni] || !mask[(ny + r.y0) * w + nx + r.x0]) continue;
            labels[ni] = 1;
            stack[sp++] = ni;
          }
        }
      }
      const comp = {
        x0: bx0 + r.x0,
        y0: by0 + r.y0,
        x1: bx1 + 1 + r.x0,
        y1: by1 + 1 + r.y0,
      };
      if (area(comp) >= minArea) comps.push(comp);
    }
  }

  // Lo que queda dentro de otra mancha (dibujo dentro de su marco) no es viñeta aparte.
  comps.sort((a, b) => area(b) - area(a));
  const kept = [];
  for (const cp of comps) {
    if (!kept.some((k) => overlap(k, cp) > area(cp) * 0.75)) kept.push(cp);
  }
  if (kept.length < 2) return null;

  for (let i = 0; i < kept.length; i++) {
    for (let j = i + 1; j < kept.length; j++) {
      if (
        overlap(kept[i], kept[j]) >
        0.35 * Math.min(area(kept[i]), area(kept[j]))
      )
        return null;
    }
  }
  const covered = kept.reduce((s, k) => s + area(k), 0);
  if (covered < area(r) * 0.7) return null;

  return readingOrder(kept, c.rtl);
}

function readingOrder(rects, rtl) {
  const rows = [];
  for (const r of [...rects].sort((a, b) => a.y0 - b.y0)) {
    const row = rows[rows.length - 1];
    if (row) {
      const ov = Math.min(row.y1, r.y1) - Math.max(row.y0, r.y0);
      if (ov > 0.5 * Math.min(row.y1 - row.y0, r.y1 - r.y0)) {
        row.items.push(r);
        row.y0 = Math.min(row.y0, r.y0);
        row.y1 = Math.max(row.y1, r.y1);
        continue;
      }
    }
    rows.push({ y0: r.y0, y1: r.y1, items: [r] });
  }
  return rows.flatMap((row) =>
    row.items.sort((a, b) => (rtl ? b.x1 - a.x1 : a.x0 - b.x0) || a.y0 - b.y0),
  );
}

function area(r) {
  return (r.x1 - r.x0) * (r.y1 - r.y0);
}

function overlap(a, b) {
  const ow = Math.min(a.x1, b.x1) - Math.max(a.x0, b.x0);
  const oh = Math.min(a.y1, b.y1) - Math.max(a.y0, b.y0);
  return ow > 0 && oh > 0 ? ow * oh : 0;
}

// Imagen de análisis (RGBA) de aw×ah: se reduce con el navegador al doble de tamaño y
// se promedia cada bloque de 2×2. Así el resultado se parece al filtro de caja que usa el
// banco de pruebas y las calles finas quedan nítidas.
// Mapas de papel a doble resolución a partir de la imagen W×H (2w×2h): `hi` (luminancia
// de papel, 0 en los píxeles con color) y `hiLuma` (luminancia). Con `invert` se calculan
// sobre el negativo de la imagen (páginas de fondo negro).
export function paperMaps(big, W, H, invert = false) {
  const n = W * H;
  const hi = new Uint8Array(n);
  const hiLuma = new Uint8Array(n);
  const ref = paperRef(invert ? invertRGBA(big) : big, W, H);
  for (let p = 0, i = 0; p < n; p++, i += 4) {
    const r = invert ? 255 - big[i] : big[i];
    const g = invert ? 255 - big[i + 1] : big[i + 1];
    const b = invert ? 255 - big[i + 2] : big[i + 2];
    hi[p] = paperLuma(r, g, b, ref);
    hiLuma[p] = 0.299 * r + 0.587 * g + 0.114 * b;
  }
  return { hi, hiLuma };
}

// Oscuridad (luminancia < 100) de las calles entre viñetas vecinas: la línea media del
// hueco entre dos viñetas contiguas (a menos de un 6 % de la página), a lo largo del tramo
// que comparten. Sin ninguna pareja vecina no hay calles que comprobar: 0.
function gapDarkness(rects, data, w, h) {
  let n = 0;
  let dark = 0;
  const near = Math.round(Math.min(w, h) * 0.06);
  const test = (x, y) => {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    const i = (y * w + x) * 4;
    n++;
    if (0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2] < 100) dark++;
  };
  for (const a of rects) {
    for (const b of rects) {
      if (a === b) continue;
      const sy = Math.min(a.y1, b.y1) - Math.max(a.y0, b.y0);
      const sx = Math.min(a.x1, b.x1) - Math.max(a.x0, b.x0);
      const gx = b.x0 - a.x1;
      const gy = b.y0 - a.y1;
      if (gx >= 0 && gx <= near && sy >= Math.min(a.y1 - a.y0, b.y1 - b.y0) * 0.5) {
        const x = Math.round(a.x1 + gx / 2);
        for (let y = Math.max(a.y0, b.y0); y < Math.min(a.y1, b.y1); y++) test(x, y);
      }
      if (gy >= 0 && gy <= near && sx >= Math.min(a.x1 - a.x0, b.x1 - b.x0) * 0.5) {
        const y = Math.round(a.y1 + gy / 2);
        for (let x = Math.max(a.x0, b.x0); x < Math.min(a.x1, b.x1); x++) test(x, y);
      }
    }
  }
  return n ? dark / n : 0;
}

export function invertRGBA(data) {
  const out = new Uint8ClampedArray(data.length);
  for (let i = 0; i < data.length; i += 4) {
    out[i] = 255 - data[i];
    out[i + 1] = 255 - data[i + 1];
    out[i + 2] = 255 - data[i + 2];
    out[i + 3] = 255;
  }
  return out;
}

// Negativo de una página oscura ({ data, hi, hiLuma, color }) o null si la página no es
// oscura. `color`: la página es en color (y no un dibujo en blanco y negro).
export function negativeOf(data, big, w, h) {
  const dark = darkFraction(data);
  if (dark < TUNE.darkColorPage) return null;
  const color = isColorful(data);
  if (!color && dark < TUNE.darkPage) return null;
  return { data: invertRGBA(data), ...paperMaps(big, 2 * w, 2 * h, true), color };
}

// Página en color: bastantes píxeles claros con saturación (un escaneo en blanco y negro
// apenas tiene, aunque el papel tenga un tono).
export function isColorful(data) {
  let lit = 0;
  let sat = 0;
  for (let i = 0; i < data.length; i += 4) {
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];
    if (Math.max(r, g, b) < 60) continue;
    lit++;
    if (Math.max(r, g, b) - Math.min(r, g, b) > 40) sat++;
  }
  return lit > 0 && sat / lit >= 0.15;
}

// Reducción por cajas: cada celda de destino promedia el rango de píxeles de origen que le
// corresponde ([floor(y·S/D), floor((y+1)·S/D)), y al menos un píxel: si la página es más
// pequeña que el destino, se repite el píxel). Se acumula recorriendo el origen (a franjas en
// el Worker, para no cargar la página entera en memoria) y es el mismo cálculo en el banco de
// pruebas, así que los dos analizan exactamente la misma imagen; el filtro de reducción del
// navegador cambia de uno a otro y con marcos finos daba resultados distintos.
function cellsOf(S, D) {
  // Para cada línea de origen, las celdas de destino que la incluyen (una, normalmente; varias
  // si el destino es mayor que el origen).
  const cells = Array.from({ length: S }, () => []);
  for (let d = 0; d < D; d++) {
    const a = Math.floor((d * S) / D);
    const b = Math.max(a + 1, Math.floor(((d + 1) * S) / D));
    for (let p = a; p < b && p < S; p++) cells[p].push(d);
  }
  return cells;
}

export function boxAccumulate(sum, cnt, src, sw, sh, W, H, yFrom = 0, rows = sh) {
  const rowsOf = cellsOf(sh, H);
  const colsOf = cellsOf(sw, W);
  for (let yy = 0; yy < rows; yy++) {
    const ys = rowsOf[yFrom + yy];
    if (!ys.length) continue;
    const row = yy * sw;
    for (let xx = 0; xx < sw; xx++) {
      const xs = colsOf[xx];
      if (!xs.length) continue;
      const i = (row + xx) * 4;
      const r = src[i];
      const g = src[i + 1];
      const b = src[i + 2];
      for (const y of ys) {
        for (const x of xs) {
          const o = (y * W + x) * 3;
          sum[o] += r;
          sum[o + 1] += g;
          sum[o + 2] += b;
          cnt[y * W + x]++;
        }
      }
    }
  }
}

export function boxFinish(sum, cnt, W, H) {
  const out = new Uint8ClampedArray(W * H * 4);
  for (let p = 0, o = 0, q = 0; p < W * H; p++, o += 4, q += 3) {
    const n = cnt[p] || 1;
    out[o] = sum[q] / n;
    out[o + 1] = sum[q + 1] / n;
    out[o + 2] = sum[q + 2] / n;
    out[o + 3] = 255;
  }
  return out;
}

// Imagen a mitad de tamaño promediando bloques 2×2 (no se usa para el análisis: la imagen
// 1× se acumula directamente desde el original, porque las celdas 2× no son todas iguales).
export function halve(big, W, H) {
  const aw = W >> 1;
  const ah = H >> 1;
  const out = new Uint8ClampedArray(aw * ah * 4);
  for (let y = 0; y < ah; y++) {
    const r0 = 2 * y * W;
    const r1 = r0 + W;
    for (let x = 0; x < aw; x++) {
      const a = (r0 + 2 * x) * 4;
      const b = (r1 + 2 * x) * 4;
      const o = (y * aw + x) * 4;
      out[o] = (big[a] + big[a + 4] + big[b] + big[b + 4]) >> 2;
      out[o + 1] = (big[a + 1] + big[a + 5] + big[b + 1] + big[b + 5]) >> 2;
      out[o + 2] = (big[a + 2] + big[a + 6] + big[b + 2] + big[b + 6]) >> 2;
      out[o + 3] = 255;
    }
  }
  return out;
}

function analysisImage(source, aw, ah, env) {
  const sw = source.width;
  const sh = source.height;
  const W = aw * 2;
  const H = ah * 2;
  const sum = new Uint32Array(W * H * 3);
  const cnt = new Uint16Array(W * H);
  const sum1 = new Uint32Array(aw * ah * 3);
  const cnt1 = new Uint16Array(aw * ah);
  // La página original, a franjas de unos 4 Mpx, sin escalar: el navegador solo copia.
  const rows = Math.max(1, Math.min(sh, Math.floor(4e6 / sw)));
  const canvas = env.makeCanvas(sw, rows);
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  for (let y0 = 0; y0 < sh; y0 += rows) {
    const n = Math.min(rows, sh - y0);
    ctx.clearRect(0, 0, sw, rows);
    ctx.drawImage(source, 0, y0, sw, n, 0, 0, sw, n);
    const strip = ctx.getImageData(0, 0, sw, n).data;
    boxAccumulate(sum, cnt, strip, sw, sh, W, H, y0, n);
    boxAccumulate(sum1, cnt1, strip, sw, sh, aw, ah, y0, n);
  }
  const big = boxFinish(sum, cnt, W, H);
  const { hi, hiLuma } = paperMaps(big, W, H);
  const out = boxFinish(sum1, cnt1, aw, ah);
  return { data: out, hi, hiLuma, neg: negativeOf(out, big, aw, ah) };
}

// Procesa una página completa a partir de su imagen original:
//   - la decodifica una sola vez y, si es más grande que `displayMax`, la reduce
//     (un escaneo de 23 Mpx no se puede pintar entero en un móvil);
//   - detecta las viñetas en ambos sentidos de lectura;
//   - genera una miniatura para la lista de páginas.
// `env` aporta lo que cambia entre Worker e hilo principal: makeCanvas(w, h) y
// toBlob(canvas, type, quality).
export async function processPage(
  blob,
  { displayMax = 3000, thumbWidth = 240, wantDisplay = true, detect = "auto" },
  env,
) {
  const full = await createImageBitmap(blob);
  try {
    const iw = full.width;
    const ih = full.height;
    const k = Math.min(1, displayMax / Math.max(iw, ih));
    let source = full;
    let dw = iw;
    let dh = ih;
    let display = null; // null → la imagen original ya sirve para mostrarla
    if (k < 1 && wantDisplay) {
      dw = Math.round(iw * k);
      dh = Math.round(ih * k);
      const canvas = env.makeCanvas(dw, dh);
      canvas.getContext("2d").drawImage(full, 0, 0, dw, dh);
      display = await env.toBlob(canvas, "image/jpeg", 0.88);
      source = canvas;
    }

    // El análisis se hace reduciendo la imagen original en un solo paso y con la mejor
    // calidad de filtrado: las calles finas sobreviven; pasando por la versión de pantalla
    // (recomprimida y reducida dos veces) se emborronan y el detector las pierde.
    const ak = Math.min(1, DETECT_MAX / Math.max(dw, dh));
    const aw = Math.max(8, Math.round(dw * ak));
    const ah = Math.max(8, Math.round(dh * ak));
    const { data, hi, hiLuma, neg } = analysisImage(full, aw, ah, env);
    // El sentido manga solo cambia el orden: se detecta una vez y se ordena de las dos formas.
    const ltr = detectPanels(data, aw, ah, {
      rtl: false,
      style: detect,
      hi,
      hiLuma,
      neg,
    });
    const rtl = { panels: ltr.panelsRtl || ltr.panels };

    const tk = Math.min(1, thumbWidth / dw);
    const tw = Math.max(1, Math.round(dw * tk));
    const th = Math.max(1, Math.round(dh * tk));
    const thumbCanvas = env.makeCanvas(tw, th);
    thumbCanvas.getContext("2d").drawImage(source, 0, 0, tw, th);
    const thumb = await env.toBlob(thumbCanvas, "image/jpeg", 0.8);

    return {
      iw: dw,
      ih: dh,
      kind: ltr.kind,
      style: ltr.style,
      panels: ltr.panels,
      panelsRtl: rtl.panels,
      sure: ltr.sure !== false,
      doubt: ltr.doubt || null,
      alternatives: ltr.alternatives || null,
      display,
      thumb,
    };
  } finally {
    full.close();
  }
}

// ---------- bocadillos ----------

// Bocadillos y cartelas de una viñeta, para la opción «zoom a diálogos» del lector. Recibe
// la viñeta (RGBA w×h, reducida a medio megapíxel o así) y devuelve sus bocadillos en orden
// de lectura, normalizados respecto a la viñeta ({ x, y, w, h } en 0..1). Un bocadillo es una
// zona clara y sin color, compacta (llena al menos casi la mitad de su recuadro), de tamaño
// de bocadillo (ni una mota ni el cielo de fondo) y con texto dentro: tinta en los agujeros
// del claro, es decir, rodeada de claro por todos lados (un dibujo que linda con una zona
// clara no está dentro de ella). `whole`: la imagen es una página entera (una sola viñeta),
// donde los bocadillos son más pequeños respecto a ella.
export function detectBalloons(data, w, h, rtl = false, debug = null, whole = false) {
  const found = findBalloons(data, w, h, whole ? BALLOON_PAGE : BALLOON_PANEL, debug);
  return orderRects(found, rtl).map((r) => ({ x: r.x0 / w, y: r.y0 / h, w: (r.x1 - r.x0) / w, h: (r.y1 - r.y0) / h }));
}

// Bocadillos del recorte { sx, sy, sw, sh } (en píxeles) de `image` (ImageBitmap o <img>),
// reducido a dw×dh para buscarlos (ver `detectBalloons`; `whole`: el recorte es la página
// entera). Normalizados respecto al recorte, en orden de lectura. Sirve en Worker y en el
// hilo principal (`env.makeCanvas`).
export function balloonsOf(image, { sx, sy, sw, sh, dw, dh, rtl = false, whole = false }, env) {
  const canvas = env.makeCanvas(dw, dh);
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  ctx.drawImage(image, sx, sy, sw, sh, 0, 0, dw, dh);
  return detectBalloons(ctx.getImageData(0, 0, dw, dh).data, dw, dh, rtl, null, whole);
}

// Tamaño de un bocadillo respecto a la imagen en la que se busca: en una viñeta (zoom a
// diálogos) o en la página entera (bocadillos que cruzan una calle; zoom a diálogos en una
// página de una sola viñeta).
// `letter`: alto mínimo de una letra respecto al alto de la imagen (en una página entera la
// letra ronda el 1 % del alto; las motas de un cielo o de una nube quedan por debajo).
// `biggest`: parte de los huecos de una cartela de color que puede ser un solo agujero: en la
// imagen JPEG reducida que muestra el lector las letras de una línea se funden en uno (la
// mitad); en la imagen de análisis de las calles, nítida, se deja el valor de siempre, para
// que la detección de viñetas no cambie.
// `text`: además, lo que encierra el claro tiene que parecer texto (ni el ojo de una letra de
// un logo ni marcas sueltas: ver `measure`); en las calles no se mira, por lo mismo.
const BALLOON_PANEL = { area: 0.004, w: 0.05, h: 0.04, maxArea: 0.35, letter: 0, biggest: 0.5, text: true };
const BALLOON_PAGE = { area: 0.0012, w: 0.03, h: 0.015, maxArea: 0.12, letter: 0.005, biggest: 0.5, text: true };
const BALLOON_GUTTER = { ...BALLOON_PAGE, letter: 0, biggest: 0.3, text: false };
// Parte de su fila que ocupan las letras de una línea de texto (ver `measure`).
const COVERAGE_MIN = 0.45;

// Bocadillos de la imagen (recuadros en píxeles, sin ordenar). Con `paint`, marca en esa
// máscara (w×h) los píxeles de cada bocadillo: su fondo y lo que encierra (el texto).
// Tres pasadas:
//   1. Zonas claras y sin color (bocadillos y cartelas blancos) con tinta en sus agujeros.
//   2. Lo mismo sobre el claro «cerrado» (dilatado y erosionado 3 px): un bocadillo cuyas
//      letras grandes parten el interior en trozos. Como el cierre también junta la piel o
//      la ropa clara de un personaje, aquí los agujeros tienen que parecer letras.
//   3. Cartelas de color (una cartela verde, una caja negra de narración): zonas de color
//      uniforme, del que sea, con letras de luminancia contraria. Se segmenta a media
//      resolución (lo caro) y cada candidata se mide en la imagen completa.
// «Parecer letras»: al menos seis agujeros pequeños, de altura parecida (la mitad a 1,6 veces la
// mediana, de al menos 5 px y no más de un cuarto de la cartela) y alineados en pocas filas
// (al menos tres por fila).
function findBalloons(data, w, h, size, debug = null, paint = null) {
  const n = w * h;
  const light = new Uint8Array(n);
  const luma = new Uint8Array(n);
  for (let p = 0, i = 0; p < n; p++, i += 4) {
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];
    const l = 0.299 * r + 0.587 * g + 0.114 * b;
    luma[p] = l;
    if (l >= 200 && Math.max(r, g, b) - Math.min(r, g, b) <= 50) light[p] = 1;
  }
  const q = new Int32Array(n);
  const seen = new Uint8Array(n); // por candidata: 1 zona, 2 exterior, 3 agujero
  const found = [];

  // Mide una candidata: la zona es `isZone(p)` dentro del recuadro; el exterior, lo que no es
  // zona y se alcanza desde el borde del recuadro; los agujeros, el resto. `zoneLum`: luminancia
  // de la zona (las letras contrastan con ella).
  const measure = (X0, Y0, X1, Y1, isZone, zoneLum) => {
    let zone = 0;
    for (let y = Y0; y < Y1; y++)
      for (let p = y * w + X0; p < y * w + X1; p++) {
        seen[p] = isZone(p) ? 1 : 0;
        if (seen[p]) zone++;
      }
    let qh = 0;
    let qt = 0;
    const push = (p) => {
      if (seen[p] === 0) {
        seen[p] = 2;
        q[qt++] = p;
      }
    };
    for (let x = X0; x < X1; x++) {
      push(Y0 * w + x);
      push((Y1 - 1) * w + x);
    }
    for (let y = Y0; y < Y1; y++) {
      push(y * w + X0);
      push(y * w + X1 - 1);
    }
    while (qh < qt) {
      const p = q[qh++];
      const x = p % w;
      const y = (p - x) / w;
      if (x > X0) push(p - 1);
      if (x < X1 - 1) push(p + 1);
      if (y > Y0) push(p - w);
      if (y < Y1 - 1) push(p + w);
    }
    let holes = 0;
    let ink = 0;
    let nHoles = 0;
    let biggest = 0;
    const heights = [];
    const centers = [];
    const glyphs = []; // los agujeros de 3 px o más, con su recuadro y su tinta
    let bigH = 0; // el agujero mayor: alto y ancho de su recuadro
    let bigW = 0;
    for (let y = Y0; y < Y1; y++)
      for (let p0 = y * w + X0; p0 < y * w + X1; p0++) {
        if (seen[p0] !== 0) continue;
        nHoles++;
        let sz = 0;
        let dark = 0;
        let hh = 0;
        let ht = 0;
        let top = h;
        let bottom = 0;
        let left = w;
        let right = 0;
        seen[p0] = 3;
        q[hh++] = p0;
        while (ht < hh) {
          const p = q[ht++];
          sz++;
          if (Math.abs(luma[p] - zoneLum) >= 80) dark++;
          const x = p % w;
          const yy = (p - x) / w;
          if (yy < top) top = yy;
          if (yy > bottom) bottom = yy;
          if (x < left) left = x;
          if (x > right) right = x;
          if (x > X0 && seen[p - 1] === 0) (seen[p - 1] = 3), (q[hh++] = p - 1);
          if (x < X1 - 1 && seen[p + 1] === 0) (seen[p + 1] = 3), (q[hh++] = p + 1);
          if (yy > Y0 && seen[p - w] === 0) (seen[p - w] = 3), (q[hh++] = p - w);
          if (yy < Y1 - 1 && seen[p + w] === 0) (seen[p + w] = 3), (q[hh++] = p + w);
        }
        holes += sz;
        ink += dark;
        if (sz > biggest) {
          biggest = sz;
          bigH = bottom - top + 1;
          bigW = right - left + 1;
        }
        if (sz >= 3) {
          heights.push(bottom - top + 1);
          centers.push((top + bottom) / 2);
          glyphs.push({ sz, dark, top, bottom, left, right, cy: (top + bottom) / 2 });
        }
      }
    const sortedH = [...heights].sort((a, b) => a - b);
    const med = sortedH.length ? sortedH[sortedH.length >> 1] : 0;
    const alike = heights.filter((v) => v >= 0.5 * med && v <= 1.6 * med).length;
    const cys = [...centers].sort((a, b) => a - b);
    const rows = [];
    for (const cy of cys) {
      const row = rows[rows.length - 1];
      if (row && cy - row.sum / row.n <= 0.7 * med) {
        row.sum += cy;
        row.n++;
      } else rows.push({ sum: cy, n: 1 });
    }
    const inRows = rows.filter((r) => r.n >= 2).reduce((t, r) => t + r.n, 0);
    const lettering =
      heights.length >= 6 &&
      alike >= 0.6 * heights.length &&
      med >= Math.max(5, size.letter * h) &&
      med <= 0.25 * (Y1 - Y0) &&
      nHoles <= 250 &&
      rows.length <= 10 &&
      cys.length >= 3 * rows.length &&
      inRows >= 0.7 * cys.length;
    const fill = (zone + holes) / ((X1 - X0) * (Y1 - Y0));
    // El cuerpo blanco de una letra de un logo con su ojo dentro (la O, la D), o un ojo: uno o
    // dos agujeros, ninguno apaisado como lo es una línea o una palabra de texto, y el mayor
    // macizo (llena su recuadro: un ojo o un óvalo; el texto fundido en una mancha a poca
    // resolución conserva huecos y no llega).
    const n3 = glyphs.length;
    const letter = n3 > 0 && n3 <= 2 && bigW < 1.2 * bigH && biggest >= 0.55 * bigH * bigW;
    // Marcas sueltas sobre un claro (un mapa, un cielo con brillos, pelaje) frente a texto: si
    // en ninguna parte del claro hay un bloque de texto, se mira si están desperdigadas (más
    // abajo). Los agujeros se agrupan en
    // filas, y las filas seguidas (a menos de 2,5 letras de alto) en bloques; un bloque es texto
    // si tiene al menos cuatro letras, de tinta (la mitad de sus píxeles) y que ocupan casi toda
    // su fila, y o bien dos filas
    // de al menos dos letras y de anchos parecidos (párrafo), o bien una sola fila que llena el
    // claro (un bocadillo de una línea). Varios bocadillos pegados (un claro con huecos entre
    // sus textos) siguen valiendo: basta con un bloque.
    // Alto de letra para agrupar: la mediana ponderada por área (la de `med`, por número de
    // agujeros, la hunden las motas de una trama o de un papel sucio, que son muchas y mínimas).
    let medA = med;
    {
      const byH = [...glyphs].sort((a, b) => a.bottom - a.top - (b.bottom - b.top));
      let total = 0;
      for (const g of byH) total += g.sz;
      let acc = 0;
      for (const g of byH) {
        acc += g.sz;
        if (acc >= total / 2) {
          medA = g.bottom - g.top + 1;
          break;
        }
      }
    }
    glyphs.sort((a, b) => a.cy - b.cy);
    const lines = [];
    for (const g of glyphs) {
      const row = lines[lines.length - 1];
      if (row && g.cy - row.sum / row.glyphs.length <= 0.7 * medA) {
        row.glyphs.push(g);
        row.sum += g.cy;
      } else lines.push({ glyphs: [g], sum: g.cy });
    }
    const blocks = [];
    for (const row of lines) {
      const c = row.sum / row.glyphs.length;
      const b = blocks[blocks.length - 1];
      if (b && c - b.last <= 2.5 * medA) {
        b.rows.push(row);
        b.last = c;
      } else blocks.push({ rows: [row], last: c });
    }
    const span = (gs) => {
      let x0 = w;
      let y0 = h;
      let x1 = 0;
      let y1 = 0;
      for (const g of gs) {
        if (g.left < x0) x0 = g.left;
        if (g.right + 1 > x1) x1 = g.right + 1;
        if (g.top < y0) y0 = g.top;
        if (g.bottom + 1 > y1) y1 = g.bottom + 1;
      }
      return { bw: x1 - x0, bh: y1 - y0 };
    };
    // Lo que ocupan las letras a lo largo de su fila (una línea de texto, casi todo; marcas
    // sueltas, poco).
    const coverage = (gs) => {
      let sum = 0;
      for (const g of gs) sum += g.right - g.left + 1;
      return Math.min(1, sum / span(gs).bw);
    };
    let covBest = 0; // (depuración) la cobertura del mejor bloque
    const textBlock = blocks.some((b) => {
      const gs = b.rows.flatMap((r) => r.glyphs);
      if (gs.length < 4) return false;
      let area = 0;
      let dark = 0;
      for (const g of gs) {
        area += g.sz;
        dark += g.dark;
      }
      if (dark < 0.5 * area) return false;
      const full = b.rows.filter((r) => r.glyphs.length >= 2);
      if (!full.length) return false;
      const covs = full.map((r) => coverage(r.glyphs)).sort((a, c) => a - c);
      covBest = Math.max(covBest, covs[covs.length >> 1]);
      if (covs[covs.length >> 1] < COVERAGE_MIN) return false;
      if (full.length >= 2) {
        const widths = full.map((r) => span(r.glyphs).bw).sort((a, c) => c - a);
        return widths[1] >= 0.5 * widths[0];
      }
      const { bw, bh } = span(gs);
      return bw >= 0.5 * (X1 - X0) && bh >= 0.3 * (Y1 - Y0);
    });
    // Sin ningún bloque de texto, y además con los agujeros desperdigados (entre todos no
    // llenan ni una sexta parte de su recuadro): texto fundido en manchas a poca resolución
    // sigue llenando el suyo.
    let gArea = 0;
    for (const g of glyphs) gArea += g.sz;
    const all = span(glyphs);
    const dens = all.bw > 0 && all.bh > 0 ? gArea / (all.bw * all.bh) : 0;
    const loose = n3 >= 6 && !textBlock && dens < 0.17;
    return {
      zone,
      holes,
      ink,
      nHoles,
      biggest,
      fill,
      lettering,
      letter,
      loose,
      text: `fill ${fill.toFixed(2)} agujeros ${nHoles} mayor ${holes ? (biggest / holes).toFixed(2) : '-'} alto ${med} parejas ${heights.length ? (alike / heights.length).toFixed(2) : '-'} filas ${rows.length} enfila ${cys.length ? (inRows / cys.length).toFixed(2) : '-'} ink/huecos ${holes ? (ink / holes).toFixed(2) : '-'} mayorHW ${bigH}x${bigW} bloques ${blocks.length}${textBlock ? ' texto' : ''} cob ${covBest.toFixed(2)} dens ${dens.toFixed(2)} altoA ${medA}`,
    };
  };
  const accept = (X0, Y0, X1, Y1, m) => {
    found.push({ x0: X0, y0: Y0, x1: X1, y1: Y1 });
    if (paint) for (let y = Y0; y < Y1; y++) for (let p = y * w + X0; p < y * w + X1; p++) if (seen[p] !== 2) paint[p] = 1;
    void m;
  };
  const sized = (area, bw, bh, maxArea) =>
    !(area < n * size.area || bw < w * size.w || bh < h * size.h) &&
    !(area > n * maxArea || (bw > w * 0.9 && bh > h * 0.5) || (bh > h * 0.9 && bw > w * 0.5) || bw > 8 * bh || bh > 8 * bw);

  // 1 y 2: zonas claras, sin cerrar y cerradas.
  const first = blackComponents(light, w, h);
  const r = 3;
  const grown = dilateBy(light, w, h, r);
  const inv = new Uint8Array(n);
  for (let p = 0; p < n; p++) inv[p] = grown[p] ^ 1;
  const shrunk = dilateBy(inv, w, h, r);
  const closed = new Uint8Array(n);
  for (let p = 0; p < n; p++) closed[p] = shrunk[p] ^ 1;
  const second = blackComponents(closed, w, h);
  for (const [strict, { lab, comps }] of [[false, first], [true, second]]) {
    for (const c of comps) {
      const bw = c.x1 - c.x0;
      const bh = c.y1 - c.y0;
      if (!sized(c.area, bw, bh, strict ? 0.12 : size.maxArea)) continue;
      if (strict && found.some((f) => overlap(f, c))) continue; // ya encontrado sin cerrar
      // (tinta: luminancia de 140 o menos, como siempre)
      const m = measure(c.x0, c.y0, c.x1, c.y1, (p) => lab[p] === c.id, 220);
      const why = [];
      // Compacto: el claro llena al menos algo más de un cuarto de su recuadro.
      if (c.area < 0.28 * bw * bh) why.push('forma');
      if (m.ink < 0.008 * bw * bh || m.ink < 0.3 * m.holes) why.push('texto');
      if (size.text && m.letter) why.push('letra');
      if (size.text && m.loose) why.push('suelto');
      if (strict) {
        // En la máscara cerrada no todo es claro de verdad: un bocadillo sí lo es en su mayor
        // parte, y sus letras forman filas.
        let lit = 0;
        for (let y = c.y0; y < c.y1; y++) for (let p = y * w + c.x0; p < y * w + c.x1; p++) if (lab[p] === c.id && light[p]) lit++;
        if (lit < 0.55 * c.area) why.push('letras');
        if (!m.lettering) why.push('filas');
      }
      if (debug) debug.push(`${strict ? 'cerrado ' : ''}(${(c.x0 / w).toFixed(2)},${(c.y0 / h).toFixed(2)}) ${(bw / w).toFixed(2)}x${(bh / h).toFixed(2)} ${m.text} ${why.join(',') || 'OK'}`);
      if (why.length) continue;
      accept(c.x0, c.y0, c.x1, c.y1, m);
    }
  }

  // 3: cartelas de color, segmentadas a media resolución.
  const hw = w >> 1;
  const hh = h >> 1;
  const half = new Uint8ClampedArray(hw * hh * 4);
  for (let y = 0; y < hh; y++)
    for (let x = 0; x < hw; x++) {
      const a = 4 * (2 * y * w + 2 * x);
      const b = a + 4 * w;
      const o = 4 * (y * hw + x);
      for (let k = 0; k < 3; k++) half[o + k] = (data[a + k] + data[a + 4 + k] + data[b + k] + data[b + 4 + k]) >> 2;
    }
  const DRIFT = 40;
  for (const c of flatZones(half, hw, hh, 30, DRIFT)) {
    const bw = c.x1 - c.x0;
    const bh = c.y1 - c.y0;
    if (c.area < hw * hh * size.area || bw < hw * size.w || bh < hh * size.h) continue;
    if (c.area > hw * hh * Math.min(size.maxArea, 0.1) || bw > 8 * bh || bh > 8 * bw) continue; // una cartela es pequeña
    const lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
    if (lum >= 185) continue; // las claras ya las ven las otras pasadas
    const X0 = Math.max(0, 2 * c.x0 - 1);
    const Y0 = Math.max(0, 2 * c.y0 - 1);
    const X1 = Math.min(w, 2 * c.x1 + 1);
    const Y1 = Math.min(h, 2 * c.y1 + 1);
    const box = { x0: X0, y0: Y0, x1: X1, y1: Y1 };
    if (found.some((f) => overlap(f, box) > 0.5 * Math.min(area(f), area(box)))) continue;
    const T = DRIFT + 12;
    const m = measure(X0, Y0, X1, Y1, (p) => {
      const i = 4 * p;
      return Math.abs(data[i] - c.r) <= T && Math.abs(data[i + 1] - c.g) <= T && Math.abs(data[i + 2] - c.b) <= T;
    }, lum);
    const why = [];
    if (m.fill < 0.6) why.push('forma');
    // (el agujero mayor: una línea entera cuyas letras se funden aún vale, según `size`; un
    // dibujo que llena la zona, no)
    if (m.nHoles < 4 || m.biggest > size.biggest * m.holes || !m.lettering) why.push('filas');
    if (m.ink < 0.008 * (X1 - X0) * (Y1 - Y0) || m.ink < 0.4 * m.holes || m.holes > 0.6 * m.zone) why.push('texto');
    if (debug) debug.push(`plano (${(X0 / w).toFixed(2)},${(Y0 / h).toFixed(2)}) ${((X1 - X0) / w).toFixed(2)}x${((Y1 - Y0) / h).toFixed(2)} lum ${Math.round(lum)} ${m.text} ${why.join(',') || 'OK'}`);
    if (why.length) continue;
    accept(X0, Y0, X1, Y1, m);
  }

  // Recuadros que se pisan: uno solo.
  for (let changed = true; changed; ) {
    changed = false;
    outer: for (let i = 0; i < found.length; i++)
      for (let j = i + 1; j < found.length; j++) {
        if (!overlap(found[i], found[j])) continue;
        const a = found[i];
        const b = found[j];
        found[i] = { x0: Math.min(a.x0, b.x0), y0: Math.min(a.y0, b.y0), x1: Math.max(a.x1, b.x1), y1: Math.max(a.y1, b.y1) };
        found.splice(j, 1);
        changed = true;
        break outer;
      }
  }
  return found;
}

// Zonas de color plano de una imagen RGBA: crece desde cada píxel por vecinos de color casi
// igual (suma de diferencias ≤ `near`) y cerca del color medio de la zona (≤ `drift` por
// canal). Devuelve { area, x0, y0, x1, y1, r, g, b } de cada zona.
function flatZones(data, w, h, near, drift) {
  const n = w * h;
  const lab = new Int32Array(n);
  const q = new Int32Array(n);
  const zones = [];
  for (let s0 = 0; s0 < n; s0++) {
    if (lab[s0]) continue;
    const id = zones.length + 1;
    let sr = 0;
    let sg = 0;
    let sb = 0;
    let area = 0;
    let x0 = w;
    let y0 = h;
    let x1 = 0;
    let y1 = 0;
    let qh = 0;
    let qt = 0;
    lab[s0] = id;
    q[qt++] = s0;
    while (qh < qt) {
      const p = q[qh++];
      const i = 4 * p;
      sr += data[i];
      sg += data[i + 1];
      sb += data[i + 2];
      area++;
      const x = p % w;
      const y = (p - x) / w;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
      const mr = sr / area;
      const mg = sg / area;
      const mb = sb / area;
      const tryPush = (o) => {
        if (lab[o]) return;
        const j = 4 * o;
        if (Math.abs(data[j] - data[i]) + Math.abs(data[j + 1] - data[i + 1]) + Math.abs(data[j + 2] - data[i + 2]) > near) return;
        if (Math.abs(data[j] - mr) > drift || Math.abs(data[j + 1] - mg) > drift || Math.abs(data[j + 2] - mb) > drift) return;
        lab[o] = id;
        q[qt++] = o;
      };
      if (x > 0) tryPush(p - 1);
      if (x < w - 1) tryPush(p + 1);
      if (p >= w) tryPush(p - w);
      if (p < n - w) tryPush(p + w);
    }
    zones.push({ area, x0, y0, x1: x1 + 1, y1: y1 + 1, r: sr / area, g: sg / area, b: sb / area });
  }
  return zones;
}

// ---------- bocadillos que cruzan una calle ----------

// Un bocadillo sobre la calle entre dos viñetas la tapa: su contorno es tinta de lado a lado
// y los métodos de calles claras y arte a sangre ven las dos viñetas como una. Aquí se buscan
// los bocadillos de la página que tocan papel de calle (claro y unido al borde de la página)
// y se devuelve una copia de la página sin ellos (pintados del color del papel, con su
// contorno), y de `hi` si se da. null si no hay ninguno. `balloons`: sus recuadros.
function withoutGutterBalloons(data, w, h, hi) {
  const n = w * h;
  const paint = new Uint8Array(n);
  const found = findBalloons(data, w, h, BALLOON_GUTTER, null, paint);
  if (!found.length) return null;
  // Papel de calle: claro y sin color, unido al borde de la página sin pasar por un bocadillo.
  const light = new Uint8Array(n);
  for (let p = 0, i = 0; p < n; p++, i += 4) {
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];
    if (!paint[p] && 0.299 * r + 0.587 * g + 0.114 * b >= 200 && Math.max(r, g, b) - Math.min(r, g, b) <= 50) light[p] = 1;
  }
  const gutter = new Uint8Array(n);
  const q = new Int32Array(n);
  let qh = 0;
  let qt = 0;
  const push = (p) => {
    if (light[p] && !gutter[p]) (gutter[p] = 1), (q[qt++] = p);
  };
  for (let x = 0; x < w; x++) push(x), push((h - 1) * w + x);
  for (let y = 0; y < h; y++) push(y * w), push(y * w + w - 1);
  while (qh < qt) {
    const p = q[qh++];
    const x = p % w;
    if (x > 0) push(p - 1);
    if (x < w - 1) push(p + 1);
    if (p >= w) push(p - w);
    if (p < n - w) push(p + w);
  }
  // Contorno: lo pintado, engordado unos píxeles (la línea del bocadillo).
  const R = Math.max(2, Math.round(Math.min(w, h) * 0.004));
  const ring = Math.max(4, 2 * R);
  const fat = dilateBy(paint, w, h, R);
  const balloons = [];
  const erase = new Uint8Array(n);
  // En una franja junto a un lado del bocadillo (fuera de su contorno), las filas (lado
  // izquierdo o derecho) o columnas (arriba o abajo) que tienen papel de calle.
  const band = (x0, y0, x1, y1, rows) => {
    x0 = Math.max(0, x0);
    y0 = Math.max(0, y0);
    x1 = Math.min(w, x1);
    y1 = Math.min(h, y1);
    const out = [];
    if (rows) {
      for (let y = y0; y < y1; y++)
        for (let p = y * w + x0; p < y * w + x1; p++)
          if (gutter[p] && !fat[p]) {
            out.push(y);
            break;
          }
    } else {
      for (let x = x0; x < x1; x++)
        for (let y = y0; y < y1; y++)
          if (gutter[y * w + x] && !fat[y * w + x]) {
            out.push(x);
            break;
          }
    }
    return out;
  };
  // La calle que pasa por debajo: a los dos lados, una franja estrecha (de anchura de calle) y
  // a la misma altura (o en la misma columna).
  const maxGutter = Math.round(Math.min(w, h) * 0.035);
  const tol = Math.max(4, Math.round(Math.min(w, h) * 0.012));
  const passes = (a, b) => {
    if (a.length < 2 || b.length < 2 || a.length > maxGutter || b.length > maxGutter) return false;
    if (a[a.length - 1] - a[0] > 2 * maxGutter || b[b.length - 1] - b[0] > 2 * maxGutter) return false;
    return Math.abs((a[0] + a[a.length - 1]) / 2 - (b[0] + b[b.length - 1]) / 2) <= tol;
  };
  for (const b of found) {
    // Cruza una calle si a los dos lados opuestos (izquierda y derecha para una calle
    // horizontal, arriba y abajo para una vertical) le toca la misma calle. Un rótulo pegado
    // al marco por dentro la tiene a lo largo de todo el lado (al otro lado del marco), y uno
    // dentro de la viñeta, en ninguno.
    const o = R + ring;
    const across =
      passes(band(b.x0 - o, b.y0, b.x0 - R, b.y1, true), band(b.x1 + R, b.y0, b.x1 + o, b.y1, true)) ||
      passes(band(b.x0, b.y0 - o, b.x1, b.y0 - R, false), band(b.x0, b.y1 + R, b.x1, b.y1 + o, false));
    if (!across) continue;
    const box = { x0: Math.max(0, b.x0 - R), y0: Math.max(0, b.y0 - R), x1: Math.min(w, b.x1 + R), y1: Math.min(h, b.y1 + R) };
    balloons.push(box);
    for (let y = box.y0; y < box.y1; y++) for (let p = y * w + box.x0; p < y * w + box.x1; p++) if (fat[p]) erase[p] = 1;
  }
  if (!balloons.length) return null;
  const bg = estimateBackground(data, w, h);
  const [pr, pg, pb] = bg.ratio >= 0.5 ? bg.color : [255, 255, 255];
  const out = new Uint8ClampedArray(data);
  for (let p = 0, i = 0; p < n; p++, i += 4)
    if (erase[p]) {
      out[i] = pr;
      out[i + 1] = pg;
      out[i + 2] = pb;
    }
  let hiOut = null;
  if (hi && hi.length === 4 * n) {
    hiOut = new Uint8Array(hi);
    const W = 2 * w;
    const paper = Math.round(0.299 * pr + 0.587 * pg + 0.114 * pb);
    for (let p = 0; p < n; p++) {
      if (!erase[p]) continue;
      const x = p % w;
      const y = (p - x) / w;
      const i = 2 * y * W + 2 * x;
      hiOut[i] = hiOut[i + 1] = hiOut[i + W] = hiOut[i + W + 1] = paper;
    }
  }
  return { data: out, hi: hiOut, balloons };
}

// Máscara engordada `r` píxeles (cuadrado).
function dilateBy(mask, w, h, r) {
  const tmp = new Uint8Array(mask.length);
  const out = new Uint8Array(mask.length);
  for (let y = 0; y < h; y++) {
    let last = -Infinity;
    for (let x = 0; x < w; x++) {
      if (mask[y * w + x]) last = x;
      if (x - last <= r) tmp[y * w + x] = 1;
    }
    last = Infinity;
    for (let x = w - 1; x >= 0; x--) {
      if (mask[y * w + x]) last = x;
      if (last - x <= r) tmp[y * w + x] = 1;
    }
  }
  for (let x = 0; x < w; x++) {
    let last = -Infinity;
    for (let y = 0; y < h; y++) {
      if (tmp[y * w + x]) last = y;
      if (y - last <= r) out[y * w + x] = 1;
    }
    last = Infinity;
    for (let y = h - 1; y >= 0; y--) {
      if (tmp[y * w + x]) last = y;
      if (last - y <= r) out[y * w + x] = 1;
    }
  }
  return out;
}

// Cada bocadillo borrado vuelve a la viñeta que más pisa, que crece para incluirlo entero
// (si ya está entero dentro de una viñeta, se queda así).
function reattachBalloons(rects, balloons) {
  if (rects.length < 2) return rects;
  const out = rects.map((r) => ({ ...r }));
  for (const b of balloons) {
    if (out.some((r) => overlap(r, b) >= 0.95 * area(b))) continue;
    let best = -1;
    let bestA = 0;
    out.forEach((r, i) => {
      const a = overlap(r, b);
      if (a > bestA) (bestA = a), (best = i);
    });
    if (best < 0) continue;
    const r = out[best];
    out[best] = { ...r, x0: Math.min(r.x0, b.x0), y0: Math.min(r.y0, b.y0), x1: Math.max(r.x1, b.x1), y1: Math.max(r.y1, b.y1) };
  }
  return out;
}
