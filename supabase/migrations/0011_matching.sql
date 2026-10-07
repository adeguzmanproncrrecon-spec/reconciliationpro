-- 0011_matching.sql
-- Yugto C (bahagi 1): matching sa SQL — kapalit ng mga XLOOKUP sa Excel. Tumatakbo bilang BACKGROUND JOB (pg_cron),
-- dahil ang request ng authenticated ay may 8s na statement_timeout at hindi iyon kakayanin ng 200k+ na claims.
--
--   process_status_map    — PROCESS → interpretation (RECON_SPEC §3b); FINMAREP ang nag-e-edit
--   recon_matches         — bawat matching job (queued → running → done | failed); walang binubura; is_current = pinakabagong done
--   recon_hf_results      — Matching Report + HF ICS Recon (isang row bawat row ng HF ICS)
--   recon_ho_results      — HO ICS Recon (isang row bawat row ng HO ICS) — PhilHealth lang
--   recon_match_unmapped  — mga PROCESS na walang mapping (PhilHealth lang)
--   request_matching(run) — FINMAREP: ilagay sa pila
--   process_matching_queue() — pg_cron (bawat minuto, bilang postgres): patakbuhin ang mga nakapila
--   reopen_recon_run(run), upsert_process_mapping(...)
-- Mga patakaran: RECON_SPEC §3a, §3c (decision table), §3c-bis (latest lang), §3c-ter (#2, #5, #8, #10b, #16, inputs), §4a–4c.

create extension if not exists pg_cron with schema pg_catalog;

-- ---------------------------------------------------------------------------
-- Process → interpretation
-- ---------------------------------------------------------------------------
create table public.process_status_map (
  id             bigint generated always as identity primary key,
  process        text not null check (process = upper(trim(process)) and length(process) between 1 and 200),
  is_pattern     boolean not null default false,     -- true: LIKE pattern (hal. 'MPR %')
  interpretation text not null check (interpretation in ('FOR PAYMENT', 'RTH/DENIED', 'DENIED', 'IN PROCESS')),
  updated_by     uuid references public.profiles (id),
  updated_at     timestamptz not null default now(),
  unique (process, is_pattern)
);

insert into public.process_status_map (process, is_pattern, interpretation) values
  ('ADJU: FOR PAYMENT APPROVAL', false, 'FOR PAYMENT'),
  ('FOR PAYMENT APPROVAL', false, 'FOR PAYMENT'),
  ('CHECK PREPARATION', false, 'FOR PAYMENT'),
  ('PAYMENT APPROVAL', false, 'FOR PAYMENT'),
  ('PAYMENT NOTICE', false, 'FOR PAYMENT'),
  ('VOUCHER GENERATION', false, 'FOR PAYMENT'),
  ('VOUCHER TRANSMITTAL', false, 'FOR PAYMENT'),
  ('RTH/DENIAL CTRL NO. GENERATION', false, 'RTH/DENIED'),
  ('RTH/DENIAL POSTING', false, 'RTH/DENIED'),
  ('CRC DENIED', false, 'DENIED'),
  ('VALIDATION', false, 'IN PROCESS'),
  ('ADJUDICATION', false, 'IN PROCESS'),
  ('EDITING', false, 'IN PROCESS'),
  ('PENDING DUE TO SYSTEM/POLICY ISSUES', false, 'IN PROCESS'),
  ('CRC GRANTED', false, 'IN PROCESS'),
  ('CRC RECEIVED', false, 'IN PROCESS'),
  ('TAGGING AS REFILED CLAIM', false, 'IN PROCESS'),
  ('VOUCHER EXCLUSION', false, 'IN PROCESS'),
  ('VOUCHER UNTRANSMITTAL', false, 'IN PROCESS'),
  ('VOUCHER EXCLUSION/UNTRANSMITTAL', false, 'IN PROCESS'),
  ('PAYMENT UN-APPROVAL', false, 'IN PROCESS'),
  ('RTH/DENIAL CTRL NO. EXCLUSION', false, 'IN PROCESS'),
  ('RTH/DENIAL CTRL NO. INCLUSION', false, 'IN PROCESS'),
  ('RTH/DENIAL CTRL NO. EXCLUSION/INCLUSION', false, 'IN PROCESS'),
  ('ECLAIMS TO NCLAIMS UPLOADING', false, 'IN PROCESS'),
  ('MPR %', true, 'IN PROCESS'),
  ('REFERRED TO %', true, 'IN PROCESS'),
  ('RETURNED BY %', true, 'IN PROCESS');

-- ---------------------------------------------------------------------------
-- Matches (jobs) at results
-- ---------------------------------------------------------------------------
create table public.recon_matches (
  id                uuid primary key default gen_random_uuid(),
  run_id            uuid not null,
  facility_id       uuid not null,
  status            text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed')),
  is_current        boolean not null default false,
  error             text,
  -- snapshot ng run sa oras na tumakbo ang job
  report_date       date,
  prev_report_date  date,
  matching_date     date,
  coverage_start    date,
  coverage_end      date,
  hf_submission_id  uuid,
  summary           jsonb not null default '{}'::jsonb,
  requested_by      uuid not null references public.profiles (id),
  requested_at      timestamptz not null default now(),
  started_at        timestamptz,
  finished_at       timestamptz,
  foreign key (run_id, facility_id) references public.recon_runs (id, facility_id),
  unique (id, facility_id)
);
create index recon_matches_run_idx on public.recon_matches (run_id, requested_at desc);
create index recon_matches_queue_idx on public.recon_matches (requested_at) where status = 'queued';
create unique index recon_matches_one_current_idx on public.recon_matches (run_id) where is_current;
create unique index recon_matches_one_active_idx on public.recon_matches (run_id) where status in ('queued', 'running');

create table public.recon_hf_results (
  id                    bigint generated always as identity primary key,
  match_id              uuid not null,
  facility_id           uuid not null,
  item_no               int  not null,
  hf_row_id             bigint not null,
  hf_row_no             int  not null,
  claim_series_raw      text,
  claim_series          text,                -- NULL = Invalid Claim Series
  ics_amount            numeric(14, 2),
  is_duplicate          boolean not null,    -- pangalawa+ na paglitaw sa HF ICS → status DUPLICATE (#5)
  in_ho_ics             boolean not null,
  in_universe           boolean not null,
  universe_duplicate    boolean not null,    -- higit sa isang row sa Raw Matching
  -- Claim details (mula sa pinakabagong Raw Matching row)
  member_id             text,
  pat_lname text, pat_fname text, pat_mname text,
  mem_lname text, mem_fname text, mem_mname text,
  date_adm date, date_dis date, date_filed date, date_recon date, last_refiled date,
  filing_tat int, refiling_tat int,
  raw_status            text,
  all_case_rate         numeric(14, 2),
  latest_check_dt       date,
  amount_on_phic_books  numeric(14, 2),      -- HO ICS ESTIMATED_AMT
  -- Status bawat cutoff (rd = report date, pd = nakaraang report date, md = matching date)
  status_rd text, trail_date_rd date, trail_process_rd text,
  status_pd text, trail_date_pd date, trail_process_pd text,
  status_md text, trail_date_md date, trail_process_md text,
  -- Payment (pinakabagong row hanggang matching date)
  bank_advise_date date, check_no text, check_dt date, is_irm boolean, is_dcpm boolean,
  pr_no text, or_no text, or_date date, tranche_number text,
  mode_of_payment       text,
  payment_status        text,
  total_amount_paid     numeric(14, 2),
  amount_used_rd numeric(14, 2), amount_used_pd numeric(14, 2), amount_used_md numeric(14, 2),
  -- RTH / Denied
  ctrl_no text, ctrl_dt date, date_rth date, date_denied date,
  -- HF ICS Recon (§4b, as of report date)
  recon_amount          numeric(14, 2),
  upgrade_downgrade     numeric(14, 2),
  reconciling_item      text,
  foreign key (match_id, facility_id) references public.recon_matches (id, facility_id)
);
create index recon_hf_results_match_idx on public.recon_hf_results (match_id, item_no);
create index recon_hf_results_series_idx on public.recon_hf_results (match_id, claim_series);

create table public.recon_ho_results (
  id                bigint generated always as identity primary key,
  match_id          uuid not null,
  facility_id       uuid not null,
  item_no           int  not null,
  ho_row_id         bigint not null,
  series_raw        text,
  series            text,
  estimated_amt     numeric(14, 2),
  recref            date,
  is_duplicate      boolean not null,        -- pangalawa+ na paglitaw sa HO ICS (flag lang)
  in_hf_ics         boolean not null,
  universe_status   text not null,           -- G / D / P / '-'
  within_period     boolean,                 -- NULL = walang RECREF (itinuturing na within; tingnan ang spec)
  status_rd text, status_pd text, status_md text,
  reconciling_item  text not null,
  foreign key (match_id, facility_id) references public.recon_matches (id, facility_id)
);
create index recon_ho_results_match_idx on public.recon_ho_results (match_id, item_no);

create table public.recon_match_unmapped (
  match_id     uuid not null,
  facility_id  uuid not null,
  process      text not null,
  row_count    int  not null,
  primary key (match_id, process),
  foreign key (match_id, facility_id) references public.recon_matches (id, facility_id)
);

-- ---------------------------------------------------------------------------
-- RLS
--   process_status_map, recon_ho_results, recon_match_unmapped: PhilHealth roles lang (ayon sa saklaw)
--   recon_matches, recon_hf_results: kung nakikita ang facility (kasama ang facility users ng sariling facility — #16)
-- ---------------------------------------------------------------------------
alter table public.process_status_map   enable row level security;
alter table public.recon_matches        enable row level security;
alter table public.recon_hf_results     enable row level security;
alter table public.recon_ho_results     enable row level security;
alter table public.recon_match_unmapped enable row level security;

revoke all on public.process_status_map, public.recon_matches, public.recon_hf_results,
              public.recon_ho_results, public.recon_match_unmapped from anon;
revoke insert, update, delete, truncate
    on public.process_status_map, public.recon_matches, public.recon_hf_results,
       public.recon_ho_results, public.recon_match_unmapped from authenticated;

create policy process_status_map_select on public.process_status_map for select to authenticated
  using ((select public.app_user_is_philhealth()));
create policy recon_matches_select on public.recon_matches for select to authenticated
  using (facility_id in (select f.id from public.facilities f));
create policy recon_hf_results_select on public.recon_hf_results for select to authenticated
  using (facility_id in (select f.id from public.facilities f));
create policy recon_ho_results_select on public.recon_ho_results for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));
create policy recon_match_unmapped_select on public.recon_match_unmapped for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));

