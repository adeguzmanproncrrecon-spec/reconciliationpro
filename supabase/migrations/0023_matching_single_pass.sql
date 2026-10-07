-- 0023_matching_single_pass.sql
-- Pagpapabilis ng matching sa malaking volume (pinahintulutan ng user, 2026-10-06).
-- Problema: pagkatapos i-insert ng do_matching ang 200k resulta, ina-update pa ito nang 2–3 beses (do_matching_yugto2,
-- do_matching_annex). Bawat UPDATE ay bagong kopya ng row na hindi nababawi hanggang matapos ang transaction, kaya
-- ~330 MB na resulta ay nagiging ~900 MB at napupuno ang disk / lumalampas sa oras.
-- Ayos:
-- 1) do_matching: kinukuwenta na sa mismong INSERT ang Patient Ref, Filed vs Actual, Annex A lines, PHIC upgrade, ang
--    "canonical" HO row (pinakabagong RECREF; ang iba ay Duplicate on HO ICS) at ang Recon Exception sa HF side.
--    Pareho ang resulta ng 0019/0020 (iisang lohika, inilipat lang).
-- 2) do_matching_yugto2: inalis ang buong-table na UPDATE ng patient_ref / filed_vs_actual (nasa do_matching na).
--    Ang Yugto 2 UPDATE ay para lang sa mga claim na may Yugto 2 data.
-- 3) Hindi na tinatawag ang do_matching_annex sa matching (nananatili ang function, hindi ginagamit).
-- 4) Nakikita na ang "running": hiwalay na cron job (claim-matching-job) na nagpapalit ng queued → running at nagko-commit
--    agad; ang process-matching-queue ang gumagawa ng matching sa job na "running" (naka-lock habang ginagawa; kung
--    maputol ang session sa unang 5 minuto, uulitin; kung hindi, minamarkahang failed pagkalipas ng 6 minuto).
--    Isa-isa lang ang tumatakbong matching (30 minutong statement_timeout mula 0021).
-- Walang DROP / DELETE / TRUNCATE (create or replace lang, at bagong cron job).

