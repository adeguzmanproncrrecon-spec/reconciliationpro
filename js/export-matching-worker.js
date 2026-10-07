// Web Worker: bumubuo ng Matching Report (.xlsx) sa hiwalay na thread — hindi naha-hang ang page (RECON_SPEC §4a).
// - Paunti-unting kinukuha ang data (1,000 rows bawat request, keyset sa item_no) gamit ang JWT ng user → parehong RLS
//   (facility = sariling facility lang; ang Internal Data Only ay PhilHealth lang).
// - Paunti-unting kino-compress (fflate streaming), kaya hindi hawak sa memory ang buong XML.
// - Claim Series ay text (inline string); petsa ay Excel date na mm/dd/yyyy; halaga ay #,##0.00.
// Pumalit sa Edge Function "export-matching-report" (lumampas sa 2s CPU limit ng Edge Functions sa 50k+ rows).
'use strict';

// Self-hosted fflate 0.8.2 (UMD); sinusuri ang SHA-384 bago gamitin (walang integrity attribute ang importScripts)
const FFLATE_URL = 'vendor/fflate-0.8.2.umd.js';
const FFLATE_SHA384 = 'DT0Ls0mO7JmjTnT+oBuMhEJzYJO1zUqzuuMXNdnOmOQRIpN2BgSjvBV/j50NngIT';
const PAGE = 1000;