-- ---------------------------------------------------------------------------
-- Mapping RPC (FINMAREP)
-- ---------------------------------------------------------------------------
create function public.upsert_process_mapping(p_process text, p_is_pattern boolean, p_interpretation text)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'FINMAREP lang' using errcode = '42501';
  end if;
  insert into public.process_status_map (process, is_pattern, interpretation, updated_by)
  values (upper(trim(p_process)), coalesce(p_is_pattern, false), p_interpretation, auth.uid())
  on conflict (process, is_pattern) do update
    set interpretation = excluded.interpretation, updated_by = auth.uid(), updated_at = now();
end;
$$;

-- ---------------------------------------------------------------------------
-- Request (FINMAREP): ilagay sa pila
-- ---------------------------------------------------------------------------
create function public.request_matching(p_run uuid)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  r      public.recon_runs;
  v_id   uuid;
  v_kind text;
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'FINMAREP lang ang makakapagpatakbo ng matching' using errcode = '42501';
  end if;
  select * into r from public.recon_runs where id = p_run for update;
  if not found then raise exception 'Run not found'; end if;
  if r.status <> 'draft' then raise exception 'Run is already matched; reopen it first'; end if;
  if r.hf_submission_id is null then raise exception 'Walang HF ICS submission ang run na ito'; end if;
  if exists (select 1 from public.run_uploads where run_id = p_run and status = 'uploading') then
    raise exception 'May upload pa na hindi tapos (uploading). Tapusin o i-discard muna.';
  end if;
  foreach v_kind in array array['ho_ics', 'raw_matching', 'status_trail', 'payment_details'] loop
    if not exists (select 1 from public.run_uploads where run_id = p_run and status = 'complete' and kind = v_kind) then
      raise exception 'Kulang ang upload: %. Kailangan ang lahat ng apat (HO ICS, Raw Matching, Status Trail, Payment Details).', v_kind;
    end if;
  end loop;
  if exists (select 1 from public.recon_matches where run_id = p_run and status in ('queued', 'running')) then
    raise exception 'May matching nang nakapila o tumatakbo para sa run na ito';
  end if;

  insert into public.recon_matches (run_id, facility_id, requested_by)
  values (r.id, r.facility_id, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Ang matching mismo (internal; tinatawag lang ng process_matching_queue)
-- ---------------------------------------------------------------------------
create function public.do_matching(p_match uuid)
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
         case when b.st_rd = 'PAID' then b.paid_rd when b.st_rd = 'DUPLICATE' then b.ics_amount
              else coalesce(b.ho_amt, b.total_acr_amount, b.ics_amount) end,
         case when b.st_pd is null then null when b.st_pd = 'PAID' then b.paid_pd when b.st_pd = 'DUPLICATE' then b.ics_amount
              else coalesce(b.ho_amt, b.total_acr_amount, b.ics_amount) end,
         case when b.st_md = 'PAID' then b.paid_md when b.st_md = 'DUPLICATE' then b.ics_amount
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
              when b.st_rd in ('IN PROCESS', 'UNMAPPED') then 'Add to PHIC Balance: In Process'
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
              when not c.in_hf and c.st_rd in ('APPROVED FOR PAYMENT', 'IN PROCESS', 'UNMAPPED')
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
                    'hf_unmapped', count(*) filter (where 'UNMAPPED' in (status_rd, status_pd, status_md)))
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
-- Worker (pg_cron, bilang postgres): isang job bawat pagtakbo (iisang transaction ang pg_cron run;
-- ang temp tables ng do_matching ay nawawala lang pag-commit, kaya hindi puwedeng dalawang job sa isang run)
-- ---------------------------------------------------------------------------
create function public.process_matching_queue()
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

  update public.recon_matches set status = 'running', started_at = now() where id = v_id;
  begin
    perform public.do_matching(v_id);
  exception when others or query_canceled then
    -- Na-rollback ang lahat ng ginawa ng do_matching (subtransaction); itala lang ang error
    update public.recon_matches set status = 'failed', error = left(sqlerrm, 500), finished_at = now() where id = v_id;
  end;
  return 1;
end;
$$;

-- ---------------------------------------------------------------------------
-- Buksan ulit ang run (hindi binubura ang lumang resulta)
-- ---------------------------------------------------------------------------
create function public.reopen_recon_run(p_run uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'FINMAREP lang' using errcode = '42501';
  end if;
  update public.recon_runs set status = 'draft', updated_by = auth.uid(), updated_at = now()
   where id = p_run and status = 'matched';
  if not found then raise exception 'Run not found or not matched'; end if;
end;
$$;

revoke execute on function public.upsert_process_mapping(text, boolean, text) from public, anon;
revoke execute on function public.request_matching(uuid)                      from public, anon;
revoke execute on function public.reopen_recon_run(uuid)                      from public, anon;
revoke execute on function public.do_matching(uuid)                           from public, anon, authenticated;
revoke execute on function public.process_matching_queue()                    from public, anon, authenticated;
grant  execute on function public.upsert_process_mapping(text, boolean, text) to authenticated;
grant  execute on function public.request_matching(uuid)                      to authenticated;
grant  execute on function public.reopen_recon_run(uuid)                      to authenticated;

-- Bawat minuto
select cron.schedule('process-matching-queue', '* * * * *', 'select public.process_matching_queue()');
