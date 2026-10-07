-- 0012_match_summary.sql
-- Buod ng isang matching result para sa Reconciliation page (bilang + halaga), kinukuwenta sa SQL.
-- SECURITY INVOKER: sinusunod ang RLS ng recon_hf_results / recon_ho_results
-- (kaya walang HO rows na lalabas sa facility user).
--   kind = 'status_rd' | 'status_pd' | 'status_md'  → bawat status; amount = amount used for recon ng cutoff na iyon
--   kind = 'hf_item'                                  → bawat HF reconciling item; amount = recon amount, amount2 = ICS amount
--   kind = 'ho_item'                                  → bawat HO reconciling item; amount = estimated amount
create function public.match_summary(p_match uuid)
returns table (kind text, label text, claims bigint, amount numeric, amount2 numeric)
language sql stable security invoker
set search_path = ''
as $$
  select 'status_rd', status_rd, count(*), sum(amount_used_rd), null::numeric
    from public.recon_hf_results where match_id = p_match group by status_rd
  union all
  select 'status_pd', status_pd, count(*), sum(amount_used_pd), null
    from public.recon_hf_results where match_id = p_match and status_pd is not null group by status_pd
  union all
  select 'status_md', status_md, count(*), sum(amount_used_md), null
    from public.recon_hf_results where match_id = p_match group by status_md
  union all
  select 'hf_item', reconciling_item, count(*), sum(recon_amount), sum(ics_amount)
    from public.recon_hf_results where match_id = p_match group by reconciling_item
  union all
  select 'ho_item', reconciling_item, count(*), sum(estimated_amt), null
    from public.recon_ho_results where match_id = p_match group by reconciling_item;
$$;

revoke execute on function public.match_summary(uuid) from public, anon;
grant  execute on function public.match_summary(uuid) to authenticated;
