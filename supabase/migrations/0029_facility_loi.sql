-- 0029_facility_loi.sql
-- Letter of Intent (LOI) ng facility (desisyon ng user, 2026-10-07):
-- - Ang Facility Admin ang nagsusumite ng LOI sa system (sa halip na email): file (PDF/larawan, max 10 MB), petsa ng LOI,
--   coverage start/end (cut-off), remarks. Walang edit/delete ng naisumite; kapag may mali, bagong LOI ang ipapasa
--   (ang pinakabago ang ginagamit).
-- - PhilHealth (FINMAREP, BAS Processor, Branch Admin) ay nakakakita ayon sa saklaw nila:
--   "Facilities with LOI" at "Facilities without LOI" (may complete na HF ICS pero wala pang LOI).
-- - File sa private storage bucket "loi", path "<facility_id>/<uuid>.<ext>".
-- Walang DROP / DELETE / TRUNCATE.

-- ---------------------------------------------------------------------------
-- Talaan ng LOI
-- ---------------------------------------------------------------------------
create table public.facility_lois (
  id             uuid primary key default gen_random_uuid(),
  facility_id    uuid not null references public.facilities (id),
  letter_date    date not null check (letter_date between '2000-01-01' and '2100-12-31'),
  coverage_start date not null check (coverage_start between '1990-01-01' and '2100-12-31'),
  coverage_end   date not null check (coverage_end between '1990-01-01' and '2100-12-31'),
  remarks        text check (length(remarks) <= 1000),
  file_path      text not null unique check (length(file_path) <= 300),
  file_name      text not null check (length(file_name) <= 255),
  file_size      int  check (file_size between 1 and 10485760),
  submitted_by   uuid not null references public.profiles (id),
  submitted_at   timestamptz not null default now(),
  check (coverage_start <= coverage_end)
);
create index facility_lois_facility_idx on public.facility_lois (facility_id, submitted_at desc);

alter table public.facility_lois enable row level security;
revoke all on public.facility_lois from anon;
revoke insert, update, delete, truncate on public.facility_lois from authenticated;
-- Saklaw = RLS ng facilities (facility: sariling facility; PhilHealth: ayon sa branch scope)
create policy facility_lois_select on public.facility_lois for select to authenticated
  using (facility_id in (select f.id from public.facilities f));

