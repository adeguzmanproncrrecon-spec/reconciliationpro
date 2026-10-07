-- 0006_account_admin_list.sql
-- Listahan ng mga account na hawak ng tumatawag na admin (para sa a_accounts.html / f_accounts.html).
-- Walang bagong karapatan: ang can_manage_profile pa rin ang huling nagpapasya kung aling row ang lalabas.
-- Kasama ang email (mula sa auth.users) para makilala ng approver ang nagrehistro.

create function public.list_manageable_accounts(
  p_status text,
  p_search text default null,
  p_limit  int  default 25,
  p_offset int  default 0
)
returns table (
  id                      uuid,
  email                   text,
  full_name               text,
  status                  text,
  role                    public.app_role,
  facility_name           text,
  branch_id               uuid,
  branch_name             text,
  requested_facility_id   uuid,
  requested_facility_name text,
  requested_branch_id     uuid,
  requested_branch_name   text,
  handled_branches        jsonb,
  created_at              timestamptz,
  total_count             bigint
)
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role  public.app_role := public.app_user_role();
  v_fac   uuid := public.app_user_facility_id();
  v_br    uuid := public.app_user_branch_id();
  v_appr  boolean := public.app_user_is_finmarep_approver();
  v_q     text := left(nullif(trim(p_search), ''), 100);
begin
  -- Literal na paghahanap: i-escape ang wildcards ng ilike
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');
  if p_status not in ('pending', 'active', 'disabled', 'rejected') then
    raise exception 'Invalid status';
  end if;
  if v_role is null or not (v_role in ('facility_admin', 'branch_admin') or v_appr) then
    return;   -- hindi admin → walang ibinabalik
  end if;

  return query
  select p.id, u.email::text, p.full_name, p.status, p.role,
         f.name, p.branch_id, b.name,
         p.requested_facility_id, rf.name,
         p.requested_branch_id, rb.name,
         coalesce((select jsonb_agg(jsonb_build_object('id', hb.id, 'code', hb.code, 'name', hb.name)
                                    order by hb.name)
                   from public.user_branches ub
                   join public.branches hb on hb.id = ub.branch_id
                   where ub.user_id = p.id), '[]'::jsonb),
         p.created_at,
         count(*) over ()
  from public.profiles p
  join auth.users u on u.id = p.id
  left join public.facilities f  on f.id  = p.facility_id
  left join public.branches   b  on b.id  = p.branch_id
  left join public.facilities rf on rf.id = p.requested_facility_id
  left join public.branches   rb on rb.id = p.requested_branch_id
  where p.status = p_status
    -- Mabilis na paunang filter ayon sa saklaw ng admin (tugma sa can_manage_profile)
    and (
      (v_role = 'facility_admin'
       and coalesce(p.facility_id, p.requested_facility_id) = v_fac)
      or (v_role = 'branch_admin'
          and (coalesce(p.branch_id, p.requested_branch_id) = v_br
               or coalesce(p.facility_id, p.requested_facility_id) in (
                    select fx.id from public.facilities fx where fx.branch_id = v_br)))
      or (v_appr and (p.role = 'finmarep' or (p.role is null and p.requested_branch_id is not null)))
    )
    -- Ang awtoritatibong check
    and public.can_manage_profile(p.id)
    and (v_q is null
         or p.full_name ilike '%' || v_q || '%'
         or u.email     ilike '%' || v_q || '%')
  order by p.created_at desc, p.id
  limit least(greatest(coalesce(p_limit, 25), 1), 100)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke execute on function public.list_manageable_accounts(text, text, int, int) from public, anon;
grant  execute on function public.list_manageable_accounts(text, text, int, int) to authenticated;
