-- 0020_annex_balance.sql
-- Annex A: dapat balanse ang COUNT at AMOUNT (desisyon ng user, 2026-10-06), at ang Matching Report (HF) at HO ICS Recon (HO)
-- ang breakdown: bawat claim ay may "Annex A line" sa HF column at/o PHILHEALTH column; ang kabuuan ng bawat linya sa
-- Annex = kabuuan ng mga row na may ganoong line.
-- - Facility version: ang sariling HF ICS lang + ang HO ICS rows ng parehong mga claim (in_hf_ics). Balanse rin.
-- - Internal: HF ICS + buong HO ICS + matching ni FINMAREP.
-- Mga bagong reconciling line (para mag-balanse):
--   * "For Archiving – Recon Exception" sa HF column: claim na nasa HF ICS at HO ICS pero labas sa LOI coverage
--     (APPROVED / IN PROCESS / UNMAPPED / NOT YET FILED sa HF) — ibinabawas sa parehong side.
--   * "Net Upgrade (Downgrade) – PHIC books" sa PHILHEALTH column: Recon Amount ng HF − HO estimated amount, para sa mga claim
--     na nasa reconciled balance ng parehong side (hal. APPROVED FOR PAYMENT = All Case Rate vs HO amount, #2).
--   * "Duplicate on HO ICS" at "Invalid Claim Series – HO ICS" sa PHILHEALTH column (lalabas lang kapag may laman).
-- Walang DROP / DELETE / TRUNCATE. Nire-recompute ang annex lines ng lahat ng natapos na matching (computed columns lang).

alter table public.recon_hf_results
  add column annex_hf_line text,
  add column annex_ph_line text,
  add column phic_upgrade  numeric(14, 2);

alter table public.recon_ho_results
  add column annex_ph_line text,
  add column annex_hf_line text;

-- ---------------------------------------------------------------------------
-- Annex A line bawat claim (as of Report Date)
-- ---------------------------------------------------------------------------
create function public.do_matching_annex(p_match uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  -- Iisang "canonical" HO row bawat series = ang ginagamit ng do_matching para sa Amount on PHIC books
  -- (pinakabagong RECREF, tapos huling row). Ang iba ay duplicate. Kaya phic_upgrade = Recon Amount − Amount on PHIC books.
  update public.recon_ho_results o
     set is_duplicate = (o.id <> c.id)
    from (select distinct on (series) series, id from public.recon_ho_results
           where match_id = p_match and series is not null
           order by series, recref desc nulls last, item_no desc) c
   where o.match_id = p_match and o.series = c.series;

  -- HO ICS rows
  update public.recon_ho_results o
     set annex_ph_line = case
           when o.series is null then 'Invalid Claim Series – HO ICS'
           when o.is_duplicate then 'Duplicate on HO ICS'
           when o.reconciling_item = 'Deduct from PHIC: Deleted Claim' then 'For Archiving – Unmatched (Deleted) – Not on NClaims'
           when o.reconciling_item = 'Deduct from PHIC: For Archiving – Recon Exception' then 'For Archiving – Recon Exception'
           when o.reconciling_item = 'Deduct from PHIC: Already Paid/RTH/Denied' then
             case o.status_rd when 'PAID' then 'Paid Claims' when 'DENIED' then 'Denied Claims' else 'RTH Claims' end
           else 'Reconciled Balance' end,
         annex_hf_line = case
           when o.series is not null and not o.is_duplicate
                and o.reconciling_item = 'Add to HF: Processed claims not reported by HF' then 'In Process – Not on HF ICS' end,
         reconciling_item = case
           when o.series is not null and o.is_duplicate
                and o.reconciling_item in ('Non-Reconciling Item', 'Add to HF: Processed claims not reported by HF')
             then 'Deduct from PHIC: Duplicate on HO ICS'
           else o.reconciling_item end
   where o.match_id = p_match;

  -- HF ICS rows (kasama ang katapat na HO row: ang hindi duplicate)
  update public.recon_hf_results h
     set annex_hf_line = x.hf_line,
         annex_ph_line = x.ph_line,
         phic_upgrade  = x.phic_up,
         reconciling_item = case when x.hf_line = 'For Archiving – Recon Exception'
                                 then 'Deduct from HF: For Archiving – Recon Exception' else h.reconciling_item end
    from (
      select h2.id,
             case when h2.is_duplicate then 'Unmatched Claims – Duplicate'
                  when h2.status_rd = 'UNMATCHED' then 'Unmatched'
                  when h2.status_rd = 'PAID' then 'Paid Claims'
                  when h2.status_rd = 'DENIED' then 'Denied Claims'
                  when h2.status_rd = 'RTH' then 'RTH Claims'
                  when ho.annex_ph_line = 'For Archiving – Recon Exception' then 'For Archiving – Recon Exception'
                  else 'Reconciled Balance' end as hf_line,
             case when h2.is_duplicate or h2.status_rd in ('UNMATCHED', 'PAID', 'DENIED', 'RTH') then null
                  when ho.series is null then
                    case when h2.reconciling_item = 'Add to PHIC Balance: Payment in Transit'
                         then 'Payment in Transit (ABP – Processed)' else 'In Process – Not on HO ICS' end
                  when ho.annex_ph_line = 'Reconciled Balance' then 'Reconciled Balance'
                  else null end as ph_line,
             case when not h2.is_duplicate and h2.status_rd not in ('UNMATCHED', 'PAID', 'DENIED', 'RTH')
                       and ho.annex_ph_line = 'Reconciled Balance'
                  then h2.recon_amount - ho.estimated_amt end as phic_up
        from public.recon_hf_results h2
        left join public.recon_ho_results ho
               on ho.match_id = h2.match_id and ho.series = h2.claim_series and not ho.is_duplicate
       where h2.match_id = p_match
    ) x
   where h.id = x.id;
end;
$$;

-- Pareho ng 0017, dagdag ang do_matching_annex sa parehong subtransaction
create or replace function public.process_matching_queue()
returns int
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.recon_matches
   where status = 'queued'
   order by requested_at
   limit 1
   for update skip locked;
  if v_id is null then
    return 0;
  end if;

  update public.recon_matches set status = 'running', started_at = clock_timestamp() where id = v_id;
  begin
    perform public.do_matching(v_id);
    perform public.do_matching_yugto2(v_id);
    perform public.do_matching_annex(v_id);
    update public.recon_matches set finished_at = clock_timestamp() where id = v_id;
  exception when others or query_canceled then
    -- Na-rollback ang lahat (subtransaction); itala lang ang error
    update public.recon_matches set status = 'failed', error = left(sqlerrm, 500), finished_at = clock_timestamp() where id = v_id;
  end;
  return 1;
end;
$$;

-- ---------------------------------------------------------------------------
-- annex_a: pareho ng 0015, maliban sa "Reconciliation of balances" (may count, mga bagong linya, difference)
-- ---------------------------------------------------------------------------
create or replace function public.annex_a(p_match uuid, p_internal boolean)
returns jsonb
language plpgsql stable security definer
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
  select * into m from public.recon_matches where id = p_match and status = 'done';
  if not found or not public.can_view_facility(m.facility_id) then
    raise exception 'Match not found' using errcode = '42501';
  end if;
  if p_internal and not public.app_user_is_philhealth() then
    raise exception 'Internal Annex A is for PhilHealth only' using errcode = '42501';
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

revoke execute on function public.do_matching_annex(uuid)    from public, anon, authenticated;
revoke execute on function public.process_matching_queue()  from public, anon, authenticated;
revoke execute on function public.annex_a(uuid, boolean)     from public, anon;
grant  execute on function public.annex_a(uuid, boolean)     to authenticated;

-- I-compute ang annex lines ng mga natapos nang matching (para hindi blangko ang lumang resulta)
select public.do_matching_annex(id) from public.recon_matches where status = 'done';
