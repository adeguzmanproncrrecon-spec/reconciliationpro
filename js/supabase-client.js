// Shared Supabase client. Publishable key lang ito (ligtas sa browser; RLS ang nagpoprotekta).
// HUWAG maglagay ng service_role / secret key dito.
// Kailangang i-load muna ang supabase-js bago ang file na ito (naka-pin + SRI; kopyahin mula sa register.html):
//   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/dist/umd/supabase.js"
//           integrity="sha384-Rj26LVGvoeRVR6+mwQmFfcR3QOBEwT+ZmuCWpuiqeTzJpCs0ER4ITAWGb4Hiy3Ok"
//           crossorigin="anonymous"></script>
(function(){
  // "Keep me signed in": naka-check → localStorage (tatagal); hindi → sessionStorage (mawawala pagsara ng tab).
  // Ang login.html ang nagse-set ng REMEMBER_KEY bago mag-sign in.
  const REMEMBER_KEY = 'rp_remember';

  function safe(fn, fallback){
    try { return fn(); } catch (e) { return fallback; }
  }
  function remember(){
    return safe(function(){ return localStorage.getItem(REMEMBER_KEY) === '1'; }, false);
  }

  const storage = {
    getItem: function(k){
      return safe(function(){ return localStorage.getItem(k) ?? sessionStorage.getItem(k); }, null);
    },
    // Kung nasaan na ang key (hal. token refresh), doon pa rin; bagong login lang ang sumusunod sa flag.
    // Laging binubura ang kopya sa kabilang storage para walang maiwang lumang session.
    setItem: function(k, v){
      safe(function(){
        const target = localStorage.getItem(k) !== null ? localStorage
                     : sessionStorage.getItem(k) !== null ? sessionStorage
                     : (remember() ? localStorage : sessionStorage);
        target.setItem(k, v);
        (target === localStorage ? sessionStorage : localStorage).removeItem(k);
      });
    },
    removeItem: function(k){
      safe(function(){ localStorage.removeItem(k); });
      safe(function(){ sessionStorage.removeItem(k); });
    }
  };

  window.sbSetRemember = function(on){
    safe(function(){
      if (on) localStorage.setItem(REMEMBER_KEY, '1');
      else localStorage.removeItem(REMEMBER_KEY);
    });
  };

  // Publishable lang (hindi secret); kailangan din ng direktang fetch sa Edge Functions
  window.SB_URL = 'https://wqqzuipitnxacreyyvur.supabase.co';
  window.SB_PUBLISHABLE_KEY = 'sb_publishable_CKx7xjd7ebibNLs3z7XCtA_QxyjZ9JG';

  window.sb = window.supabase.createClient(
    window.SB_URL,
    window.SB_PUBLISHABLE_KEY,
    { auth: { storage: storage, persistSession: true, autoRefreshToken: true } }
  );

  // Saan pupunta ang bawat role pagka-login
  window.sbHomeFor = function(role){
    if (role === 'facility' || role === 'facility_admin') return 'f_dashboard.html';
    if (role === 'finmarep' || role === 'bas_processor' || role === 'branch_admin') return 'a_dashboard.html';
    return null;
  };

  window.sbRoleLabel = {
    facility: 'Facility Staff',
    facility_admin: 'Facility Admin',
    finmarep: 'FINMAREP',
    bas_processor: 'BAS Processor',
    branch_admin: 'Branch Admin'
  };
})();
