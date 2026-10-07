// Export sa Excel ng Annex A at Matching Report — RECON_SPEC §4a, §4d.
// - Annex A: pinupunan ang mismong template ng PhilHealth (templates/annex-a.xlsx — layout, font, borders, logo) sa
//   eksaktong mga cell; hindi ginagalaw ang iba. Binubuksan at isinasara ang .xlsx gamit ang fflate (self-hosted, may SRI).
// - Matching Report: background worker (js/export-matching-worker.js).
// Kailangan: window.sbUser (js/auth-guard.js), window.SB_URL. RLS ang nagpapasya ng data (facility = sariling facility lang).
(function(){
  const NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
  const XML_NS = 'http://www.w3.org/XML/1998/namespace';
  const TEMPLATE_URL = 'templates/annex-a.xlsx';
  const FFLATE_URL = 'js/vendor/fflate-0.8.2.umd.js';
  const FFLATE_SRI = 'sha384-DT0Ls0mO7JmjTnT+oBuMhEJzYJO1zUqzuuMXNdnOmOQRIpN2BgSjvBV/j50NngIT';
  const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

  function mdy(d){ if (!d) return ''; const p = String(d).slice(0, 10).split('-'); return p[1] + '/' + p[2] + '/' + p[0]; }
  function longDate(d){ if (!d) return ''; const p = String(d).slice(0, 10).split('-').map(Number); return MONTHS[p[1] - 1] + ' ' + p[2] + ', ' + p[0]; }
  function fileDate(d){ return mdy(d).replace(/\//g, '-'); }
  function num(v){ return v === null || v === undefined || v === '' ? null : Number(v); }

  let fflateReady = null;
  function loadFflate(){
    if (window.fflate) return Promise.resolve(window.fflate);
    if (!fflateReady) fflateReady = new Promise(function(resolve, reject){
      const s = document.createElement('script');
      s.src = FFLATE_URL; s.integrity = FFLATE_SRI; s.crossOrigin = 'anonymous';
      s.onload = function(){ window.fflate ? resolve(window.fflate) : reject(new Error('The compression library did not load')); };
      s.onerror = function(){ fflateReady = null; reject(new Error('The compression library did not load')); };
      document.head.append(s);
    });
    return fflateReady;
  }

  function download(bytes, name){
    const url = URL.createObjectURL(new Blob([bytes], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
    const a = document.createElement('a');
    a.href = url; a.download = name;
    document.body.append(a); a.click(); a.remove();
    setTimeout(function(){ URL.revokeObjectURL(url); }, 10000);
  }

  // ---------------- Pagbabago ng sheet XML ----------------
  function colNum(c){ let n = 0; for (let i = 0; i < c.length; i++) n = n * 26 + c.charCodeAt(i) - 64; return n; }
  function splitRef(ref){ const m = /^([A-Z]+)(\d+)$/.exec(ref); return { col: m[1], row: +m[2] }; }

  function Sheet(doc, sst){
    this.doc = doc; this.sst = sst;
    this.data = doc.getElementsByTagNameNS(NS, 'sheetData')[0];
  }
  Sheet.prototype.el = function(name){ return this.doc.createElementNS(NS, name); };
  Sheet.prototype.row = function(r){
    const rows = this.data.getElementsByTagNameNS(NS, 'row');
    for (let i = 0; i < rows.length; i++) {
      const n = +rows[i].getAttribute('r');
      if (n === r) return rows[i];
      if (n > r) { const nr = this.el('row'); nr.setAttribute('r', r); this.data.insertBefore(nr, rows[i]); return nr; }
    }
    const nr = this.el('row'); nr.setAttribute('r', r); this.data.append(nr); return nr;
  };
  Sheet.prototype.cell = function(ref){
    const p = splitRef(ref), row = this.row(p.row), want = colNum(p.col);
    const cs = row.getElementsByTagNameNS(NS, 'c');
    for (let i = 0; i < cs.length; i++) {
      const c = splitRef(cs[i].getAttribute('r')), n = colNum(c.col);
      if (n === want) return cs[i];
      if (n > want) { const nc = this.el('c'); nc.setAttribute('r', ref); row.insertBefore(nc, cs[i]); return nc; }
    }
    const nc = this.el('c'); nc.setAttribute('r', ref); row.append(nc); return nc;
  };
  // Kapag walang style ang cell (wala sa template), kopyahin ang style ng ibang cell (hal. parehong column sa ibang row)
  Sheet.prototype.styleLike = function(ref, fromRef){
    const c = this.cell(ref);
    if (!c.getAttribute('s')) { const s = this.cell(fromRef).getAttribute('s'); if (s) c.setAttribute('s', s); }
  };
  Sheet.prototype.clear = function(ref){
    const c = this.cell(ref);
    while (c.firstChild) c.removeChild(c.firstChild);
    c.removeAttribute('t');
    return c;
  };
  Sheet.prototype.num = function(ref, v){
    const c = this.clear(ref);
    if (v === null || v === undefined || isNaN(v)) return;
    const e = this.el('v'); e.textContent = String(Math.round(Number(v) * 1e6) / 1e6); c.append(e);
  };
  Sheet.prototype.str = function(ref, s){
    const c = this.clear(ref);
    if (s === null || s === undefined || s === '') return;
    c.setAttribute('t', 'inlineStr');
    const is = this.el('is'), t = this.el('t');
    t.setAttributeNS(XML_NS, 'xml:space', 'preserve'); t.textContent = String(s);
    is.append(t); c.append(is);
  };
  // Rich text: kinokopya ang <si> ng template (font, bold, italic) at pinapalitan ang text ng bawat run gamit ang fn
  Sheet.prototype.rich = function(ref, si, fn){
    const c = this.clear(ref);
    const is = this.el('is');
    Array.from(si.childNodes).forEach(function(n){ is.append(this.doc.importNode(n, true)); }, this);
    Array.from(is.getElementsByTagNameNS(NS, 't')).forEach(function(t){
      t.textContent = fn(t.textContent); t.setAttributeNS(XML_NS, 'xml:space', 'preserve');
    });
    c.setAttribute('t', 'inlineStr'); c.append(is);
  };
  // Shared string na nasa cell ng template (para sa rich text)
  Sheet.prototype.siOf = function(ref){
    const c = this.cell(ref), v = c.getElementsByTagNameNS(NS, 'v')[0];
    return c.getAttribute('t') === 's' && v ? this.sst[+v.textContent] : null;
  };

  // Magsingit ng mga bagong row pagkatapos ng row `after` (kopya ng style ng row na iyon); inuusog ang lahat ng ref sa ibaba
  function insertRows(sh, wbDoc, after, count){
    if (!count) return;
    const shift = function(ref){
      return ref.replace(/(\$?)([A-Z]+)(\$?)(\d+)/g, function(m, d1, c, d2, r){ return d1 + c + d2 + (+r > after ? +r + count : r); });
    };
    const rows = Array.from(sh.data.getElementsByTagNameNS(NS, 'row'));
    rows.slice().reverse().forEach(function(row){
      const r = +row.getAttribute('r');
      if (r <= after) return;
      row.setAttribute('r', r + count);
      Array.from(row.getElementsByTagNameNS(NS, 'c')).forEach(function(c){ c.setAttribute('r', shift(c.getAttribute('r'))); });
    });
    Array.from(sh.doc.getElementsByTagNameNS(NS, 'mergeCell')).forEach(function(m){ m.setAttribute('ref', shift(m.getAttribute('ref'))); });
    Array.from(sh.doc.getElementsByTagNameNS(NS, 'dimension')).forEach(function(d){ d.setAttribute('ref', shift(d.getAttribute('ref'))); });
    const rb = sh.doc.getElementsByTagNameNS(NS, 'rowBreaks')[0];
    if (rb) Array.from(rb.getElementsByTagNameNS(NS, 'brk')).forEach(function(b){ if (+b.getAttribute('id') >= after) b.setAttribute('id', +b.getAttribute('id') + count); });
    Array.from(wbDoc.getElementsByTagNameNS(NS, 'definedName')).forEach(function(d){ d.textContent = shift(d.textContent); });
    // Mga bagong row: kopya ng row `after`, walang laman (walang merge, para hindi maputol ang mahabang label)
    const tpl = rows.find(function(x){ return +x.getAttribute('r') === after; });
    const mc = sh.doc.getElementsByTagNameNS(NS, 'mergeCells')[0];
    for (let i = 1; i <= count; i++) {
      const nr = tpl.cloneNode(true), r = after + i;
      nr.setAttribute('r', r);
      Array.from(nr.getElementsByTagNameNS(NS, 'c')).forEach(function(c){
        c.setAttribute('r', splitRef(c.getAttribute('r')).col + r);
        while (c.firstChild) c.removeChild(c.firstChild);
        c.removeAttribute('t');
      });
      tpl.parentNode.insertBefore(nr, sh.data.getElementsByTagNameNS(NS, 'row')[Array.from(sh.data.getElementsByTagNameNS(NS, 'row')).indexOf(tpl) + i] || null);
    }
    if (mc) mc.setAttribute('count', mc.getElementsByTagNameNS(NS, 'mergeCell').length);
  }

  // ---------------- Annex A (template) ----------------
  // Mga row ng template: Reconciliation of balances (G = Health Facility, J = PhilHealth)
  const REC_ROWS = {
    'Paid Claims': 19, 'Denied Claims': 20, 'RTH Claims': 21, 'Unmatched Claims – Duplicate': 22, 'Unmatched': 23,
    'In Process – Not on HF ICS': 24, 'In Process – Not on HO ICS': 25, 'Payment in Transit (ABP – Processed)': 26,
    'For Archiving – Recon Exception': 27, 'For Archiving – Unmatched (Deleted) – Not on NClaims': 28,
    'Net Upgrade (Downgrade) – HF ICS': 29
  };
  // Mga linyang wala sa template — idinadagdag na row kapag may laman (para manatiling balanse ang PhilHealth column)
  const EXTRA_AFTER_23 = ['Duplicate on HO ICS', 'Invalid Claim Series – HO ICS'];
  const EXTRA_AFTER_29 = ['Net Upgrade (Downgrade) – PHIC books'];
  // Summary of Status: row bawat status; UNMAPPED ay kasama ng IN PROCESS (RECON_SPEC §6 #27)
  const HF_ROWS = { 'PAID': 14, 'APPROVED FOR PAYMENT': 15, 'DENIED': 16, 'RTH': 17, 'IN PROCESS': 18, 'UNMAPPED': 18, 'UNMATCHED': 19, 'DUPLICATE': 20 };
  const HO_ROWS = { 'PAID': 14, 'APPROVED FOR PAYMENT': 15, 'DENIED': 16, 'RTH': 17, 'IN PROCESS': 18, 'UNMAPPED': 18, 'FOR ARCHIVING': 19 };
  const HF_COLS = { rd: ['L', 'M', 'N'], pd: ['O', 'P', 'Q'], md: ['R', 'S', 'T'] };
  const HO_COLS = { rd: ['V', 'W', 'X'], pd: ['Y', 'Z', 'AA'], md: ['AB', 'AC', 'AD'] };

  function fillStatus(sh, sec, rowsMap, cols, cuts, spareRow, labelCol, upgrade){
    const extra = [];
    (sec.rows || []).forEach(function(r){ if (!(r.status in rowsMap) && !extra.includes(r.status)) extra.push(r.status); });
    // Status na walang sariling row sa template → sa bakanteng row (ICS side, row 20)
    const map = Object.assign({}, rowsMap);
    if (extra.length && spareRow) {
      extra.forEach(function(s){ map[s] = spareRow; });
      sh.styleLike(labelCol + spareRow, labelCol + 14); sh.str(labelCol + spareRow, extra.join(' / '));
    }
    const allRows = Array.from(new Set(Object.values(map)));
    Object.keys(cols).forEach(function(k){
      const c = cols[k], on = cuts[k];
      const tot = (sec.totals || []).find(function(t){ return t.cutoff === k; });
      const totAmt = tot ? Number(tot.amount) : 0;
      allRows.forEach(function(row){
        if (!on) { sh.clear(c[0] + row); sh.clear(c[1] + row); sh.clear(c[2] + row); return; }
        let n = 0, amt = 0;
        (sec.rows || []).forEach(function(r){ if (r.cutoff === k && map[r.status] === row) { n += Number(r.claims); amt += Number(r.amount); } });
        c.forEach(function(col){
          // Bakanteng row ng template (walang tamang format) → laging style ng row 14
          if (row === spareRow) sh.cell(col + row).removeAttribute('s');
          sh.styleLike(col + row, col + 14);
        });
        sh.num(c[0] + row, n); sh.num(c[1] + row, amt); sh.num(c[2] + row, totAmt ? amt / totAmt : null);
      });
      // Upgrade (downgrade) — row 21 (HF side lang)
      sh.clear(c[0] + 21); sh.clear(c[2] + 21);
      if (upgrade && on) { sh.styleLike(c[1] + 21, c[1] + 14); sh.num(c[1] + 21, num(upgrade[k])); } else sh.clear(c[1] + 21);
      // TOTAL — row 22
      if (on && tot) { sh.num(c[0] + 22, Number(tot.claims)); sh.num(c[1] + 22, totAmt); sh.num(c[2] + 22, totAmt ? 1 : null); }
      else { sh.clear(c[0] + 22); sh.clear(c[1] + 22); sh.clear(c[2] + 22); }
    });
  }

  // Internal: ipakita ang Summary of Status of ICS Claims (U–AD), kapareho ng lapad ng gitnang bahagi (K–T);
  // ang "as of" nakaraang report date (Y–AA) ay nakatago gaya ng O–Q sa gitna
  function showIcsColumns(sh){
    const cols = sh.doc.getElementsByTagNameNS(NS, 'cols')[0];
    if (!cols) return;
    Array.from(cols.getElementsByTagNameNS(NS, 'col')).forEach(function(c){ if (+c.getAttribute('min') >= 21) c.remove(); });
    const width = function(n){
      const c = Array.from(cols.getElementsByTagNameNS(NS, 'col')).find(function(x){ return +x.getAttribute('min') <= n && +x.getAttribute('max') >= n; });
      return c ? c.getAttribute('width') : '14.4259259259259';
    };
    // U..AD (21..30) ← K..T (11..20)
    for (let n = 21; n <= 30; n++) {
      const c = sh.el('col');
      c.setAttribute('min', n); c.setAttribute('max', n); c.setAttribute('width', width(n - 10)); c.setAttribute('customWidth', '1');
      if (n >= 25 && n <= 27) c.setAttribute('hidden', '1');
      cols.append(c);
    }
    const rest = sh.el('col');
    rest.setAttribute('min', 31); rest.setAttribute('max', 16384); rest.setAttribute('width', '14.4259259259259');
    rest.setAttribute('hidden', '1'); rest.setAttribute('customWidth', '1');
    cols.append(rest);
  }

  function fillAnnex(sh, wbDoc, a){
    const hd = a.header, me = window.sbUser || {};
    const rec = a.reconciliation || { lines: [] };
    const cuts = { rd: hd.report_date, pd: hd.prev_report_date, md: hd.matching_date };
    const asOf = function(d){ return d ? 'as of ' + longDate(d) : ''; };

    // Mga rich text na kailangang basahin bago magsingit ng row
    const siCov = sh.siOf('A9'), siFoot = sh.siOf('A32');

    // Mga linyang wala sa template (may laman lang)
    const lineOf = function(l){ return rec.lines.find(function(x){ return x.label === l; }); };
    const hasVal = function(x){ return x && ((x.hf !== null && Number(x.hf) !== 0) || (x.ph !== null && Number(x.ph) !== 0)); };
    const ex29 = EXTRA_AFTER_29.filter(function(l){ return hasVal(lineOf(l)); });
    const ex23 = EXTRA_AFTER_23.filter(function(l){ return hasVal(lineOf(l)); });
    insertRows(sh, wbDoc, 29, ex29.length);
    insertRows(sh, wbDoc, 23, ex23.length);
    const e1 = ex23.length, e2 = ex29.length;
    const rowOf = function(label){
      if (ex23.includes(label)) return 24 + ex23.indexOf(label);
      if (ex29.includes(label)) return 30 + e1 + ex29.indexOf(label);
      const r = REC_ROWS[label];
      return r === undefined ? null : (r >= 24 ? r + e1 : r);
    };
    const below = function(r){ return r + e1 + e2; };   // mga row ng template mula row 30 pababa

    // ---- Header ----
    sh.str('A7', asOf(hd.report_date));
    const covText = 'Received claims for the period ' + longDate(a.coverage.received_start) + ' to ' + longDate(a.coverage.received_end);
    const covFn = function(t){ return /^Received claims/.test(t) ? covText : t; };
    if (siCov) { sh.rich('A9', siCov, covFn); sh.rich('K9', siCov, covFn); }
    else { sh.str('A9', 'Coverage: ' + covText); sh.str('K9', 'Coverage: ' + covText); }
    sh.str('D12', hd.hospital_name); sh.str('D13', hd.accreditation_no); sh.str('D14', hd.branch || '');
    sh.str('L12', asOf(cuts.rd)); sh.str('O12', asOf(cuts.pd)); sh.str('R12', asOf(cuts.md));
    // ---- Summary of Status (HF: gitna; ICS/HO: kanan — internal lang) ----
    fillStatus(sh, a.hf_status || {}, HF_ROWS, HF_COLS, cuts, null, 'K', (a.hf_status || {}).upgrade);
    if (a.version === 'internal') {
      sh.str('U9', 'Coverage: Recorded ICS claims from HO as of ' + longDate(hd.report_date));
      sh.str('V12', asOf(cuts.rd)); sh.str('Y12', asOf(cuts.pd)); sh.str('AB12', asOf(cuts.md));
      fillStatus(sh, a.ho_status || {}, HO_ROWS, HO_COLS, cuts, 20, 'U', null);
      showIcsColumns(sh);
    } else {
      ['U9', 'V12', 'Y12', 'AB12'].forEach(function(r){ sh.clear(r); });   // lumang petsa ng template
    }
    // Facility version: walang laman ang kanang side at nananatiling nakatago (walang data ng PhilHealth books sa file)

    // ---- Reconciliation of balances (amount; ang bilang ng claims ay nasa app at sa Matching Report) ----
    sh.num('G17', num(rec.unreconciled.hf)); sh.num('J17', num(rec.unreconciled.ph));
    Object.keys(REC_ROWS).forEach(function(l){ const r = rowOf(l); sh.clear('G' + r); sh.clear('J' + r); });
    ex23.concat(ex29).forEach(function(l){ sh.str('B' + rowOf(l), l.replace(/–/g, '-')); });   // "-" gaya ng ibang label sa template
    rec.lines.forEach(function(l){
      const r = rowOf(l.label);
      if (r === null) throw new Error('Annex A line "' + l.label + '" has no row in the template');
      sh.num('G' + r, num(l.hf)); sh.num('J' + r, num(l.ph));
    });
    const r30 = below(30);
    sh.num('G' + r30, num(rec.reconciled.hf)); sh.num('J' + r30, num(rec.reconciled.ph));
    sh.num('K' + r30, num((rec.difference || {}).amount));

    // ---- Footnote (petsa ng matching at report date) ----
    if (siFoot) sh.rich('A' + below(32), siFoot, function(t){
      return t.replace(/matched on \d{1,2}\/\d{1,2}\/\d{4}/, 'matched on ' + mdy(hd.matching_date))
              .replace(/as of [A-Za-z]+ \d{1,2}, \d{4} reporting date/, 'as of ' + longDate(hd.report_date) + ' reporting date');
    });

    // ---- Prepared by = nag-export; blangko ang PANGALAN sa Reviewed / Certified Correct / Acknowledged;
    //      ang mga posisyon ay mula sa System Settings (app_settings, 0033) ----
    sh.str('A' + below(41), me.name || ''); sh.str('A' + below(42), me.roleLabel || '');
    const pos = a.positions || {};   // kapag hindi nabasa ang settings, iiwan ang nasa template
    if ('annex_reviewed_position' in pos) { sh.styleLike('F' + below(42), 'A' + below(42)); sh.str('F' + below(42), pos.annex_reviewed_position); }
    if ('annex_certified_position' in pos) sh.str('A' + below(48), pos.annex_certified_position);
    if ('annex_acknowledged_position' in pos) { sh.styleLike('F' + below(48), 'A' + below(48)); sh.str('F' + below(48), pos.annex_acknowledged_position); }
  }

  // Hindi gumagana ang template fetch at Web Worker kapag file:// ang page
  function requireHttp(){
    if (location.protocol === 'file:') {
      throw new Error('Excel export needs the system to be opened through a web address, not as a file. ' +
                      'Start tools/serve.cmd and open http://localhost:8080/login.html.');
    }
  }

  async function exportAnnex(matchId, internal){
    requireHttp();
    const [{ data, error }, fl, res, st] = await Promise.all([
      sb.rpc('annex_a', { p_match: matchId, p_internal: !!internal }),
      loadFflate(),
      fetch(TEMPLATE_URL, { cache: 'no-cache' }),
      sb.from('app_settings').select('key, value').like('key', 'annex_%')
    ]);
    if (error) throw error;
    data.positions = {};
    (st && st.data || []).forEach(function(s){ data.positions[s.key] = s.value; });
    if (!res.ok) throw new Error('Could not load the Annex A template (' + res.status + ')');
    const files = fl.unzipSync(new Uint8Array(await res.arrayBuffer()));
    const parse = function(name){
      const d = new DOMParser().parseFromString(fl.strFromU8(files[name]), 'application/xml');
      if (d.getElementsByTagName('parsererror').length) throw new Error('The Annex A template is damaged (' + name + ')');
      return d;
    };
    const sheetDoc = parse('xl/worksheets/sheet1.xml'), wbDoc = parse('xl/workbook.xml');
    const sst = files['xl/sharedStrings.xml'] ? Array.from(parse('xl/sharedStrings.xml').getElementsByTagNameNS(NS, 'si')) : [];
    fillAnnex(new Sheet(sheetDoc, sst), wbDoc, data);
    const ser = new XMLSerializer();
    files['xl/worksheets/sheet1.xml'] = fl.strToU8(ser.serializeToString(sheetDoc));
    files['xl/workbook.xml'] = fl.strToU8(ser.serializeToString(wbDoc));
    const hd = data.header;
    download(fl.zipSync(files, { level: 6 }), 'ANNEX A - ' + hd.accreditation_no + ' - AS OF ' + fileDate(hd.report_date) +
             (data.version === 'internal' ? ' - INTERNAL' : '') + '.xlsx');
    logExport(matchId, 'annex_a', data.version === 'internal' ? 'internal' : 'facility');
  }

  // System Logs (0032): itala ang export; hindi pinipigilan ng error ang download
  function logExport(matchId, kind, version){
    sb.rpc('log_export', { p_match: matchId, p_kind: kind, p_version: version })
      .then(function(r){ if (r.error) console.warn('log_export:', r.error.message); });
  }

  // ---------------- Matching Report (background worker) ----------------
  // js/export-matching-worker.js: paunti-unting kinukuha ang rows (JWT ng user → parehong RLS) at binubuo ang .xlsx sa
  // hiwalay na thread, kaya hindi naha-hang ang page. (Ang Edge Function ay lumampas sa 2s CPU limit sa 50k+ rows.)
  // match: { id, report_date, prev_report_date, matching_date, summary, hospital_name, accreditation_no }
  // onProgress(rowsNaNagawa, kabuuangRows)
  async function exportMatchingReport(match, onProgress){
    requireHttp();
    const { data: { session } } = await sb.auth.getSession();
    if (!session) throw new Error('Not signed in');
    const total = match.summary && match.summary.hf_rows !== undefined ? Number(match.summary.hf_rows) : 0;
    const result = await new Promise(function(resolve, reject){
      const w = new Worker('js/export-matching-worker.js');
      w.onmessage = function(ev){
        const d = ev.data;
        if (d.type === 'progress') { if (onProgress) onProgress(d.rows, d.total); }
        else if (d.type === 'done') { w.terminate(); resolve(d); }
        else if (d.type === 'error') { w.terminate(); reject(new Error(d.message)); }
      };
      w.onerror = function(e){ w.terminate(); reject(new Error(e.message || 'Export failed')); };
      w.postMessage({
        url: window.SB_URL, key: window.SB_PUBLISHABLE_KEY, token: session.access_token, total: total,
        hospital_name: match.hospital_name || '',
        match: { id: match.id, report_date: match.report_date, prev_report_date: match.prev_report_date, matching_date: match.matching_date }
      });
    });
    const name = 'MATCHING REPORT - ' + (match.accreditation_no || '') + ' - AS OF ' + fileDate(match.report_date) + '.xlsx';
    const url = URL.createObjectURL(new Blob(result.chunks, { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
    const a = document.createElement('a');
    a.href = url; a.download = name;
    document.body.append(a); a.click(); a.remove();
    setTimeout(function(){ URL.revokeObjectURL(url); }, 10000);
    // Ang worker ay naglalagay ng internal columns kapag PhilHealth ang user
    const role = (window.sbUser || {}).role;
    logExport(match.id, 'matching_report', role === 'facility' || role === 'facility_admin' ? 'facility' : 'internal');
    return result.bytes;
  }

  window.ReconExport = { exportAnnex: exportAnnex, exportMatchingReport: exportMatchingReport };
})();
