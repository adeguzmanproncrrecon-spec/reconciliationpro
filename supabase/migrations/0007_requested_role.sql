-- 0007_requested_role.sql
-- Ang nagrerehistro ay pumipili ng position (hiling lang; ang approver pa rin ang nagpapasya).
-- Ang pending request ay makikita lang ng tamang approver:
--   finmarep       → FINMAREP approver
--   bas_processor  → Branch Admin ng branch
--   facility_admin → Branch Admin ng branch ng facility
--   facility       → Facility Admin ng facility
-- Lumang pending (walang requested_role) → gaya ng dati, makikita ng lahat ng may saklaw.
-- Ang approval ay dapat tugma sa hiniling na role.

-- ---------------------------------------------------------------------------
-- Column
-- ---------------------------------------------------------------------------
alter table public.profiles add column requested_role public.app_role;

alter table public.profiles add constraint profiles_requested_role_chk check (
  requested_role is null
  or (status in ('pending', 'rejected')
      and ((requested_facility_id is not null and requested_role in ('facility', 'facility_admin'))
           or (requested_branch_id is not null and requested_role in ('finmarep', 'bas_processor'))))
);

-- ---------------------------------------------------------------------------
-- Registration: basahin din ang requested_role (validated; hindi ito ang role)
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uuid_re constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  v_fac  text := new.raw_user_meta_data ->> 'requested_facility_id';
  v_br   text := new.raw_user_meta_data ->> 'requested_branch_id';
  v_req  text := new.raw_user_meta_data ->> 'requested_role';
  v_fac_id uuid;
  v_br_id  uuid;
  v_role   public.app_role;
begin
  if v_fac ~ v_uuid_re then
    select f.id into v_fac_id from public.facilities f where f.id = v_fac::uuid;
  end if;
  if v_fac_id is null and v_br ~ v_uuid_re then
    select b.id into v_br_id from public.branches b where b.id = v_br::uuid;
  end if;

  -- Tanggapin lang ang position na tugma sa uri ng request; kung hindi → null
  if v_fac_id is not null and v_req in ('facility', 'facility_admin') then
    v_role := v_req::public.app_role;
  elsif v_br_id is not null and v_req in ('finmarep', 'bas_processor') then
    v_role := v_req::public.app_role;
  end if;

  -- role, facility_id, branch_id: sinasadyang hindi galing sa metadata
  insert into public.profiles (id, full_name, status, requested_facility_id, requested_branch_id, requested_role)
  values (new.id,
          coalesce(left(trim(new.raw_user_meta_data ->> 'full_name'), 200), ''),
          'pending', v_fac_id, v_br_id, v_role);
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Sino ang pwedeng mag-manage: pending → ayon sa requested_role
-- ---------------------------------------------------------------------------
create or replace function public.can_manage_profile(p_target uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles me
    join public.profiles t on t.id = p_target
    where me.id = auth.uid()
      and me.status = 'active'
      and t.id <> me.id
      and (
        -- Facility Admin → staff ng sariling facility (o pending na humiling bilang staff)
        (me.role = 'facility_admin'
         and coalesce(t.facility_id, t.requested_facility_id) = me.facility_id
         and (t.role = 'facility'
              or (t.role is null and coalesce(t.requested_role, 'facility') = 'facility')))
        or
        -- Branch Admin → FINMAREP / BAS Processor ng home branch niya
        --   (pending: BAS Processor lang; hindi kasama ang FINMAREP approvers)
        (me.role = 'branch_admin'
         and coalesce(t.branch_id, t.requested_branch_id) = me.branch_id
         and not t.is_finmarep_approver
         and (t.role in ('finmarep', 'bas_processor')
              or (t.role is null and coalesce(t.requested_role, 'bas_processor') = 'bas_processor')))
        or
        -- Branch Admin → Facility Admin (o pending na humiling bilang Facility Admin) ng facility sa branch niya
        (me.role = 'branch_admin'
         and (t.role = 'facility_admin'
              or (t.role is null and coalesce(t.requested_role, 'facility_admin') = 'facility_admin'))
         and exists (select 1 from public.facilities f
                     where f.id = coalesce(t.facility_id, t.requested_facility_id)
                       and f.branch_id = me.branch_id))
        or
        -- FINMAREP approver (IT) → FINMAREP accounts (o pending na humiling bilang FINMAREP), lahat ng branch
        (me.role = 'finmarep' and me.is_finmarep_approver
         and not t.is_finmarep_approver
         and (t.role = 'finmarep'
              or (t.role is null and t.requested_branch_id is not null
                  and coalesce(t.requested_role, 'finmarep') = 'finmarep')))
      )
  );
