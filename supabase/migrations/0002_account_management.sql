-- 0002_account_management.sql
-- Registration (pending) → approval ng admin. Sino ang humahawak kanino:
--   branch_admin   → PhilHealth users (finmarep, bas_processor) na ang home branch ay branch niya,
--                    at Facility Admin ng mga facility sa branch niya.
--                    Hindi siya makaka-approve ng FINMAREP (lahat ng branch ang nakikita nito).
--   finmarep na may is_finmarep_approver (IT) → nag-a-approve ng FINMAREP accounts
--   facility_admin → staff (facility) ng sariling facility
-- Ang Branch Admin mismo ay ginagawa ng IT sa SQL editor.
-- Ang role ay itinatakda ng approver, hindi kinukuha sa signup metadata.

-- ---------------------------------------------------------------------------
-- Registration: bawat bagong auth user → pending profile
-- ---------------------------------------------------------------------------
create function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uuid_re constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  v_fac  text := new.raw_user_meta_data ->> 'requested_facility_id';
  v_br   text := new.raw_user_meta_data ->> 'requested_branch_id';
  v_fac_id uuid;
  v_br_id  uuid;
begin
  if v_fac ~ v_uuid_re then
    select f.id into v_fac_id from public.facilities f where f.id = v_fac::uuid;
  end if;
  if v_fac_id is null and v_br ~ v_uuid_re then
    select b.id into v_br_id from public.branches b where b.id = v_br::uuid;
  end if;

  -- role, facility_id, branch_id: sinasadyang hindi galing sa metadata
  insert into public.profiles (id, full_name, status, requested_facility_id, requested_branch_id)
  values (new.id,
          coalesce(left(trim(new.raw_user_meta_data ->> 'full_name'), 200), ''),
          'pending', v_fac_id, v_br_id);
  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Sino ang pwedeng mag-manage sa isang account
-- ---------------------------------------------------------------------------
create function public.can_manage_profile(p_target uuid)
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
        -- Facility Admin → staff ng sariling facility (o pending na humiling sa facility niya)
        (me.role = 'facility_admin'
         and coalesce(t.facility_id, t.requested_facility_id) = me.facility_id
         and (t.role = 'facility' or t.role is null))
        or
        -- Branch Admin → FINMAREP / BAS Processor ng home branch niya
        --   (hindi kasama ang FINMAREP approvers; IT lang ang humahawak sa kanila)
        (me.role = 'branch_admin'
         and coalesce(t.branch_id, t.requested_branch_id) = me.branch_id
         and not t.is_finmarep_approver
         and (t.role in ('finmarep', 'bas_processor') or t.role is null))
        or
        -- Branch Admin → Facility Admin (o pending na humiling) ng facility sa branch niya
        (me.role = 'branch_admin'
         and (t.role = 'facility_admin' or t.role is null)
         and exists (select 1 from public.facilities f
                     where f.id = coalesce(t.facility_id, t.requested_facility_id)
                       and f.branch_id = me.branch_id))
        or
        -- FINMAREP approver (IT) → FINMAREP accounts (o pending na humiling ng branch), lahat ng branch
        --   (hindi kasama ang kapwa approver)
        (me.role = 'finmarep' and me.is_finmarep_approver
         and not t.is_finmarep_approver
         and (t.role = 'finmarep'
              or (t.role is null and t.requested_branch_id is not null)))
      )
  );
$$;

revoke execute on function public.can_manage_profile(uuid) from public, anon;
grant  execute on function public.can_manage_profile(uuid) to authenticated;

create function public.app_user_is_finmarep_approver()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce((select p.is_finmarep_approver from public.profiles p
                   where p.id = auth.uid() and p.status = 'active'
                     and p.role = 'finmarep'), false);
$$;

revoke execute on function public.app_user_is_finmarep_approver() from public, anon;
grant  execute on function public.app_user_is_finmarep_approver() to authenticated;

-- ---------------------------------------------------------------------------
-- RLS policies
-- ---------------------------------------------------------------------------
-- Sariling profile (para makita ng UI ang role/status), at mga account na hawak niya.
-- Inline na bersyon ng can_manage_profile para hindi tumawag ng function bawat row;
-- panatilihing magkatugma ang dalawa.
create policy profiles_select on public.profiles
  for select to authenticated
  using (
    id = (select auth.uid())
    or ((select public.app_user_role()) = 'facility_admin'
        and coalesce(facility_id, requested_facility_id) = (select public.app_user_facility_id())
        and (role = 'facility' or role is null))
    or ((select public.app_user_role()) = 'branch_admin'
        and ((coalesce(branch_id, requested_branch_id) = (select public.app_user_branch_id())
              and not is_finmarep_approver
              and (role in ('finmarep', 'bas_processor') or role is null))
             or ((role = 'facility_admin' or role is null)
                 and coalesce(facility_id, requested_facility_id) in (
                   select f.id from public.facilities f
                   where f.branch_id = (select public.app_user_branch_id())))))
    or ((select public.app_user_is_finmarep_approver())
        and id <> (select auth.uid())
        and not is_finmarep_approver
        and (role = 'finmarep' or (role is null and requested_branch_id is not null)))
  );

