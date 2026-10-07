-- 0025_annex_precompute.sql
-- Annex A ng 50k claims: 11 segundo ang annex_a (internal) → timeout (8s limit ng authenticated). Sa 200k ay ~40s.
-- Ayos: kinukuwenta ang Annex A (internal at facility) SA MATCHING JOB (background, 30 min limit) at sine-save sa
-- recon_annex; ang annex_a ay nagbabalik na lang ng naka-save (pareho ang access checks). Kung wala pa (lumang matching),
-- kinukuwenta on the fly gaya ng dati.
-- - annex_a_compute: ang dating katawan ng annex_a (0020) — walang access check; hindi matatawag ng client.
-- - recon_annex: RLS na walang policy (walang direktang makakabasa); binabasa lang ng annex_a (security definer).
-- PAALALA: kapag binago sa hinaharap ang Annex A logic o ang recon_*_results ng mga natapos nang matching, i-refresh din ang
-- recon_annex (insert ... on conflict (match_id, version) do update), kung hindi ay luma ang ibabalik ng annex_a.
-- Walang DROP / DELETE / TRUNCATE.

set local statement_timeout = '30min';

create table public.recon_annex (
  match_id    uuid not null,
  facility_id uuid not null,
  version     text not null check (version in ('internal', 'facility')),
  data        jsonb not null,
  created_at  timestamptz not null default now(),
  primary key (match_id, version),
  foreign key (match_id, facility_id) references public.recon_matches (id, facility_id)
);
alter table public.recon_annex enable row level security;
revoke all on public.recon_annex from anon, authenticated;
create function public.annex_a_compute(p_match uuid, p_internal boolean)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  m        public.recon_matches;
  v_fac    record;
  v_hf     jsonb;
  v_ho     jsonb;
  v_rec    jsonb;
  v_cov    jsonb;
