// Shared na pagbasa ng .xlsx para sa uploads (HF ICS ngayon; FINMAREP extractions sa Yugto B).
// Kailangang i-load muna ang SheetJS: js/vendor/xlsx-0.20.3.full.min.js (may SRI; kopyahin ang tag mula sa f_upload.html).
// Mga patakaran (RECON_SPEC §2): Claim Series ay laging text; "-" / blangko = null;
// petsa ay MM/DD/YYYY o Excel date serial; header row ay hinahanap, hindi naka-fix.
(function(){
  const BLANK = /^\s*-?\s*$/;   // "", puro espasyo, o "-"

  function isBlank(v){
    return v === null || v === undefined || (typeof v === 'string' && BLANK.test(v));
  }

  async function readWorkbook(file){
    const buf = await file.arrayBuffer();
    // cellDates:false → ang petsa ay nananatiling serial number (v) + formatted text (w)
    // dense:true → mas tipid sa memory para sa 200k+ row (ws["!data"][r][c])
    // cellNF:true → alam kung date-formatted ang number cell (para MM/DD/YYYY ang text nito)
    return XLSX.read(buf, { type: 'array', dense: true, cellDates: false, cellNF: true, cellStyles: false });
  }

  function range(ws){
    return ws['!ref'] ? XLSX.utils.decode_range(ws['!ref']) : null;
  }

  function cell(ws, r, c){
    const data = ws['!data'];
    if (data) { const row = data[r]; return row ? row[c] : undefined; }
    return ws[XLSX.utils.encode_cell({ r: r, c: c })];
  }

  // Number cell na naka-date format sa Excel?
  function isDateCell(ce){
    return !!(ce && ce.t === 'n' && ce.z && typeof ce.z === 'string' && XLSX.SSF.is_date(ce.z));
  }

  // Text na nakikita sa Excel (w), o ang value bilang text; null kung blangko.
  // Ang date cell ay laging MM/DD/YYYY (hindi ang format ng Excel, hal. "5/28/25").
  function cellText(ce){
    if (!ce) return null;
    if (isDateCell(ce)) {
      const d = XLSX.SSF.parse_date_code(ce.v);
      if (d) return String(d.m).padStart(2, '0') + '/' + String(d.d).padStart(2, '0') + '/' + d.y;
    }
    let v = ce.w !== undefined ? ce.w : (ce.v === undefined || ce.v === null ? null : String(ce.v));
    if (v === null) return null;
    v = String(v).trim();
    return isBlank(v) ? null : v;
  }

  // Claim Series: LAGING text. Kung naka-number ang cell, iwasan ang scientific notation at decimal.
  function seriesText(ce){
    if (!ce) return null;
    if (ce.t === 'n' && typeof ce.v === 'number' && isFinite(ce.v)) {
      // Integer → eksaktong digits; hindi integer → text na nakikita sa Excel (iwas "1.2e+21")
      return Number.isInteger(ce.v) ? BigInt(ce.v).toString() : cellText(ce);
    }
    return cellText(ce);
  }

  // Halaga: number, o null. Tinatanggap ang "1,234.50", "₱ 1,234.50", "(1,234.50)" = negatibo.
  // Lampas sa numeric(14,2) (≥ 1e12) → null (hindi kasya sa DB).
  function amount(ce){
    if (!ce) return null;
    let n;
    if (ce.t === 'n' && typeof ce.v === 'number' && isFinite(ce.v)) {
      n = ce.v;
    } else {
      const t = cellText(ce);
      if (t === null || t.replace(/[^0-9]/g, '') === '') return null;
      // Currency sign lang ang pinapayagang letra (₱, PHP, "P 1,000"); iba pang letra (hal. "K35.8") → hindi halaga
      const s = t.replace(/₱|PHP/gi, '').replace(/^(\s*\(?\s*)P(?=[\s\d])/i, '$1');
      if (/[^0-9.,\-()\s]/.test(s)) return null;
      const neg = /^\(.*\)$/.test(s.trim());
      n = Number(s.replace(/[^0-9.\-]/g, ''));
      if (!isFinite(n)) return null;
      if (neg) n = -Math.abs(n);
    }
    n = Math.round(n * 100) / 100;
    return Math.abs(n) < 1e12 ? n : null;
  }

  // Totoong petsa ba (hal. hindi 2/31) at nasa 1900–2100?
  function validYmd(y, m, d){
    if (y < 1900 || y > 2100 || m < 1 || m > 12 || d < 1) return false;
    const dt = new Date(Date.UTC(y, m - 1, d));
    return dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 && dt.getUTCDate() === d;
  }
  function ymd(y, m, d){ return y + '-' + String(m).padStart(2, '0') + '-' + String(d).padStart(2, '0'); }

  // Petsa → "YYYY-MM-DD" o null. Excel serial (1900 system) o text na MM/DD/YYYY.
  function dateISO(ce){
    if (!ce) return null;
    if (ce.t === 'n' && typeof ce.v === 'number' && ce.v > 0 && ce.v < 2958466) {
      const d = XLSX.SSF.parse_date_code(ce.v);
      if (d && validYmd(d.y, d.m, d.d)) return ymd(d.y, d.m, d.d);
      return null;
    }
    const t = cellText(ce);
    const m = t && t.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/);
    if (!m) return null;
    const mm = +m[1], dd = +m[2], yy = +m[3];
    return validYmd(yy, mm, dd) ? ymd(yy, mm, dd) : null;
  }

  // Hanapin ang header row sa unang `scan` na row: unang row na may cell na tugma sa alinmang pattern;
  // kung wala, ang row na may pinakamaraming text cell. Ibinabalik ang 0-based row index.
  function detectHeaderRow(ws, patterns, scan){
    const rg = range(ws);
    if (!rg) return 0;
    const last = Math.min(rg.e.r, rg.s.r + (scan || 30) - 1);
    let best = rg.s.r, bestCount = -1;
    for (let r = rg.s.r; r <= last; r++) {
      let count = 0;
      for (let c = rg.s.c; c <= rg.e.c; c++) {
        const ce = cell(ws, r, c);
        if (!ce || ce.t === 'n') continue;
        const t = cellText(ce);
        if (!t) continue;
        count++;
        if (patterns && patterns.some(function(p){ return p.test(t); })) return r;
      }
      if (count > bestCount) { best = r; bestCount = count; }
    }
    return best;
  }

  // Mga header ng row: [{col, letter, name}], hindi kasama ang blangko; inaayos ang dobleng pangalan.
  function headers(ws, headerRow){
    const rg = range(ws);
    if (!rg) return [];
    const out = [], seen = Object.create(null);
    for (let c = rg.s.c; c <= rg.e.c; c++) {
      let name = cellText(cell(ws, headerRow, c));
      if (!name) continue;
      name = name.replace(/\s+/g, ' ').trim();
      const letter = XLSX.utils.encode_col(c);
      if (seen[name]) name = name + ' (' + letter + ')';
      seen[name] = true;
      out.push({ col: c, letter: letter, name: name });
    }
    return out;
  }

  window.XlsxImport = {
    isBlank: isBlank, readWorkbook: readWorkbook, range: range, cell: cell,
    cellText: cellText, seriesText: seriesText, amount: amount, dateISO: dateISO,
    detectHeaderRow: detectHeaderRow, headers: headers
  };
})();