-- ---------------------------------------------------------------------------
-- do_matching (pareho ng 0015 + mga column ng 0019/0020 sa INSERT)
-- ---------------------------------------------------------------------------
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
  select * into r from public.recon_runs where id = m.run_id for update;
  if r.status <> 'draft' then raise exception 'Run is no longer a draft'; end if;
  if r.hf_submission_id is null then raise exception 'Walang HF ICS submission ang run'; end if;
  if exists (select 1 from public.run_uploads where run_id = r.id and status = 'uploading') then
    raise exception 'May upload na hindi tapos (uploading)';
  end if;
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

  -- HO ICS: "canonical" row bawat series (pinakabagong RECREF, tapos huling row) — amount on PHIC books at LOI coverage
  create temp table _ho on commit drop as
    select distinct on (h.series) h.series, h.estimated_amt,
           case when r.coverage_start is null and r.coverage_end is null then true
                when h.recref is null then null
                else h.recref >= coalesce(r.coverage_start, '1900-01-01'::date)
                 and h.recref <= coalesce(r.coverage_end, '2100-12-31'::date) end as within
    from public.ho_ics_rows h join _up u on u.id = h.upload_id
    where h.series is not null
    order by h.series, h.recref desc nulls last, u.created_at desc, h.row_no desc, h.id desc;
  create index on _ho (series);
  analyze _ho;

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

  create temp table _paylast on commit drop as
    select distinct on (p.series) p.*
    from _pay p where p.pay_date is null or p.pay_date <= r.matching_date
    order by p.series, p.check_dt desc nulls last, p.date_ext desc nulls last, p.receipt_dt desc nulls last,
             p.tranche_int desc nulls last, p.up_at desc, p.row_no desc;
  create index on _paylast (series);
  analyze _paylast;

  -- ---- HF ICS results (Matching Report + §4b + Annex A lines) — isang INSERT lang ----
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
    recon_amount, upgrade_downgrade, reconciling_item,
    patient_ref, filed_vs_actual, annex_hf_line, annex_ph_line, phic_upgrade)
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
              when b.ho_exception then 'Deduct from HF: For Archiving – Recon Exception'
              when b.in_ho_ics then 'Non-Reconciling Item'
              when b.st_rd = 'UNMATCHED' then 'Deduct from HF: Unmatched'
              when b.st_rd = 'APPROVED FOR PAYMENT' then 'Add to PHIC Balance: Payment in Transit'
              when b.st_rd in ('IN PROCESS', 'UNMAPPED', 'NOT YET FILED') then 'Add to PHIC Balance: In Process'
              else 'Non-Reconciling Item' end,
         b.patient_ref,
         -- Filed vs Actual Payment Upgrade (#15): PAID / APPROVED / IN PROCESS (+ UNMAPPED, NOT YET FILED) lang
         case when b.st_rd in ('PAID', 'APPROVED FOR PAYMENT', 'IN PROCESS', 'UNMAPPED', 'NOT YET FILED')
              then b.recon_amount - b.ics_amount end,
         -- Annex A line (HF column)
         case when b.is_duplicate then 'Unmatched Claims – Duplicate'
              when b.st_rd = 'UNMATCHED' then 'Unmatched'
              when b.st_rd = 'PAID' then 'Paid Claims'
              when b.st_rd = 'DENIED' then 'Denied Claims'
              when b.st_rd = 'RTH' then 'RTH Claims'
              when b.ho_exception then 'For Archiving – Recon Exception'
              else 'Reconciled Balance' end,
         -- Annex A line (PhilHealth column)
         case when b.is_duplicate or b.st_rd in ('UNMATCHED', 'PAID', 'DENIED', 'RTH') then null
              when not b.in_ho_ics then
                case when b.st_rd = 'APPROVED FOR PAYMENT' then 'Payment in Transit (ABP – Processed)' else 'In Process – Not on HO ICS' end
              when b.ho_exception then null
              else 'Reconciled Balance' end,
         -- PHIC books upgrade: Recon Amount − Amount on PHIC books (canonical HO row) ng mga nasa reconciled balance ng dalawang side
         case when not b.is_duplicate and b.in_ho_ics and not b.ho_exception
                   and b.st_rd not in ('UNMATCHED', 'PAID', 'DENIED', 'RTH')
              then b.recon_amount - b.ho_amt end
  from (
    select x.*,
           case when x.is_duplicate then x.ics_amount
                when x.st_rd = 'PAID' then x.paid_rd
                when x.st_rd = 'APPROVED FOR PAYMENT' then coalesce(x.total_acr_amount, x.ics_amount)
                when x.st_rd in ('RTH', 'DENIED', 'UNMATCHED') then x.ics_amount
                else coalesce(x.ho_amt, x.total_acr_amount, x.ics_amount) end as recon_amount,
           -- Nasa HO ICS pero labas sa LOI coverage, at nasa reconciled balance sana (APPROVED / IN PROCESS / UNMAPPED / NYF)
           (not x.is_duplicate and x.in_ho_ics and x.ho_within is false
            and x.st_rd in ('APPROVED FOR PAYMENT', 'IN PROCESS', 'UNMAPPED', 'NOT YET FILED')) as ho_exception
    from (
      select y.*,
             case when y.is_duplicate then 'DUPLICATE' else coalesce(y.srd_status, 'UNMATCHED') end as st_rd,
             case when r.prev_report_date is null then null
                  when y.is_duplicate then 'DUPLICATE' else coalesce(y.spd_status, 'UNMATCHED') end as st_pd,
             case when y.is_duplicate then 'DUPLICATE' else coalesce(y.smd_status, 'UNMATCHED') end as st_md
      from (
        select row_number() over (order by h.row_no) as item_no,
               h.id as hf_row_id, h.row_no as hf_row_no, h.claim_series_raw, h.claim_series, h.ics_amount, h.patient_ref,
               (h.claim_series is not null
                and row_number() over (partition by h.claim_series order by h.row_no) > 1) as is_duplicate,
               (ho.series is not null) as in_ho_ics,
               (rw.series is not null) as in_universe,
               coalesce(rw.dup_count > 1, false) as universe_duplicate,
               rw.mecno, rw.patlname, rw.patfname, rw.patmname, rw.worlname, rw.worfname, rw.wormname,
               rw.date_adm, rw.date_dis, rw.date_rec, rw.date_recon, rw.last_refiled,
               rw.status as raw_status, rw.total_acr_amount, rw.latest_check_dt, rw.latest_ctrl_no, rw.latest_ctrl_dt,
               ho.estimated_amt as ho_amt, ho.within as ho_within,
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

  -- ---- HO ICS results (§4c + Annex A lines) — isang INSERT lang ----
  insert into public.recon_ho_results (match_id, facility_id, item_no, ho_row_id, series_raw, series, estimated_amt, recref,
                                       is_duplicate, in_hf_ics, universe_status, within_period,
                                       status_rd, status_pd, status_md, reconciling_item, annex_ph_line, annex_hf_line)
  select p_match, r.facility_id, d.item_no, d.id, d.series_raw, d.series, d.estimated_amt, d.recref,
         d.is_duplicate, d.in_hf, d.universe_status, d.within_period, d.st_rd, d.st_pd, d.st_md,
         case when d.series is not null and d.is_duplicate
                   and d.base_item in ('Non-Reconciling Item', 'Add to HF: Processed claims not reported by HF')
              then 'Deduct from PHIC: Duplicate on HO ICS' else d.base_item end,
         case when d.series is null then 'Invalid Claim Series – HO ICS'
              when d.is_duplicate then 'Duplicate on HO ICS'
              when d.base_item = 'Deduct from PHIC: Deleted Claim' then 'For Archiving – Unmatched (Deleted) – Not on NClaims'
              when d.base_item = 'Deduct from PHIC: For Archiving – Recon Exception' then 'For Archiving – Recon Exception'
              when d.base_item = 'Deduct from PHIC: Already Paid/RTH/Denied' then
                case d.st_rd when 'PAID' then 'Paid Claims' when 'DENIED' then 'Denied Claims' else 'RTH Claims' end
              else 'Reconciled Balance' end,
         case when d.series is not null and not d.is_duplicate
                   and d.base_item = 'Add to HF: Processed claims not reported by HF' then 'In Process – Not on HF ICS' end
  from (
    select c.*,
           case when c.series is null then 'Invalid Claim Series'
                when not c.in_universe then 'Deduct from PHIC: Deleted Claim'
                when c.within_period = false then 'Deduct from PHIC: For Archiving – Recon Exception'
                when c.st_rd in ('PAID', 'RTH', 'DENIED') then 'Deduct from PHIC: Already Paid/RTH/Denied'
                when not c.in_hf and c.st_rd in ('APPROVED FOR PAYMENT', 'IN PROCESS', 'UNMAPPED', 'NOT YET FILED')
                  then 'Add to HF: Processed claims not reported by HF'
                else 'Non-Reconciling Item' end as base_item
    from (
      select row_number() over (order by u.created_at, h.row_no) as item_no,
             h.id, h.series_raw, h.series, h.estimated_amt, h.recref,
             -- Duplicate = hindi ang canonical row (pinakabagong RECREF, tapos huling row) ng series
             (h.series is not null
              and row_number() over (partition by h.series order by h.recref desc nulls last, u.created_at desc, h.row_no desc, h.id desc) > 1) as is_duplicate,
             (hf.series is not null) as in_hf,
             (rw.series is not null) as in_universe,
             coalesce(rw.status, '-') as universe_status,
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
    ) c
  ) d;

  -- ---- Buod ----
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

-- ---------------------------------------------------------------------------
-- do_matching_yugto2 (pareho ng 0019, maliban sa inalis na buong-table na UPDATE ng patient_ref / filed_vs_actual)
-- ---------------------------------------------------------------------------
create or replace function public.do_matching_yugto2(p_match uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  m public.recon_matches;
begin
  select * into m from public.recon_matches where id = p_match;

  create temp table _y2up on commit drop as
    select id, kind, created_at from public.run_uploads
     where run_id = m.run_id and status = 'complete'
       and kind in ('rth_reasons', 'mr', 'pard', 'pf_name', 'tagging', 'untagging', 'icd_codes', 'claim_type');

  create temp table _y2s on commit drop as
    select distinct claim_series as series from public.recon_hf_results
     where match_id = p_match and claim_series is not null;
  create index on _y2s (series);
  analyze _y2s;

  if exists (select 1 from _y2up) then
    create temp table _y2icd on commit drop as
      select series,
             max(cr) filter (where rn = 1) as first_cr,
             max(cr) filter (where rn = 2) as second_cr
      from (
        select d.series, d.cr,
               row_number() over (partition by d.series order by d.amt desc nulls last, d.up_at desc, d.row_no desc) as rn
        from (
          select distinct on (i.series, i.icd_code, i.rvs_code)
                 i.series, concat_ws(' / ', i.icd_code, i.rvs_code) as cr, i.total_acr_amount as amt,
                 u.created_at as up_at, i.row_no
            from public.icd_codes i
            join _y2up u on u.id = i.upload_id
            join _y2s s on s.series = i.series
           where i.icd_code is not null or i.rvs_code is not null
           order by i.series, i.icd_code, i.rvs_code, i.total_acr_amount desc nulls last, u.created_at desc, i.row_no desc
        ) d
      ) q
      group by series;

    create temp table _y2pf on commit drop as
      select p.series, string_agg(distinct p.doctors_name, '; ' order by p.doctors_name) as names
        from public.pf_names p
        join _y2up u on u.id = p.upload_id
        join _y2s s on s.series = p.series
       where p.doctors_name is not null and p.doctors_name <> ''
       group by p.series;

    create temp table _y2rth on commit drop as
      select distinct on (x.series) x.series, x.effect
        from public.rth_reasons x
        join _y2up u on u.id = x.upload_id
        join _y2s s on s.series = x.series
       where x.effect is not null and x.effect <> ''
       order by x.series, u.created_at desc, x.row_no desc;

    create temp table _y2mr on commit drop as
      select distinct on (x.series) x.series, x.mr_rcv_date, x.final_recom, x.date_finalized
        from public.mr_records x
        join _y2up u on u.id = x.upload_id
        join _y2s s on s.series = x.series
       order by x.series, x.mr_rcv_date desc nulls last, u.created_at desc, x.row_no desc;

    create temp table _y2pard on commit drop as
      select distinct on (x.series) x.series, x.entry_date, x.approval_source
        from public.pard_records x
        join _y2up u on u.id = x.upload_id
        join _y2s s on s.series = x.series
       order by x.series, x.entry_date desc nulls last, u.created_at desc, x.row_no desc;

    update public.recon_hf_results h
       set first_case_rate     = icd.first_cr,
           second_case_rate    = icd.second_cr,
           health_professional = pf.names,
           history_effect      = rth.effect,
           mr_rcv_date         = mr.mr_rcv_date,
           mr_status           = mr.final_recom,
           mr_decision_date    = mr.date_finalized,
           pard_rcv_date       = pard.entry_date,
           pard_status         = pard.approval_source
      from _y2s s
      left join _y2icd  icd  on icd.series  = s.series
      left join _y2pf   pf   on pf.series   = s.series
      left join _y2rth  rth  on rth.series  = s.series
      left join _y2mr   mr   on mr.series   = s.series
      left join _y2pard pard on pard.series = s.series
     where h.match_id = p_match and h.claim_series = s.series
       and (icd.series is not null or pf.series is not null or rth.series is not null
            or mr.series is not null or pard.series is not null);
  end if;

  create temp table _y2ct on commit drop as
    select distinct on (x.series) x.series, x.claim_type
      from public.claim_types x
      join _y2up u on u.id = x.upload_id
      join _y2s s on s.series = x.series
     where x.claim_type is not null and x.claim_type <> ''
     order by x.series, u.created_at desc, x.row_no desc;
  create index on _y2ct (series);
  analyze _y2ct;

  create temp table _y2tag on commit drop as
    select x.series, x.date_tagged as d, x.process, u.created_at as up_at, x.row_no
      from public.issue_tags x
      join _y2up u on u.id = x.upload_id
      join _y2s s on s.series = x.series
     where x.date_tagged is not null;
  create index on _y2tag (series, d);
  analyze _y2tag;

  create temp table _y2untag on commit drop as
    select x.series, x.date_untagged as d, x.process, u.created_at as up_at, x.row_no
      from public.issue_untags x
      join _y2up u on u.id = x.upload_id
      join _y2s s on s.series = x.series
     where x.date_untagged is not null;
  create index on _y2untag (series, d);
  analyze _y2untag;

  insert into public.recon_hf_internal (match_id, facility_id, item_no, tag_date, tag_status, untag_date, untag_status,
                                        issue, days_on_issue, payment_tat, type_of_claim)
  select p_match, h.facility_id, h.item_no, tg.d, tg.process, ut.d, ut.process,
         case when tg.series is null then null
              when ut.series is not null and ut.d >= tg.d then 'RESOLVED'
              else 'OPEN' end,
         case when w.ok then coalesce(iss.days, 0) end,
         case when w.ok then (w.pay_d - w.start_d) - coalesce(iss.days, 0) end,
         ct.claim_type
    from public.recon_hf_results h
    left join (select distinct on (t.series) t.series, t.d, t.process
                 from _y2tag t order by t.series, t.d desc, t.up_at desc, t.row_no desc) tg
           on tg.series = h.claim_series
    left join (select distinct on (t.series) t.series, t.d, t.process
                 from _y2untag t order by t.series, t.d desc, t.up_at desc, t.row_no desc) ut
           on ut.series = h.claim_series
    left join _y2ct ct on ct.series = h.claim_series
    cross join lateral (
      select coalesce(h.last_refiled, h.date_filed) as start_d,
             case when h.payment_status = 'PAID' then coalesce(h.check_dt, h.bank_advise_date) end as pay_d
    ) w0
    cross join lateral (
      select w0.start_d, w0.pay_d, (w0.start_d is not null and w0.pay_d is not null and w0.start_d <= w0.pay_d) as ok
    ) w
    left join lateral (
      select sum(upper(rg) - lower(rg))::int as days
        from unnest(
          (select range_agg(daterange(t.d,
                    least(coalesce((select min(u2.d) from _y2untag u2 where u2.series = t.series and u2.d >= t.d), w.pay_d), w.pay_d),
                    '[)'))
             from _y2tag t
            where t.series = h.claim_series and t.d < w.pay_d)
          * datemultirange(case when w.ok then daterange(w.start_d, w.pay_d, '[)') end)) rg
    ) iss on w.ok
   where h.match_id = p_match
     and (tg.series is not null or ut.series is not null or w.ok or ct.series is not null);
end;
$$;

-- ---------------------------------------------------------------------------
-- Queue: claim (nakikita agad ang "running") at process (hiwalay na cron job)
-- ---------------------------------------------------------------------------
create or replace function public.claim_matching_job()
returns int
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  -- Iisang claim job lang sa isang pagkakataon
  perform pg_advisory_xact_lock(732023);
  -- Naputol na matching: "running" na walang may hawak (hindi pinoproseso) at lampas 6 minuto mula ma-claim → failed.
  -- (Ang pinoprosesong matching ay naka-lock, kaya nilalaktawan ng SKIP LOCKED; ang process job ay kumukuha lang ng
  -- na-claim sa loob ng 5 minuto, kaya hindi inuulit-ulit ang naputol na matching.)
  update public.recon_matches
     set status = 'failed', error = 'Matching was interrupted. Please run matching again.', finished_at = clock_timestamp()
   where id in (select id from public.recon_matches
                 where status = 'running' and finished_at is null and started_at < clock_timestamp() - interval '6 minutes'
                 for update skip locked);
  -- Isa-isa lang: kukuha ng susunod na queued kapag walang running
  if exists (select 1 from public.recon_matches where status = 'running') then
    return 0;
  end if;
  select id into v_id from public.recon_matches where status = 'queued' order by requested_at limit 1 for update skip locked;
  if v_id is null then
    return 0;
  end if;
  update public.recon_matches set status = 'running', started_at = clock_timestamp() where id = v_id;
  return 1;
end;
$$;

create or replace function public.process_matching_queue()
returns int
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  -- Ang job na "running" na hindi pa tapos; naka-lock habang ginagawa (hindi makukuha ng ibang session)
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
    update public.recon_matches set finished_at = clock_timestamp() where id = v_id;
  exception when others or query_canceled then
    update public.recon_matches set status = 'failed', error = left(sqlerrm, 500), finished_at = clock_timestamp() where id = v_id;
  end;
  return 1;
end;
$$;

revoke execute on function public.do_matching(uuid)          from public, anon, authenticated;
revoke execute on function public.do_matching_yugto2(uuid)   from public, anon, authenticated;
revoke execute on function public.claim_matching_job()       from public, anon, authenticated;
revoke execute on function public.process_matching_queue()   from public, anon, authenticated;

select cron.schedule('claim-matching-job', '* * * * *', 'select public.claim_matching_job()');
