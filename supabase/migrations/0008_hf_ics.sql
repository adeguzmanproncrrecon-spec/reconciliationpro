-- 0008_hf_ics.sql
-- Yugto A: HF ICS na ina-upload ng facility (facility / facility_admin), kahit kailan.
-- Kapag gumawa ang FINMAREP ng recon run, pipiliin ang pinakabagong 'complete' na submission ng facility.
--
-- Upload flow (lahat sa RPC; walang direktang insert/update ang browser):
--   1. start_hf_ics_submission(...)  → bagong submission (status 'uploading'); facility_id mula sa account ng caller
--   2. add_hf_ics_rows(id, rows)     → paulit-ulit, hanggang 5,000 row bawat tawag
--   3. finish_hf_ics_submission(id)  → 'complete' (o fail_hf_ics_submission → 'failed')
-- Ang 'complete' na submission ay hindi na nababago.
-- Ang Claim Series ay laging text; ang normalized na 13 digits ay kinukuwenta ng DB (generated column).

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.hf_ics_submissions (
  id             uuid primary key default gen_random_uuid(),
  facility_id    uuid not null references public.facilities (id),
  uploaded_by    uuid not null references public.profiles (id),
  file_name      text not null check (length(file_name) <= 255),
  sheet_name     text check (length(sheet_name) <= 100),
  header_row     int  check (header_row > 0),
  column_map     jsonb not null default '{}'::jsonb   -- hal. {"claim_series":"CLAIM SERIES NO.","ics_amount":"AMOUNT"}
                 check (jsonb_typeof(column_map) = 'object' and pg_column_size(column_map) <= 2048),
  status         text not null default 'uploading'
                 check (status in ('uploading', 'complete', 'failed')),
  row_count      int not null default 0,
  invalid_series_count int not null default 0,
  created_at     timestamptz not null default now(),
  completed_at   timestamptz,
  unique (id, facility_id)                            -- para sa composite FK ng hf_ics_rows
);
create index hf_ics_submissions_facility_idx on public.hf_ics_submissions (facility_id, created_at desc);

create table public.hf_ics_rows (
  id               bigint generated always as identity primary key,
  submission_id    uuid not null,
  facility_id      uuid not null,                                     -- denormalized para sa RLS
  row_no           int  not null check (row_no > 0),                  -- row number sa Excel
  claim_series_raw text check (length(claim_series_raw) <= 100),
  -- 13 digits (alisin ang non-digit, kunin ang unang 13); kulang → NULL = "Invalid Claim Series"
  claim_series     text generated always as (
                     case when length(regexp_replace(coalesce(claim_series_raw, ''), '\D', '', 'g')) >= 13
                          then left(regexp_replace(claim_series_raw, '\D', '', 'g'), 13)
                     end) stored,
  ics_amount       numeric(14, 2) check (ics_amount is null or ics_amount <> 'NaN'),
  ics_amount_raw   text check (length(ics_amount_raw) <= 100),
  extra            jsonb not null default '{}'::jsonb                 -- ibang columns: {"<header>": "<text>"}
                   check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 8192),
  foreign key (submission_id, facility_id) references public.hf_ics_submissions (id, facility_id),
  unique (submission_id, row_no)
);
create index hf_ics_rows_submission_series_idx on public.hf_ics_rows (submission_id, claim_series);
create index hf_ics_rows_facility_idx on public.hf_ics_rows (facility_id);

-- ---------------------------------------------------------------------------
-- RLS: makikita kung makikita ang facility (ginagamit ang RLS ng public.facilities)
-- ---------------------------------------------------------------------------
alter table public.hf_ics_submissions enable row level security;
alter table public.hf_ics_rows        enable row level security;

revoke all on public.hf_ics_submissions, public.hf_ics_rows from anon;
revoke insert, update, delete, truncate on public.hf_ics_submissions, public.hf_ics_rows from authenticated;

create policy hf_ics_submissions_select on public.hf_ics_submissions
  for select to authenticated
  using (facility_id in (select f.id from public.facilities f));

