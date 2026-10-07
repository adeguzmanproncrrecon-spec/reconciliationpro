// Pagpapakita ng Annex A mula sa resulta ng annex_a() RPC (RECON_SPEC §4d).
// Ginagamit ng a_reconciliation.html (internal/facility) at f_reports.html (facility lang).
// Lahat ng data ay ipinapakita gamit ang textContent (rule 8). Petsa: MM/DD/YYYY.
// Kailangan ng page ang CSS classes: .table-wrap, .num, .muted, .bad, .msg, .status, .s-<STATUS>.
(function(){
  function h(tag, attrs, kids){
    const n = document.createElement(tag);
    Object.entries(attrs || {}).forEach(function([k, v]){
      if (k === 'class') n.className = v; else if (k === 'text') n.textContent = v; else n.setAttribute(k, v);
    });
    (kids || []).forEach(function(c){ if (c !== null && c !== undefined) n.append(c); });
    return n;
  }
  function td(t, cls){ return h('td', { class: cls || '', text: t === null || t === undefined ? '—' : String(t) }); }
  function fmtDate(d){ if (!d) return '—'; const p = String(d).slice(0, 10).split('-'); return p[1] + '/' + p[2] + '/' + p[0]; }
  function money(n){
    return n === null || n === undefined ? '—'
      : Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }
  function badge(s){ return h('span', { class: 'status s-' + String(s || '').split(' ')[0], text: s || '—' }); }

  // a = resulta ng annex_a(); box = lalagyan (lilinisin muna)
  function render(box, a){
    box.replaceChildren();
    const hd = a.header;
    const cuts = [['rd', 'as of ' + fmtDate(hd.report_date)], ['pd', 'as of ' + fmtDate(hd.prev_report_date)],
                  ['md', 'as of ' + fmtDate(hd.matching_date)]]
      .filter(function(c){ return c[0] !== 'pd' || hd.prev_report_date; });

    box.append(
      h('h3', { text: 'ANNEX A: PhilHealth eClaims Reconciliation Report' + (a.version === 'internal' ? ' (INTERNAL)' : '') }),
      h('p', { class: 'sub', text: hd.hospital_name + ' · ' + hd.accreditation_no + ' · ' + (hd.branch || '') +
        ' · as of ' + fmtDate(hd.report_date) + ' · Coverage: received claims ' + fmtDate(a.coverage.received_start) +
        ' to ' + fmtDate(a.coverage.received_end) }));

    function statusTable(title, sec, extra){
      const head = [h('th', { text: 'Status' })];
      cuts.forEach(function(c){
        head.push(h('th', { class: 'num', text: 'Claims ' + c[1] }), h('th', { class: 'num', text: 'Amount' }), h('th', { class: 'num', text: '%' }));
      });
      const body = h('tbody');
      const labels = [];
      (sec.rows || []).forEach(function(r){ if (!labels.includes(r.status)) labels.push(r.status); });
      labels.forEach(function(s){
        const cells = [h('td', {}, [badge(s)])];
        cuts.forEach(function(c){
          const r = sec.rows.find(function(x){ return x.cutoff === c[0] && x.status === s; });
          cells.push(td(r ? Number(r.claims).toLocaleString() : '0', 'num'), td(r ? money(r.amount) : '—', 'num'),
                     td(r && r.pct !== null ? r.pct + '%' : '—', 'num'));
        });
        body.append(h('tr', {}, cells));
      });
      if (extra) body.append(extra);
      const tcells = [h('td', {}, [h('b', { text: 'TOTAL' })])];
      cuts.forEach(function(c){
        const t = (sec.totals || []).find(function(x){ return x.cutoff === c[0]; });
        tcells.push(td(t ? Number(t.claims).toLocaleString() : '0', 'num'), td(t ? money(t.amount) : '—', 'num'), td('100%', 'num'));
      });
      body.append(h('tr', {}, tcells));
      return [h('h3', { style: 'margin-top:16px', text: title }),
              h('div', { class: 'table-wrap' }, [h('table', {}, [h('thead', {}, [h('tr', {}, head)]), body])])];
    }

    const up = a.hf_status.upgrade || {};
    const upRow = h('tr', {}, [td('UPGRADE (DOWNGRADE)')].concat(cuts.flatMap(function(c){
      return [td(''), td(money(up[c[0]]), 'num'), td('')];
    })));
    statusTable('Summary of Status of Received eClaims (HF side)', a.hf_status, upRow).forEach(function(n){ box.append(n); });
    const nyf = a.hf_status.not_yet_filed || {};
    if (cuts.some(function(c){ return nyf[c[0]]; })) {
      box.append(h('div', { class: 'muted', text: 'Not yet filed (excluded from totals): ' +
        cuts.map(function(c){ return c[1] + ' = ' + (nyf[c[0]] || 0); }).join(' · ') }));
    }
    statusTable('Summary of Status of ICS Claims (PhilHealth side)', a.ho_status).forEach(function(n){ box.append(n); });

    // Reconciliation of balances: count at amount bawat side; ang breakdown ay ang "Annex A line" sa Matching Report / HO ICS Recon
    const rec = a.reconciliation, rb = h('tbody');
    function cnt(n){ return n === null || n === undefined ? '' : Number(n).toLocaleString(); }
    function amt(n){ return n === null || n === undefined ? '' : money(n); }
    function row(label, x, bold){
      return h('tr', {}, [bold ? h('td', {}, [h('b', { text: label })]) : td('   ' + label),
        td(cnt(x.hf_n), 'num'), td(amt(x.hf), 'num'), td(cnt(x.ph_n), 'num'), td(amt(x.ph), 'num')]);
    }
    rb.append(row('UNRECONCILED BALANCE', rec.unreconciled, true));
    rb.append(h('tr', {}, [h('td', { colspan: '5', class: 'muted', text: 'Add (Less) Reconciling Items' })]));
    rec.lines.forEach(function(l){ rb.append(row(l.label, l)); });
    rb.append(row('RECONCILED BALANCE', rec.reconciled, true));
    const d = rec.difference || { amount: 0, n: 0 };
    const off = Number(d.amount) !== 0 || Number(d.n) !== 0;
    rb.append(h('tr', {}, [h('td', {}, [h('b', { text: 'DIFFERENCE (Health Facility − PhilHealth)' })]),
      h('td', { class: 'num' + (off ? ' bad' : ''), colspan: '2', text: cnt(d.n) + ' claims · ' + money(d.amount) }),
      h('td', { colspan: '2' })]));
    box.append(h('h3', { style: 'margin-top:16px', text: 'Reconciliation of balances (as of ' + fmtDate(hd.report_date) + ')' }),
      h('div', { class: 'table-wrap' }, [h('table', {}, [
        h('thead', {}, [
          h('tr', {}, [h('th', { text: '' }), h('th', { colspan: '2', class: 'num', text: 'Health Facility' }), h('th', { colspan: '2', class: 'num', text: 'PhilHealth' })]),
          h('tr', {}, [h('th', { text: 'Particulars' }), h('th', { class: 'num', text: 'Claims' }), h('th', { class: 'num', text: 'Amount' }),
                       h('th', { class: 'num', text: 'Claims' }), h('th', { class: 'num', text: 'Amount' })])]),
        rb])]));
    if (off) {
      box.append(h('div', { class: 'msg show err', text: 'The reconciliation does not balance. Check the "Annex A line" columns of the Matching Report' +
        (a.version === 'internal' ? ' and HO ICS Recon' : '') + ' and report this to the system administrator.' }));
    } else {
      box.append(h('div', { class: 'muted', text: 'Balanced (claims and amount). Breakdown: filter the "Annex A line" columns of the Matching Report' +
        (a.version === 'internal' ? ' and HO ICS Recon' : '') + '.' }));
    }
  }

  // Kunin at ipakita; internal = true para sa PhilHealth (tinatanggihan ng DB kung facility user)
  async function load(box, matchId, internal){
    box.replaceChildren();
    const { data, error } = await sb.rpc('annex_a', { p_match: matchId, p_internal: !!internal });
    if (error) { box.append(h('div', { class: 'msg show err', text: error.message })); return null; }
    render(box, data);
    return data;
  }

  window.AnnexView = { render: render, load: load };
})();
