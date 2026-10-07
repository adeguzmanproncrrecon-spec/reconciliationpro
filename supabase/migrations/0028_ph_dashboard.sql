-- 0028_ph_dashboard.sql
-- Data ng PhilHealth Dashboard (a_dash.html) sa iisang tawag. PhilHealth roles lang.
-- Saklaw = mga facility na nakikita ng user (can_view_facility: FINMAREP lahat; BAS Processor = naka-assign na branches;
-- Branch Admin = home branch), at opsyonal na branch filter (UI filter lang; hindi nito pinalalawak ang saklaw).
-- Mabilis kahit maraming facility: ang status totals ay galing sa naka-save na summary (recon_summary_cache, 0027).
-- Read-only; walang DROP / DELETE / TRUNCATE.

create function public.ph_dashboard(p_branches uuid[] default null)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v      jsonb;
  v_role public.app_role := public.app_user_role();
  v_br   uuid := public.app_user_branch_id();
begin
  if not coalesce(public.app_user_is_philhealth(), false) then
    raise exception 'PhilHealth only' using errcode = '42501';
  end if;
  if p_branches is not null and cardinality(p_branches) > 500 then
    raise exception 'Too many branches' using errcode = '22023';
  end if;

  with fac as (
    -- Saklaw: pareho ng facilities_select / can_view_facility (0001), naka-inline para hindi function call bawat facility
    select f.id, f.name, f.accreditation_no, f.branch_id, b.code as branch_code, b.name as branch_name
      from public.facilities f
      left join public.branches b on b.id = f.branch_id
     where (v_role = 'finmarep'
            or (v_role = 'bas_processor'
                and f.branch_id in (select ub.branch_id from public.user_branches ub where ub.user_id = auth.uid()))
            or (v_role = 'branch_admin' and f.branch_id = v_br))
       and (p_branches is null or f.branch_id = any (p_branches))
  ),
  -- Pinakabagong complete na HF ICS bawat facility
  sub as (
    select distinct on (s.facility_id) s.facility_id, s.id, s.file_name, s.row_count, s.completed_at
      from public.hf_ics_submissions s join fac on fac.id = s.facility_id
     where s.status = 'complete'
     order by s.facility_id, s.completed_at desc nulls last
  ),
  runs as (select r.* from public.recon_runs r join fac on fac.id = r.facility_id),
  cur as (select m.* from public.recon_matches m join fac on fac.id = m.facility_id where m.is_current and m.status = 'done'),
  -- Pinakabagong matching job bawat run (index sa run_id)
  lastjob as (
    select r.id as run_id, r.facility_id, l.status, l.finished_at, l.error
      from runs r
      cross join lateral (select m.status, m.finished_at, m.error from public.recon_matches m
                           where m.run_id = r.id order by m.requested_at desc limit 1) l
  ),
  draft as (
    select r.id, r.facility_id, r.report_date, r.created_at,
           array_remove(array[
             case when r.hf_submission_id is null then 'HF ICS' end,
             case when not exists (select 1 from public.run_uploads u where u.run_id = r.id and u.status = 'complete' and u.kind = 'ho_ics') then 'HO ICS' end,
             case when not exists (select 1 from public.run_uploads u where u.run_id = r.id and u.status = 'complete' and u.kind = 'raw_matching') then 'Raw Matching' end,
             case when not exists (select 1 from public.run_uploads u where u.run_id = r.id and u.status = 'complete' and u.kind = 'status_trail') then 'Status Trail' end,
             case when not exists (select 1 from public.run_uploads u where u.run_id = r.id and u.status = 'complete' and u.kind = 'payment_details') then 'Payment Details' end
           ], null) as missing,
           exists (select 1 from public.recon_matches m where m.run_id = r.id and m.status in ('queued', 'running')) as job_active
      from runs r where r.status = 'draft'
  )
  select jsonb_build_object(
    'tiles', jsonb_build_object(
       'facilities',   (select count(*) from fac),
       'with_hf_ics',  (select count(*) from sub),
       'with_match',   (select count(distinct facility_id) from cur),
       'runs_draft',   (select count(*) from runs where status = 'draft'),
       'runs_matched', (select count(*) from runs where status = 'matched'),
       'jobs_active',  (select count(*) from public.recon_matches m
                         where m.status in ('queued', 'running') and m.facility_id in (select fac.id from fac)),
       'jobs_failed',  (select count(*) from lastjob where status = 'failed')),

    -- Status ng claims (as of Report Date) ng mga current na matching, bawat branch
    'status_by_branch', coalesce((
       select jsonb_agg(jsonb_build_object('branch_code', x.branch_code, 'branch_name', x.branch_name, 'status', x.status,
                                           'claims', x.claims, 'amount', x.amount) order by x.branch_code, x.status)
         from (select fac.branch_code, fac.branch_name, e->>'label' as status,
                      sum((e->>'claims')::bigint) as claims, sum((e->>'amount')::numeric) as amount
                 from cur
                 join fac on fac.id = cur.facility_id
                 join public.recon_summary_cache c on c.match_id = cur.id
                 cross join lateral jsonb_array_elements(c.data) e
                where e->>'kind' = 'status_rd'
                group by 1, 2, 3) x), '[]'::jsonb),
    'facilities_in_status', (select count(distinct cur.facility_id) from cur join public.recon_summary_cache c on c.match_id = cur.id),

    -- Kailangang aksyunan
    'new_hf_ics', jsonb_build_object(
       'count', (select count(*) from sub where not exists (select 1 from runs r where r.hf_submission_id = sub.id)),
       'items', coalesce((select jsonb_agg(t order by t.completed_at desc nulls last) from (
           select fac.name as facility, fac.accreditation_no, fac.branch_code, sub.file_name, sub.row_count, sub.completed_at
             from sub join fac on fac.id = sub.facility_id
            where not exists (select 1 from runs r where r.hf_submission_id = sub.id)
            order by sub.completed_at desc nulls last limit 10) t), '[]'::jsonb)),
    'incomplete_runs', jsonb_build_object(
       'count', (select count(*) from draft where cardinality(missing) > 0),
       'items', coalesce((select jsonb_agg(t order by t.created_at desc) from (
           select d.id as run_id, fac.name as facility, fac.accreditation_no, fac.branch_code, d.report_date, d.missing, d.created_at
             from draft d join fac on fac.id = d.facility_id
            where cardinality(d.missing) > 0
            order by d.created_at desc limit 10) t), '[]'::jsonb)),
    'ready_runs', jsonb_build_object(
       'count', (select count(*) from draft where cardinality(missing) = 0 and not job_active),
       'items', coalesce((select jsonb_agg(t order by t.created_at desc) from (
           select d.id as run_id, fac.name as facility, fac.accreditation_no, fac.branch_code, d.report_date, d.created_at
             from draft d join fac on fac.id = d.facility_id
            where cardinality(d.missing) = 0 and not d.job_active
            order by d.created_at desc limit 10) t), '[]'::jsonb)),
    'unmapped', jsonb_build_object(
       'count', (select count(*) from cur where coalesce((cur.summary->>'unmapped_process_count')::int, 0) > 0),
       'items', coalesce((select jsonb_agg(t order by t.finished_at desc nulls last) from (
           select cur.run_id, fac.name as facility, fac.accreditation_no, fac.branch_code, cur.finished_at,
                  (cur.summary->>'unmapped_process_count')::int as processes
             from cur join fac on fac.id = cur.facility_id
            where coalesce((cur.summary->>'unmapped_process_count')::int, 0) > 0
            order by cur.finished_at desc nulls last limit 10) t), '[]'::jsonb)),
    'failed_jobs', jsonb_build_object(
       'count', (select count(*) from lastjob where status = 'failed'),
       'items', coalesce((select jsonb_agg(t order by t.finished_at desc nulls last) from (
           select l.run_id, fac.name as facility, fac.accreditation_no, fac.branch_code, l.finished_at, left(l.error, 200) as error
             from lastjob l join fac on fac.id = l.facility_id
            where l.status = 'failed'
            order by l.finished_at desc nulls last limit 10) t), '[]'::jsonb)),

    -- Pinakabagong runs
    'latest_runs', coalesce((select jsonb_agg(t order by t.created_at desc) from (
        select r.id as run_id, fac.name as facility, fac.accreditation_no, fac.branch_code, r.report_date, r.matching_date, r.created_at,
               r.status as run_status, l.status as job_status, l.finished_at
          from runs r
          join fac on fac.id = r.facility_id
          left join lastjob l on l.run_id = r.id
         order by r.created_at desc limit 10) t), '[]'::jsonb)
  ) into v;
  return v;
end;
$$;

revoke execute on function public.ph_dashboard(uuid[]) from public, anon;
grant  execute on function public.ph_dashboard(uuid[]) to authenticated;
