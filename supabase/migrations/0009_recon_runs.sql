-- 0009_recon_runs.sql
-- Yugto B: recon run ng FINMAREP at ang mga extraction upload nito.
--   recon_runs   — isang run = isang facility + mga petsa (report, nakaraang report, matching) + LOI coverage
--                  + HF ICS submission na gagamitin
--   run_uploads  — bawat upload ng file sa run (kind: ho_ics | raw_matching | status_trail | payment_details);
--                  pwedeng marami bawat kind; ang lahat ng 'complete' ay pinagsasama sa matching
--   ho_ics_rows, raw_claims, status_trail, payment_details — ang laman ng mga upload
-- FINMAREP lang ang gumagawa ng run at nag-a-upload (kahit anong branch). Ang PhilHealth roles (FINMAREP, BAS Processor,
-- Branch Admin) lang ang nakakakita, ayon sa saklaw nila sa facilities. Lahat ng sulat ay dumadaan sa RPC.

-- ---------------------------------------------------------------------------
-- Shared: Claim Series normalization (docs/DEVELOPER_NOTES.md) — immutable para magamit sa generated columns
-- ---------------------------------------------------------------------------
create function public.normalize_claim_series(p text)
returns text
language sql immutable parallel safe
set search_path = ''
as $$
  select case when length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) >= 13
              then left(regexp_replace(p, '\D', '', 'g'), 13) end;
$$;

-- Saklaw ng PhilHealth role (para sa RLS ng extraction tables)
create function public.app_user_is_philhealth()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce(public.app_user_role() in ('finmarep', 'bas_processor', 'branch_admin'), false);
$$;

revoke execute on function public.app_user_is_philhealth() from public, anon;
grant  execute on function public.app_user_is_philhealth() to authenticated;

-- ---------------------------------------------------------------------------
-- Runs
-- ---------------------------------------------------------------------------
create table public.recon_runs (
  id                uuid primary key default gen_random_uuid(),
  facility_id       uuid not null references public.facilities (id),
  report_date       date not null,
  prev_report_date  date,
  matching_date     date not null,
  coverage_start    date,
  coverage_end      date,
  hf_submission_id  uuid,
  status            text not null default 'draft' check (status in ('draft', 'matched')),
  created_by        uuid not null references public.profiles (id),
  created_at        timestamptz not null default now(),
  updated_by        uuid references public.profiles (id),
  updated_at        timestamptz not null default now(),
  unique (id, facility_id),
  -- HF ICS submission ay dapat sa parehong facility
  foreign key (hf_submission_id, facility_id) references public.hf_ics_submissions (id, facility_id),
  check (report_date between '1900-01-01' and '2100-12-31'),
  check (matching_date between '1900-01-01' and '2100-12-31'),
  check (prev_report_date between '1900-01-01' and '2100-12-31'),
  check (coverage_start between '1900-01-01' and '2100-12-31'),
  check (coverage_end between '1900-01-01' and '2100-12-31'),
  check (prev_report_date is null or prev_report_date < report_date),
  check (coverage_start is null or coverage_end is null or coverage_start <= coverage_end)
);
create index recon_runs_facility_idx on public.recon_runs (facility_id, report_date desc);

create table public.run_uploads (
  id            uuid primary key default gen_random_uuid(),
  run_id        uuid not null,
  facility_id   uuid not null,
  kind          text not null check (kind in ('ho_ics', 'raw_matching', 'status_trail', 'payment_details')),
  uploaded_by   uuid not null references public.profiles (id),
  file_name     text not null check (length(file_name) <= 255),
  sheet_name    text check (length(sheet_name) <= 100),
  header_row    int  check (header_row > 0),
  column_map    jsonb not null default '{}'::jsonb
                check (jsonb_typeof(column_map) = 'object' and pg_column_size(column_map) <= 4096),
  status        text not null default 'uploading' check (status in ('uploading', 'complete', 'failed', 'discarded')),
  row_count     int not null default 0,
  invalid_series_count int not null default 0,
  created_at    timestamptz not null default now(),
  completed_at  timestamptz,
  discarded_by  uuid references public.profiles (id),
  discarded_at  timestamptz,
  foreign key (run_id, facility_id) references public.recon_runs (id, facility_id),
  unique (id, facility_id)
);
create index run_uploads_run_idx on public.run_uploads (run_id, kind, created_at desc);