$$;

-- Inline na bersyon sa RLS (dapat tugma sa can_manage_profile)
alter policy profiles_select on public.profiles
  using (
    id = (select auth.uid())
    or ((select public.app_user_role()) = 'facility_admin'
        and coalesce(facility_id, requested_facility_id) = (select public.app_user_facility_id())
        and (role = 'facility'
             or (role is null and coalesce(requested_role, 'facility') = 'facility')))
    or ((select public.app_user_role()) = 'branch_admin'
        and ((coalesce(branch_id, requested_branch_id) = (select public.app_user_branch_id())
              and not is_finmarep_approver
              and (role in ('finmarep', 'bas_processor')
                   or (role is null and coalesce(requested_role, 'bas_processor') = 'bas_processor')))
             or ((role = 'facility_admin'
                  or (role is null and coalesce(requested_role, 'facility_admin') = 'facility_admin'))
                 and coalesce(facility_id, requested_facility_id) in (
                   select f.id from public.facilities f
                   where f.branch_id = (select public.app_user_branch_id())))))
    or ((select public.app_user_is_finmarep_approver())
        and id <> (select auth.uid())
        and not is_finmarep_approver
        and (role = 'finmarep'
             or (role is null and requested_branch_id is not null
                 and coalesce(requested_role, 'finmarep') = 'finmarep')))
  );

-- ---------------------------------------------------------------------------
-- Approval: dapat tugma sa hiniling na role; burahin ang requested_* pagka-approve
-- ---------------------------------------------------------------------------
create or replace function public.approve_account(p_user uuid, p_role public.app_role)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_my_role public.app_role := public.app_user_role();
  t public.profiles;
begin
  if not public.can_manage_profile(p_user) then
    raise exception 'Hindi mo hawak ang account na ito' using errcode = '42501';
  end if;

  select * into t from public.profiles where id = p_user for update;
  if t.status <> 'pending' then
    raise exception 'Hindi pending ang account';
  end if;
  if t.requested_role is not null and t.requested_role <> p_role then
    raise exception 'Requested position is %; reject it if it is wrong', t.requested_role using errcode = '42501';
  end if;

  if v_my_role = 'facility_admin'
     and p_role = 'facility' and t.requested_facility_id is not null then
    update public.profiles
       set status = 'active', role = p_role,
           facility_id = t.requested_facility_id, requested_facility_id = null, requested_role = null
     where id = p_user;
  elsif v_my_role = 'branch_admin'
     and p_role = 'facility_admin' and t.requested_facility_id is not null then
    -- Ang unique index ang magbabawal kung may active na Facility Admin na
    update public.profiles
       set status = 'active', role = p_role,
           facility_id = t.requested_facility_id, requested_facility_id = null, requested_role = null
     where id = p_user;
  elsif t.requested_branch_id is not null
     and ((v_my_role = 'branch_admin' and p_role = 'bas_processor')
          or (p_role = 'finmarep' and public.app_user_is_finmarep_approver())) then
    update public.profiles
       set status = 'active', role = p_role,
           branch_id = t.requested_branch_id, requested_branch_id = null, requested_role = null
     where id = p_user;
    -- Home branch ay awtomatikong hawak niya
    insert into public.user_branches (user_id, branch_id)
    values (p_user, t.requested_branch_id)
    on conflict do nothing;
  else
    raise exception 'Hindi pwedeng i-approve bilang %', p_role using errcode = '42501';
  end if;
end;
$$;
