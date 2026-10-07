// Auth guard para sa mga dashboard shell at sa mga page sa loob ng iframe.
// UX lang ito — ang tunay na proteksyon ng data ay RLS.
// Gamit (sa <head>, pagkatapos ng supabase-js at js/supabase-client.js):
//   <script src="js/auth-guard.js" data-roles="finmarep,bas_processor,branch_admin"></script>
// Ang "finmarep_approver" sa data-roles / data-show-for ay FINMAREP na may is_finmarep_approver.
// Pinupunan ang mga element na may data-user="name|initials|role|org|name-role|role-org"
// (textContent lang). Ang data-show-for="role,role" ay ipinapakita lang sa mga role na iyon.
// Ang mga element na may data-signout ay nagla-log out. Hintayin ang window.sbUserReady bago gamitin ang sbUser.
(function(){
  const script = document.currentScript;
  const allowed = ((script && script.dataset.roles) || '')
    .split(',').map(function(s){ return s.trim(); }).filter(Boolean);
  const root = document.documentElement;
  root.style.visibility = 'hidden';   // huwag ipakita ang page hangga't hindi kumpirmado

  let resolveUser;
  window.sbUserReady = new Promise(function(resolve){ resolveUser = resolve; });

  // Laging sa buong window (hindi sa loob ng iframe)
  function go(url){ (window.top || window).location.replace(url); }
  function toLogin(){ go('login.html'); }
  function ready(fn){
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fn);
    else fn();
  }
  function tokensOf(prof){
    const t = [prof.role];
    if (prof.role === 'finmarep' && prof.is_finmarep_approver) t.push('finmarep_approver');
    return t;
  }
  function matches(list, tokens){
    return list.some(function(r){ return tokens.includes(r); });
  }

  async function nameOf(table, id){
    if (!id) return '';
    const { data } = await sb.from(table).select('name').eq('id', id).maybeSingle();
    return data ? data.name : '';
  }

  async function check(){
    try {
      const { data: { session } } = await sb.auth.getSession();
      if (!session) return toLogin();

      const { data: prof } = await sb.from('profiles')
        .select('full_name, role, status, facility_id, branch_id, is_finmarep_approver')
        .eq('id', session.user.id).maybeSingle();

      if (!prof || prof.status !== 'active' || !matches(allowed, tokensOf(prof))) {
        // Active pero walang access dito → ilipat sa tamang dashboard; kung hindi → logout
        const home = prof && prof.status === 'active' ? sbHomeFor(prof.role) : null;
        if (home) return go(home);
        await sb.auth.signOut({ scope: 'local' });
        return toLogin();
      }

      const tokens = tokensOf(prof);
      const org = prof.facility_id
        ? await nameOf('facilities', prof.facility_id)
        : await nameOf('branches', prof.branch_id);
      const name = prof.full_name || session.user.email;
      const role = sbRoleLabel[prof.role] || '';
      const initials = name.split(/\s+/).filter(Boolean).slice(0, 2)
        .map(function(w){ return w[0].toUpperCase(); }).join('') || '?';

      window.sbUser = {
        id: session.user.id, email: session.user.email, name: name,
        role: prof.role, roleLabel: role, org: org,
        facilityId: prof.facility_id, branchId: prof.branch_id,
        isFinmarepApprover: !!prof.is_finmarep_approver
      };

      const values = {
        name: name, initials: initials, role: role, org: org,
        'name-role': name + ' · ' + role,
        'role-org': org ? role + ' · ' + org : role
      };
      ready(function(){
        document.querySelectorAll('[data-user]').forEach(function(el){
          el.textContent = values[el.dataset.user] || '';
        });
        document.querySelectorAll('[data-show-for]').forEach(function(el){
          el.hidden = !matches(el.dataset.showFor.split(',').map(function(s){ return s.trim(); }), tokens);
        });
        root.style.visibility = '';
        resolveUser(window.sbUser);
      });
    } catch (e) {
      toLogin();
    }
  }

  ready(function(){
    document.addEventListener('click', async function(e){
      const el = e.target.closest('[data-signout]');
      if (!el) return;
      e.preventDefault();
      // local: itong browser lang; hindi nila-logout ang ibang device ng user
      try { await sb.auth.signOut({ scope: 'local' }); } finally { toLogin(); }
    });
  });

  // Nag-logout sa ibang tab
  sb.auth.onAuthStateChange(function(event){
    if (event === 'SIGNED_OUT') toLogin();
  });

  check();
})();
