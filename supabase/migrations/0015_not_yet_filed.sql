-- 0015_not_yet_filed.sql
-- NOT YET FILED (RECON_SPEC §3c): kapag DATE_REC > cutoff, ang status as of cutoff ay NOT YET FILED;
-- hindi kasama sa status totals ng cutoff na iyon (Annex A), walang amount used for recon sa cutoff na iyon;
-- sa reconciliation as of Report Date ay gaya ng IN PROCESS (pansamantala, Open Question #27).
-- Pinapalitan (create or replace, walang DROP) ang do_matching (mula 0011) at annex_a (mula 0013).

create or replace function public.do_matching(p_match uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  m      public.recon_matches;
  r      public.recon_runs;
  v_cut  record;
  v_kind text;
begin
  select * into m from public.recon_matches where id = p_match;
  -- Lock ang run (gaya ng dati: hindi naglo-lock ng run_uploads → walang deadlock sa add/finish/discard)
  select * into r from public.recon_runs where id = m.run_id for update;
  if r.status <> 'draft' then raise exception 'Run is no longer a draft'; end if;
  if r.hf_submission_id is null then raise exception 'Walang HF ICS submission ang run'; end if;
  if exists (select 1 from public.run_uploads where run_id = r.id and status = 'uploading') then
    raise exception 'May upload na hindi tapos (uploading)';
  end if;
  -- Suriin ulit sa oras ng pagtakbo (puwedeng may na-discard mula nang mailagay sa pila)
  foreach v_kind in array array['ho_ics', 'raw_matching', 'status_trail', 'payment_details'] loop
    if not exists (select 1 from public.run_uploads where run_id = r.id and status = 'complete' and kind = v_kind) then
      raise exception 'Kulang ang upload: %', v_kind;
    end if;
  end loop;

  update public.recon_matches
     set report_date = r.report_date, prev_report_date = r.prev_report_date, matching_date = r.matching_date,
         coverage_start = r.coverage_start, coverage_end = r.coverage_end, hf_submission_id = r.hf_submission_id
   where id = p_match;

  -- ---- Mga input (complete uploads lang) ----
  create temp table _up on commit drop as
    select id, kind, created_at from public.run_uploads where run_id = r.id and status = 'complete';

  -- Raw Matching: pinakabagong row bawat series (§3c-bis); mga kailangang column lang
  create temp table _raw on commit drop as
    select distinct on (rc.series)
           rc.series, rc.mecno, rc.patlname, rc.patfname, rc.patmname, rc.worlname, rc.worfname, rc.wormname,
           rc.date_adm, rc.date_dis, rc.date_rec, rc.date_recon, rc.last_refiled, rc.status,
           rc.total_acr_amount, rc.latest_check_dt, rc.latest_ctrl_no, rc.latest_ctrl_dt,
           count(*) over (partition by rc.series) as dup_count
    from public.raw_claims rc join _up u on u.id = rc.upload_id
    where rc.series is not null
    order by rc.series, rc.latest_check_dt desc nulls last, rc.latest_ctrl_dt desc nulls last,
             rc.date_recon desc nulls last, rc.last_refiled desc nulls last, rc.date_rec desc nulls last,
             u.created_at desc, rc.row_no desc;
  create index on _raw (series);
  analyze _raw;

  -- HO ICS: pinakabagong row bawat series (para sa "amount on PHIC books")
  create temp table _ho on commit drop as
    select distinct on (h.series) h.series, h.estimated_amt
    from public.ho_ics_rows h join _up u on u.id = h.upload_id
    where h.series is not null
    order by h.series, h.recref desc nulls last, u.created_at desc, h.row_no desc;
  create index on _ho (series);
  analyze _ho;

  -- Mapping: i-resolve nang isang beses bawat natatanging PROCESS (exact muna, tapos pinakamahabang LIKE pattern)
  create temp table _pmap on commit drop as
    select d.process,
           coalesce(
             (select pm.interpretation from public.process_status_map pm where not pm.is_pattern and pm.process = d.process),
             (select pm.interpretation from public.process_status_map pm
               where pm.is_pattern and d.process like pm.process order by length(pm.process) desc limit 1),
             'UNMAPPED') as interp
    from (select distinct upper(trim(st.process)) as process
            from public.status_trail st join _up u on u.id = st.upload_id
           where st.series is not null and st.date_tagged is not null) d;

  create temp table _trail on commit drop as
    select st.series, st.date_tagged, st.time_rec, st.row_no, u.created_at as up_at,
           upper(trim(st.process)) as process, pm.interp
    from public.status_trail st
    join _up u on u.id = st.upload_id
    left join _pmap pm on pm.process = upper(trim(st.process))
    where st.series is not null and st.date_tagged is not null;
  create index on _trail (series, date_tagged desc, time_rec desc);
  analyze _trail;

  insert into public.recon_match_unmapped (match_id, facility_id, process, row_count)
  select p_match, r.facility_id, coalesce(t.process, '(blank)'), count(*)::int
    from _trail t where t.interp = 'UNMAPPED' group by coalesce(t.process, '(blank)');

  -- Payment Details: bayad lang kung may OR date o mode of payment (§3d)
  create temp table _pay on commit drop as
    select * from (
      select p.series, p.date_ext, p.check_no, p.check_dt, p.isirm, p.is_dcpm, p.pr_no, p.tranche_number,
             p.receipt_no, p.receipt_dt, p.total_tot_amnt, p.row_no, u.created_at as up_at,
             coalesce(p.check_dt, p.date_ext, p.receipt_dt) as pay_date,
             case when p.date_ext is not null then 'AC'
                  when p.check_no is not null then 'CHECK'
                  when p.isirm = 'T' then 'IRM'
                  when p.is_dcpm = 'T' then 'DCPM LIQ'
                  when p.pr_no is not null then 'PR' end as mode,
             case when p.tranche_number ~ '^\d{1,9}$' then p.tranche_number::int end as tranche_int
      from public.payment_details p join _up u on u.id = p.upload_id
      where p.series is not null
    ) q
    where q.mode is not null or q.receipt_dt is not null;
  create index on _pay (series);
  analyze _pay;

  -- Lahat ng series na kailangan ng status: HF ICS (valid) + HO ICS
  create temp table _series on commit drop as
    select distinct claim_series as series from public.hf_ics_rows
     where submission_id = r.hf_submission_id and claim_series is not null
    union
    select series from _ho;
  create index on _series (series);
  analyze _series;

  -- ---- Status bawat cutoff (decision table §3c) ----
  create temp table _st (k text, series text, status text, trail_date date, trail_process text, paid_amt numeric) on commit drop;
  for v_cut in
    select 'rd'::text as k, r.report_date as d
    union all select 'pd'::text, r.prev_report_date where r.prev_report_date is not null
    union all select 'md'::text, r.matching_date
  loop
    insert into _st (k, series, status, trail_date, trail_process, paid_amt)
    select v_cut.k, s.series,
           case
             when rw.series is null then 'UNMATCHED'
             when rw.date_rec is not null and rw.date_rec > v_cut.d then 'NOT YET FILED'
             when lp.series is not null then 'PAID'
             when lt.interp = 'FOR PAYMENT' then 'APPROVED FOR PAYMENT'
             when lt.interp = 'DENIED' then 'DENIED'
             when lt.interp = 'RTH/DENIED' then case rw.status when 'P' then 'RTH' when 'D' then 'DENIED' else 'IN PROCESS' end
             when lt.interp = 'IN PROCESS' then 'IN PROCESS'
             when lt.interp = 'UNMAPPED' then 'UNMAPPED'
             else case rw.status when 'G' then 'APPROVED FOR PAYMENT' when 'D' then 'DENIED' when 'P' then 'RTH' else 'IN PROCESS' end
           end,
           lt.date_tagged, lt.process, coalesce(lp.total_tot_amnt, 0)
    from _series s
    left join _raw rw on rw.series = s.series
    left join (select distinct on (t.series) t.series, t.date_tagged, t.process, t.interp
                 from _trail t where t.date_tagged <= v_cut.d
                order by t.series, t.date_tagged desc, t.time_rec desc nulls last, t.up_at desc, t.row_no desc) lt
           on lt.series = s.series
    left join (select distinct on (p.series) p.series, p.total_tot_amnt
                 from _pay p where p.pay_date is null or p.pay_date <= v_cut.d
                order by p.series, p.check_dt desc nulls last, p.date_ext desc nulls last, p.receipt_dt desc nulls last,
                         p.tranche_int desc nulls last, p.up_at desc, p.row_no desc) lp
           on lp.series = s.series;
  end loop;
  create index on _st (k, series);
  analyze _st;

  -- Pinakabagong payment row (hanggang matching date) para sa mga payment column ng report
  create temp table _paylast on commit drop as
    select distinct on (p.series) p.*
    from _pay p where p.pay_date is null or p.pay_date <= r.matching_date
    order by p.series, p.check_dt desc nulls last, p.date_ext desc nulls last, p.receipt_dt desc nulls last,
             p.tranche_int desc nulls last, p.up_at desc, p.row_no desc;
  create index on _paylast (series);
  analyze _paylast;

  -- ---- HF ICS results (Matching Report + §4b) ----
  insert into public.recon_hf_results (
    match_id, facility_id, item_no, hf_row_id, hf_row_no, claim_series_raw, claim_series, ics_amount,
    is_duplicate, in_ho_ics, in_universe, universe_duplicate,
    member_id, pat_lname, pat_fname, pat_mname, mem_lname, mem_fname, mem_mname,
    date_adm, date_dis, date_filed, date_recon, last_refiled, filing_tat, refiling_tat,
    raw_status, all_case_rate, latest_check_dt, amount_on_phic_books,
    status_rd, trail_date_rd, trail_process_rd, status_pd, trail_date_pd, trail_process_pd,
    status_md, trail_date_md, trail_process_md,
    bank_advise_date, check_no, check_dt, is_irm, is_dcpm, pr_no, or_no, or_date, tranche_number,
    mode_of_payment, payment_status, total_amount_paid,
    amount_used_rd, amount_used_pd, amount_used_md,
    ctrl_no, ctrl_dt, date_rth, date_denied,
    recon_amount, upgrade_downgrade, reconciling_item)
  select p_match, r.facility_id, b.item_no, b.hf_row_id, b.hf_row_no, b.claim_series_raw, b.claim_series, b.ics_amount,
         b.is_duplicate, b.in_ho_ics, b.in_universe, b.universe_duplicate,
         b.mecno, b.patlname, b.patfname, b.patmname, b.worlname, b.worfname, b.wormname,
         b.date_adm, b.date_dis, b.date_rec, b.date_recon, b.last_refiled,
         b.date_rec - b.date_dis, b.last_refiled - b.date_dis,
         b.raw_status, b.total_acr_amount, b.latest_check_dt, b.ho_amt,
         b.st_rd, b.td_rd, b.tp_rd, b.st_pd, b.td_pd, b.tp_pd, b.st_md, b.td_md, b.tp_md,
         b.p_date_ext, b.p_check_no, b.p_check_dt, b.p_isirm = 'T', b.p_is_dcpm = 'T', b.p_pr_no,
         b.p_receipt_no, b.p_receipt_dt, b.p_tranche, b.p_mode,
         case when b.st_md = 'PAID' then 'PAID' when b.st_md <> 'DUPLICATE' and b.raw_status = 'G' then 'APPROVED FOR PAYMENT' end,
         case when b.st_md = 'PAID' then b.paid_md else 0 end,
         -- §4a: PAID → amount paid; DUPLICATE → ICS amount; kung hindi → amount on PHIC books → all case rate → ICS amount
         case when b.st_rd = 'NOT YET FILED' then null when b.st_rd = 'PAID' then b.paid_rd when b.st_rd = 'DUPLICATE' then b.ics_amount
              else coalesce(b.ho_amt, b.total_acr_amount, b.ics_amount) end,
         case when b.st_pd is null or b.st_pd = 'NOT YET FILED' then null when b.st_pd = 'PAID' then b.paid_pd when b.st_pd = 'DUPLICATE' then b.ics_amount
              else coalesce(b.ho_amt, b.total_acr_amount, b.ics_amount) end,
         case when b.st_md = 'NOT YET FILED' then null when b.st_md = 'PAID' then b.paid_md when b.st_md = 'DUPLICATE' then b.ics_amount
              else coalesce(b.ho_amt, b.total_acr_amount, b.ics_amount) end,
         case when b.raw_status in ('P', 'D') then b.latest_ctrl_no end,
         case when b.raw_status in ('P', 'D') then b.latest_ctrl_dt end,
         case when b.raw_status = 'P' then b.latest_ctrl_dt end,
         case when b.raw_status = 'D' then b.latest_ctrl_dt end,
         b.recon_amount,
         b.recon_amount - b.ics_amount,
         case when b.is_duplicate then 'Deduct from HF: Unmatched Claims – Duplicate'
              when b.in_ho_ics then 'Non-Reconciling Item'
              when b.st_rd = 'UNMATCHED' then 'Deduct from HF: Unmatched'
              when b.st_rd = 'APPROVED FOR PAYMENT' then 'Add to PHIC Balance: Payment in Transit'
              when b.st_rd in ('IN PROCESS', 'UNMAPPED', 'NOT YET FILED') then 'Add to PHIC Balance: In Process'
              else 'Non-Reconciling Item' end
  from (
    select x.*,
           -- §4b Recon amount (as of report date); #5 duplicate → ICS; #2 APPROVED → all case rate; UNMAPPED → gaya ng IN PROCESS (#26)
           case when x.is_duplicate then x.ics_amount
                when x.st_rd = 'PAID' then x.paid_rd
                when x.st_rd = 'APPROVED FOR PAYMENT' then coalesce(x.total_acr_amount, x.ics_amount)
                when x.st_rd in ('RTH', 'DENIED', 'UNMATCHED') then x.ics_amount
                else coalesce(x.ho_amt, x.total_acr_amount, x.ics_amount) end as recon_amount
    from (
      select y.*,
             case when y.is_duplicate then 'DUPLICATE' else coalesce(y.srd_status, 'UNMATCHED') end as st_rd,
             case when r.prev_report_date is null then null
                  when y.is_duplicate then 'DUPLICATE' else coalesce(y.spd_status, 'UNMATCHED') end as st_pd,
             case when y.is_duplicate then 'DUPLICATE' else coalesce(y.smd_status, 'UNMATCHED') end as st_md
      from (
        select row_number() over (order by h.row_no) as item_no,
               h.id as hf_row_id, h.row_no as hf_row_no, h.claim_series_raw, h.claim_series, h.ics_amount,
               (h.claim_series is not null
                and row_number() over (partition by h.claim_series order by h.row_no) > 1) as is_duplicate,
               (ho.series is not null) as in_ho_ics,
               (rw.series is not null) as in_universe,
               coalesce(rw.dup_count > 1, false) as universe_duplicate,
               rw.mecno, rw.patlname, rw.patfname, rw.patmname, rw.worlname, rw.worfname, rw.wormname,
               rw.date_adm, rw.date_dis, rw.date_rec, rw.date_recon, rw.last_refiled,
               rw.status as raw_status, rw.total_acr_amount, rw.latest_check_dt, rw.latest_ctrl_no, rw.latest_ctrl_dt,
               ho.estimated_amt as ho_amt,
               srd.status as srd_status, srd.trail_date as td_rd, srd.trail_process as tp_rd, srd.paid_amt as paid_rd,
               spd.status as spd_status, spd.trail_date as td_pd, spd.trail_process as tp_pd, spd.paid_amt as paid_pd,
               smd.status as smd_status, smd.trail_date as td_md, smd.trail_process as tp_md, smd.paid_amt as paid_md,
               pl.date_ext as p_date_ext, pl.check_no as p_check_no, pl.check_dt as p_check_dt, pl.isirm as p_isirm,
               pl.is_dcpm as p_is_dcpm, pl.pr_no as p_pr_no, pl.receipt_no as p_receipt_no, pl.receipt_dt as p_receipt_dt,
               pl.tranche_number as p_tranche, pl.mode as p_mode
        from public.hf_ics_rows h
        left join _raw rw on rw.series = h.claim_series
        left join _ho ho on ho.series = h.claim_series
        left join _st srd on srd.k = 'rd' and srd.series = h.claim_series
        left join _st spd on spd.k = 'pd' and spd.series = h.claim_series
        left join _st smd on smd.k = 'md' and smd.series = h.claim_series
        left join _paylast pl on pl.series = h.claim_series
        where h.submission_id = r.hf_submission_id
      ) y
    ) x
  ) b;

  -- ---- HO ICS results (§4c) ----
  insert into public.recon_ho_results (match_id, facility_id, item_no, ho_row_id, series_raw, series, estimated_amt, recref,
                                       is_duplicate, in_hf_ics, universe_status, within_period,
                                       status_rd, status_pd, status_md, reconciling_item)
  select p_match, r.facility_id, c.item_no, c.id, c.series_raw, c.series, c.estimated_amt, c.recref,
         c.is_duplicate, c.in_hf, c.universe_status, c.within_period, c.st_rd, c.st_pd, c.st_md,
         case when c.series is null then 'Invalid Claim Series'
              when not c.in_universe then 'Deduct from PHIC: Deleted Claim'
              when c.within_period = false then 'Deduct from PHIC: For Archiving – Recon Exception'
              when c.st_rd in ('PAID', 'RTH', 'DENIED') then 'Deduct from PHIC: Already Paid/RTH/Denied'
              when not c.in_hf and c.st_rd in ('APPROVED FOR PAYMENT', 'IN PROCESS', 'UNMAPPED', 'NOT YET FILED')
                then 'Add to HF: Processed claims not reported by HF'
              else 'Non-Reconciling Item' end
  from (
    select row_number() over (order by u.created_at, h.row_no) as item_no,
           h.id, h.series_raw, h.series, h.estimated_amt, h.recref,
           (h.series is not null
            and row_number() over (partition by h.series order by u.created_at, h.row_no) > 1) as is_duplicate,
           (hf.series is not null) as in_hf,
           (rw.series is not null) as in_universe,
           coalesce(rw.status, '-') as universe_status,
           -- #10b: eksaktong petsa; walang coverage → within; walang RECREF → NULL (itinuturing na within)
           case when r.coverage_start is null and r.coverage_end is null then true
                when h.recref is null then null
                else h.recref >= coalesce(r.coverage_start, '1900-01-01'::date)
                 and h.recref <= coalesce(r.coverage_end, '2100-12-31'::date) end as within_period,
           coalesce(srd.status, 'UNMATCHED') as st_rd,
           case when r.prev_report_date is not null then coalesce(spd.status, 'UNMATCHED') end as st_pd,
           coalesce(smd.status, 'UNMATCHED') as st_md
    from public.ho_ics_rows h
    join _up u on u.id = h.upload_id
    left join (select distinct claim_series as series from public.hf_ics_rows
                where submission_id = r.hf_submission_id and claim_series is not null) hf on hf.series = h.series
    left join _raw rw on rw.series = h.series
    left join _st srd on srd.k = 'rd' and srd.series = h.series
    left join _st spd on spd.k = 'pd' and spd.series = h.series
    left join _st smd on smd.k = 'md' and smd.series = h.series
  ) c;

  -- ---- Buod (isang pass bawat table) ----
  update public.recon_matches mm
     set summary = (
           select jsonb_build_object(
                    'hf_rows', count(*),
                    'hf_invalid', count(*) filter (where claim_series is null),
                    'hf_duplicates', count(*) filter (where is_duplicate),
                    'hf_unmatched', count(*) filter (where status_rd = 'UNMATCHED'),
                    'hf_unmapped', count(*) filter (where 'UNMAPPED' in (status_rd, status_pd, status_md)),
                    'hf_not_yet_filed_rd', count(*) filter (where status_rd = 'NOT YET FILED'),
                    'hf_not_yet_filed_pd', count(*) filter (where status_pd = 'NOT YET FILED'))
           from public.recon_hf_results where match_id = p_match)
        || (select jsonb_build_object('ho_rows', count(*)) from public.recon_ho_results where match_id = p_match)
        || (select jsonb_build_object('unmapped_process_count', count(*)) from public.recon_match_unmapped where match_id = p_match)
   where mm.id = p_match;

  update public.recon_matches set is_current = false where run_id = r.id and is_current and id <> p_match;
  update public.recon_matches set status = 'done', is_current = true, finished_at = now() where id = p_match;
  update public.recon_runs set status = 'matched', updated_by = m.requested_by, updated_at = now() where id = r.id;
end;
$$;

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
  -- amount = amount used for recon ng cutoff; percentage = bahagi ng kabuuang halaga
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
           -- Upgrade (downgrade) = kabuuang amount used for recon − kabuuang ICS amount
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
  -- FOR ARCHIVING = Recon Exception o Deleted Claim; facility version: HO rows na nasa HF ICS lang
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
        where status_rd in ('APPROVED FOR PAYMENT', 'IN PROCESS', 'UNMAPPED', 'NOT YET FILED'))                        as hf_upgrade,
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

revoke execute on function public.do_matching(uuid) from public, anon, authenticated;
revoke execute on function public.annex_a(uuid, boolean) from public, anon;
grant  execute on function public.annex_a(uuid, boolean) to authenticated;
