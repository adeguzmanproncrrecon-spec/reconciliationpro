-- 0026_match_summary_fast.sql
-- Summary tab ng 50k claims: 6+ segundo ang match_summary bilang user (per-row RLS) → nagti-timeout (8s) sa unang bukas.
-- Ayos: security definer na may sariling access check (pareho ng annex_a):
--   - kailangang may access ang user sa facility ng matching (can_view_facility);
--   - ang 'ho_item' (HO ICS reconciling items) ay PhilHealth lang (dati: RLS ng recon_ho_results).
-- Pareho ang ibinabalik na columns at rows. Walang DROP / DELETE / TRUNCATE.

create or replace function public.match_summary(p_match uuid)
returns table (kind text, label text, claims bigint, amount numeric, amount2 numeric)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_fac uuid;
  v_ph  boolean := coalesce(public.app_user_is_philhealth(), false);
begin
  select m.facility_id into v_fac from public.recon_matches m where m.id = p_match;
  if v_fac is null or not public.can_view_facility(v_fac) then
    raise exception 'Match not found' using errcode = '42501';
  end if;

  return query
  select 'status_rd'::text, h.status_rd, count(*), sum(h.amount_used_rd), null::numeric
    from public.recon_hf_results h where h.match_id = p_match group by h.status_rd
  union all
  select 'status_pd', h.status_pd, count(*), sum(h.amount_used_pd), null
    from public.recon_hf_results h where h.match_id = p_match and h.status_pd is not null group by h.status_pd
  union all
  select 'status_md', h.status_md, count(*), sum(h.amount_used_md), null
    from public.recon_hf_results h where h.match_id = p_match group by h.status_md
  union all
  select 'hf_item', h.reconciling_item, count(*), sum(h.recon_amount), sum(h.ics_amount)
    from public.recon_hf_results h where h.match_id = p_match group by h.reconciling_item
  union all
  select 'ho_item', o.reconciling_item, count(*), sum(o.estimated_amt), null
    from public.recon_ho_results o where v_ph and o.match_id = p_match group by o.reconciling_item;
end;
$$;

revoke execute on function public.match_summary(uuid) from public, anon;
grant  execute on function public.match_summary(uuid) to authenticated;
