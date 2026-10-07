-- 0003_seed_fake_branches_facilities.sql
-- PEKENG test data lang (test project). Walang tunay na branch, facility, o accreditation no.

insert into public.branches (code, name) values
  ('TEST-A', 'Test Branch Alpha'),
  ('TEST-B', 'Test Branch Bravo')
on conflict (code) do nothing;

insert into public.facilities (accreditation_no, name, branch_id)
select v.accreditation_no, v.name, b.id
from (values
  ('TEST-HOSP-0001', 'Sample General Hospital', 'TEST-A'),
  ('TEST-HOSP-0002', 'Demo Medical Center',     'TEST-A'),
  ('TEST-HOSP-0003', 'Mock Community Hospital', 'TEST-B')
) as v(accreditation_no, name, branch_code)
join public.branches b on b.code = v.branch_code
on conflict (accreditation_no) do nothing;
