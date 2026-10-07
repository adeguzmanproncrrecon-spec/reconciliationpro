-- 0001_profiles_and_roles.sql
-- Roles, branches, facilities, profiles, at user ↔ branch mapping.
--
-- Access (tingnan ang docs/DEVELOPER_NOTES.md "Mga user"):
--   facility, facility_admin → sariling facility lang
--   finmarep                 → lahat ng branch (UI filter lang ang "hawak na branch", hindi RLS)
--   bas_processor            → mga branch na naka-assign sa kanya sa user_branches lang
--   branch_admin             → home branch niya lang (profiles.branch_id)
-- Pending / rejected / disabled na account → walang nakikita.
--
-- Walang insert/update/delete policy dito. Ang account management ay sa RPC
-- (0002_account_management.sql); ang branches at facilities ay sa SQL editor muna.

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
create type public.app_role as enum (
  'facility', 'facility_admin', 'finmarep', 'bas_processor', 'branch_admin'
);

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.branches (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null,
  created_at timestamptz not null default now()
);

create table public.facilities (
  id               uuid primary key default gen_random_uuid(),
  accreditation_no text not null unique,
  name             text not null,
  branch_id        uuid not null references public.branches (id),
  created_at       timestamptz not null default now()
);
create index facilities_branch_id_idx on public.facilities (branch_id);

create table public.profiles (
  id                    uuid primary key references auth.users (id) on delete cascade,
  full_name             text not null,
  status                text not null default 'pending'
                        check (status in ('pending', 'active', 'disabled', 'rejected')),
  role                  public.app_role,
  facility_id           uuid references public.facilities (id),  -- facility users
  branch_id             uuid references public.branches (id),    -- home branch ng PhilHealth users
  -- Hinihiling sa registration; ang approver ang magtatakda ng facility_id/branch_id
  requested_facility_id uuid references public.facilities (id),
  requested_branch_id   uuid references public.branches (id),
  -- FINMAREP (IT) na pwedeng mag-approve ng FINMAREP accounts. IT lang ang nagse-set (SQL editor).
  is_finmarep_approver  boolean not null default false,
  created_at            timestamptz not null default now(),
  constraint profiles_finmarep_approver_chk check (not is_finmarep_approver or role is not distinct from 'finmarep'),
  constraint profiles_role_scope_chk check (
    case
      when status in ('pending', 'rejected') then
        role is null and facility_id is null and branch_id is null
        and num_nonnulls(requested_facility_id, requested_branch_id) <= 1
      when role in ('facility', 'facility_admin') then
        facility_id is not null and branch_id is null
      when role in ('finmarep', 'bas_processor', 'branch_admin') then
        branch_id is not null and facility_id is null
      else false
    end
  )
);
create index profiles_facility_id_idx           on public.profiles (facility_id);
create index profiles_branch_id_idx             on public.profiles (branch_id);
create index profiles_requested_facility_id_idx on public.profiles (requested_facility_id);
create index profiles_requested_branch_id_idx   on public.profiles (requested_branch_id);
-- Isa lang na active na Facility Admin bawat facility
create unique index profiles_one_facility_admin_idx
  on public.profiles (facility_id)
  where role = 'facility_admin' and status = 'active';

-- Mga branch na hawak ng FINMAREP / BAS Processor (pwedeng higit sa isa).
-- PAALALA: kapag pinalitan ang role ng user, linisin din ang rows niya rito —
-- ang lumang rows ay agad magbibigay ng branch access kapag naging bas_processor siya.
create table public.user_branches (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  branch_id  uuid not null references public.branches (id),
  created_at timestamptz not null default now(),
  primary key (user_id, branch_id)
);
create index user_branches_branch_id_idx on public.user_branches (branch_id);

-- ---------------------------------------------------------------------------
-- Helper functions (security definer para hindi mag-recurse ang RLS)
-- ---------------------------------------------------------------------------
-- Role ng caller, kung active lang ang account; kung hindi → null
create function public.app_user_role()
returns public.app_role
language sql stable security definer
set search_path = ''
as $$
  select p.role from public.profiles p
  where p.id = auth.uid() and p.status = 'active';
