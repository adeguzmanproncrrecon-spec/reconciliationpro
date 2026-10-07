-- 0014_matching_timestamps.sql
-- Ang now() ay oras ng simula ng transaction, kaya pareho ang started_at at finished_at ng matching job.
-- Gamitin ang clock_timestamp() (aktuwal na oras) para sa started_at / finished_at.
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
    update public.recon_matches set finished_at = clock_timestamp() where id = v_id;
  exception when others or query_canceled then
    -- Na-rollback ang lahat ng ginawa ng do_matching (subtransaction); itala lang ang error
    update public.recon_matches set status = 'failed', error = left(sqlerrm, 500), finished_at = clock_timestamp() where id = v_id;
  end;
  return 1;
end;
$$;

revoke execute on function public.process_matching_queue() from public, anon, authenticated;
