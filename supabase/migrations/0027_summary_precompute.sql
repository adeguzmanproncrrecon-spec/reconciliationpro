-- 0027_summary_precompute.sql
-- Summary tab ng 50k claims: 0.2s kapag nasa memory, pero ~6s sa unang bukas (binabasa sa disk; mabagal ang disk ng Free plan)
-- → timeout (8s); sa 200k ay ~20s. Ayos (gaya ng 0025 para sa Annex A): kinukuwenta at sine-save ang summary SA MATCHING JOB.
-- - match_summary_compute: ang mga row ng summary bilang jsonb (kasama ang ho_item) — walang access check; hindi matatawag ng client.
-- - recon_summary_cache: RLS na walang policy; binabasa lang ng match_summary (security definer).
-- - match_summary: pareho ang access checks ng 0026 (can_view_facility; ho_item ay PhilHealth lang); kung walang naka-save,
--   kinukuwenta on the fly.
-- PAALALA: kapag binago ang summary logic o ang resulta ng natapos na matching, i-refresh din ang recon_summary_cache.
-- Walang DROP / DELETE / TRUNCATE.

set local statement_timeout = '30min';

create table public.recon_summary_cache (
  match_id    uuid primary key,
  facility_id uuid not null,
  data        jsonb not null,
  created_at  timestamptz not null default now(),
  foreign key (match_id, facility_id) references public.recon_matches (id, facility_id)
);
alter table public.recon_summary_cache enable row level security;
revoke all on public.recon_summary_cache from anon, authenticated;

create function public.match_summary_compute(p_match uuid)
returns jsonb
language sql stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'label', x.label, 'claims', x.claims,
                                               'amount', x.amount, 'amount2', x.amount2)), '[]'::jsonb)
  from (
    select 'status_rd'::text as kind, h.status_rd as label, count(*) as claims, sum(h.amount_used_rd) as amount, null::numeric as amount2
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
      from public.recon_ho_results o where o.match_id = p_match group by o.reconciling_item
  ) x;
$$;

create or replace function public.match_summary(p_match uuid)
returns table (kind text, label text, claims bigint, amount numeric, amount2 numeric)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_fac  uuid;
  v_ph   boolean := coalesce(public.app_user_is_philhealth(), false);
  v_data jsonb;
begin
  select m.facility_id into v_fac from public.recon_matches m where m.id = p_match;
  if v_fac is null or not public.can_view_facility(v_fac) then
    raise exception 'Match not found' using errcode = '42501';
  end if;
  select c.data into v_data from public.recon_summary_cache c where c.match_id = p_match;
  if v_data is null then
    v_data := public.match_summary_compute(p_match);
  end if;
  return query
  select r.kind, r.label, r.claims, r.amount, r.amount2
    from jsonb_to_recordset(v_data) as r(kind text, label text, claims bigint, amount numeric, amount2 numeric)
   where r.kind <> 'ho_item' or v_ph;
end;
$$;

-- Pareho ng 0025, dagdag ang naka-save na summary (sa parehong protektadong bloke ng Annex A)
create or replace function public.process_matching_queue()
returns int
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.recon_matches
   where status = 'running' and finished_at is null and started_at > clock_timestamp() - interval '5 minutes'
   order by started_at
   limit 1
   for update skip locked;
  if v_id is null then
    return 0;
  end if;

  begin
    perform public.do_matching(v_id);
    analyze public.recon_hf_results;
    perform public.do_matching_yugto2(v_id);
    -- Naka-save na Annex A at Summary; kapag pumalya, hindi pinapalya ang matching (kukuwentahin na lang kapag binuksan)
    begin
      insert into public.recon_annex (match_id, facility_id, version, data)
      select m.id, m.facility_id, 'internal', public.annex_a_compute(m.id, true) from public.recon_matches m where m.id = v_id
      union all
      select m.id, m.facility_id, 'facility', public.annex_a_compute(m.id, false) from public.recon_matches m where m.id = v_id;
    exception when others then
      raise warning 'Annex A precompute failed for match %: %', v_id, sqlerrm;
    end;
    begin
      insert into public.recon_summary_cache (match_id, facility_id, data)
      select m.id, m.facility_id, public.match_summary_compute(m.id) from public.recon_matches m where m.id = v_id;
    exception when others then
      raise warning 'Summary precompute failed for match %: %', v_id, sqlerrm;
    end;
    update public.recon_matches set finished_at = clock_timestamp() where id = v_id;
  exception when others or query_canceled then
    update public.recon_matches set status = 'failed', error = left(sqlerrm, 500), finished_at = clock_timestamp() where id = v_id;
  end;
  return 1;
end;
$$;

revoke execute on function public.match_summary_compute(uuid) from public, anon, authenticated;
revoke execute on function public.match_summary(uuid)         from public, anon;
grant  execute on function public.match_summary(uuid)         to authenticated;
revoke execute on function public.process_matching_queue()    from public, anon, authenticated;

-- Naka-save na summary ng mga current na matching
insert into public.recon_summary_cache (match_id, facility_id, data)
select m.id, m.facility_id, public.match_summary_compute(m.id)
  from public.recon_matches m where m.status = 'done' and m.is_current;