-- ---------------------------------------------------------------------------
-- Data tables (columns ayon sa RECON_SPEC §2). Lahat may upload_id + facility_id (para sa RLS),
-- series_raw (text) at series (13 digits, generated). Ang "-" / blangko ay NULL (ginagawa sa browser).
-- ---------------------------------------------------------------------------
create table public.ho_ics_rows (
  id             bigint generated always as identity primary key,
  upload_id      uuid not null,
  facility_id    uuid not null,
  row_no         int  not null check (row_no > 0),
  series_raw     text check (length(series_raw) <= 100),
  series         text generated always as (public.normalize_claim_series(series_raw)) stored,
  estimated_amt  numeric(14, 2) check (estimated_amt is null or estimated_amt <> 'NaN'),
  recref         date,
  extra          jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (upload_id, facility_id) references public.run_uploads (id, facility_id),
  unique (upload_id, row_no)
);
create index ho_ics_rows_upload_series_idx on public.ho_ics_rows (upload_id, series);

create table public.raw_claims (
  id               bigint generated always as identity primary key,
  upload_id        uuid not null,
  facility_id      uuid not null,
  row_no           int  not null check (row_no > 0),
  ph_inst_code     text check (length(ph_inst_code) <= 50),
  series_raw       text check (length(series_raw) <= 100),
  series           text generated always as (public.normalize_claim_series(series_raw)) stored,
  mecno            text check (length(mecno) <= 50),
  patlname         text check (length(patlname) <= 200),
  patfname         text check (length(patfname) <= 200),
  patmname         text check (length(patmname) <= 200),
  worlname         text check (length(worlname) <= 200),
  worfname         text check (length(worfname) <= 200),
  wormname         text check (length(wormname) <= 200),
  date_adm         date,
  date_dis         date,
  date_rec         date,
  date_recon       date,
  last_refiled     date,
  status           text check (length(status) <= 10),
  total_acr_amount numeric(14, 2) check (total_acr_amount is null or total_acr_amount <> 'NaN'),
  latest_check_dt  date,
  total_tot_amnt   numeric(14, 2) check (total_tot_amnt is null or total_tot_amnt <> 'NaN'),
  latest_ctrl_no   text check (length(latest_ctrl_no) <= 100),
  latest_ctrl_dt   date,
  extra            jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (upload_id, facility_id) references public.run_uploads (id, facility_id),
  unique (upload_id, row_no)
);
create index raw_claims_upload_series_idx on public.raw_claims (upload_id, series);

create table public.status_trail (
  id            bigint generated always as identity primary key,
  upload_id     uuid not null,
  facility_id   uuid not null,
  row_no        int  not null check (row_no > 0),
  series_raw    text check (length(series_raw) <= 100),
  series        text generated always as (public.normalize_claim_series(series_raw)) stored,
  time_rec      int,                 -- "Convert TIME_REC to number"; hindi numero → NULL (flag)
  date_tagged   date,
  process       text check (length(process) <= 200),
  extra         jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (upload_id, facility_id) references public.run_uploads (id, facility_id),
  unique (upload_id, row_no)
);
-- Para sa "pinakabagong trail bawat series" (§3a)
create index status_trail_upload_series_idx on public.status_trail (upload_id, series, date_tagged desc, time_rec desc);

create table public.payment_details (
  id              bigint generated always as identity primary key,
  upload_id       uuid not null,
  facility_id     uuid not null,
  row_no          int  not null check (row_no > 0),
  series_raw      text check (length(series_raw) <= 100),
  series          text generated always as (public.normalize_claim_series(series_raw)) stored,
  date_ext        date,
  check_no        text check (length(check_no) <= 100),
  check_dt        date,
  isirm           text check (length(isirm) <= 10),
  is_dcpm         text check (length(is_dcpm) <= 10),
  pr_no           text check (length(pr_no) <= 100),
  tranche_number  text check (length(tranche_number) <= 50),
  cw_tax          numeric(14, 2) check (cw_tax is null or cw_tax <> 'NaN'),
  receipt_no      text check (length(receipt_no) <= 100),
  receipt_dt      date,
  cpay_to         text check (length(cpay_to) <= 200),
  total_tot_amnt  numeric(14, 2) check (total_tot_amnt is null or total_tot_amnt <> 'NaN'),
  extra           jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (upload_id, facility_id) references public.run_uploads (id, facility_id),
  unique (upload_id, row_no)
);
create index payment_details_upload_series_idx on public.payment_details (upload_id, series);

