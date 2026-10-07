-- 0032_audit_log.sql
-- System Logs (desisyon ng user, 2026-10-07): talaan ng mahahalagang aksyon.
-- - Isinusulat ng mga trigger sa database (hindi malalampasan ng browser); ang export lang ang galing sa RPC log_export.
-- - Hindi mababago o mabubura ng user (walang insert/update/delete policy o grant).
-- - Makikita: FINMAREP = lahat; Branch Admin = sariling (home) branch lang. Hindi ng BAS Processor o facility.
-- - Walang FK sa ibang table: mananatili ang log kahit burahin ang run/match (hal. test data reset).
-- Walang DROP / DELETE / TRUNCATE.

create table public.audit_log (
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  actor_id      uuid,                      -- null = System (hal. matching job)
  actor_name    text,
  actor_role    public.app_role,
  action        text not null,
  branch_id     uuid,
  facility_id   uuid,
  facility_name text,
  target_id     uuid,                      -- account na apektado (para sa account actions)
  target_name   text,
  run_id        uuid,
  match_id      uuid,
  details       jsonb not null default '{}'::jsonb
);
create index audit_log_at_idx on public.audit_log (at desc);
create index audit_log_branch_at_idx on public.audit_log (branch_id, at desc);
create index audit_log_action_at_idx on public.audit_log (action, at desc);

alter table public.audit_log enable row level security;
revoke all on public.audit_log from anon;
revoke insert, update, delete, truncate on public.audit_log from authenticated;
create policy audit_log_select on public.audit_log for select to authenticated
  using (
    (select public.app_user_role()) = 'finmarep'
    or ((select public.app_user_role()) = 'branch_admin' and branch_id = (select public.app_user_branch_id()))
  );