// [grupo, header, field, uri] — pareho ng Matching Report template
const COLS = [
  ['HEALTH FACILITY DATA', 'ITEM NO.', 'item_no', 'int'],
  ['HEALTH FACILITY DATA', 'PATIENT REFERENCE NO.', 'patient_ref', 'text'],
  ['HEALTH FACILITY DATA', 'FIRST CASE RATE (ICD10/RVS)', 'first_case_rate', 'text'],
  ['HEALTH FACILITY DATA', 'SECOND CASE RATE (ICD10/RVS)', 'second_case_rate', 'text'],
  ['HEALTH FACILITY DATA', 'HEALTH CARE PROFESSIONAL', 'health_professional', 'text'],
  ['CLAIM DETAILS', 'CLAIM SERIES NUMBER', 'claim_series', 'text'],
  ['CLAIM DETAILS', 'CLAIM SERIES (AS IN HF ICS)', 'claim_series_raw', 'text'],
  ['CLAIM DETAILS', "MEMBER'S PIN", 'member_id', 'text'],
  ['CLAIM DETAILS', "PATIENT'S LAST NAME", 'pat_lname', 'text'],
  ['CLAIM DETAILS', "PATIENT'S FIRST NAME", 'pat_fname', 'text'],
  ['CLAIM DETAILS', "PATIENT'S MIDDLE NAME", 'pat_mname', 'text'],
  ['CLAIM DETAILS', "MEMBER'S LAST NAME", 'mem_lname', 'text'],
  ['CLAIM DETAILS', "MEMBER'S FIRST NAME", 'mem_fname', 'text'],
  ['CLAIM DETAILS', "MEMBER'S MIDDLE NAME", 'mem_mname', 'text'],
  ['CLAIM DETAILS', 'ADMISSION DATE', 'date_adm', 'date'],
  ['CLAIM DETAILS', 'DISCHARGE DATE', 'date_dis', 'date'],
  ['CLAIM DETAILS', 'FILING DATE', 'date_filed', 'date'],
  ['CLAIM DETAILS', 'LATEST RECONSIDERED DATE', 'date_recon', 'date'],
  ['CLAIM DETAILS', 'LATEST REFILING DATE', 'last_refiled', 'date'],
  ['CLAIM DETAILS', 'CLAIMS FILING TAT (DISCHARGE TO FILING)', 'filing_tat', 'int'],
  ['CLAIM DETAILS', 'CLAIMS REFILING TAT', 'refiling_tat', 'int'],
  ['STATUS DETAILS', 'STATUS AS OF {rd}', 'status_rd', 'text'],
  ['STATUS DETAILS', 'LAST TRAIL DATE AS OF {rd}', 'trail_date_rd', 'date'],
  ['STATUS DETAILS', 'LAST TRAIL PROCESS AS OF {rd}', 'trail_process_rd', 'text'],
  ['STATUS DETAILS', 'STATUS AS OF {pd}', 'status_pd', 'text'],
  ['STATUS DETAILS', 'STATUS AS OF MATCHING DATE', 'status_md', 'text'],
  ['STATUS DETAILS', 'LAST TRAIL DATE AS OF MATCHING DATE', 'trail_date_md', 'date'],
  ['STATUS DETAILS', 'LAST TRAIL PROCESS AS OF MATCHING DATE', 'trail_process_md', 'text'],
  ['STATUS DETAILS', 'STATUS (G/D/P)', 'raw_status', 'text'],
  ['STATUS DETAILS', 'ALL CASE RATE', 'all_case_rate', 'money'],
  ['PAYMENT DETAILS', 'PHIC PAYMENT PROCESSED DATE', 'latest_check_dt', 'date'],
  ['PAYMENT DETAILS', 'BANK ADVISE DATE', 'bank_advise_date', 'date'],
  ['PAYMENT DETAILS', 'CHECK NO.', 'check_no', 'text'],
  ['PAYMENT DETAILS', 'CHECK DATE', 'check_dt', 'date'],
  ['PAYMENT DETAILS', 'IRM POPULATION?', 'is_irm', 'bool'],
  ['PAYMENT DETAILS', 'DCPM POPULATION?', 'is_dcpm', 'bool'],
  ['PAYMENT DETAILS', 'PAYMENT RECOVERY NO.', 'pr_no', 'text'],
  ['PAYMENT DETAILS', 'OR NO.', 'or_no', 'text'],
  ['PAYMENT DETAILS', 'OR DATE', 'or_date', 'date'],
  ['PAYMENT DETAILS', 'MODE OF PAYMENT', 'mode_of_payment', 'text'],
  ['PAYMENT DETAILS', 'PAYMENT STATUS', 'payment_status', 'text'],
  ['PAYMENT DETAILS', 'TOTAL AMOUNT PAID', 'total_amount_paid', 'money'],
  ['PAYMENT DETAILS', 'ICS AMT (AMOUNT ON HF BOOKS)', 'ics_amount', 'money'],
  ['PAYMENT DETAILS', 'AMOUNT ON PHIC BOOKS', 'amount_on_phic_books', 'money'],
  ['PAYMENT DETAILS', 'AMOUNT USED FOR RECON (AS OF {rd})', 'amount_used_rd', 'money'],
  ['PAYMENT DETAILS', 'AMOUNT USED FOR RECON (AS OF {pd})', 'amount_used_pd', 'money'],
  ['PAYMENT DETAILS', 'AMOUNT USED FOR RECON (AS OF MATCHING DATE)', 'amount_used_md', 'money'],
  ['PAYMENT DETAILS', 'FILED AMOUNT VS. ACTUAL PAYMENT UPGRADE', 'filed_vs_actual', 'money'],
  ['HF ICS RECON', 'RECON AMOUNT', 'recon_amount', 'money'],
  ['HF ICS RECON', 'UPGRADE (DOWNGRADE)', 'upgrade_downgrade', 'money'],
  ['HF ICS RECON', 'ALSO ON ICS OF HO?', 'in_ho_ics', 'bool'],
  ['HF ICS RECON', 'DUPLICATE CHECK', 'is_duplicate', 'bool'],
  ['HF ICS RECON', 'RECONCILING ITEM', 'reconciling_item', 'text'],
  ['ANNEX A (BREAKDOWN)', 'ANNEX A LINE – HEALTH FACILITY', 'annex_hf_line', 'text'],
  ['ANNEX A (BREAKDOWN)', 'ANNEX A LINE – PHILHEALTH', 'annex_ph_line', 'text'],
  ['RTH / DENIED', 'RTH / DENIED CONTROL NUMBER', 'ctrl_no', 'text'],
  ['RTH / DENIED', 'CONTROL NUMBER ISSUANCE DATE', 'ctrl_dt', 'date'],
  ['RTH / DENIED', 'DATE RTH', 'date_rth', 'date'],
  ['RTH / DENIED', 'DATE DENIED', 'date_denied', 'date'],
  ['RTH / DENIED', 'HISTORY EFFECT', 'history_effect', 'text'],
  ['MOTION FOR RECONSIDERATION', 'MR RECEIVED DATE', 'mr_rcv_date', 'date'],
  ['MOTION FOR RECONSIDERATION', 'MR STATUS', 'mr_status', 'text'],
  ['MOTION FOR RECONSIDERATION', 'DECISION RELEASE DATE', 'mr_decision_date', 'date'],
  ['APPEALS', 'PARD RECEIVE DATE', 'pard_rcv_date', 'date'],
  ['APPEALS', 'LATEST PARD STATUS', 'pard_status', 'text'],
];
// Internal Data Only — mula sa recon_hf_internal; PhilHealth lang
const INTERNAL_COLS = [
  ['INTERNAL DATA ONLY', 'TYPE OF CLAIM', 'type_of_claim', 'text'],
  ['INTERNAL DATA ONLY', 'PROCESS/POLICY ISSUE TAGGING (TAGGING DATE)', 'tag_date', 'date'],
  ['INTERNAL DATA ONLY', 'LATEST TAG STATUS', 'tag_status', 'text'],
  ['INTERNAL DATA ONLY', 'PROCESS/ISSUE RESOLUTION (UNTAGGING DATE)', 'untag_date', 'date'],
  ['INTERNAL DATA ONLY', 'LATEST UNTAG STATUS', 'untag_status', 'text'],
  ['INTERNAL DATA ONLY', 'ISSUE', 'issue', 'text'],
  ['INTERNAL DATA ONLY', 'LAST DATE TAG', 'tag_date', 'date'],
  ['INTERNAL DATA ONLY', 'PAYMENT TAT (DAYS, LESS DAYS ON ISSUE)', 'payment_tat', 'int'],
  ['INTERNAL DATA ONLY', 'DAYS ON ISSUE', 'days_on_issue', 'int'],
];
const INTERNAL_FIELDS = 'item_no,tag_date,tag_status,untag_date,untag_status,issue,days_on_issue,payment_tat,type_of_claim';