create policy hf_ics_rows_select on public.hf_ics_rows
  for select to authenticated
  using (facility_id in (select f.id from public.facilities f));

comment on policy facilities_select on public.facilities is
  'Saklaw ng user sa facilities. Ginagamit din ito ng RLS ng hf_ics_* (at susunod na data tables): '
  'ang pagpapalawak ng policy na ito ay nagpapalawak din ng access sa claims data.';

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create function public.start_hf_ics_submission(
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
  v_fac uuid := public.app_user_facility_id();
  v_id  uuid;
begin
  if coalesce(public.app_user_role()::text, '') not in ('facility', 'facility_admin') or v_fac is null then
    raise exception 'Facility staff lang ang makaka-upload ng HF ICS' using errcode = '42501';
  end if;
  if jsonb_typeof(coalesce(p_column_map, '{}'::jsonb)) <> 'object' then
    raise exception 'Invalid column map';
  end if;

  insert into public.hf_ics_submissions (facility_id, uploaded_by, file_name, sheet_name, header_row, column_map)
  values (v_fac, auth.uid(), left(coalesce(nullif(trim(p_file_name), ''), 'upload.xlsx'), 255),
          left(p_sheet_name, 100), p_header_row, coalesce(p_column_map, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

-- p_rows: [{"row_no":9,"claim_series_raw":"…","ics_amount":1234.5,"ics_amount_raw":"1,234.50","extra":{…}}, …]
create function public.add_hf_ics_rows(p_submission uuid, p_rows jsonb)
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

  -- Lock: hindi makakasabay ang finish habang nagdadagdag
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

  insert into public.hf_ics_rows (submission_id, facility_id, row_no, claim_series_raw, ics_amount, ics_amount_raw, extra)
  select p_submission, v_fac, r.row_no,
         left(r.claim_series_raw, 100),
         r.ics_amount,
         left(r.ics_amount_raw, 100),
         case when jsonb_typeof(r.extra) = 'object' then r.extra else '{}'::jsonb end
  from jsonb_to_recordset(p_rows)
       as r(row_no int, claim_series_raw text, ics_amount numeric, ics_amount_raw text, extra jsonb);
  get diagnostics v_n = row_count;

  update public.hf_ics_submissions set row_count = row_count + v_n
   where id = p_submission and status = 'uploading';
  return v_n;
end;
$$;

create function public.finish_hf_ics_submission(p_submission uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.hf_ics_submissions s
     set status = 'complete',
         completed_at = now(),
         invalid_series_count = (select count(*) from public.hf_ics_rows r
                                 where r.submission_id = s.id and r.claim_series is null)
   where s.id = p_submission and s.status = 'uploading' and s.row_count > 0
     and s.uploaded_by = auth.uid() and s.facility_id = public.app_user_facility_id()
     and public.app_user_role() in ('facility', 'facility_admin');
  if not found then
    raise exception 'Hindi matapos ang submission na ito (walang row, o hindi sa iyo)' using errcode = '42501';
  end if;
end;
$$;

create function public.fail_hf_ics_submission(p_submission uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.hf_ics_submissions s
     set status = 'failed', completed_at = now()
   where s.id = p_submission and s.status = 'uploading'
     and s.uploaded_by = auth.uid() and s.facility_id = public.app_user_facility_id()
     and public.app_user_role() in ('facility', 'facility_admin');
end;
$$;

revoke execute on function public.start_hf_ics_submission(text, text, int, jsonb) from public, anon;
revoke execute on function public.add_hf_ics_rows(uuid, jsonb)                    from public, anon;
revoke execute on function public.finish_hf_ics_submission(uuid)                  from public, anon;
revoke execute on function public.fail_hf_ics_submission(uuid)                    from public, anon;
grant  execute on function public.start_hf_ics_submission(text, text, int, jsonb) to authenticated;
grant  execute on function public.add_hf_ics_rows(uuid, jsonb)                    to authenticated;
grant  execute on function public.finish_hf_ics_submission(uuid)                  to authenticated;
grant  execute on function public.fail_hf_ics_submission(uuid)                    to authenticated;
