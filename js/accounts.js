// Account management (a_accounts.html / f_accounts.html).
// Lahat ng data ay galing sa RPC; ang server ang nagche-check ng karapatan sa bawat aksyon.
// Lahat ng user data ay ipinapakita gamit ang textContent (rule 8).
(async function(){
  const PAGE_SIZE = 25;
  const STATUSES = ['pending', 'active', 'disabled', 'rejected'];
  const state = { status: 'pending', search: '', offset: 0 };

  const el = {
    tabs:   document.getElementById('acctTabs'),
    search: document.getElementById('acctSearch'),
    body:   document.getElementById('acctBody'),
    empty:  document.getElementById('acctEmpty'),
    msg:    document.getElementById('acctMsg'),
    range:  document.getElementById('acctRange'),
    prev:   document.getElementById('acctPrev'),
    next:   document.getElementById('acctNext')
  };

  const me = await window.sbUserReady;

  // ---------- helpers ----------
  function h(tag, attrs, children){
    const node = document.createElement(tag);
    Object.entries(attrs || {}).forEach(function([k, v]){
      if (k === 'class') node.className = v;
      else if (k === 'text') node.textContent = v;
      else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
      else node.setAttribute(k, v);
    });
    (children || []).forEach(function(c){ if (c) node.append(c); });
    return node;
  }

  function showMsg(text, kind){
    el.msg.textContent = text;
    el.msg.className = 'acct-msg show ' + kind;
  }
  function clearMsg(){ el.msg.className = 'acct-msg'; }

  // MM/DD/YYYY (hindi nakadepende sa locale ng browser)
  function fmtDate(iso){
    const t = new Date(iso);
    return String(t.getMonth() + 1).padStart(2, '0') + '/' + String(t.getDate()).padStart(2, '0') + '/' + t.getFullYear();
  }

  // Mga role na pwedeng ibigay ng admin na ito sa isang pending na account (tugma sa approve_account)
  function approveRoles(a){
    if (a.requested_facility_id) {
      if (me.role === 'facility_admin') return ['facility'];
      if (me.role === 'branch_admin') return ['facility_admin'];
      return [];
    }
    if (a.requested_branch_id) {
      const r = [];
      if (me.role === 'branch_admin') r.push('bas_processor');
      if (me.isFinmarepApprover) r.push('finmarep');
      return r;
    }
    return [];
  }

  // Mas malinaw na mensahe para sa mga kilalang error ng server
  function friendlyError(error){
    if (error.code === '23505' && /one_facility_admin/.test(error.message || '')) {
      return 'This facility already has an active Facility Admin. That Facility Admin should approve this ' +
             'account as Facility Staff. To replace the Facility Admin, disable the current one first.';
    }
    if (error.code === '42501') return 'You are not allowed to do this: ' + error.message;
    return error.message;
  }

  async function rpc(name, args, okText){
    clearMsg();
    const { error } = await sb.rpc(name, args);
    if (error) { showMsg(friendlyError(error), 'err'); return false; }
    showMsg(okText, 'ok');
    await Promise.all([load(), loadCounts()]);
    return true;
  }

  // ---------- data ----------
  async function fetchPage(status, search, limit, offset){
    return sb.rpc('list_manageable_accounts', {
      p_status: status, p_search: search || null, p_limit: limit, p_offset: offset
    });
  }

  async function loadCounts(){
    await Promise.all(STATUSES.map(async function(s){
      const { data } = await fetchPage(s, '', 1, 0);
      const pill = el.tabs.querySelector('[data-status="' + s + '"] .pill');
      if (pill) pill.textContent = data && data.length ? String(data[0].total_count) : '0';
    }));
  }

  async function load(){
    const { data, error } = await fetchPage(state.status, state.search, PAGE_SIZE, state.offset);
    el.body.replaceChildren();
    if (error) { showMsg('Could not load accounts: ' + error.message, 'err'); return; }

    const total = data.length ? Number(data[0].total_count) : 0;
    // Kung naubos ang page pagkatapos ng aksyon, bumalik sa nakaraang page
    if (!data.length && state.offset > 0) { state.offset = Math.max(0, state.offset - PAGE_SIZE); return load(); }

    data.forEach(function(a){ el.body.append(renderRow(a)); });
    el.empty.hidden = data.length > 0;
    el.range.textContent = total
      ? (state.offset + 1) + '–' + (state.offset + data.length) + ' of ' + total
      : '';
    el.prev.disabled = state.offset === 0;
    el.next.disabled = state.offset + data.length >= total;
  }

  // ---------- render ----------
  function scopeText(a){
    if (a.status === 'pending' || a.status === 'rejected') {
      if (a.requested_facility_name) return 'Facility: ' + a.requested_facility_name;
      if (a.requested_branch_name) return 'Branch: ' + a.requested_branch_name;
      return '—';
    }
    return a.facility_name || a.branch_name || '—';
  }

  function branchCell(a){
    if (!(a.role === 'finmarep' || a.role === 'bas_processor')) return null;
    const wrap = h('div', { class: 'chips' });
    (a.handled_branches || []).forEach(function(b){
      const canRemove = me.role === 'branch_admin' && (b.id === me.branchId || a.branch_id === me.branchId);
      wrap.append(h('span', { class: 'chip' }, [
        document.createTextNode(b.code),
        canRemove ? h('button', {
          class: 'chip-x', type: 'button', title: 'Remove ' + b.code, 'aria-label': 'Remove ' + b.code,
          text: '×',
          onclick: function(){
            if (confirm('Remove branch ' + b.code + ' from ' + (a.full_name || a.email) + '?'))
              rpc('unassign_user_branch', { p_user: a.id, p_branch: b.id }, 'Branch removed.');
          }
        }) : null
      ]));
    });
    const has = (a.handled_branches || []).some(function(b){ return b.id === me.branchId; });
    if (me.role === 'branch_admin' && a.status === 'active' && !has) {
      wrap.append(h('button', {
        class: 'btn-link', type: 'button', text: '+ ' + (me.org || 'my branch'),
        onclick: function(){
          if (confirm('Assign ' + (me.org || 'your branch') + ' to ' + (a.full_name || a.email) + '?'))
            rpc('assign_user_branch', { p_user: a.id, p_branch: me.branchId }, 'Branch assigned.');
        }
      }));
    }
    return wrap;
  }

  function actionsCell(a){
    const wrap = h('div', { class: 'actions' });
    const who = a.full_name || a.email;

    if (a.status === 'pending') {
      const roles = approveRoles(a);
      if (roles.length) {
        const sel = h('select', { class: 'role-select', 'aria-label': 'Role for ' + who });
        roles.forEach(function(r){ sel.add(new Option(sbRoleLabel[r] || r, r)); });
        if (roles.length === 1) sel.disabled = true;
        wrap.append(sel, h('button', {
          class: 'btn btn-ok', type: 'button', text: 'Approve',
          onclick: function(){
            const label = sbRoleLabel[sel.value] || sel.value;
            if (confirm('Approve ' + who + ' as ' + label + '?'))
              rpc('approve_account', { p_user: a.id, p_role: sel.value }, who + ' approved as ' + label + '.');
          }
        }));
      }
      wrap.append(h('button', {
        class: 'btn btn-danger', type: 'button', text: 'Reject',
        onclick: function(){
          if (confirm('Reject the registration of ' + who + '?'))
            rpc('reject_account', { p_user: a.id }, who + ' rejected.');
        }
      }));
    } else if (a.status === 'active') {
      wrap.append(h('button', {
        class: 'btn btn-danger', type: 'button', text: 'Disable',
        onclick: function(){
          if (confirm('Disable ' + who + '? They will lose access right away.'))
            rpc('set_account_active', { p_user: a.id, p_active: false }, who + ' disabled.');
        }
      }));
    } else if (a.status === 'disabled') {
      // FINMAREP: approver lang ang makakapag-enable ulit (server rule din)
      if (a.role !== 'finmarep' || me.isFinmarepApprover) {
        wrap.append(h('button', {
          class: 'btn', type: 'button', text: 'Enable',
          onclick: function(){
            if (confirm('Enable ' + who + ' again?'))
              rpc('set_account_active', { p_user: a.id, p_active: true }, who + ' enabled.');
          }
        }));
      } else {
        wrap.append(h('span', { class: 'muted', text: 'FINMAREP approver only' }));
      }
    }
    return wrap;
  }

  function renderRow(a){
    return h('tr', {}, [
      h('td', {}, [
        h('div', { class: 'name', text: a.full_name || '(no name)' }),
        h('div', { class: 'muted', text: a.email })
      ]),
      h('td', { text: scopeText(a) }),
      h('td', { text: a.role ? (sbRoleLabel[a.role] || a.role) : '—' }),
      h('td', {}, [branchCell(a)]),
      h('td', { class: 'nowrap', text: fmtDate(a.created_at) }),
      h('td', {}, [actionsCell(a)])
    ]);
  }

  // ---------- events ----------
  el.tabs.addEventListener('click', function(e){
    const tab = e.target.closest('[data-status]');
    if (!tab) return;
    state.status = tab.dataset.status;
    state.offset = 0;
    el.tabs.querySelectorAll('[data-status]').forEach(function(t){
      t.classList.toggle('active', t === tab);
      t.setAttribute('aria-selected', t === tab ? 'true' : 'false');
    });
    clearMsg();
    load();
  });

  let searchTimer;
  el.search.addEventListener('input', function(){
    clearTimeout(searchTimer);
    searchTimer = setTimeout(function(){
      state.search = el.search.value.trim();
      state.offset = 0;
      load();
    }, 300);
  });

  el.prev.addEventListener('click', function(){ state.offset = Math.max(0, state.offset - PAGE_SIZE); load(); });
  el.next.addEventListener('click', function(){ state.offset += PAGE_SIZE; load(); });

  await Promise.all([load(), loadCounts()]);
})();
