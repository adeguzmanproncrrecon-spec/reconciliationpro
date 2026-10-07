-- 0005_registration_lookup.sql
-- Para sa register.html (hindi pa naka-login ang user, kaya walang access sa
-- facilities/branches dahil sa RLS). Limitadong datos lang ang ibinabalik.

-- Para magamit ng case-insensitive na lookup sa ibaba (iwas full scan sa anon calls)
create index facilities_accreditation_no_upper_idx on public.facilities (upper(accreditation_no));

-- Eksaktong accreditation no. lang → id at pangalan ng facility (walang listahan/search,
-- para hindi ma-enumerate ang facilities).
create function public.lookup_facility_for_registration(p_accreditation_no text)
returns table (id uuid, name text)
language sql stable security definer
set search_path = ''
as $$
  select f.id, f.name
  from public.facilities f
  where upper(f.accreditation_no) = upper(trim(p_accreditation_no))
  limit 1;
$$;

-- Listahan ng branches (kaunti lang) para sa PhilHealth staff registration.
create function public.list_branches_for_registration()
returns table (id uuid, code text, name text)
language sql stable security definer
set search_path = ''
as $$
  select b.id, b.code, b.name from public.branches b order by b.name;
$$;

revoke execute on function public.lookup_facility_for_registration(text) from public;
revoke execute on function public.list_branches_for_registration()       from public;
grant  execute on function public.lookup_facility_for_registration(text) to anon, authenticated;
grant  execute on function public.list_branches_for_registration()       to anon, authenticated;
