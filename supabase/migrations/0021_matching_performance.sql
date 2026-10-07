-- 0021_matching_performance.sql
-- Pumalya ang matching ng 200k claims (2026-10-06): "canceling statement due to statement timeout".
-- Dahilan: (1) 2 minuto ang default na statement_timeout ng server, sakop pati ang pg_cron job;
-- (2) luma ang statistics ng recon_hf_results / recon_ho_results sa loob ng transaction ng matching (bagong 200k rows),
--     kaya mabagal na join plan ang pinipili sa do_matching_yugto2 / do_matching_annex.
-- Ayos:
-- - ANALYZE ng dalawang results table pagkatapos ng do_matching (nakikita ng ANALYZE ang sariling rows ng transaction).
-- - Index para sa HO row bawat series.
-- - 30 minutong statement_timeout para sa matching job lang (hindi apektado ang authenticated = 8s at anon = 3s).
-- Walang DROP / DELETE / TRUNCATE.

create index if not exists recon_ho_results_series_idx on public.recon_ho_results (match_id, series);

-- Pareho ng 0020, dagdag ang ANALYZE pagkatapos ng do_matching
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
    -- Bagong statistics (kasama ang mga bagong row ng transaction na ito) bago ang mga sumusunod na hakbang
    analyze public.recon_hf_results;
    analyze public.recon_ho_results;
    perform public.do_matching_yugto2(v_id);
    perform public.do_matching_annex(v_id);
    update public.recon_matches set finished_at = clock_timestamp() where id = v_id;
  exception when others or query_canceled then
    update public.recon_matches set status = 'failed', error = left(sqlerrm, 500), finished_at = clock_timestamp() where id = v_id;
  end;
  return 1;
end;
$$;

revoke execute on function public.process_matching_queue() from public, anon, authenticated;

-- Matching job: 30 minutong limit (sa halip na 2 minuto ng server)
select cron.alter_job(
  job_id  := (select jobid from cron.job where jobname = 'process-matching-queue'),
  command := 'set statement_timeout = ''30min''; select public.process_matching_queue()'
);
