-- 0017_yugto2_matching.sql
-- Yugto 2 sa Matching Report (RECON_SPEC §3c-quater) at Claim History.
-- - Bagong nullable columns sa recon_hf_results (nakikita ng facility, ayon sa §4a): First/Second Case Rate,
--   Health Care Professional, History Effect, MR, PARD.
-- - "Internal Data Only" (Tagging/Untagging) → hiwalay na table recon_hf_internal (PhilHealth lang), dahil nakikita
--   ng facility ang recon_hf_results.
-- - do_matching_yugto2(): tinatawag ng process_matching_queue() pagkatapos ng do_matching(), sa parehong subtransaction
--   (kapag pumalya, na-rollback lahat). Hindi binabago ang do_matching. Optional ang Yugto 2: walang upload → walang ginagawa.
-- - claim_history(): buong kasaysayan ng isang claim series sa isang run (PhilHealth lang; security invoker → RLS).
-- Walang DROP / DELETE / TRUNCATE.

-- ---------------------------------------------------------------------------
-- Columns (nullable; ang lumang resulta ay NULL)
-- ---------------------------------------------------------------------------
alter table public.recon_hf_results
  add column first_case_rate     text,
  add column second_case_rate    text,
  add column health_professional text,
  add column history_effect      text,
  add column mr_rcv_date         date,
  add column mr_status           text,
  add column mr_decision_date    date,
  add column pard_rcv_date       date,
  add column pard_status         text;

create table public.recon_hf_internal (
  match_id     uuid not null,
  facility_id  uuid not null,
  item_no      int  not null,
  tag_date     date,
  tag_status   text,
  untag_date   date,
  untag_status text,
  primary key (match_id, item_no),
  foreign key (match_id, facility_id) references public.recon_matches (id, facility_id)
);

alter table public.recon_hf_internal enable row level security;
revoke all on public.recon_hf_internal from anon;
revoke insert, update, delete, truncate on public.recon_hf_internal from authenticated;
create policy recon_hf_internal_select on public.recon_hf_internal for select to authenticated
  using ((select public.app_user_is_philhealth()) and facility_id in (select f.id from public.facilities f));

