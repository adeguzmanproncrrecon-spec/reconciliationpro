-- 0033_facility_profile_settings.sql
-- (1) Facility Profile (view-only; desisyon ng user, 2026-10-07): RPC facility_profile() para sa sariling facility.
-- (2) Settings (System settings, FINMAREP lang): app_settings — sa ngayon, mga posisyon ng signatory sa Annex A.
--     Blangko pa rin ang mga PANGALAN sa Reviewed by / Certified Correct / Acknowledged by (docs/DEVELOPER_NOTES.md); posisyon lang ito.
-- Kailangan ang 0032 (audit_write). Walang DROP / DELETE / TRUNCATE.

-- ---------------------------------------------------------------------------
-- (1) Facility Profile
-- ---------------------------------------------------------------------------
create function public.facility_profile()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_fac uuid := public.app_user_facility_id();
  v     jsonb;
begin
  if public.app_user_role() not in ('facility', 'facility_admin') or v_fac is null then
    raise exception 'Facility users only' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'name', f.name, 'accreditation_no', f.accreditation_no, 'branch_code', b.code, 'branch_name', b.name,
    'registered_at', f.created_at,
    -- Pangalan lang ng Facility Admin (walang email)
    'facility_admin', (select p.full_name from public.profiles p
                        where p.facility_id = f.id and p.role = 'facility_admin' and p.status = 'active' limit 1),
    'active_staff', (select count(*) from public.profiles p where p.facility_id = f.id and p.status = 'active'),
    'pending_staff', (select count(*) from public.profiles p
                       where coalesce(p.facility_id, p.requested_facility_id) = f.id and p.status = 'pending'),
    'latest_hf_ics', (select jsonb_build_object('file_name', s.file_name, 'rows', s.row_count, 'completed_at', s.completed_at)
                        from public.hf_ics_submissions s where s.facility_id = f.id and s.status = 'complete'
                       order by s.completed_at desc nulls last limit 1),
    'hf_ics_count', (select count(*) from public.hf_ics_submissions s where s.facility_id = f.id and s.status = 'complete'),
    'latest_loi', (select jsonb_build_object('letter_date', l.letter_date, 'coverage_start', l.coverage_start,
                                             'coverage_end', l.coverage_end, 'submitted_at', l.submitted_at)
                     from public.facility_lois l where l.facility_id = f.id order by l.submitted_at desc limit 1),
    'latest_recon', (select jsonb_build_object('report_date', m.report_date, 'matching_date', m.matching_date,
                                               'finished_at', m.finished_at)
                       from public.recon_matches m where m.facility_id = f.id and m.status = 'done'
                      order by m.finished_at desc limit 1))
    into v
    from public.facilities f left join public.branches b on b.id = f.branch_id
   where f.id = v_fac;
  return v;
end;
$$;
revoke execute on function public.facility_profile() from public, anon;
grant  execute on function public.facility_profile() to authenticated;

-- ---------------------------------------------------------------------------
-- (2) System settings
-- ---------------------------------------------------------------------------
create table public.app_settings (
  key        text primary key check (key ~ '^[a-z_]{1,60}$'),
  value      text not null default '' check (length(value) <= 200),
  label      text not null,
  updated_by uuid references public.profiles (id),
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon;
revoke insert, update, delete, truncate on public.app_settings from authenticated;
-- Basa: lahat ng active na user (kailangan sa Annex A export, pati ng facility); hindi sensitibo
create policy app_settings_select on public.app_settings for select to authenticated
  using ((select public.app_user_role()) is not null);

insert into public.app_settings (key, value, label) values
  ('annex_reviewed_position',     'Accountant III',                'Annex A – Reviewed by (position)'),
  ('annex_certified_position',    'Head, Fund Management Section', 'Annex A – Certified Correct (position)'),
  ('annex_acknowledged_position', '',                              'Annex A – Acknowledged by (position)')
on conflict (key) do nothing;

create function public.set_app_setting(p_key text, p_value text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_old text;
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'Only FINMAREP can change system settings' using errcode = '42501';
  end if;
  select value into v_old from public.app_settings where key = p_key for update;
  if not found then
    raise exception 'Unknown setting' using errcode = '22023';
  end if;
  update public.app_settings
     set value = left(coalesce(trim(p_value), ''), 200), updated_by = auth.uid(), updated_at = now()
   where key = p_key;
  perform public.audit_write('setting_changed', null, null, null, null, null,
    jsonb_build_object('key', p_key, 'from', v_old, 'to', left(coalesce(trim(p_value), ''), 200)));
end;
$$;
revoke execute on function public.set_app_setting(text, text) from public, anon;
grant  execute on function public.set_app_setting(text, text) to authenticated;
