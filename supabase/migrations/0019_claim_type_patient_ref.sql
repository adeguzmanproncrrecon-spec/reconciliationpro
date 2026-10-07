-- 0019_claim_type_patient_ref.sql
-- Mga sagot ng user (2026-10-06) sa RECON_SPEC #15:
-- - Type of Claim (Internal Data Only) = eClaims / Manual, mula sa bagong raw data na ina-upload ng FINMAREP
--   (upload kind 'claim_type': SERIES + CLAIM TYPE). Pinakabagong row bawat series.
-- - Patient Reference No. (Health Facility Data) = optional na column sa HF ICS ng facility.
-- - Filed Amount vs. Actual Payment Upgrade = Recon Amount − ICS amount, para sa PAID / APPROVED FOR PAYMENT / IN PROCESS
--   lang (as of Report Date; ang UNMAPPED at NOT YET FILED ay gaya ng IN PROCESS ayon sa #26/#27). Blangko sa iba.
-- Tahasang pinahintulutan ng user (2026-10-06) ang pag-drop at muling paggawa ng run_uploads_kind_check (walang data na nabubura).
-- Ang ibang pagbabago ay add column / create table / create or replace lang.

alter table public.run_uploads
  drop constraint run_uploads_kind_check,
  add constraint run_uploads_kind_check check (kind in (
    'ho_ics', 'raw_matching', 'status_trail', 'payment_details',
    'rth_reasons', 'mr', 'pard', 'pf_name', 'tagging', 'untagging', 'icd_codes', 'claim_type'));

-- ---------------------------------------------------------------------------
-- Type of Claim (raw data ng FINMAREP; PhilHealth lang)
-- ---------------------------------------------------------------------------
create table public.claim_types (
  id           bigint generated always as identity primary key,
  upload_id    uuid not null,
  facility_id  uuid not null,
  row_no       int  not null check (row_no > 0),
  series_raw   text check (length(series_raw) <= 100),
  series       text generated always as (public.normalize_claim_series(series_raw)) stored,
  claim_type   text check (length(claim_type) <= 50),
  extra        jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (upload_id, facility_id) references public.run_uploads (id, facility_id),
  unique (upload_id, row_no)
);
create index claim_types_upload_series_idx on public.claim_types (upload_id, series);

alter table public.claim_types enable row level security;
revoke all on public.claim_types from anon;
revoke insert, update, delete, truncate on public.claim_types from authenticated;
create policy claim_types_select on public.claim_types for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));

-- ---------------------------------------------------------------------------
-- Mga bagong column
-- ---------------------------------------------------------------------------
alter table public.hf_ics_rows       add column patient_ref text check (length(patient_ref) <= 100);
alter table public.recon_hf_results  add column patient_ref text,
                                     add column filed_vs_actual numeric(14, 2);
alter table public.recon_hf_internal add column type_of_claim text;

-- ---------------------------------------------------------------------------
-- HF ICS upload: tumatanggap na ng patient_ref (pareho ng 0008 + isang field)
-- ---------------------------------------------------------------------------
create or replace function public.add_hf_ics_rows(p_submission uuid, p_rows jsonb)
returns int
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fac   uuid := public.app_user_facility_id();
  v_count int;
  v_n     int;
