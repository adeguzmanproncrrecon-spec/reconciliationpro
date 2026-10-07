// Listahan ng Facilities with / without LOI (a_faciwithloi.html, a_facinoloi.html).
// Ang mode ay mula sa <body data-has-loi="true|false">. Data mula sa RPC list_facilities_loi (saklaw ay nasa server).
// textContent lang para sa data ng facility.
(async function(){
  const PAGE = 25;
  const hasLoi = document.body.dataset.hasLoi === 'true';
  const $ = function(id){ return document.getElementById(id); };
  const state = { offset: 0, myBranches: [] };
  const me = await window.sbUserReady;
  const isFinmarep = me.role === 'finmarep';

  function h(tag, attrs, kids){
    const n = document.createElement(tag);
    Object.entries(attrs || {}).forEach(function([k, v]){
      if (k === 'class') n.className = v; else if (k === 'text') n.textContent = v;
      else if (k.startsWith('on')) n.addEventListener(k.slice(2), v); else n.setAttribute(k, v);
    });
    (kids || []).forEach(function(c){ if (c !== null && c !== undefined) n.append(c); });
    return n;
  }
  function td(t, cls){ return h('td', { class: cls || '', text: t === null || t === undefined || t === '' ? '—' : String(t) }); }
  function fmtDate(d){ if (!d) return '—'; const p = String(d).slice(0, 10).split('-'); return p[1] + '/' + p[2] + '/' + p[0]; }
  function fmtTs(ts){ if (!ts) return '—'; const t = new Date(ts), z = function(n){ return String(n).padStart(2, '0'); };
    return z(t.getMonth() + 1) + '/' + z(t.getDate()) + '/' + t.getFullYear() + ' ' + z(t.getHours()) + ':' + z(t.getMinutes()); }
  function showErr(t){ const m = $('msg'); m.textContent = t; m.className = 'msg show err'; }
  function clearMsg(){ $('msg').className = 'msg'; }

  async function download(path){
    clearMsg();
    const { data, error } = await sb.storage.from('loi').createSignedUrl(path, 120);
    if (error) { showErr('Could not open the file: ' + error.message); return; }
    window.open(data.signedUrl, '_blank', 'noopener');
  }
  function fileBtn(path, name){
    return h('button', { class: 'btn', type: 'button', text: name || 'Open', onclick: function(ev){ ev.stopPropagation(); download(path); } });
  }

  // ---------- branch filter (UI lang; ang saklaw ay nasa server) ----------
  async function loadBranches(){
    const [{ data: br }, { data: mine }] = await Promise.all([
      sb.from('branches').select('id, code, name').order('name'),
      sb.from('user_branches').select('branch_id').eq('user_id', me.id)
    ]);
    state.myBranches = (mine || []).map(function(r){ return r.branch_id; });
    if (me.branchId && !state.myBranches.includes(me.branchId)) state.myBranches.push(me.branchId);
    const sel = $('branchFilter');
    if (isFinmarep) {
      if (state.myBranches.length) sel.add(new Option('My branches', 'mine'));
      sel.add(new Option('All branches', 'all'));
      (br || []).forEach(function(b){ sel.add(new Option(b.name + ' (' + b.code + ')', b.id)); });
    } else {
      sel.add(new Option('All my branches', 'all'));
      (br || []).filter(function(b){ return state.myBranches.includes(b.id); })
        .forEach(function(b){ sel.add(new Option(b.name + ' (' + b.code + ')', b.id)); });
    }
  }
  function branchParam(){
    const f = $('branchFilter').value;
    if (f === 'mine') return state.myBranches;
    if (f && f !== 'all') return [f];
    return null;
  }

  // ---------- lahat ng LOI ng isang facility (sub-row) ----------
  async function toggleHistory(tr, facilityId, cols){
    const next = tr.nextElementSibling;
    if (next && next.classList.contains('hist')) { next.remove(); return; }
    const cell = h('td', { colspan: String(cols) }, [h('span', { class: 'muted', text: 'Loading…' })]);
    const row = h('tr', { class: 'hist' }, [cell]);
    tr.after(row);
    const { data, error } = await sb.from('facility_lois')
      .select('letter_date, coverage_start, coverage_end, remarks, file_path, file_name, submitted_at')
      .eq('facility_id', facilityId).order('submitted_at', { ascending: false }).limit(50);
    if (error) { cell.replaceChildren(h('span', { class: 'bad', text: error.message })); return; }
    const t = h('table', {}, [
      h('thead', {}, [h('tr', {}, ['Submitted', 'Date of letter', 'Coverage', 'Remarks', 'File'].map(function(x){ return h('th', { text: x }); }))]),
      h('tbody', {}, data.map(function(l){
        return h('tr', {}, [td(fmtTs(l.submitted_at)), td(fmtDate(l.letter_date)),
          td(fmtDate(l.coverage_start) + ' – ' + fmtDate(l.coverage_end)), td(l.remarks, 'wrap'),
          h('td', {}, [fileBtn(l.file_path, l.file_name)])]);
      }))
    ]);
    cell.replaceChildren(h('div', { class: 'sub-table' }, [t]));
  }

  // ---------- listahan ----------
  async function loadList(){
    clearMsg();
    const s = $('facSearch').value.trim();
    const { data, error } = await sb.rpc('list_facilities_loi', {
      p_has_loi: hasLoi, p_branches: branchParam(), p_search: s.length >= 2 ? s : null,
      p_limit: PAGE, p_offset: state.offset
    });
    const body = $('listBody'); body.replaceChildren();
    if (error) { showErr('Could not load facilities: ' + error.message); return; }
    const cols = document.querySelectorAll('thead th').length;
    data.forEach(function(r){
      const fac = h('td', {}, [h('div', { text: r.facility_name }), h('div', { class: 'muted', text: r.accreditation_no })]);
      const hf = h('td', {}, r.hf_file_name
        ? [h('div', { text: r.hf_file_name }), h('div', { class: 'muted', text: Number(r.hf_row_count || 0).toLocaleString() + ' rows · ' + fmtTs(r.hf_completed_at) })]
        : [document.createTextNode('—')]);
      let tr;
      if (hasLoi) {
        tr = h('tr', {}, [
          fac, td(r.branch_code),
          td(fmtDate(r.letter_date)), td(fmtDate(r.coverage_start) + ' – ' + fmtDate(r.coverage_end)),
          td(r.remarks, 'wrap'), h('td', {}, [fileBtn(r.file_path, r.file_name)]), td(fmtTs(r.submitted_at)),
          hf,
          h('td', {}, [Number(r.loi_count) > 1
            ? h('button', { class: 'btn', type: 'button', text: 'All ' + r.loi_count, onclick: function(){ toggleHistory(tr, r.facility_id, cols); } })
            : null])
        ]);
      } else {
        tr = h('tr', {}, [fac, td(r.branch_code), td(r.branch_name), hf]);
      }
      body.append(tr);
    });
    $('listEmpty').hidden = data.length > 0;
    const total = data.length ? Number(data[0].total_count) : 0;
    $('listRange').textContent = total ? (state.offset + 1) + '–' + (state.offset + data.length) + ' of ' + total.toLocaleString() : '';
    $('listPrev').disabled = state.offset === 0;
    $('listNext').disabled = state.offset + data.length >= total;
  }

  let timer;
  $('facSearch').addEventListener('input', function(){ clearTimeout(timer); timer = setTimeout(function(){ state.offset = 0; loadList(); }, 300); });
  $('branchFilter').addEventListener('change', function(){ state.offset = 0; loadList(); });
  $('listPrev').addEventListener('click', function(){ state.offset = Math.max(0, state.offset - PAGE); loadList(); });
  $('listNext').addEventListener('click', function(){ state.offset += PAGE; loadList(); });

  await loadBranches();
  await loadList();
})();
