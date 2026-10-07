-- 0030_loi_upload_policy_fix.sql
-- Ayos sa 0029: ang insert policy ng storage.objects (bucket 'loi') ay may subquery sa storage.objects mismo
-- (limit na 20 upload bawat 24 oras) → "infinite recursion detected in policy" (42P17), na ipinapakita ng Storage bilang
-- "The database schema is invalid or incompatible". Ang pagbilang ay inilipat sa security definer function (walang RLS).
-- ALTER POLICY lang; walang DROP / DELETE / TRUNCATE.

create function public.loi_recent_uploads()
returns int
language sql stable security definer
set search_path = ''
as $$
  select count(*)::int
    from storage.objects o
   where o.bucket_id = 'loi'
     and o.name like public.app_user_facility_id()::text || '/%'
     and o.created_at > now() - interval '24 hours';
$$;
revoke execute on function public.loi_recent_uploads() from public, anon;
grant  execute on function public.loi_recent_uploads() to authenticated;

alter policy loi_files_insert on storage.objects
  with check (
    bucket_id = 'loi'
    and (select public.app_user_role()) = 'facility_admin'
    and name ~ ('^' || (select public.app_user_facility_id())::text
                || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(pdf|jpg|png)$')
    and (select public.loi_recent_uploads()) < 20
  );