begin
  if coalesce(public.app_user_role()::text, '') not in ('facility', 'facility_admin') or v_fac is null then
    raise exception 'Hindi mo ma-a-upload sa submission na ito' using errcode = '42501';
  end if;

  select s.row_count into v_count
    from public.hf_ics_submissions s
   where s.id = p_submission and s.status = 'uploading'
     and s.uploaded_by = auth.uid() and s.facility_id = v_fac
   for update;
  if not found then
    raise exception 'Hindi mo ma-a-upload sa submission na ito' using errcode = '42501';
  end if;

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000
     or octet_length(p_rows::text) > 6 * 1024 * 1024 then
    raise exception 'Rows must be an array of at most 5000 items and 6 MB';
  end if;
  if v_count + jsonb_array_length(p_rows) > 1000000 then
    raise exception 'Too many rows in one submission (max 1,000,000)';
  end if;
  if exists (select 1 from jsonb_array_elements(p_rows) e
             where jsonb_typeof(e -> 'ics_amount') not in ('number', 'null')) then
    raise exception 'ics_amount must be a number or null';
  end if;
  if exists (select 1 from jsonb_array_elements(p_rows) e
             where jsonb_typeof(e -> 'patient_ref') not in ('string', 'null')) then
    raise exception 'patient_ref must be text or null';
  end if;

  insert into public.hf_ics_rows (submission_id, facility_id, row_no, claim_series_raw, ics_amount, ics_amount_raw, patient_ref, extra)
  select p_submission, v_fac, r.row_no,
         left(r.claim_series_raw, 100),
         r.ics_amount,
         left(r.ics_amount_raw, 100),
         left(nullif(trim(r.patient_ref), ''), 100),
         case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
  from jsonb_to_recordset(p_rows)
       as r(row_no int, claim_series_raw text, ics_amount numeric, ics_amount_raw text, patient_ref text, extra jsonb);
  get diagnostics v_n = row_count;

  update public.hf_ics_submissions set row_count = row_count + v_n
   where id = p_submission and status = 'uploading';
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Extraction upload RPCs (pareho ng 0016 + 'claim_type')
-- ---------------------------------------------------------------------------
create or replace function public.start_run_upload(
  p_run        uuid,
  p_kind       text,
  p_file_name  text,
  p_sheet_name text,
  p_header_row int,
  p_column_map jsonb
)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fac uuid;
  v_id  uuid;
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'FINMAREP lang ang makaka-upload ng extraction' using errcode = '42501';
  end if;
  select r.facility_id into v_fac from public.recon_runs r where r.id = p_run and r.status = 'draft' for share;
  if not found then
    raise exception 'Run not found or not editable';
  end if;
  if p_kind not in ('ho_ics', 'raw_matching', 'status_trail', 'payment_details',
                    'rth_reasons', 'mr', 'pard', 'pf_name', 'tagging', 'untagging', 'icd_codes', 'claim_type') then
    raise exception 'Invalid upload kind';
  end if;
  if jsonb_typeof(coalesce(p_column_map, '{}'::jsonb)) <> 'object' then
    raise exception 'Invalid column map';
  end if;

  insert into public.run_uploads (run_id, facility_id, kind, uploaded_by, file_name, sheet_name, header_row, column_map)
  values (p_run, v_fac, p_kind, auth.uid(), left(coalesce(nullif(trim(p_file_name), ''), 'upload.xlsx'), 255),
          left(p_sheet_name, 100), p_header_row, coalesce(p_column_map, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.add_run_rows(p_upload uuid, p_rows jsonb)
returns int
language plpgsql security definer
set search_path = ''
as $$
declare
  u   public.run_uploads;
  v_n int;
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'FINMAREP lang ang makaka-upload ng extraction' using errcode = '42501';
  end if;

  select * into u from public.run_uploads
   where id = p_upload and status = 'uploading' and uploaded_by = auth.uid()
   for update;
  if not found then
    raise exception 'Hindi mo ma-a-upload sa upload na ito' using errcode = '42501';
  end if;
  perform 1 from public.recon_runs where id = u.run_id and status = 'draft' for share;
  if not found then
    raise exception 'Run is no longer editable' using errcode = '42501';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000
     or octet_length(p_rows::text) > 6 * 1024 * 1024 then
    raise exception 'Rows must be an array of at most 5000 items and 6 MB';
  end if;
  if u.row_count + jsonb_array_length(p_rows) > 1000000 then
    raise exception 'Too many rows in one upload (max 1,000,000)';
  end if;
  if exists (select 1 from jsonb_array_elements(p_rows) e where jsonb_typeof(e) <> 'object') then
    raise exception 'Each row must be an object';
  end if;
  if exists (select 1 from jsonb_array_elements(p_rows) e, jsonb_each(e) kv
             where jsonb_typeof(kv.value) <> 'null'
               and case
                     when kv.key in ('estimated_amt', 'total_acr_amount', 'total_tot_amnt', 'cw_tax', 'time_rec', 'row_no')
                       then jsonb_typeof(kv.value) <> 'number'
                     when kv.key = 'extra' then jsonb_typeof(kv.value) <> 'object'
                     else jsonb_typeof(kv.value) <> 'string'
                   end) then
    raise exception 'Invalid value type (amounts must be numbers; series, text and dates must be strings)';
  end if;

  if u.kind = 'ho_ics' then
    insert into public.ho_ics_rows (upload_id, facility_id, row_no, series_raw, estimated_amt, recref, extra)
    select u.id, u.facility_id, r.row_no, left(r.series_raw, 100), r.estimated_amt, r.recref,
           case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
    from jsonb_to_recordset(p_rows) as r(row_no int, series_raw text, estimated_amt numeric, recref date, extra jsonb);

  elsif u.kind = 'raw_matching' then
    insert into public.raw_claims (upload_id, facility_id, row_no, ph_inst_code, series_raw, mecno,
                                   patlname, patfname, patmname, worlname, worfname, wormname,
                                   date_adm, date_dis, date_rec, date_recon, last_refiled, status,
                                   total_acr_amount, latest_check_dt, total_tot_amnt, latest_ctrl_no, latest_ctrl_dt, extra)
    select u.id, u.facility_id, r.row_no, left(r.ph_inst_code, 50), left(r.series_raw, 100), left(r.mecno, 50),
           left(r.patlname, 200), left(r.patfname, 200), left(r.patmname, 200),
           left(r.worlname, 200), left(r.worfname, 200), left(r.wormname, 200),
           r.date_adm, r.date_dis, r.date_rec, r.date_recon, r.last_refiled, left(upper(trim(r.status)), 10),
           r.total_acr_amount, r.latest_check_dt, r.total_tot_amnt, left(r.latest_ctrl_no, 100), r.latest_ctrl_dt,
           case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
    from jsonb_to_recordset(p_rows) as r(row_no int, ph_inst_code text, series_raw text, mecno text,
         patlname text, patfname text, patmname text, worlname text, worfname text, wormname text,
         date_adm date, date_dis date, date_rec date, date_recon date, last_refiled date, status text,
         total_acr_amount numeric, latest_check_dt date, total_tot_amnt numeric, latest_ctrl_no text,
         latest_ctrl_dt date, extra jsonb);

  elsif u.kind = 'status_trail' then
    insert into public.status_trail (upload_id, facility_id, row_no, series_raw, time_rec, date_tagged, process, extra)
    select u.id, u.facility_id, r.row_no, left(r.series_raw, 100), r.time_rec, r.date_tagged, left(trim(r.process), 200),
           case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
    from jsonb_to_recordset(p_rows) as r(row_no int, series_raw text, time_rec int, date_tagged date, process text, extra jsonb);

  elsif u.kind = 'payment_details' then
    insert into public.payment_details (upload_id, facility_id, row_no, series_raw, date_ext, check_no, check_dt,
                                        isirm, is_dcpm, pr_no, tranche_number, cw_tax, receipt_no, receipt_dt,
                                        cpay_to, total_tot_amnt, extra)
    select u.id, u.facility_id, r.row_no, left(r.series_raw, 100), r.date_ext, left(r.check_no, 100), r.check_dt,
           left(upper(trim(r.isirm)), 10), left(upper(trim(r.is_dcpm)), 10), left(r.pr_no, 100),
           left(r.tranche_number, 50), r.cw_tax, left(r.receipt_no, 100), r.receipt_dt, left(r.cpay_to, 200),
           r.total_tot_amnt,
           case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
    from jsonb_to_recordset(p_rows) as r(row_no int, series_raw text, date_ext date, check_no text, check_dt date,
         isirm text, is_dcpm text, pr_no text, tranche_number text, cw_tax numeric, receipt_no text,
         receipt_dt date, cpay_to text, total_tot_amnt numeric, extra jsonb);

  elsif u.kind = 'rth_reasons' then
    insert into public.rth_reasons (upload_id, facility_id, row_no, series_raw, def_code, reason, effect, icd_code,
                                    health_professional, extra)
    select u.id, u.facility_id, r.row_no, left(r.series_raw, 100), left(trim(r.def_code), 50), left(r.reason, 500),
           left(upper(trim(r.effect)), 20), left(trim(r.icd_code), 50), left(r.health_professional, 300),
           case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
    from jsonb_to_recordset(p_rows) as r(row_no int, series_raw text, def_code text, reason text, effect text,
         icd_code text, health_professional text, extra jsonb);

  elsif u.kind = 'mr' then
    insert into public.mr_records (upload_id, facility_id, row_no, series_raw, hci_pan, member_pin, mr_rcv_date, approval,
                                   final_recom, final_basis, date_finalized, uploaded_date, crc_received_date,
                                   ini_date_encoded, final_date_encoded, extra)
    select u.id, u.facility_id, r.row_no, left(r.series_raw, 100), left(r.hci_pan, 50), left(r.member_pin, 50),
           r.mr_rcv_date, left(r.approval, 200), left(r.final_recom, 200), left(r.final_basis, 500), r.date_finalized,
           r.uploaded_date, r.crc_received_date, r.ini_date_encoded, r.final_date_encoded,
           case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
    from jsonb_to_recordset(p_rows) as r(row_no int, series_raw text, hci_pan text, member_pin text, mr_rcv_date date,
         approval text, final_recom text, final_basis text, date_finalized date, uploaded_date date,
         crc_received_date date, ini_date_encoded date, final_date_encoded date, extra jsonb);

  elsif u.kind = 'pard' then
    insert into public.pard_records (upload_id, facility_id, row_no, series_raw, entry_date, approval_source, extra)
    select u.id, u.facility_id, r.row_no, left(r.series_raw, 100), r.entry_date, left(r.approval_source, 200),
           case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
    from jsonb_to_recordset(p_rows) as r(row_no int, series_raw text, entry_date date, approval_source text, extra jsonb);

  elsif u.kind = 'pf_name' then
    insert into public.pf_names (upload_id, facility_id, row_no, series_raw, doctors_name, extra)
    select u.id, u.facility_id, r.row_no, left(r.series_raw, 100), left(trim(r.doctors_name), 300),
           case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
    from jsonb_to_recordset(p_rows) as r(row_no int, series_raw text, doctors_name text, extra jsonb);

  elsif u.kind = 'tagging' then
    insert into public.issue_tags (upload_id, facility_id, row_no, series_raw, date_tagged, process, extra)
    select u.id, u.facility_id, r.row_no, left(r.series_raw, 100), r.date_tagged, left(trim(r.process), 200),
           case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
    from jsonb_to_recordset(p_rows) as r(row_no int, series_raw text, date_tagged date, process text, extra jsonb);

  elsif u.kind = 'untagging' then
    insert into public.issue_untags (upload_id, facility_id, row_no, series_raw, date_untagged, process, extra)
    select u.id, u.facility_id, r.row_no, left(r.series_raw, 100), r.date_untagged, left(trim(r.process), 200),
           case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
    from jsonb_to_recordset(p_rows) as r(row_no int, series_raw text, date_untagged date, process text, extra jsonb);

  elsif u.kind = 'icd_codes' then
    insert into public.icd_codes (upload_id, facility_id, row_no, series_raw, icd_code, rvs_code, total_acr_amount, extra)
    select u.id, u.facility_id, r.row_no, left(r.series_raw, 100), left(trim(r.icd_code), 50), left(trim(r.rvs_code), 50),
           r.total_acr_amount,
           case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
    from jsonb_to_recordset(p_rows) as r(row_no int, series_raw text, icd_code text, rvs_code text,
         total_acr_amount numeric, extra jsonb);

  elsif u.kind = 'claim_type' then
    insert into public.claim_types (upload_id, facility_id, row_no, series_raw, claim_type, extra)
    select u.id, u.facility_id, r.row_no, left(r.series_raw, 100), left(trim(r.claim_type), 50),
           case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
    from jsonb_to_recordset(p_rows) as r(row_no int, series_raw text, claim_type text, extra jsonb);
  else
    raise exception 'Unsupported upload kind %', u.kind;
  end if;
  get diagnostics v_n = row_count;

  update public.run_uploads set row_count = row_count + v_n
   where id = p_upload and status = 'uploading';
  return v_n;
end;
$$;

create or replace function public.finish_run_upload(p_upload uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  u public.run_uploads;
  v_invalid int;
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'FINMAREP lang' using errcode = '42501';
  end if;
  select * into u from public.run_uploads
   where id = p_upload and status = 'uploading' and uploaded_by = auth.uid() and row_count > 0
   for update;
  if not found then
    raise exception 'Hindi matapos ang upload na ito (walang row, o hindi sa iyo)' using errcode = '42501';
  end if;
  perform 1 from public.recon_runs where id = u.run_id and status = 'draft' for share;
  if not found then
    raise exception 'Run is no longer editable' using errcode = '42501';
  end if;

  v_invalid := case u.kind
    when 'ho_ics'          then (select count(*) from public.ho_ics_rows     where upload_id = u.id and series is null)
    when 'raw_matching'    then (select count(*) from public.raw_claims      where upload_id = u.id and series is null)
    when 'status_trail'    then (select count(*) from public.status_trail    where upload_id = u.id and series is null)
    when 'payment_details' then (select count(*) from public.payment_details where upload_id = u.id and series is null)
    when 'rth_reasons'     then (select count(*) from public.rth_reasons     where upload_id = u.id and series is null)
    when 'mr'              then (select count(*) from public.mr_records      where upload_id = u.id and series is null)
    when 'pard'            then (select count(*) from public.pard_records    where upload_id = u.id and series is null)
    when 'pf_name'         then (select count(*) from public.pf_names        where upload_id = u.id and series is null)
    when 'tagging'         then (select count(*) from public.issue_tags      where upload_id = u.id and series is null)
    when 'untagging'       then (select count(*) from public.issue_untags    where upload_id = u.id and series is null)
    when 'icd_codes'       then (select count(*) from public.icd_codes       where upload_id = u.id and series is null)
    when 'claim_type'      then (select count(*) from public.claim_types     where upload_id = u.id and series is null)
  end;

  update public.run_uploads
     set status = 'complete', completed_at = now(), invalid_series_count = v_invalid
   where id = u.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- do_matching_yugto2 (pareho ng 0018 + patient_ref, filed_vs_actual, type_of_claim)
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

  -- Patient Reference No. (mula sa HF ICS) at Filed vs Actual Payment Upgrade (as of Report Date)
  update public.recon_hf_results h
     set patient_ref     = r.patient_ref,
         filed_vs_actual = case when h.status_rd in ('PAID', 'APPROVED FOR PAYMENT', 'IN PROCESS', 'UNMAPPED', 'NOT YET FILED')
                                then h.recon_amount - h.ics_amount end
    from public.hf_ics_rows r
   where h.match_id = p_match and r.id = h.hf_row_id and r.submission_id = m.hf_submission_id
     and (r.patient_ref is not null
          or h.status_rd in ('PAID', 'APPROVED FOR PAYMENT', 'IN PROCESS', 'UNMAPPED', 'NOT YET FILED'));

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

  -- Type of Claim: pinakabagong row (huling row sa pinakabagong upload) na may laman
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
-- Claim History (pareho ng 0017 + Type of Claim)
-- ---------------------------------------------------------------------------
create or replace function public.claim_history(p_run uuid, p_series text, p_limit int default 200, p_offset int default 0)
returns table (source text, event_date date, sort_key bigint, title text, details jsonb, file_name text)
language plpgsql stable security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_series text := public.normalize_claim_series(p_series);
begin
  if not public.app_user_is_philhealth() then
    raise exception 'Claim History is for PhilHealth only' using errcode = '42501';
  end if;
  if v_series is null then
    raise exception 'Invalid Claim Series' using errcode = '22023';
  end if;

  return query
  with up as (
    select u.id, u.file_name from public.run_uploads u where u.run_id = p_run and u.status = 'complete'
  ),
  ev as (
    select 'Raw Matching'::text as source, x.date_rec as event_date, x.row_no::bigint as sort_key,
           ('STATUS ' || coalesce(x.status, '-'))::text as title,
           jsonb_build_object('date_rec', x.date_rec, 'date_recon', x.date_recon, 'last_refiled', x.last_refiled,
                              'status', x.status, 'total_acr_amount', x.total_acr_amount,
                              'latest_check_dt', x.latest_check_dt, 'latest_ctrl_no', x.latest_ctrl_no,
                              'latest_ctrl_dt', x.latest_ctrl_dt) as details,
           up.file_name
      from public.raw_claims x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'Status Trail', x.date_tagged, coalesce(x.time_rec, 0)::bigint, x.process,
           jsonb_build_object('date_tagged', x.date_tagged, 'time_rec', x.time_rec, 'process', x.process), up.file_name
      from public.status_trail x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'Payment', coalesce(x.check_dt, x.date_ext, x.receipt_dt), x.row_no::bigint,
           ('Tranche ' || coalesce(x.tranche_number, '-')),
           jsonb_build_object('date_ext', x.date_ext, 'check_no', x.check_no, 'check_dt', x.check_dt, 'pr_no', x.pr_no,
                              'receipt_no', x.receipt_no, 'receipt_dt', x.receipt_dt, 'total_tot_amnt', x.total_tot_amnt,
                              'tranche_number', x.tranche_number), up.file_name
      from public.payment_details x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'HO ICS', x.recref, x.row_no::bigint, 'HO ICS',
           jsonb_build_object('recref', x.recref, 'estimated_amt', x.estimated_amt), up.file_name
      from public.ho_ics_rows x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'RTH/Denial Reason', null::date, x.row_no::bigint, coalesce(x.def_code, '-'),
           jsonb_build_object('def_code', x.def_code, 'reason', x.reason, 'effect', x.effect, 'icd_code', x.icd_code,
                              'health_professional', x.health_professional), up.file_name
      from public.rth_reasons x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'MR', x.mr_rcv_date, x.row_no::bigint, coalesce(x.final_recom, '-'),
           jsonb_build_object('mr_rcv_date', x.mr_rcv_date, 'approval', x.approval, 'final_recom', x.final_recom,
                              'final_basis', x.final_basis, 'date_finalized', x.date_finalized), up.file_name
      from public.mr_records x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'PARD', x.entry_date, x.row_no::bigint, coalesce(x.approval_source, '-'),
           jsonb_build_object('entry_date', x.entry_date, 'approval_source', x.approval_source), up.file_name
      from public.pard_records x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'Tagging', x.date_tagged, x.row_no::bigint, coalesce(x.process, '-'),
           jsonb_build_object('date_tagged', x.date_tagged, 'process', x.process), up.file_name
      from public.issue_tags x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'Untagging', x.date_untagged, x.row_no::bigint, coalesce(x.process, '-'),
           jsonb_build_object('date_untagged', x.date_untagged, 'process', x.process), up.file_name
      from public.issue_untags x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'PF Name', null::date, x.row_no::bigint, coalesce(x.doctors_name, '-'),
           jsonb_build_object('doctors_name', x.doctors_name), up.file_name
      from public.pf_names x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'ICD Code', null::date, x.row_no::bigint, concat_ws(' / ', x.icd_code, x.rvs_code),
           jsonb_build_object('icd_code', x.icd_code, 'rvs_code', x.rvs_code, 'total_acr_amount', x.total_acr_amount),
           up.file_name
      from public.icd_codes x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'Type of Claim', null::date, x.row_no::bigint, coalesce(x.claim_type, '-'),
           jsonb_build_object('claim_type', x.claim_type), up.file_name
      from public.claim_types x join up on up.id = x.upload_id where x.series = v_series
  )
  select ev.source, ev.event_date, ev.sort_key, ev.title, ev.details, ev.file_name
    from ev
   order by ev.event_date desc nulls last, ev.source, ev.sort_key desc
   limit least(greatest(coalesce(p_limit, 200), 1), 500)
  offset least(greatest(coalesce(p_offset, 0), 0), 100000);
end;
$$;

revoke execute on function public.claim_history(uuid, text, int, int)              from public, anon;
grant  execute on function public.claim_history(uuid, text, int, int)              to authenticated;
revoke execute on function public.add_hf_ics_rows(uuid, jsonb)                      from public, anon;
revoke execute on function public.start_run_upload(uuid, text, text, text, int, jsonb) from public, anon;
revoke execute on function public.add_run_rows(uuid, jsonb)                           from public, anon;
revoke execute on function public.finish_run_upload(uuid)                             from public, anon;
revoke execute on function public.do_matching_yugto2(uuid)                            from public, anon, authenticated;
grant  execute on function public.add_hf_ics_rows(uuid, jsonb)                      to authenticated;
grant  execute on function public.start_run_upload(uuid, text, text, text, int, jsonb) to authenticated;
grant  execute on function public.add_run_rows(uuid, jsonb)                           to authenticated;
grant  execute on function public.finish_run_upload(uuid)                             to authenticated;