-- ---------------------------------------------------------------------------
-- Panloob na helper (trigger / RPC lang; walang grant sa authenticated)
-- ---------------------------------------------------------------------------
create function public.audit_write(
  p_action text, p_facility uuid, p_branch uuid, p_target uuid, p_run uuid, p_match uuid, p_details jsonb
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_name  text;
  v_role  public.app_role;
  v_fname text;
  v_fbr   uuid;
  v_tname text;
begin
  if v_actor is not null then
    select p.full_name, p.role into v_name, v_role from public.profiles p where p.id = v_actor;
  end if;
  if p_facility is not null then
    select f.name, f.branch_id into v_fname, v_fbr from public.facilities f where f.id = p_facility;
  end if;
  if p_target is not null then
    select p.full_name into v_tname from public.profiles p where p.id = p_target;
  end if;
  -- Kapag p_branch = '00000000-…' (tingnan ang audit_account_branch): sadyang walang branch → FINMAREP lang ang makakakita
  -- Availability muna: hindi dapat pigilan ng pagsulat ng log ang mismong aksyon (hal. puno ang disk)
  begin
    insert into public.audit_log (actor_id, actor_name, actor_role, action, branch_id, facility_id, facility_name,
                                  target_id, target_name, run_id, match_id, details)
    values (v_actor, v_name, v_role, p_action,
            case when p_branch = '00000000-0000-0000-0000-000000000000'::uuid then null else coalesce(p_branch, v_fbr) end,
            p_facility, v_fname, p_target, v_tname, p_run, p_match, coalesce(p_details, '{}'::jsonb));
  exception when others then
    raise warning 'audit_log write failed (%): %', p_action, sqlerrm;
  end;
end;
$$;
revoke execute on function public.audit_write(text, uuid, uuid, uuid, uuid, uuid, jsonb) from public, anon, authenticated;

-- Branch ng account event — kapareho ng nakikita ng Branch Admin sa profiles_select (0007):
-- BAS Processor / active na FINMAREP (hindi approver) ng home branch niya, at Facility Admin ng facility sa branch niya.
-- Iba (pending na FINMAREP, approver, facility staff) → "walang branch" (FINMAREP lang ang makakakita ng log).
create function public.audit_account_branch(
  p_role public.app_role, p_req_role public.app_role, p_approver boolean,
  p_branch uuid, p_req_branch uuid, p_facility uuid, p_req_facility uuid
)
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select case
    when coalesce(p_role, p_req_role) = 'bas_processor'
      or (p_role = 'finmarep' and not coalesce(p_approver, false))
      then coalesce(p_branch, p_req_branch, '00000000-0000-0000-0000-000000000000'::uuid)
    when coalesce(p_role, p_req_role) = 'facility_admin'
      then coalesce((select f.branch_id from public.facilities f where f.id = coalesce(p_facility, p_req_facility)),
                    '00000000-0000-0000-0000-000000000000'::uuid)
    else '00000000-0000-0000-0000-000000000000'::uuid
  end;
$$;
revoke execute on function public.audit_account_branch(public.app_role, public.app_role, boolean, uuid, uuid, uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Accounts
-- ---------------------------------------------------------------------------
create function public.audit_profiles()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_action text;
  v_branch uuid;
begin
  v_branch := public.audit_account_branch(new.role, new.requested_role, new.is_finmarep_approver, new.branch_id,
                                          new.requested_branch_id, new.facility_id, new.requested_facility_id);
  if tg_op = 'INSERT' then
    perform public.audit_write('account_registered', new.requested_facility_id, v_branch, new.id, null, null,
      jsonb_build_object('requested_role', new.requested_role));
    return new;
  end if;

  v_action := case
    when old.status is distinct from new.status then
      case new.status
        when 'active'   then case when old.status = 'pending' then 'account_approved' else 'account_enabled' end
        when 'disabled' then 'account_disabled'
        when 'rejected' then 'account_rejected'
        else 'account_status_changed' end
    when old.role is distinct from new.role or old.facility_id is distinct from new.facility_id
         or old.branch_id is distinct from new.branch_id then 'account_changed'
  end;
  if v_action is null then
    return new;
  end if;
  -- Rejection: walang role/branch ang bagong row → gamitin ang luma/hiniling
  if new.role is null and new.branch_id is null and new.facility_id is null then
    v_branch := public.audit_account_branch(old.role, new.requested_role, old.is_finmarep_approver, old.branch_id,
                                            new.requested_branch_id, old.facility_id, new.requested_facility_id);
  end if;
  perform public.audit_write(v_action, coalesce(new.facility_id, old.facility_id, new.requested_facility_id), v_branch,
    new.id, null, null,
    jsonb_strip_nulls(jsonb_build_object(
      'from_status', old.status, 'to_status', new.status,
      'role', new.role, 'old_role', nullif(old.role::text, new.role::text),
      'requested_role', new.requested_role)));
  return new;
end;
$$;
create trigger audit_profiles_ins after insert on public.profiles
  for each row execute function public.audit_profiles();
create trigger audit_profiles_upd after update of status, role, facility_id, branch_id on public.profiles
  for each row execute function public.audit_profiles();

-- Ang log ay nasa home branch ng account (ayon sa audit_account_branch), hindi sa naka-assign na branch
create function public.audit_user_branches()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_user   uuid := case when tg_op = 'INSERT' then new.user_id else old.user_id end;
  v_br     uuid := case when tg_op = 'INSERT' then new.branch_id else old.branch_id end;
  v_branch uuid;
  v_code   text;
begin
  select public.audit_account_branch(p.role, p.requested_role, p.is_finmarep_approver, p.branch_id,
                                     p.requested_branch_id, p.facility_id, p.requested_facility_id)
    into v_branch from public.profiles p where p.id = v_user;
  select b.code into v_code from public.branches b where b.id = v_br;
  perform public.audit_write(case when tg_op = 'INSERT' then 'branch_assigned' else 'branch_removed' end,
    null, coalesce(v_branch, '00000000-0000-0000-0000-000000000000'::uuid), v_user, null, null,
    jsonb_build_object('branch', v_code));
  return case when tg_op = 'INSERT' then new else old end;
end;
$$;
create trigger audit_user_branches after insert or delete on public.user_branches
  for each row execute function public.audit_user_branches();

-- ---------------------------------------------------------------------------
-- Uploads
-- ---------------------------------------------------------------------------
create function public.audit_hf_ics()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.status in ('complete', 'failed') and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform public.audit_write(case new.status when 'complete' then 'hf_ics_uploaded' else 'hf_ics_upload_failed' end,
      new.facility_id, null, null, null, null,
      jsonb_build_object('file_name', new.file_name, 'rows', new.row_count, 'invalid_series', new.invalid_series_count));
  end if;
  return new;
end;
$$;
create trigger audit_hf_ics_ins after insert on public.hf_ics_submissions
  for each row execute function public.audit_hf_ics();
create trigger audit_hf_ics_upd after update of status on public.hf_ics_submissions
  for each row execute function public.audit_hf_ics();

create function public.audit_run_uploads()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.status in ('complete', 'failed') and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform public.audit_write(case new.status when 'complete' then 'extraction_uploaded' else 'extraction_upload_failed' end,
      new.facility_id, null, null, new.run_id, null,
      jsonb_build_object('kind', new.kind, 'file_name', new.file_name, 'rows', new.row_count));
  end if;
  if tg_op = 'UPDATE' and new.discarded_at is not null and old.discarded_at is null then
    perform public.audit_write('extraction_discarded', new.facility_id, null, null, new.run_id, null,
      jsonb_build_object('kind', new.kind, 'file_name', new.file_name));
  end if;
  return new;
end;
$$;
create trigger audit_run_uploads_ins after insert on public.run_uploads
  for each row execute function public.audit_run_uploads();
create trigger audit_run_uploads_upd after update of status, discarded_at on public.run_uploads
  for each row execute function public.audit_run_uploads();

-- ---------------------------------------------------------------------------
-- Recon runs at matching
-- ---------------------------------------------------------------------------
create function public.audit_recon_runs()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform public.audit_write('recon_run_created', new.facility_id, null, null, new.id, null,
      jsonb_build_object('report_date', new.report_date, 'matching_date', new.matching_date,
                         'coverage_start', new.coverage_start, 'coverage_end', new.coverage_end));
  elsif old.report_date is distinct from new.report_date or old.prev_report_date is distinct from new.prev_report_date
        or old.matching_date is distinct from new.matching_date or old.coverage_start is distinct from new.coverage_start
        or old.coverage_end is distinct from new.coverage_end or old.hf_submission_id is distinct from new.hf_submission_id then
    perform public.audit_write('recon_run_updated', new.facility_id, null, null, new.id, null,
      jsonb_build_object('report_date', new.report_date, 'matching_date', new.matching_date,
                         'coverage_start', new.coverage_start, 'coverage_end', new.coverage_end,
                         'hf_ics_changed', old.hf_submission_id is distinct from new.hf_submission_id));
  end if;
  return new;
end;
$$;
create trigger audit_recon_runs_ins after insert on public.recon_runs
  for each row execute function public.audit_recon_runs();
create trigger audit_recon_runs_upd
  after update of report_date, prev_report_date, matching_date, coverage_start, coverage_end, hf_submission_id on public.recon_runs
  for each row execute function public.audit_recon_runs();

create function public.audit_recon_matches()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform public.audit_write('matching_requested', new.facility_id, null, null, new.run_id, new.id,
      jsonb_build_object('report_date', new.report_date, 'matching_date', new.matching_date));
  elsif new.status in ('done', 'failed') and old.status is distinct from new.status then
    perform public.audit_write(case new.status when 'done' then 'matching_done' else 'matching_failed' end,
      new.facility_id, null, null, new.run_id, new.id,
      jsonb_strip_nulls(jsonb_build_object(
        -- clock_timestamp(): ang now() ay simula ng transaction ng cron job, hindi ang oras ng pagtatapos
        'seconds', round(extract(epoch from (clock_timestamp() - coalesce(new.started_at, new.requested_at)))),
        'error', left(new.error, 300))));
  end if;
  return new;
end;
$$;
create trigger audit_recon_matches_ins after insert on public.recon_matches
  for each row execute function public.audit_recon_matches();
create trigger audit_recon_matches_upd after update of status on public.recon_matches
  for each row execute function public.audit_recon_matches();

-- ---------------------------------------------------------------------------
-- LOI at templates
-- ---------------------------------------------------------------------------
create function public.audit_facility_lois()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  perform public.audit_write('loi_submitted', new.facility_id, null, null, null, null,
    jsonb_build_object('letter_date', new.letter_date, 'coverage_start', new.coverage_start,
                       'coverage_end', new.coverage_end, 'file_name', new.file_name));
  return new;
end;
$$;
create trigger audit_facility_lois after insert on public.facility_lois
  for each row execute function public.audit_facility_lois();

create function public.audit_templates()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and old.is_active = new.is_active and old.visible_to_facility = new.visible_to_facility then
    return new;   -- walang nagbago
  end if;
  perform public.audit_write(case tg_op when 'INSERT' then 'template_uploaded' else 'template_updated' end,
    null, null, null, null, null,
    jsonb_build_object('name', new.name, 'file_name', new.file_name,
                       'active', new.is_active, 'visible_to_facility', new.visible_to_facility));
  return new;
end;
$$;
create trigger audit_templates after insert or update of is_active, visible_to_facility on public.templates
  for each row execute function public.audit_templates();

-- ---------------------------------------------------------------------------
-- Export (galing sa browser pagkatapos ng matagumpay na export)
-- ---------------------------------------------------------------------------
create function public.log_export(p_match uuid, p_kind text, p_version text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  m public.recon_matches;
begin
  if p_kind not in ('annex_a', 'matching_report') or p_version not in ('internal', 'facility') then
    raise exception 'Invalid export' using errcode = '22023';
  end if;
  -- Self-report ng browser pagkatapos ng export (hindi patunay na may file); saklaw at bersyon ay sinusuri
  select * into m from public.recon_matches where id = p_match and status = 'done';
  if not found or not coalesce(public.can_view_facility(m.facility_id), false) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if p_version = 'internal' and not coalesce(public.app_user_is_philhealth(), false) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  -- Iwas spam: isang log lang bawat user/match/uri bawat 10 segundo
  if exists (select 1 from public.audit_log a
              where a.action = 'export_' || p_kind and a.match_id = p_match and a.actor_id = auth.uid()
                and a.at > now() - interval '10 seconds') then
    return;
  end if;
  perform public.audit_write('export_' || p_kind, m.facility_id, null, null, m.run_id, m.id,
    jsonb_build_object('version', p_version, 'report_date', m.report_date));
end;
$$;
revoke execute on function public.log_export(uuid, text, text) from public, anon;
grant  execute on function public.log_export(uuid, text, text) to authenticated;

-- Ang mga trigger function ay hindi dapat tawagin nang direkta
revoke execute on function public.audit_profiles() from public, anon, authenticated;
revoke execute on function public.audit_user_branches() from public, anon, authenticated;
revoke execute on function public.audit_hf_ics() from public, anon, authenticated;
revoke execute on function public.audit_run_uploads() from public, anon, authenticated;
revoke execute on function public.audit_recon_runs() from public, anon, authenticated;
revoke execute on function public.audit_recon_matches() from public, anon, authenticated;
revoke execute on function public.audit_facility_lois() from public, anon, authenticated;
revoke execute on function public.audit_templates() from public, anon, authenticated;