// ---------- helpers ----------
function esc(v) {
  return v.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, '')
    .replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
function colLetter(c) {
  let s = '', n = c + 1;
  while (n > 0) { const m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = Math.floor((n - m - 1) / 26); }
  return s;
}
function mdy(d) { if (!d) return ''; const p = String(d).slice(0, 10).split('-'); return p[1] + '/' + p[2] + '/' + p[0]; }
function serial(d) { const p = String(d).slice(0, 10).split('-').map(Number); return (Date.UTC(p[0], p[1] - 1, p[2]) - Date.UTC(1899, 11, 30)) / 86400000; }
// Styles: 0 = default, 1 = date mm/dd/yyyy, 2 = pera #,##0.00, 3 = bold (header)
function cell(ref, v, type) {
  if (v === null || v === undefined || v === '') return '';
  if (type === 'date' || type === 'money' || type === 'int') {
    const n = type === 'date' ? serial(v) : Number(v);
    if (!Number.isFinite(n)) return '';
    return '<c r="' + ref + '"' + (type === 'date' ? ' s="1"' : type === 'money' ? ' s="2"' : '') + '><v>' + n + '</v></c>';
  }
  if (type === 'bool') return '<c r="' + ref + '" t="inlineStr"><is><t>' + (v ? 'TRUE' : 'FALSE') + '</t></is></c>';
  return '<c r="' + ref + '" t="inlineStr"><is><t xml:space="preserve">' + esc(String(v)) + '</t></is></c>';
}
function textCell(ref, v, bold) {
  return '<c r="' + ref + '" t="inlineStr"' + (bold ? ' s="3"' : '') + '><is><t xml:space="preserve">' + esc(v) + '</t></is></c>';
}
const STATIC_FILES = {
  '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
  '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
  'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="MATCHING REPORT" sheetId="1" r:id="rId1"/></sheets></workbook>',
  'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
  'xl/styles.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="2"><numFmt numFmtId="164" formatCode="mm/dd/yyyy"/><numFmt numFmtId="165" formatCode="#,##0.00"/></numFmts><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>',
};

async function loadFflate() {
  const res = await fetch(FFLATE_URL, { cache: 'force-cache' });
  if (!res.ok) throw new Error('Could not load the compression library');
  const buf = await res.arrayBuffer();
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-384', buf));
  let bin = ''; digest.forEach(function (b) { bin += String.fromCharCode(b); });
  if (btoa(bin) !== FFLATE_SHA384) throw new Error('The compression library failed its integrity check');
  const url = URL.createObjectURL(new Blob([buf], { type: 'text/javascript' }));
  try { importScripts(url); } finally { URL.revokeObjectURL(url); }
  if (!self.fflate) throw new Error('The compression library did not load');
  return self.fflate;
}

// ---------- PostgREST (RLS ng user) ----------
let API, KEY, TOKEN;
async function rest(path, opts) {
  const res = await fetch(API + '/rest/v1/' + path, Object.assign({
    headers: { apikey: KEY, Authorization: 'Bearer ' + TOKEN, Accept: 'application/json', 'Content-Type': 'application/json' }
  }, opts || {}));
  if (!res.ok) {
    let msg = 'HTTP ' + res.status;
    try { const j = await res.json(); if (j && j.message) msg = j.message; } catch (e) { /* hindi JSON */ }
    throw new Error(msg);
  }
  return res.json();
}