-- Makatwirang petsa lang (iwas 'infinity', 'epoch', BC na petsa na sisira sa cutoff comparisons)
alter table public.ho_ics_rows     add check (recref between '1900-01-01' and '2100-12-31');
alter table public.raw_claims      add check (date_adm between '1900-01-01' and '2100-12-31'),
                                   add check (date_dis between '1900-01-01' and '2100-12-31'),
                                   add check (date_rec between '1900-01-01' and '2100-12-31'),
                                   add check (date_recon between '1900-01-01' and '2100-12-31'),
                                   add check (last_refiled between '1900-01-01' and '2100-12-31'),
                                   add check (latest_check_dt between '1900-01-01' and '2100-12-31'),
                                   add check (latest_ctrl_dt between '1900-01-01' and '2100-12-31');
alter table public.status_trail    add check (date_tagged between '1900-01-01' and '2100-12-31');
alter table public.payment_details add check (date_ext between '1900-01-01' and '2100-12-31'),
                                   add check (check_dt between '1900-01-01' and '2100-12-31'),
                                   add check (receipt_dt between '1900-01-01' and '2100-12-31');

-- Tandaan: kapag binago ang normalize_claim_series(), hindi kusang nare-recompute ang stored na generated columns
-- (kailangan ng table rewrite). Huwag itong baguhin nang walang migration na nagre-rewrite ng mga table.
revoke execute on function public.normalize_claim_series(text) from public, anon;
grant  execute on function public.normalize_claim_series(text) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS: PhilHealth roles lang, at facilities na saklaw nila (RLS ng public.facilities)
-- ---------------------------------------------------------------------------
alter table public.recon_runs      enable row level security;
alter table public.run_uploads     enable row level security;
alter table public.ho_ics_rows     enable row level security;
alter table public.raw_claims      enable row level security;
alter table public.status_trail    enable row level security;
alter table public.payment_details enable row level security;

revoke all on public.recon_runs, public.run_uploads, public.ho_ics_rows, public.raw_claims,
              public.status_trail, public.payment_details from anon;
revoke insert, update, delete, truncate
    on public.recon_runs, public.run_uploads, public.ho_ics_rows, public.raw_claims,
       public.status_trail, public.payment_details from authenticated;

create policy recon_runs_select on public.recon_runs for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));
create policy run_uploads_select on public.run_uploads for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));
create policy ho_ics_rows_select on public.ho_ics_rows for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));
create policy raw_claims_select on public.raw_claims for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));
create policy status_trail_select on public.status_trail for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));
create policy payment_details_select on public.payment_details for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));