begin
  -- Walang access check dito: tinatawag lang ng matching job (postgres) at ng annex_a (na may check)
  select * into m from public.recon_matches where id = p_match and status = 'done';
  if not found then
    raise exception 'Match not found';
  end if;


  select f.name, f.accreditation_no, b.name as branch into v_fac
    from public.facilities f left join public.branches b on b.id = f.branch_id where f.id = m.facility_id;

  -- ---- Summary of Status of Received eClaims (HF side), 3 cutoff ----
  with hf as (select * from public.recon_hf_results where match_id = p_match),
  per as (
    select 'rd' as k, status_rd as st, count(*) as n, coalesce(sum(amount_used_rd), 0) as amt from hf where status_rd <> 'NOT YET FILED' group by status_rd
    union all
    select 'pd', status_pd, count(*), coalesce(sum(amount_used_pd), 0) from hf where status_pd is not null and status_pd <> 'NOT YET FILED' group by status_pd
    union all
    select 'md', status_md, count(*), coalesce(sum(amount_used_md), 0) from hf where status_md <> 'NOT YET FILED' group by status_md
  ),
  tot as (select k, sum(n) as n, sum(amt) as amt from per group by k)
  select jsonb_build_object(
           'rows', coalesce((select jsonb_agg(jsonb_build_object('cutoff', p.k, 'status', p.st, 'claims', p.n, 'amount', p.amt,
                                     'pct', case when t.amt <> 0 then round(p.amt / t.amt * 100, 2) end))
                             from per p join tot t on t.k = p.k), '[]'::jsonb),
           'totals', coalesce((select jsonb_agg(jsonb_build_object('cutoff', k, 'claims', n, 'amount', amt)) from tot), '[]'::jsonb),
           'upgrade', jsonb_build_object(
              'rd', (select coalesce(sum(amount_used_rd), 0) - coalesce(sum(ics_amount), 0) from hf where status_rd <> 'NOT YET FILED'),
              'pd', (select case when m.prev_report_date is null then null
                                 else coalesce(sum(amount_used_pd), 0) - coalesce(sum(ics_amount), 0) end from hf where status_pd <> 'NOT YET FILED'),
              'md', (select coalesce(sum(amount_used_md), 0) - coalesce(sum(ics_amount), 0) from hf where status_md <> 'NOT YET FILED')),
           'not_yet_filed', jsonb_build_object(
              'rd', (select count(*) from hf where status_rd = 'NOT YET FILED'),
              'pd', (select count(*) from hf where status_pd = 'NOT YET FILED'),
              'md', (select count(*) from hf where status_md = 'NOT YET FILED')))
    into v_hf;

  -- ---- Summary of Status of ICS Claims (PhilHealth / HO side), 3 cutoff ----
  with ho as (
    select o.*,
           (o.reconciling_item in ('Deduct from PHIC: For Archiving – Recon Exception', 'Deduct from PHIC: Deleted Claim')) as archive
      from public.recon_ho_results o
     where o.match_id = p_match and (p_internal or o.in_hf_ics)
  ),
  per as (
    select 'rd' as k, case when archive then 'FOR ARCHIVING' else status_rd end as st, count(*) as n,
           coalesce(sum(estimated_amt), 0) as amt from ho where archive or status_rd <> 'NOT YET FILED' group by 2
    union all
    select 'pd', case when archive then 'FOR ARCHIVING' else status_pd end, count(*), coalesce(sum(estimated_amt), 0)
      from ho where status_pd is not null and (archive or status_pd <> 'NOT YET FILED') group by 2
    union all
    select 'md', case when archive then 'FOR ARCHIVING' else status_md end, count(*), coalesce(sum(estimated_amt), 0)
      from ho where archive or status_md <> 'NOT YET FILED' group by 2
  ),
  tot as (select k, sum(n) as n, sum(amt) as amt from per group by k)
  select jsonb_build_object(
           'rows', coalesce((select jsonb_agg(jsonb_build_object('cutoff', p.k, 'status', p.st, 'claims', p.n, 'amount', p.amt,
                                     'pct', case when t.amt <> 0 then round(p.amt / t.amt * 100, 2) end))
                             from per p join tot t on t.k = p.k), '[]'::jsonb),
           'totals', coalesce((select jsonb_agg(jsonb_build_object('cutoff', k, 'claims', n, 'amount', amt)) from tot), '[]'::jsonb))
    into v_ho;

  -- ---- Reconciliation of balances (as of Report Date) — kabuuan ng annex lines (breakdown = Matching Report / HO ICS Recon) ----
  with hf as (select * from public.recon_hf_results where match_id = p_match),
  ho as (select * from public.recon_ho_results where match_id = p_match and (p_internal or in_hf_ics)),
  -- HF column: ibinabawas ang ICS amount; PHILHEALTH column: ibinabawas ang HO estimated amount
  hf_ded as (select annex_hf_line as l, count(*) as n, coalesce(sum(ics_amount), 0) as a from hf group by 1),
  ho_ded as (select annex_ph_line as l, count(*) as n, coalesce(sum(estimated_amt), 0) as a from ho group by 1),
  -- PHILHEALTH column: dinadagdag ang Recon Amount ng HF claims na wala sa HO ICS
  ph_add as (select annex_ph_line as l, count(*) as n, coalesce(sum(recon_amount), 0) as a from hf
              where annex_ph_line in ('In Process – Not on HO ICS', 'Payment in Transit (ABP – Processed)') group by 1),
  -- HF column (internal lang): dinadagdag ang HO claims na wala sa HF ICS
  hf_add as (select count(*) as n, coalesce(sum(estimated_amt), 0) as a from ho where p_internal and annex_hf_line = 'In Process – Not on HF ICS'),
  ln as (
    select 1 as ord, 'Paid Claims' as label, false as opt,
           -(select a from hf_ded where l = 'Paid Claims') as hf, -(select n from hf_ded where l = 'Paid Claims') as hf_n,
           -(select a from ho_ded where l = 'Paid Claims') as ph, -(select n from ho_ded where l = 'Paid Claims') as ph_n
    union all select 2, 'Denied Claims', false,
           -(select a from hf_ded where l = 'Denied Claims'), -(select n from hf_ded where l = 'Denied Claims'),
           -(select a from ho_ded where l = 'Denied Claims'), -(select n from ho_ded where l = 'Denied Claims')
    union all select 3, 'RTH Claims', false,
           -(select a from hf_ded where l = 'RTH Claims'), -(select n from hf_ded where l = 'RTH Claims'),
           -(select a from ho_ded where l = 'RTH Claims'), -(select n from ho_ded where l = 'RTH Claims')
    union all select 4, 'Unmatched Claims – Duplicate', false,
           -(select a from hf_ded where l = 'Unmatched Claims – Duplicate'), -(select n from hf_ded where l = 'Unmatched Claims – Duplicate'),
           null, null
    union all select 5, 'Unmatched', false,
           -(select a from hf_ded where l = 'Unmatched'), -(select n from hf_ded where l = 'Unmatched'), null, null
    union all select 6, 'Duplicate on HO ICS', true,
           null, null, -(select a from ho_ded where l = 'Duplicate on HO ICS'), -(select n from ho_ded where l = 'Duplicate on HO ICS')
    union all select 7, 'Invalid Claim Series – HO ICS', true,
           null, null, -(select a from ho_ded where l = 'Invalid Claim Series – HO ICS'), -(select n from ho_ded where l = 'Invalid Claim Series – HO ICS')
    union all select 8, 'In Process – Not on HF ICS', false,
           (select a from hf_add), (select n from hf_add), null, null
    union all select 9, 'In Process – Not on HO ICS', false,
           null, null, (select a from ph_add where l = 'In Process – Not on HO ICS'), (select n from ph_add where l = 'In Process – Not on HO ICS')
    union all select 10, 'Payment in Transit (ABP – Processed)', false,
           null, null, (select a from ph_add where l = 'Payment in Transit (ABP – Processed)'),
           (select n from ph_add where l = 'Payment in Transit (ABP – Processed)')
    union all select 11, 'For Archiving – Recon Exception', false,
           -(select a from hf_ded where l = 'For Archiving – Recon Exception'), -(select n from hf_ded where l = 'For Archiving – Recon Exception'),
           -(select a from ho_ded where l = 'For Archiving – Recon Exception'), -(select n from ho_ded where l = 'For Archiving – Recon Exception')
    union all select 12, 'For Archiving – Unmatched (Deleted) – Not on NClaims', false,
           null, null,
           -(select a from ho_ded where l = 'For Archiving – Unmatched (Deleted) – Not on NClaims'),
           -(select n from ho_ded where l = 'For Archiving – Unmatched (Deleted) – Not on NClaims')
    union all select 13, 'Net Upgrade (Downgrade) – HF ICS', false,
           (select coalesce(sum(recon_amount - ics_amount), 0) from hf where annex_hf_line = 'Reconciled Balance'), null, null, null
    union all select 14, 'Net Upgrade (Downgrade) – PHIC books', false,
           null, null, (select coalesce(sum(phic_upgrade), 0) from hf), null
  ),
  lines as (
    select ord, label,
           -- HF column: 0 kapag walang laman (para sa mga linyang may HF column); null kapag hindi ito HF line
           case when ord in (6, 7, 9, 10, 12, 14) then null else coalesce(hf, 0) end as hf,
           case when ord in (6, 7, 9, 10, 12, 13, 14) then null else coalesce(hf_n, 0) end as hf_n,
           case when ord in (4, 5, 8, 13) then null else coalesce(ph, 0) end as ph,
           case when ord in (4, 5, 8, 13, 14) then null else coalesce(ph_n, 0) end as ph_n
      from ln
     where (p_internal or ord <> 8)
       and (not opt or coalesce(ph_n, 0) <> 0)
  ),
  t as (
    select (select coalesce(sum(ics_amount), 0) from hf) as hf_unrec, (select count(*) from hf) as hf_unrec_n,
           (select coalesce(sum(estimated_amt), 0) from ho) as ph_unrec, (select count(*) from ho) as ph_unrec_n,
           (select coalesce(sum(hf), 0) from lines) as hf_sum, (select coalesce(sum(hf_n), 0) from lines) as hf_sum_n,
           (select coalesce(sum(ph), 0) from lines) as ph_sum, (select coalesce(sum(ph_n), 0) from lines) as ph_sum_n
  )
  select jsonb_build_object(
           'lines', coalesce((select jsonb_agg(jsonb_build_object('label', label, 'hf', hf, 'hf_n', hf_n, 'ph', ph, 'ph_n', ph_n)
                                               order by ord) from lines), '[]'::jsonb),
           'unreconciled', jsonb_build_object('hf', hf_unrec, 'hf_n', hf_unrec_n, 'ph', ph_unrec, 'ph_n', ph_unrec_n),
           'reconciled', jsonb_build_object('hf', hf_unrec + hf_sum, 'hf_n', hf_unrec_n + hf_sum_n,
                                            'ph', ph_unrec + ph_sum, 'ph_n', ph_unrec_n + ph_sum_n),
           'difference', jsonb_build_object('amount', (hf_unrec + hf_sum) - (ph_unrec + ph_sum),
                                            'n', (hf_unrec_n + hf_sum_n) - (ph_unrec_n + ph_sum_n)))
    into v_rec
    from t;

  -- ---- Coverage (#12): pinakamaagang filing date ng na-match na HF claim hanggang Report Date ----
  select jsonb_build_object('received_start', min(date_filed), 'received_end', m.report_date) into v_cov
    from public.recon_hf_results where match_id = p_match and in_universe;

  return jsonb_build_object(
    'version', case when p_internal then 'internal' else 'facility' end,
    'header', jsonb_build_object(
       'hospital_name', v_fac.name, 'accreditation_no', v_fac.accreditation_no, 'branch', v_fac.branch,
       'report_date', m.report_date, 'prev_report_date', m.prev_report_date, 'matching_date', m.matching_date,
       'matched_at', m.finished_at),
    'coverage', v_cov,
    'hf_status', v_hf,
    'ho_status', v_ho,
    'reconciliation', v_rec);
end;
$$;

create or replace function public.annex_a(p_match uuid, p_internal boolean)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  m public.recon_matches;
  v jsonb;
begin
  select * into m from public.recon_matches where id = p_match and status = 'done';
  if not found or not public.can_view_facility(m.facility_id) then
    raise exception 'Match not found' using errcode = '42501';
  end if;
  if p_internal and not public.app_user_is_philhealth() then
    raise exception 'Internal Annex A is for PhilHealth only' using errcode = '42501';
  end if;
  select a.data into v from public.recon_annex a
   where a.match_id = p_match and a.version = case when p_internal then 'internal' else 'facility' end;
  if v is null then
    v := public.annex_a_compute(p_match, coalesce(p_internal, false));
  end if;
  return jsonb_set(v, '{header,matched_at}', coalesce(to_jsonb(m.finished_at), 'null'::jsonb));
end;
$$;

-- Pareho ng 0023, dagdag ang pag-save ng Annex A (internal at facility) sa parehong subtransaction
create or replace function public.process_matching_queue()
returns int
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.recon_matches
   where status = 'running' and finished_at is null and started_at > clock_timestamp() - interval '5 minutes'
   order by started_at
   limit 1
   for update skip locked;
  if v_id is null then
    return 0;
  end if;

  begin
    perform public.do_matching(v_id);
    analyze public.recon_hf_results;
    perform public.do_matching_yugto2(v_id);
    -- Naka-save na Annex A; kapag pumalya, hindi pinapalya ang matching (kukuwentahin na lang ng annex_a kapag binuksan)
    begin
      insert into public.recon_annex (match_id, facility_id, version, data)
      select m.id, m.facility_id, 'internal', public.annex_a_compute(m.id, true) from public.recon_matches m where m.id = v_id
      union all
      select m.id, m.facility_id, 'facility', public.annex_a_compute(m.id, false) from public.recon_matches m where m.id = v_id;
    exception when others then
      raise warning 'Annex A precompute failed for match %: %', v_id, sqlerrm;
    end;
    update public.recon_matches set finished_at = clock_timestamp() where id = v_id;
  exception when others or query_canceled then
    update public.recon_matches set status = 'failed', error = left(sqlerrm, 500), finished_at = clock_timestamp() where id = v_id;
  end;
  return 1;
end;
$$;

revoke execute on function public.annex_a_compute(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.annex_a(uuid, boolean)         from public, anon;
grant  execute on function public.annex_a(uuid, boolean)         to authenticated;
revoke execute on function public.process_matching_queue()       from public, anon, authenticated;

-- Naka-save na Annex A ng mga current na matching (ang luma ay kinukuwenta on the fly kapag binuksan)
insert into public.recon_annex (match_id, facility_id, version, data)
select m.id, m.facility_id, x.version, public.annex_a_compute(m.id, x.version = 'internal')
  from public.recon_matches m cross join (values ('internal'), ('facility')) x(version)
 where m.status = 'done' and m.is_current;