-- 0013_annex_a.sql
-- Annex A (RECON_SPEC §4d + mga desisyon sa §3c-ter), kinukuwenta mula sa isang matching result.
--   annex_a(match, internal)
--     internal = true  → PhilHealth lang; kumpleto (kasama ang HO claims na wala sa HF ICS)
--     internal = false → Facility version; hindi kasama ang HO rows na wala sa HF ICS at ang linyang
--                        "In Process – Not on HF ICS" (PhilHealth-only na impormasyon)
-- SECURITY DEFINER dahil ang facility version ay gumagamit ng HO rows (na hindi nababasa ng facility sa RLS);
-- mano-manong sinusuri ang saklaw ng caller.

create function public.annex_a(p_match uuid, p_internal boolean)
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
  -- amount = amount used for recon ng cutoff; percentage = bahagi ng kabuuang halaga
  with hf as (select * from public.recon_hf_results where match_id = p_match),
  per as (
    select 'rd' as k, status_rd as st, count(*) as n, coalesce(sum(amount_used_rd), 0) as amt from hf group by status_rd
    union all
    select 'pd', status_pd, count(*), coalesce(sum(amount_used_pd), 0) from hf where status_pd is not null group by status_pd
    union all
    select 'md', status_md, count(*), coalesce(sum(amount_used_md), 0) from hf group by status_md
  ),
  tot as (select k, sum(n) as n, sum(amt) as amt from per group by k)
  select jsonb_build_object(
           'rows', coalesce((select jsonb_agg(jsonb_build_object('cutoff', p.k, 'status', p.st, 'claims', p.n, 'amount', p.amt,
                                     'pct', case when t.amt <> 0 then round(p.amt / t.amt * 100, 2) end))
                             from per p join tot t on t.k = p.k), '[]'::jsonb),
           'totals', coalesce((select jsonb_agg(jsonb_build_object('cutoff', k, 'claims', n, 'amount', amt)) from tot), '[]'::jsonb),
           -- Upgrade (downgrade) = kabuuang amount used for recon − kabuuang ICS amount
           'upgrade', jsonb_build_object(
              'rd', (select coalesce(sum(amount_used_rd), 0) - coalesce(sum(ics_amount), 0) from hf),
              'pd', (select case when m.prev_report_date is null then null
                                 else coalesce(sum(amount_used_pd), 0) - coalesce(sum(ics_amount), 0) end from hf),
              'md', (select coalesce(sum(amount_used_md), 0) - coalesce(sum(ics_amount), 0) from hf)))
    into v_hf;

  -- ---- Summary of Status of ICS Claims (PhilHealth / HO side), 3 cutoff ----
  -- FOR ARCHIVING = Recon Exception o Deleted Claim; facility version: HO rows na nasa HF ICS lang
  with ho as (
    select o.*,
           (o.reconciling_item in ('Deduct from PHIC: For Archiving – Recon Exception', 'Deduct from PHIC: Deleted Claim')) as archive
      from public.recon_ho_results o
     where o.match_id = p_match and (p_internal or o.in_hf_ics)
  ),
  per as (
    select 'rd' as k, case when archive then 'FOR ARCHIVING' else status_rd end as st, count(*) as n,
           coalesce(sum(estimated_amt), 0) as amt from ho group by 2
    union all
    select 'pd', case when archive then 'FOR ARCHIVING' else status_pd end, count(*), coalesce(sum(estimated_amt), 0)
      from ho where status_pd is not null group by 2
    union all
    select 'md', case when archive then 'FOR ARCHIVING' else status_md end, count(*), coalesce(sum(estimated_amt), 0)
      from ho group by 2
  ),
  tot as (select k, sum(n) as n, sum(amt) as amt from per group by k)
  select jsonb_build_object(
           'rows', coalesce((select jsonb_agg(jsonb_build_object('cutoff', p.k, 'status', p.st, 'claims', p.n, 'amount', p.amt,
                                     'pct', case when t.amt <> 0 then round(p.amt / t.amt * 100, 2) end))
                             from per p join tot t on t.k = p.k), '[]'::jsonb),
           'totals', coalesce((select jsonb_agg(jsonb_build_object('cutoff', k, 'claims', n, 'amount', amt)) from tot), '[]'::jsonb))
    into v_ho;

  -- ---- Reconciliation of balances (as of Report Date; table sa §3c-ter) ----
  with hf as (select * from public.recon_hf_results where match_id = p_match),
  ho as (select * from public.recon_ho_results where match_id = p_match and (p_internal or in_hf_ics)),
  l as (
    select
      (select coalesce(sum(ics_amount), 0) from hf)                                                   as hf_unrec,
      (select coalesce(sum(estimated_amt), 0) from ho)                                                as ph_unrec,
      (select -coalesce(sum(ics_amount), 0) from hf where status_rd = 'PAID')                         as hf_paid,
      (select -coalesce(sum(ics_amount), 0) from hf where status_rd = 'DENIED')                       as hf_denied,
      (select -coalesce(sum(ics_amount), 0) from hf where status_rd = 'RTH')                          as hf_rth,
      (select -coalesce(sum(ics_amount), 0) from hf where status_rd = 'DUPLICATE')                    as hf_dup,
      (select -coalesce(sum(ics_amount), 0) from hf where status_rd = 'UNMATCHED')                    as hf_unmatched,
      (select coalesce(sum(estimated_amt), 0) from ho
        where reconciling_item = 'Add to HF: Processed claims not reported by HF')                    as hf_ip_not_hf,
      (select coalesce(sum(upgrade_downgrade), 0) from hf
        where status_rd in ('APPROVED FOR PAYMENT', 'IN PROCESS', 'UNMAPPED'))                        as hf_upgrade,
      (select -coalesce(sum(estimated_amt), 0) from ho
        where reconciling_item = 'Deduct from PHIC: Already Paid/RTH/Denied' and status_rd = 'PAID')   as ph_paid,
      (select -coalesce(sum(estimated_amt), 0) from ho
        where reconciling_item = 'Deduct from PHIC: Already Paid/RTH/Denied' and status_rd = 'DENIED') as ph_denied,
      (select -coalesce(sum(estimated_amt), 0) from ho
        where reconciling_item = 'Deduct from PHIC: Already Paid/RTH/Denied' and status_rd = 'RTH')    as ph_rth,
      (select coalesce(sum(recon_amount), 0) from hf
        where reconciling_item = 'Add to PHIC Balance: In Process')                                    as ph_ip_not_ho,
      (select coalesce(sum(recon_amount), 0) from hf
        where reconciling_item = 'Add to PHIC Balance: Payment in Transit')                            as ph_pit,
      (select -coalesce(sum(estimated_amt), 0) from ho
        where reconciling_item = 'Deduct from PHIC: For Archiving – Recon Exception')                  as ph_exception,
      (select -coalesce(sum(estimated_amt), 0) from ho
        where reconciling_item = 'Deduct from PHIC: Deleted Claim')                                    as ph_deleted
  )
  select jsonb_build_object(
           'lines', jsonb_build_array(
              jsonb_build_object('label', 'Paid Claims', 'hf', hf_paid, 'ph', ph_paid),
              jsonb_build_object('label', 'Denied Claims', 'hf', hf_denied, 'ph', ph_denied),
              jsonb_build_object('label', 'RTH Claims', 'hf', hf_rth, 'ph', ph_rth),
              jsonb_build_object('label', 'Unmatched Claims – Duplicate', 'hf', hf_dup, 'ph', null),
              jsonb_build_object('label', 'Unmatched', 'hf', hf_unmatched, 'ph', null))
            || case when p_internal
                    then jsonb_build_array(jsonb_build_object('label', 'In Process – Not on HF ICS', 'hf', hf_ip_not_hf, 'ph', null))
                    else '[]'::jsonb end
            || jsonb_build_array(
              jsonb_build_object('label', 'In Process – Not on HO ICS', 'hf', null, 'ph', ph_ip_not_ho),
              jsonb_build_object('label', 'Payment in Transit (ABP – Processed)', 'hf', null, 'ph', ph_pit),
              jsonb_build_object('label', 'For Archiving – Recon Exception', 'hf', null, 'ph', ph_exception),
              jsonb_build_object('label', 'For Archiving – Unmatched (Deleted) – Not on NClaims', 'hf', null, 'ph', ph_deleted),
              jsonb_build_object('label', 'Net Upgrade (Downgrade) – HF ICS', 'hf', hf_upgrade, 'ph', null)),
           'unreconciled', jsonb_build_object('hf', hf_unrec, 'ph', ph_unrec),
           'reconciled', jsonb_build_object(
              'hf', hf_unrec + hf_paid + hf_denied + hf_rth + hf_dup + hf_unmatched
                    + case when p_internal then hf_ip_not_hf else 0 end + hf_upgrade,
              'ph', ph_unrec + ph_paid + ph_denied + ph_rth + ph_ip_not_ho + ph_pit + ph_exception + ph_deleted))
    into v_rec
    from l;

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

revoke execute on function public.annex_a(uuid, boolean) from public, anon;
grant  execute on function public.annex_a(uuid, boolean) to authenticated;
