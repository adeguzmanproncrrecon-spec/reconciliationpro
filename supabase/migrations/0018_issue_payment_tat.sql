-- 0018_issue_payment_tat.sql
-- Internal Data Only (RECON_SPEC §3c-quater, mga sagot ng user 2026-10-06):
-- - Issue (#23b): OPEN kapag ang pinakabagong tag ay mas bago kaysa sa pinakabagong untag (o walang untag);
--   RESOLVED kapag may untag na kasabay o mas bago; blangko kapag walang tag.
-- - Payment TAT (#15): (petsa ng bayad − simula) − araw na may issue.
--   Simula = LATEST REFILING DATE kung na-refile, kung hindi ay FILING DATE (DATE_REC).
--   Petsa ng bayad = CHECK_DT ng pinakabagong payment; kung wala, DATE_EXT (bank advise). PAID lang (as of matching date).
--   Araw na may issue = mga araw na naka-tag ang claim (bawat tag → unang untag na kasabay o mas bago; kung wala → petsa ng bayad),
--   pinagsama ang nagsasapaw, at sa loob lang ng [simula, petsa ng bayad). Ipinapakita rin bilang "Days on Issue".
-- Pinapalitan (create or replace) ang do_matching_yugto2 mula 0017: kinukuwenta na ang Payment TAT kahit walang Yugto 2 upload.
-- Walang DROP / DELETE / TRUNCATE.

alter table public.recon_hf_internal
  add column issue         text,
  add column days_on_issue int,
  add column payment_tat   int;

create or replace function public.do_matching_yugto2(p_match uuid)
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

  create temp table _y2s on commit drop as
    select distinct claim_series as series from public.recon_hf_results
     where match_id = p_match and claim_series is not null;
  create index on _y2s (series);
  analyze _y2s;

  if exists (select 1 from _y2up) then
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
  end if;

  -- ---- Tagging / Untagging: lahat ng row (para sa Issue at araw na may issue) ----
  create temp table _y2tag on commit drop as
    select x.series, x.date_tagged as d, x.process, u.created_at as up_at, x.row_no
      from public.issue_tags x
      join _y2up u on u.id = x.upload_id
      join _y2s s on s.series = x.series
     where x.date_tagged is not null;
  create index on _y2tag (series, d);
  analyze _y2tag;

  create temp table _y2untag on commit drop as
    select x.series, x.date_untagged as d, x.process, u.created_at as up_at, x.row_no
      from public.issue_untags x
      join _y2up u on u.id = x.upload_id
      join _y2s s on s.series = x.series
     where x.date_untagged is not null;
  create index on _y2untag (series, d);
  analyze _y2untag;

  insert into public.recon_hf_internal (match_id, facility_id, item_no, tag_date, tag_status, untag_date, untag_status,
                                        issue, days_on_issue, payment_tat)
  select p_match, h.facility_id, h.item_no, tg.d, tg.process, ut.d, ut.process,
         case when tg.series is null then null
              when ut.series is not null and ut.d >= tg.d then 'RESOLVED'
              else 'OPEN' end,
         case when w.ok then coalesce(iss.days, 0) end,
         case when w.ok then (w.pay_d - w.start_d) - coalesce(iss.days, 0) end
    from public.recon_hf_results h
    left join (select distinct on (t.series) t.series, t.d, t.process
                 from _y2tag t order by t.series, t.d desc, t.up_at desc, t.row_no desc) tg
           on tg.series = h.claim_series
    left join (select distinct on (t.series) t.series, t.d, t.process
                 from _y2untag t order by t.series, t.d desc, t.up_at desc, t.row_no desc) ut
           on ut.series = h.claim_series
    -- Simula at petsa ng bayad (PAID as of matching date lang)
    cross join lateral (
      select coalesce(h.last_refiled, h.date_filed) as start_d,
             case when h.payment_status = 'PAID' then coalesce(h.check_dt, h.bank_advise_date) end as pay_d
    ) w0
    cross join lateral (
      select w0.start_d, w0.pay_d, (w0.start_d is not null and w0.pay_d is not null and w0.start_d <= w0.pay_d) as ok
    ) w
    -- Araw na may issue: bawat tag → unang untag (≥ tag) o petsa ng bayad; pinagsama; sa loob ng [simula, bayad)
    left join lateral (
      select sum(upper(rg) - lower(rg))::int as days
        from unnest(
          (select range_agg(daterange(t.d,
                    least(coalesce((select min(u2.d) from _y2untag u2 where u2.series = t.series and u2.d >= t.d), w.pay_d), w.pay_d),
                    '[)'))
             from _y2tag t
            where t.series = h.claim_series and t.d < w.pay_d)
          * datemultirange(case when w.ok then daterange(w.start_d, w.pay_d, '[)') end)) rg
    ) iss on w.ok
   where h.match_id = p_match
     and (tg.series is not null or ut.series is not null or w.ok);
end;
$$;

revoke execute on function public.do_matching_yugto2(uuid) from public, anon, authenticated;