$$;

-- Facility / home branch ng caller (active lang). Ginagamit sa policies para hindi
-- direktang mag-query ng profiles (iwas recursion ng profiles ↔ facilities policies).
create function public.app_user_facility_id()
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select p.facility_id from public.profiles p
  where p.id = auth.uid() and p.status = 'active';
$$;

create function public.app_user_branch_id()
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select p.branch_id from public.profiles p
  where p.id = auth.uid() and p.status = 'active';
$$;

create function public.can_view_branch(p_branch_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select case public.app_user_role()
    when 'finmarep' then true
    when 'bas_processor' then exists (
      select 1 from public.user_branches ub
      where ub.user_id = auth.uid() and ub.branch_id = p_branch_id)
    when 'branch_admin' then exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.branch_id = p_branch_id)
    when 'facility' then exists (
      select 1 from public.profiles p
      join public.facilities f on f.id = p.facility_id
      where p.id = auth.uid() and f.branch_id = p_branch_id)
    when 'facility_admin' then exists (
      select 1 from public.profiles p
      join public.facilities f on f.id = p.facility_id
      where p.id = auth.uid() and f.branch_id = p_branch_id)
    else false
  end;
$$;

create function public.can_view_facility(p_facility_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select case public.app_user_role()
    when 'finmarep' then true
    when 'bas_processor' then exists (
      select 1 from public.facilities f
      join public.user_branches ub on ub.branch_id = f.branch_id
      where f.id = p_facility_id and ub.user_id = auth.uid())
    when 'branch_admin' then exists (
      select 1 from public.facilities f
      join public.profiles p on p.branch_id = f.branch_id
      where f.id = p_facility_id and p.id = auth.uid())
    when 'facility' then exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.facility_id = p_facility_id)
    when 'facility_admin' then exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.facility_id = p_facility_id)
    else false
  end;
$$;

revoke execute on function public.app_user_facility_id()   from public, anon;
revoke execute on function public.app_user_branch_id()     from public, anon;
grant  execute on function public.app_user_facility_id()   to authenticated;
grant  execute on function public.app_user_branch_id()     to authenticated;
revoke execute on function public.app_user_role()          from public, anon;
revoke execute on function public.can_view_branch(uuid)    from public, anon;
revoke execute on function public.can_view_facility(uuid)  from public, anon;
grant  execute on function public.app_user_role()          to authenticated;
grant  execute on function public.can_view_branch(uuid)    to authenticated;
grant  execute on function public.can_view_facility(uuid)  to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.branches      enable row level security;
alter table public.facilities    enable row level security;
alter table public.profiles      enable row level security;
alter table public.user_branches enable row level security;

revoke all on public.branches, public.facilities, public.profiles, public.user_branches from anon;
-- Read-only ang authenticated sa mga table na ito; ang pagbabago ay sa RPC lang.
revoke insert, update, delete, truncate
  on public.branches, public.facilities, public.profiles, public.user_branches
  from authenticated;

create policy branches_select on public.branches
  for select to authenticated
  using (public.can_view_branch(id));

-- Inline (hindi can_view_facility per row) para mabilis sa libu-libong facility.
create policy facilities_select on public.facilities
  for select to authenticated
  using (
    (select public.app_user_role()) = 'finmarep'
    or ((select public.app_user_role()) = 'bas_processor'
        and branch_id in (select ub.branch_id from public.user_branches ub
                          where ub.user_id = (select auth.uid())))
    or ((select public.app_user_role()) = 'branch_admin'
        and branch_id = (select public.app_user_branch_id()))
    or ((select public.app_user_role()) in ('facility', 'facility_admin')
        and id = (select public.app_user_facility_id()))
  );

-- profiles_select at user_branches_select: nasa 0002 (kailangan ng can_manage_profile)