-- ---------------------------------------------------------------------------
-- RPCs: runs
-- ---------------------------------------------------------------------------
create function public.create_recon_run(
  p_facility         uuid,
  p_report_date      date,
  p_prev_report_date date,
  p_matching_date    date,
  p_coverage_start   date,
  p_coverage_end     date
)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id  uuid;
  v_sub uuid;
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'FINMAREP lang ang makakagawa ng recon run' using errcode = '42501';
  end if;
  if not exists (select 1 from public.facilities where id = p_facility) then
    raise exception 'Facility not found';
  end if;
  if p_report_date is null or p_matching_date is null then
    raise exception 'Report Date at Matching Date ay kailangan';
  end if;

  -- Default: pinakabagong complete na HF ICS ng facility (pwedeng wala pa)
  select s.id into v_sub from public.hf_ics_submissions s
   where s.facility_id = p_facility and s.status = 'complete'
   order by s.completed_at desc nulls last limit 1;

  insert into public.recon_runs (facility_id, report_date, prev_report_date, matching_date,
                                 coverage_start, coverage_end, hf_submission_id, created_by)
  values (p_facility, p_report_date, p_prev_report_date, p_matching_date,
          p_coverage_start, p_coverage_end, v_sub, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- Palitan ang mga petsa / coverage ng draft run
create function public.update_recon_run(
  p_run              uuid,
  p_report_date      date,
  p_prev_report_date date,
  p_matching_date    date,
  p_coverage_start   date,
  p_coverage_end     date
)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'FINMAREP lang ang makakapagbago ng recon run' using errcode = '42501';
  end if;
  update public.recon_runs
     set report_date = p_report_date, prev_report_date = p_prev_report_date, matching_date = p_matching_date,
         coverage_start = p_coverage_start, coverage_end = p_coverage_end,
         updated_by = auth.uid(), updated_at = now()
   where id = p_run and status = 'draft';
  if not found then
    raise exception 'Run not found or not editable';
  end if;
end;
$$;

-- Piliin ang HF ICS submission ng parehong facility (complete lang)
create function public.set_run_hf_submission(p_run uuid, p_submission uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'FINMAREP lang' using errcode = '42501';
  end if;
  update public.recon_runs r
     set hf_submission_id = p_submission, updated_by = auth.uid(), updated_at = now()
   where r.id = p_run and r.status = 'draft'
     and exists (select 1 from public.hf_ics_submissions s
                 where s.id = p_submission and s.facility_id = r.facility_id and s.status = 'complete');
  if not found then
    raise exception 'Run not editable, or submission is not a complete HF ICS of this facility';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPCs: uploads (start → add rows → finish | fail; discard = hindi na gagamitin)
-- ---------------------------------------------------------------------------
create function public.start_run_upload(
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
  if p_kind not in ('ho_ics', 'raw_matching', 'status_trail', 'payment_details') then
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

-- p_rows: array ng objects na may row_no, series_raw, mga field ng kind (petsa = "YYYY-MM-DD", halaga = number), extra
create function public.add_run_rows(p_upload uuid, p_rows jsonb)
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

  -- Lock: hindi makakasabay ang finish habang nagdadagdag
  select * into u from public.run_uploads
   where id = p_upload and status = 'uploading' and uploaded_by = auth.uid()
   for update;
  if not found then
    raise exception 'Hindi mo ma-a-upload sa upload na ito' using errcode = '42501';
  end if;
  -- Ang run ay dapat draft pa (hindi magbabago ang input ng na-match na run)
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
  -- Mga uri ng value: halaga/TIME_REC/row_no = number; extra = object; lahat ng iba (series, text, petsa) = string.
  -- (Iwas "NaN" na string sa halaga, at Claim Series na ipinadala bilang number.)
  if exists (select 1 from jsonb_array_elements(p_rows) e
             where jsonb_typeof(e) <> 'object') then
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
  end if;
  get diagnostics v_n = row_count;

  update public.run_uploads set row_count = row_count + v_n
   where id = p_upload and status = 'uploading';
  return v_n;
end;
$$;

create function public.finish_run_upload(p_upload uuid)
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
  end;

  update public.run_uploads
     set status = 'complete', completed_at = now(), invalid_series_count = v_invalid
   where id = u.id;
end;
$$;

create function public.fail_run_upload(p_upload uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.run_uploads
     set status = 'failed', completed_at = now()
   where id = p_upload and status = 'uploading' and uploaded_by = auth.uid()
     and public.app_user_role() = 'finmarep';
end;
$$;

-- Huwag nang gamitin ang isang complete na upload (hal. maling file). Walang binubura.
create function public.discard_run_upload(p_upload uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'FINMAREP lang' using errcode = '42501';
  end if;
  -- Lock ang run (gaya ng add/finish) para hindi makasabay ang matching
  perform 1 from public.recon_runs r
    join public.run_uploads u on u.run_id = r.id
   where u.id = p_upload and r.status = 'draft'
   for share of r;
  if not found then
    raise exception 'Upload not found, or the run is no longer editable';
  end if;
  -- Kasama ang 'uploading' na naiwan nang higit 6 na oras (hal. nasara ang tab)
  update public.run_uploads u
     set status = 'discarded', discarded_by = auth.uid(), discarded_at = now()
   where u.id = p_upload
     and (u.status in ('complete', 'failed')
          or (u.status = 'uploading' and u.created_at < now() - interval '6 hours'))
     and exists (select 1 from public.recon_runs r where r.id = u.run_id and r.status = 'draft');
  if not found then
    raise exception 'Upload not found, or the run is no longer editable';
  end if;
end;
$$;

revoke execute on function public.create_recon_run(uuid, date, date, date, date, date)      from public, anon;
revoke execute on function public.update_recon_run(uuid, date, date, date, date, date)      from public, anon;
revoke execute on function public.set_run_hf_submission(uuid, uuid)                         from public, anon;
revoke execute on function public.start_run_upload(uuid, text, text, text, int, jsonb)       from public, anon;
revoke execute on function public.add_run_rows(uuid, jsonb)                                 from public, anon;
revoke execute on function public.finish_run_upload(uuid)                                   from public, anon;
revoke execute on function public.fail_run_upload(uuid)                                     from public, anon;
revoke execute on function public.discard_run_upload(uuid)                                  from public, anon;
grant  execute on function public.create_recon_run(uuid, date, date, date, date, date)      to authenticated;
grant  execute on function public.update_recon_run(uuid, date, date, date, date, date)      to authenticated;
grant  execute on function public.set_run_hf_submission(uuid, uuid)                         to authenticated;
grant  execute on function public.start_run_upload(uuid, text, text, text, int, jsonb)       to authenticated;
grant  execute on function public.add_run_rows(uuid, jsonb)                                 to authenticated;
grant  execute on function public.finish_run_upload(uuid)                                   to authenticated;
grant  execute on function public.fail_run_upload(uuid)                                     to authenticated;
grant  execute on function public.discard_run_upload(uuid)                                  to authenticated;