-- ---------------------------------------------------------------------------
-- Storage: private bucket para sa LOI files
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('loi', 'loi', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Upload: Facility Admin lang, sa folder ng sariling facility, hugis "<facility_id>/<uuid>.<pdf|jpg|png>",
-- at hanggang 20 file bawat 24 oras bawat facility (iwas mapuno ang storage ng mga file na hindi naisumite)
create policy loi_files_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'loi'
    and (select public.app_user_role()) = 'facility_admin'
    and name ~ ('^' || (select public.app_user_facility_id())::text
                || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(pdf|jpg|png)$')
    and (select count(*) from storage.objects o
          where o.bucket_id = 'loi'
            and o.name like (select public.app_user_facility_id())::text || '/%'
            and o.created_at > now() - interval '24 hours') < 20
  );

-- Basa (para sa signed URL / download): sariling facility, o PhilHealth na may saklaw sa facility
create policy loi_files_select on storage.objects for select to authenticated
  using (
    bucket_id = 'loi'
    and (
      (storage.foldername(name))[1] = (select public.app_user_facility_id())::text
      or ((select public.app_user_is_philhealth())
          and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   then public.can_view_facility(((storage.foldername(name))[1])::uuid)
                   else false end)
    )
  );
-- Walang update/delete policy: hindi mababago o mabubura ang naisumiteng file.

-- ---------------------------------------------------------------------------
-- RPC: isumite ang LOI (pagkatapos i-upload ang file sa storage)
-- ---------------------------------------------------------------------------
create function public.submit_loi(
  p_letter_date    date,
  p_coverage_start date,
  p_coverage_end   date,
  p_remarks        text,
  p_file_path      text,
  p_file_name      text,
  p_file_size      int
)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fac uuid := public.app_user_facility_id();
  v_id  uuid;
  v_size bigint;
begin
  if public.app_user_role() is distinct from 'facility_admin' or v_fac is null then
    raise exception 'Only the Facility Admin can submit a Letter of Intent' using errcode = '42501';
  end if;
  if p_letter_date is null or p_coverage_start is null or p_coverage_end is null then
    raise exception 'Letter date and coverage start/end are required' using errcode = '22023';
  end if;
  if p_coverage_start > p_coverage_end then
    raise exception 'Coverage start must be on or before coverage end' using errcode = '22023';
  end if;
  -- Ang file ay dapat nasa folder ng sariling facility at talagang na-upload na
  if p_file_path is null or p_file_path !~ ('^' || v_fac::text
       || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(pdf|jpg|png)$') then
    raise exception 'Invalid file' using errcode = '42501';
  end if;
  -- Ang laki ay mula sa storage, hindi sa client
  select coalesce((o.metadata->>'size')::bigint, p_file_size) into v_size
    from storage.objects o where o.bucket_id = 'loi' and o.name = p_file_path;
  if not found then
    raise exception 'The file was not uploaded' using errcode = '22023';
  end if;

  insert into public.facility_lois (facility_id, letter_date, coverage_start, coverage_end, remarks,
                                    file_path, file_name, file_size, submitted_by)
  values (v_fac, p_letter_date, p_coverage_start, p_coverage_end, left(nullif(trim(p_remarks), ''), 1000),
          p_file_path, left(coalesce(nullif(trim(p_file_name), ''), 'loi'), 255), least(greatest(v_size, 1), 10485760)::int, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: listahan para sa PhilHealth — Facilities with / without LOI
-- p_has_loi = true  → may LOI (pinakabagong LOI ng bawat facility)
-- p_has_loi = false → may complete na HF ICS pero wala pang LOI
-- ---------------------------------------------------------------------------
create function public.list_facilities_loi(
  p_has_loi  boolean,
  p_branches uuid[] default null,
  p_search   text   default null,
  p_limit    int    default 25,
  p_offset   int    default 0
)
returns table (
  facility_id       uuid,
  facility_name     text,
  accreditation_no  text,
  branch_code       text,
  branch_name       text,
  loi_id            uuid,
  letter_date       date,
  coverage_start    date,
  coverage_end      date,
  remarks           text,
  file_path         text,
  file_name         text,
  submitted_at      timestamptz,
  loi_count         bigint,
  hf_file_name      text,
  hf_row_count      int,
  hf_completed_at   timestamptz,
  total_count       bigint
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_role public.app_role := public.app_user_role();
  v_br   uuid := public.app_user_branch_id();
  v_q    text := left(nullif(trim(p_search), ''), 100);
begin
  if not coalesce(public.app_user_is_philhealth(), false) then
    raise exception 'PhilHealth only' using errcode = '42501';
  end if;
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');

  return query
  with fac as (
    select f.id, f.name, f.accreditation_no, b.code as branch_code, b.name as branch_name
      from public.facilities f
      left join public.branches b on b.id = f.branch_id
     where (v_role = 'finmarep'
            or (v_role = 'bas_processor'
                and f.branch_id in (select ub.branch_id from public.user_branches ub where ub.user_id = auth.uid()))
            or (v_role = 'branch_admin' and f.branch_id = v_br))
       and (p_branches is null or f.branch_id = any (p_branches))
       and (v_q is null or f.name ilike '%' || v_q || '%' or f.accreditation_no ilike '%' || v_q || '%')
  ),
  loi as (
    select distinct on (l.facility_id) l.*, count(*) over (partition by l.facility_id) as n
      from public.facility_lois l join fac on fac.id = l.facility_id
     order by l.facility_id, l.submitted_at desc
  ),
  hf as (
    select distinct on (s.facility_id) s.facility_id, s.file_name, s.row_count, s.completed_at
      from public.hf_ics_submissions s join fac on fac.id = s.facility_id
     where s.status = 'complete'
     order by s.facility_id, s.completed_at desc nulls last
  ),
  rows_ as (
    select fac.id, fac.name, fac.accreditation_no, fac.branch_code, fac.branch_name,
           loi.id as loi_id, loi.letter_date, loi.coverage_start, loi.coverage_end, loi.remarks,
           loi.file_path, loi.file_name, loi.submitted_at, coalesce(loi.n, 0) as loi_count,
           hf.file_name as hf_file_name, hf.row_count as hf_row_count, hf.completed_at as hf_completed_at
      from fac
      left join loi on loi.facility_id = fac.id
      left join hf on hf.facility_id = fac.id
     where (p_has_loi and loi.id is not null)
        or (not p_has_loi and loi.id is null and hf.facility_id is not null)
  )
  select r.id, r.name, r.accreditation_no, r.branch_code, r.branch_name,
         r.loi_id, r.letter_date, r.coverage_start, r.coverage_end, r.remarks, r.file_path, r.file_name, r.submitted_at,
         r.loi_count, r.hf_file_name, r.hf_row_count, r.hf_completed_at,
         count(*) over () as total_count
    from rows_ r
   order by case when p_has_loi then r.submitted_at else r.hf_completed_at end desc nulls last, r.name
   limit least(greatest(coalesce(p_limit, 25), 1), 100)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke execute on function public.submit_loi(date, date, date, text, text, text, int) from public, anon;
grant  execute on function public.submit_loi(date, date, date, text, text, text, int) to authenticated;
revoke execute on function public.list_facilities_loi(boolean, uuid[], text, int, int) from public, anon;
grant  execute on function public.list_facilities_loi(boolean, uuid[], text, int, int) to authenticated;
