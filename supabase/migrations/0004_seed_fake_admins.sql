-- 0004_seed_fake_admins.sql
-- PEKENG test accounts lang (test project). Ang auth users ay ginawa muna sa
-- Dashboard → Authentication → Users; dito itinatakda ang role nila.

-- Branch Admin ng TEST-A
update public.profiles p
   set status = 'active', role = 'branch_admin', full_name = 'Test Branch Admin Alpha',
       branch_id = (select id from public.branches where code = 'TEST-A'),
       requested_facility_id = null, requested_branch_id = null
  from auth.users u
 where u.id = p.id and u.email = 'branchadmin.alpha@example.com' and p.status = 'pending';

-- FINMAREP approver (home branch TEST-A)
update public.profiles p
   set status = 'active', role = 'finmarep', is_finmarep_approver = true,
       full_name = 'Test FINMAREP Approver',
       branch_id = (select id from public.branches where code = 'TEST-A'),
       requested_facility_id = null, requested_branch_id = null
  from auth.users u
 where u.id = p.id and u.email = 'finmarep.approver@example.com' and p.status = 'pending';

-- Home branch ng FINMAREP approver ay hawak niya
insert into public.user_branches (user_id, branch_id)
select p.id, p.branch_id
from public.profiles p join auth.users u on u.id = p.id
where u.email = 'finmarep.approver@example.com' and p.role = 'finmarep'
on conflict do nothing;