-- ---------------------------------------------------------------------------
-- Yugto 2 matching ("latest lang", §3c-quater)
-- ---------------------------------------------------------------------------
create function public.do_matching_yugto2(p_match uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  m public.recon_matches;
begin
  select * into m from public.recon_matches where id = p_match;

  create temp table _y2up on commit drop as
    select id, kind, created_at from public.run_uploads
     where run_id = m.run_id and status = 'complete'
       and kind in ('rth_reasons', 'mr', 'pard', 'pf_name', 'tagging', 'untagging', 'icd_codes');
  if not exists (select 1 from _y2up) then
    return;
  end if;

  create temp table _y2s on commit drop as
    select distinct claim_series as series from public.recon_hf_results
     where match_id = p_match and claim_series is not null;
  create index on _y2s (series);
  analyze _y2s;

  -- #24 ICD: natatanging ICD/RVS bawat series; First = mas mataas na TOTAL_ACR_AMOUNT, Second = kasunod
  create temp table _y2icd on commit drop as
    select series,
           max(cr) filter (where rn = 1) as first_cr,
           max(cr) filter (where rn = 2) as second_cr
    from (
      select d.series, d.cr,
             row_number() over (partition by d.series order by d.amt desc nulls last, d.up_at desc, d.row_no desc) as rn
      from (
        select distinct on (i.series, i.icd_code, i.rvs_code)
               i.series, concat_ws(' / ', i.icd_code, i.rvs_code) as cr, i.total_acr_amount as amt,
               u.created_at as up_at, i.row_no
          from public.icd_codes i
          join _y2up u on u.id = i.upload_id
          join _y2s s on s.series = i.series
         where i.icd_code is not null or i.rvs_code is not null
         order by i.series, i.icd_code, i.rvs_code, i.total_acr_amount desc nulls last, u.created_at desc, i.row_no desc
      ) d
    ) q
    group by series;

  -- #22 PF Name: lahat ng doktor, pinagsama, walang ulit
  create temp table _y2pf on commit drop as
    select p.series, string_agg(distinct p.doctors_name, '; ' order by p.doctors_name) as names
      from public.pf_names p
      join _y2up u on u.id = p.upload_id
      join _y2s s on s.series = p.series
     where p.doctors_name is not null and p.doctors_name <> ''
     group by p.series;

  -- #19 History Effect: EFFECT ng pinakabagong reason (huling row sa pinakabagong upload)
  create temp table _y2rth on commit drop as
    select distinct on (x.series) x.series, x.effect
      from public.rth_reasons x
      join _y2up u on u.id = x.upload_id
      join _y2s s on s.series = x.series
     where x.effect is not null and x.effect <> ''
     order by x.series, u.created_at desc, x.row_no desc;

  -- #20 MR: pinakabagong ayon sa mrRcvDate; MR Status = finalRecom; Decision Release Date = dateFinalized
  create temp table _y2mr on commit drop as
    select distinct on (x.series) x.series, x.mr_rcv_date, x.final_recom, x.date_finalized
      from public.mr_records x
      join _y2up u on u.id = x.upload_id
      join _y2s s on s.series = x.series
     order by x.series, x.mr_rcv_date desc nulls last, u.created_at desc, x.row_no desc;

  -- #21 PARD: pinakabagong ENTRY_DATE at ang APPROVAL_SOURCE nito
  create temp table _y2pard on commit drop as
    select distinct on (x.series) x.series, x.entry_date, x.approval_source
      from public.pard_records x
      join _y2up u on u.id = x.upload_id
      join _y2s s on s.series = x.series
     order by x.series, x.entry_date desc nulls last, u.created_at desc, x.row_no desc;

  update public.recon_hf_results h
     set first_case_rate     = icd.first_cr,
         second_case_rate    = icd.second_cr,
         health_professional = pf.names,
         history_effect      = rth.effect,
         mr_rcv_date         = mr.mr_rcv_date,
         mr_status           = mr.final_recom,
         mr_decision_date    = mr.date_finalized,
         pard_rcv_date       = pard.entry_date,
         pard_status         = pard.approval_source
    from _y2s s
    left join _y2icd  icd  on icd.series  = s.series
    left join _y2pf   pf   on pf.series   = s.series
    left join _y2rth  rth  on rth.series  = s.series
    left join _y2mr   mr   on mr.series   = s.series
    left join _y2pard pard on pard.series = s.series
   where h.match_id = p_match and h.claim_series = s.series
     and (icd.series is not null or pf.series is not null or rth.series is not null
          or mr.series is not null or pard.series is not null);

  -- #23 Tagging/Untagging (Internal Data Only): pinakabagong DATE_TAGGED / DATE_UNTAGGED at PROCESS nito
  insert into public.recon_hf_internal (match_id, facility_id, item_no, tag_date, tag_status, untag_date, untag_status)
  select p_match, h.facility_id, h.item_no, tg.date_tagged, tg.process, ut.date_untagged, ut.process
    from public.recon_hf_results h
    left join (select distinct on (x.series) x.series, x.date_tagged, x.process
                 from public.issue_tags x
                 join _y2up u on u.id = x.upload_id
                 join _y2s s on s.series = x.series
                order by x.series, x.date_tagged desc nulls last, u.created_at desc, x.row_no desc) tg
           on tg.series = h.claim_series
    left join (select distinct on (x.series) x.series, x.date_untagged, x.process
                 from public.issue_untags x
                 join _y2up u on u.id = x.upload_id
                 join _y2s s on s.series = x.series
                order by x.series, x.date_untagged desc nulls last, u.created_at desc, x.row_no desc) ut
           on ut.series = h.claim_series
   where h.match_id = p_match
     and (tg.series is not null or ut.series is not null);
end;
$$;

-- Pareho ng 0014, dagdag ang do_matching_yugto2 sa parehong subtransaction
create or replace function public.process_matching_queue()
returns int
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.recon_matches
   where status = 'queued'
   order by requested_at
   limit 1
   for update skip locked;
  if v_id is null then
    return 0;
  end if;

  update public.recon_matches set status = 'running', started_at = clock_timestamp() where id = v_id;
  begin
    perform public.do_matching(v_id);
    perform public.do_matching_yugto2(v_id);
    update public.recon_matches set finished_at = clock_timestamp() where id = v_id;
  exception when others or query_canceled then
    -- Na-rollback ang lahat ng ginawa ng do_matching / do_matching_yugto2 (subtransaction); itala lang ang error
    update public.recon_matches set status = 'failed', error = left(sqlerrm, 500), finished_at = clock_timestamp() where id = v_id;
  end;
  return 1;
end;
$$;

-- ---------------------------------------------------------------------------
-- Claim History (§3c-quater): lahat ng row ng isang claim series sa complete uploads ng isang run.
-- Security invoker: RLS ng run_uploads at ng raw tables ang naglilimita (PhilHealth + saklaw na facility).
-- ---------------------------------------------------------------------------
create function public.claim_history(p_run uuid, p_series text, p_limit int default 200, p_offset int default 0)
returns table (source text, event_date date, sort_key bigint, title text, details jsonb, file_name text)
language plpgsql stable security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_series text := public.normalize_claim_series(p_series);
begin
  if not public.app_user_is_philhealth() then
    raise exception 'Claim History is for PhilHealth only' using errcode = '42501';
  end if;
  if v_series is null then
    raise exception 'Invalid Claim Series' using errcode = '22023';
  end if;

  return query
  with up as (
    select u.id, u.file_name from public.run_uploads u where u.run_id = p_run and u.status = 'complete'
  ),
  ev as (
    select 'Raw Matching'::text as source, x.date_rec as event_date, x.row_no::bigint as sort_key,
           ('STATUS ' || coalesce(x.status, '-'))::text as title,
           jsonb_build_object('date_rec', x.date_rec, 'date_recon', x.date_recon, 'last_refiled', x.last_refiled,
                              'status', x.status, 'total_acr_amount', x.total_acr_amount,
                              'latest_check_dt', x.latest_check_dt, 'latest_ctrl_no', x.latest_ctrl_no,
                              'latest_ctrl_dt', x.latest_ctrl_dt) as details,
           up.file_name
      from public.raw_claims x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'Status Trail', x.date_tagged, coalesce(x.time_rec, 0)::bigint, x.process,
           jsonb_build_object('date_tagged', x.date_tagged, 'time_rec', x.time_rec, 'process', x.process), up.file_name
      from public.status_trail x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'Payment', coalesce(x.check_dt, x.date_ext, x.receipt_dt), x.row_no::bigint,
           ('Tranche ' || coalesce(x.tranche_number, '-')),
           jsonb_build_object('date_ext', x.date_ext, 'check_no', x.check_no, 'check_dt', x.check_dt, 'pr_no', x.pr_no,
                              'receipt_no', x.receipt_no, 'receipt_dt', x.receipt_dt, 'total_tot_amnt', x.total_tot_amnt,
                              'tranche_number', x.tranche_number), up.file_name
      from public.payment_details x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'HO ICS', x.recref, x.row_no::bigint, 'HO ICS',
           jsonb_build_object('recref', x.recref, 'estimated_amt', x.estimated_amt), up.file_name
      from public.ho_ics_rows x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'RTH/Denial Reason', null::date, x.row_no::bigint, coalesce(x.def_code, '-'),
           jsonb_build_object('def_code', x.def_code, 'reason', x.reason, 'effect', x.effect, 'icd_code', x.icd_code,
                              'health_professional', x.health_professional), up.file_name
      from public.rth_reasons x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'MR', x.mr_rcv_date, x.row_no::bigint, coalesce(x.final_recom, '-'),
           jsonb_build_object('mr_rcv_date', x.mr_rcv_date, 'approval', x.approval, 'final_recom', x.final_recom,
                              'final_basis', x.final_basis, 'date_finalized', x.date_finalized), up.file_name
      from public.mr_records x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'PARD', x.entry_date, x.row_no::bigint, coalesce(x.approval_source, '-'),
           jsonb_build_object('entry_date', x.entry_date, 'approval_source', x.approval_source), up.file_name
      from public.pard_records x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'Tagging', x.date_tagged, x.row_no::bigint, coalesce(x.process, '-'),
           jsonb_build_object('date_tagged', x.date_tagged, 'process', x.process), up.file_name
      from public.issue_tags x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'Untagging', x.date_untagged, x.row_no::bigint, coalesce(x.process, '-'),
           jsonb_build_object('date_untagged', x.date_untagged, 'process', x.process), up.file_name
      from public.issue_untags x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'PF Name', null::date, x.row_no::bigint, coalesce(x.doctors_name, '-'),
           jsonb_build_object('doctors_name', x.doctors_name), up.file_name
      from public.pf_names x join up on up.id = x.upload_id where x.series = v_series
    union all
    select 'ICD Code', null::date, x.row_no::bigint, concat_ws(' / ', x.icd_code, x.rvs_code),
           jsonb_build_object('icd_code', x.icd_code, 'rvs_code', x.rvs_code, 'total_acr_amount', x.total_acr_amount),
           up.file_name
      from public.icd_codes x join up on up.id = x.upload_id where x.series = v_series
  )
  select ev.source, ev.event_date, ev.sort_key, ev.title, ev.details, ev.file_name
    from ev
   order by ev.event_date desc nulls last, ev.source, ev.sort_key desc
   limit least(greatest(coalesce(p_limit, 200), 1), 500)
  offset least(greatest(coalesce(p_offset, 0), 0), 100000);
end;
$$;

revoke execute on function public.do_matching_yugto2(uuid) from public, anon, authenticated;
revoke execute on function public.process_matching_queue() from public, anon, authenticated;
revoke execute on function public.claim_history(uuid, text, int, int) from public, anon;
grant  execute on function public.claim_history(uuid, text, int, int) to authenticated;