self.onmessage = async function (ev) {
  const job = ev.data;
  API = job.url; KEY = job.key; TOKEN = job.token;
  try {
    const fflate = await loadFflate();
    const m = job.match;
    // PhilHealth user → kasama ang Internal Data Only (RLS rin ang nagbabantay sa recon_hf_internal)
    const isPh = await rest('rpc/app_user_is_philhealth', { method: 'POST', body: '{}' });
    const internal = isPh === true;

    const baseCols = COLS.filter(function (c) { return (c[2] !== 'status_pd' && c[2] !== 'amount_used_pd') || m.prev_report_date; });
    const cols = internal ? baseCols.concat(INTERNAL_COLS) : baseCols;
    const label = function (t) { return t.replace('{rd}', mdy(m.report_date)).replace('{pd}', mdy(m.prev_report_date)); };
    const fields = baseCols.map(function (c) { return c[2]; }).join(',');
    const refs = cols.map(function (c, i) { return colLetter(i); });
    const total = Number(job.total) || 0;

    // Zip (streaming): kinokolekta ang compressed chunks
    const out = [];
    let outBytes = 0, failed = null, done = false;
    const zip = new fflate.Zip(function (err, chunk, final) {
      if (err) { failed = err; return; }
      out.push(chunk); outBytes += chunk.length;
      if (final) done = true;
    });
    Object.keys(STATIC_FILES).forEach(function (name) {
      const f = new fflate.ZipDeflate(name, { level: 6 });
      zip.add(f);
      f.push(fflate.strToU8(STATIC_FILES[name]), true);
    });
    const sheet = new fflate.ZipDeflate('xl/worksheets/sheet1.xml', { level: 6 });
    zip.add(sheet);
    const put = function (s) { sheet.push(fflate.strToU8(s)); };

    put('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">');
    put('<dimension ref="A1:' + colLetter(cols.length - 1) + (6 + total) + '"/>');
    put('<sheetViews><sheetView workbookViewId="0"><pane xSplit="6" ySplit="6" topLeftCell="G7" activePane="bottomRight" state="frozen"/></sheetView></sheetViews>');
    put('<cols>' + cols.map(function (c, i) { return '<col min="' + (i + 1) + '" max="' + (i + 1) + '" width="' + (c[3] === 'text' ? 20 : 15) + '" customWidth="1"/>'; }).join('') + '</cols>');
    put('<sheetData>');
    put('<row r="1">' + textCell('A1', 'NAME OF HEALTH FACILITY', true) + textCell('B1', job.hospital_name || '') + '</row>');
    put('<row r="2">' + textCell('A2', 'REPORT DATE', true) + cell('B2', m.report_date, 'date') + '</row>');
    put('<row r="3">' + textCell('A3', 'MATCHING DATE', true) + cell('B3', m.matching_date, 'date') + '</row>');
    put('<row r="5">' + cols.map(function (c, i) { return (i === 0 || cols[i - 1][0] !== c[0]) ? textCell(refs[i] + '5', c[0], true) : ''; }).join('') + '</row>');
    put('<row r="6">' + cols.map(function (c, i) { return textCell(refs[i] + '6', label(c[1]), true); }).join('') + '</row>');

    let lastItem = 0, r = 7, rows = 0;
    for (;;) {
      const data = await rest('recon_hf_results?select=' + fields + '&match_id=eq.' + encodeURIComponent(m.id) +
                              '&item_no=gt.' + lastItem + '&order=item_no.asc&limit=' + PAGE);
      if (internal && data.length) {
        const ins = await rest('recon_hf_internal?select=' + INTERNAL_FIELDS + '&match_id=eq.' + encodeURIComponent(m.id) +
                               '&item_no=gte.' + data[0].item_no + '&item_no=lte.' + data[data.length - 1].item_no);
        const byItem = new Map(ins.map(function (x) { return [x.item_no, x]; }));
        data.forEach(function (row) { const x = byItem.get(row.item_no); if (x) Object.assign(row, x); });
      }
      let xml = '';
      for (const row of data) {
        xml += '<row r="' + r + '">';
        for (let i = 0; i < cols.length; i++) xml += cell(refs[i] + r, row[cols[i][2]], cols[i][3]);
        xml += '</row>';
        r++;
        lastItem = row.item_no;
      }
      if (xml) put(xml);
      if (failed) throw failed;
      rows += data.length;
      self.postMessage({ type: 'progress', rows: rows, total: total });
      if (data.length < PAGE) break;
    }
    put('</sheetData></worksheet>');
    sheet.push(new Uint8Array(0), true);
    zip.end();
    if (failed) throw failed;
    if (!done) throw new Error('The file could not be completed');
    // Hindi ginagamit ang transfer list: maaaring magkakapareho ang buffer ng mga chunk (subarray)
    self.postMessage({ type: 'done', chunks: out, bytes: outBytes, rows: rows });
  } catch (e) {
    self.postMessage({ type: 'error', message: (e && e.message) || String(e) });
  }
};
