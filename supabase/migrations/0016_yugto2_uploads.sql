-- 0016_yugto2_uploads.sql
-- Yugto 2 uploads ng FINMAREP (RECON_SPEC §2): RTH/Denial Reasons, Motion for Reconsideration, PARD, PF Name,
-- Tagging of Issue, Untagging of Issue, ICD Codes. Optional ang mga ito (hindi kailangan para sa matching).
-- Pareho ang pattern ng 0009: upload_id + facility_id (RLS), series_raw + series (generated), extra jsonb.
-- PhilHealth roles lang ang nakakakita (internal data). Lahat ng sulat ay sa RPC.
-- Tahasang pinahintulutan ng user (2026-10-06) ang pag-drop at muling paggawa ng run_uploads_kind_check (walang data na nabubura).

alter table public.run_uploads
  drop constraint run_uploads_kind_check,
  add constraint run_uploads_kind_check check (kind in (
    'ho_ics', 'raw_matching', 'status_trail', 'payment_details',
    'rth_reasons', 'mr', 'pard', 'pf_name', 'tagging', 'untagging', 'icd_codes'));

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.rth_reasons (
  id                  bigint generated always as identity primary key,
  upload_id           uuid not null,
  facility_id         uuid not null,
  row_no              int  not null check (row_no > 0),
  series_raw          text check (length(series_raw) <= 100),
  series              text generated always as (public.normalize_claim_series(series_raw)) stored,
  def_code            text check (length(def_code) <= 50),
  reason              text check (length(reason) <= 500),
  effect              text check (length(effect) <= 20),
  icd_code            text check (length(icd_code) <= 50),
  health_professional text check (length(health_professional) <= 300),
  extra               jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (upload_id, facility_id) references public.run_uploads (id, facility_id),
  unique (upload_id, row_no)
);
create index rth_reasons_upload_series_idx on public.rth_reasons (upload_id, series);

create table public.mr_records (
  id                 bigint generated always as identity primary key,
  upload_id          uuid not null,
  facility_id        uuid not null,
  row_no             int  not null check (row_no > 0),
  series_raw         text check (length(series_raw) <= 100),
  series             text generated always as (public.normalize_claim_series(series_raw)) stored,
  hci_pan            text check (length(hci_pan) <= 50),
  member_pin         text check (length(member_pin) <= 50),
  mr_rcv_date        date check (mr_rcv_date between '1900-01-01' and '2100-12-31'),
  approval           text check (length(approval) <= 200),
  final_recom        text check (length(final_recom) <= 200),
  final_basis        text check (length(final_basis) <= 500),
  date_finalized     date check (date_finalized between '1900-01-01' and '2100-12-31'),
  uploaded_date      date check (uploaded_date between '1900-01-01' and '2100-12-31'),
  crc_received_date  date check (crc_received_date between '1900-01-01' and '2100-12-31'),
  ini_date_encoded   date check (ini_date_encoded between '1900-01-01' and '2100-12-31'),
  final_date_encoded date check (final_date_encoded between '1900-01-01' and '2100-12-31'),
  extra              jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (upload_id, facility_id) references public.run_uploads (id, facility_id),
  unique (upload_id, row_no)
);
create index mr_records_upload_series_idx on public.mr_records (upload_id, series);

create table public.pard_records (
  id              bigint generated always as identity primary key,
  upload_id       uuid not null,
  facility_id     uuid not null,
  row_no          int  not null check (row_no > 0),
  series_raw      text check (length(series_raw) <= 100),
  series          text generated always as (public.normalize_claim_series(series_raw)) stored,
  entry_date      date check (entry_date between '1900-01-01' and '2100-12-31'),
  approval_source text check (length(approval_source) <= 200),
  extra           jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (upload_id, facility_id) references public.run_uploads (id, facility_id),
  unique (upload_id, row_no)
);
create index pard_records_upload_series_idx on public.pard_records (upload_id, series);

create table public.pf_names (
  id           bigint generated always as identity primary key,
  upload_id    uuid not null,
  facility_id  uuid not null,
  row_no       int  not null check (row_no > 0),
  series_raw   text check (length(series_raw) <= 100),
  series       text generated always as (public.normalize_claim_series(series_raw)) stored,
  doctors_name text check (length(doctors_name) <= 300),
  extra        jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (upload_id, facility_id) references public.run_uploads (id, facility_id),
  unique (upload_id, row_no)
);
create index pf_names_upload_series_idx on public.pf_names (upload_id, series);