-- Sariling branch assignments (active lang); FINMAREP nakikita lahat; admin nakikita ng mga
-- hawak niya at ng mga assignment sa branch niya (para ma-unassign)
create policy user_branches_select on public.user_branches
  for select to authenticated
  using ((user_id = (select auth.uid()) and (select public.app_user_role()) is not null)
         or (select public.app_user_role()) = 'finmarep'
         or ((select public.app_user_role()) = 'branch_admin'
             and branch_id = (select public.app_user_branch_id()))
         or public.can_manage_profile(user_id));

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
-- I-approve ang pending na account at itakda ang role.
--   facility_admin → 'facility' lang
--   branch_admin   → 'bas_processor' (humiling ng branch),
--                    'facility_admin' (humiling ng facility)
--   finmarep approver (IT) → 'finmarep' (humiling ng branch)
create function public.approve_account(p_user uuid, p_role public.app_role)
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

  if v_my_role = 'facility_admin'
     and p_role = 'facility' and t.requested_facility_id is not null then
    update public.profiles
       set status = 'active', role = p_role,
           facility_id = t.requested_facility_id, requested_facility_id = null
     where id = p_user;
  elsif v_my_role = 'branch_admin'
     and p_role = 'facility_admin' and t.requested_facility_id is not null then
    -- Ang unique index ang magbabawal kung may active na Facility Admin na
    update public.profiles
       set status = 'active', role = p_role,
           facility_id = t.requested_facility_id, requested_facility_id = null
     where id = p_user;
  elsif t.requested_branch_id is not null
     and ((v_my_role = 'branch_admin' and p_role = 'bas_processor')
          or (p_role = 'finmarep' and public.app_user_is_finmarep_approver())) then
    update public.profiles
       set status = 'active', role = p_role,
           branch_id = t.requested_branch_id, requested_branch_id = null
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

-- I-reject ang pending na account
create function public.reject_account(p_user uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not public.can_manage_profile(p_user) then
    raise exception 'Hindi mo hawak ang account na ito' using errcode = '42501';
  end if;
  update public.profiles set status = 'rejected'
   where id = p_user and status = 'pending';
  if not found then
    raise exception 'Hindi pending ang account';
  end if;
end;
$$;

-- I-disable o i-enable ulit ang active/disabled na account (walang binubura)
create function public.set_account_active(p_user uuid, p_active boolean)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not public.can_manage_profile(p_user) then
    raise exception 'Hindi mo hawak ang account na ito' using errcode = '42501';
  end if;
  -- Pwedeng i-disable ng Branch Admin ang FINMAREP, pero FINMAREP approver lang
  -- ang makakapag-enable ulit (lahat ng branch ang nakikita ng FINMAREP).
  if p_active and not public.app_user_is_finmarep_approver()
     and exists (select 1 from public.profiles where id = p_user and role = 'finmarep') then
    raise exception 'FINMAREP approver lang ang makakapag-enable ng FINMAREP' using errcode = '42501';
  end if;
  update public.profiles
     set status = case when p_active then 'active' else 'disabled' end
   where id = p_user and status in ('active', 'disabled');
  if not found then
    raise exception 'Pending o rejected ang account; gamitin ang approve/reject';
  end if;
end;
$$;

-- Mag-assign ng branch sa FINMAREP / BAS Processor. Sariling branch lang ng Branch Admin
-- ang pwedeng i-assign (kahit taga-ibang home branch ang user).
create function public.assign_user_branch(p_user uuid, p_branch uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if public.app_user_role() is distinct from 'branch_admin'
     or p_branch is distinct from public.app_user_branch_id()
     or not exists (select 1 from public.profiles
                    where id = p_user and status = 'active'
                      and role in ('finmarep', 'bas_processor')) then
    raise exception 'Hindi pwedeng mag-assign ng branch sa account na ito' using errcode = '42501';
  end if;
  insert into public.user_branches (user_id, branch_id)
  values (p_user, p_branch)
  on conflict do nothing;
end;
$$;

-- Alisin ang branch assignment: Branch Admin ng branch na iyon, o home-branch admin ng user.
create function public.unassign_user_branch(p_user uuid, p_branch uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if public.app_user_role() is distinct from 'branch_admin'
     or not (p_branch = public.app_user_branch_id() or public.can_manage_profile(p_user)) then
    raise exception 'Hindi pwedeng alisin ang branch na ito' using errcode = '42501';
  end if;
  delete from public.user_branches
   where user_id = p_user and branch_id = p_branch;
end;
$$;

revoke execute on function public.approve_account(uuid, public.app_role) from public, anon;
revoke execute on function public.reject_account(uuid)                   from public, anon;
revoke execute on function public.set_account_active(uuid, boolean)      from public, anon;
revoke execute on function public.assign_user_branch(uuid, uuid)         from public, anon;
revoke execute on function public.unassign_user_branch(uuid, uuid)       from public, anon;
grant  execute on function public.unassign_user_branch(uuid, uuid)       to authenticated;
grant  execute on function public.approve_account(uuid, public.app_role) to authenticated;
grant  execute on function public.reject_account(uuid)                   to authenticated;
grant  execute on function public.set_account_active(uuid, boolean)      to authenticated;
grant  execute on function public.assign_user_branch(uuid, uuid)         to authenticated;