create table public.issue_tags (
  id           bigint generated always as identity primary key,
  upload_id    uuid not null,
  facility_id  uuid not null,
  row_no       int  not null check (row_no > 0),
  series_raw   text check (length(series_raw) <= 100),
  series       text generated always as (public.normalize_claim_series(series_raw)) stored,
  date_tagged  date check (date_tagged between '1900-01-01' and '2100-12-31'),
  process      text check (length(process) <= 200),
  extra        jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (upload_id, facility_id) references public.run_uploads (id, facility_id),
  unique (upload_id, row_no)
);
create index issue_tags_upload_series_idx on public.issue_tags (upload_id, series);

create table public.issue_untags (
  id             bigint generated always as identity primary key,
  upload_id      uuid not null,
  facility_id    uuid not null,
  row_no         int  not null check (row_no > 0),
  series_raw     text check (length(series_raw) <= 100),
  series         text generated always as (public.normalize_claim_series(series_raw)) stored,
  date_untagged  date check (date_untagged between '1900-01-01' and '2100-12-31'),
  process        text check (length(process) <= 200),
  extra          jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (upload_id, facility_id) references public.run_uploads (id, facility_id),
  unique (upload_id, row_no)
);
create index issue_untags_upload_series_idx on public.issue_untags (upload_id, series);

create table public.icd_codes (
  id               bigint generated always as identity primary key,
  upload_id        uuid not null,
  facility_id      uuid not null,
  row_no           int  not null check (row_no > 0),
  series_raw       text check (length(series_raw) <= 100),
  series           text generated always as (public.normalize_claim_series(series_raw)) stored,
  icd_code         text check (length(icd_code) <= 50),
  rvs_code         text check (length(rvs_code) <= 50),
  total_acr_amount numeric(14, 2) check (total_acr_amount is null or total_acr_amount <> 'NaN'),
  extra            jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (upload_id, facility_id) references public.run_uploads (id, facility_id),
  unique (upload_id, row_no)
);
create index icd_codes_upload_series_idx on public.icd_codes (upload_id, series);

-- ---------------------------------------------------------------------------
-- RLS: PhilHealth roles lang, ayon sa saklaw sa facilities (gaya ng 0009)
-- ---------------------------------------------------------------------------
alter table public.rth_reasons  enable row level security;
alter table public.mr_records   enable row level security;
alter table public.pard_records enable row level security;
alter table public.pf_names     enable row level security;
alter table public.issue_tags   enable row level security;
alter table public.issue_untags enable row level security;
alter table public.icd_codes    enable row level security;

revoke all on public.rth_reasons, public.mr_records, public.pard_records, public.pf_names,
              public.issue_tags, public.issue_untags, public.icd_codes from anon;
revoke insert, update, delete, truncate
    on public.rth_reasons, public.mr_records, public.pard_records, public.pf_names,
       public.issue_tags, public.issue_untags, public.icd_codes from authenticated;

create policy rth_reasons_select on public.rth_reasons for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));
create policy mr_records_select on public.mr_records for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));
create policy pard_records_select on public.pard_records for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));
create policy pf_names_select on public.pf_names for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));
create policy issue_tags_select on public.issue_tags for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));
create policy issue_untags_select on public.issue_untags for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));
create policy icd_codes_select on public.icd_codes for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));

-- ---------------------------------------------------------------------------
-- RPCs (create or replace; pareho ng 0009 + mga bagong kind)
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
                    'rth_reasons', 'mr', 'pard', 'pf_name', 'tagging', 'untagging', 'icd_codes') then
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
  end;

  update public.run_uploads
     set status = 'complete', completed_at = now(), invalid_series_count = v_invalid
   where id = u.id;
end;
$$;

revoke execute on function public.start_run_upload(uuid, text, text, text, int, jsonb) from public, anon;
revoke execute on function public.add_run_rows(uuid, jsonb)                           from public, anon;
revoke execute on function public.finish_run_upload(uuid)                             from public, anon;
grant  execute on function public.start_run_upload(uuid, text, text, text, int, jsonb) to authenticated;
grant  execute on function public.add_run_rows(uuid, jsonb)                           to authenticated;
grant  execute on function public.finish_run_upload(uuid)                             to authenticated;
