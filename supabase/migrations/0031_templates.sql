-- 0031_templates.sql
-- Templates tab (desisyon ng user, 2026-10-07): ina-upload ni FINMAREP ang mismong blankong template (hal. ICS .xlsx)
-- at nada-download ito ng PhilHealth users. May "visible to facilities" flag: kapag naka-on, nakikita at nada-download
-- din ito ng facility users (sa Upload Claims). Walang delete — "retire" (is_active = false) lang.
-- File sa private bucket "templates", path "<uuid>.<xlsx|xls>".
-- Walang DROP / DELETE / TRUNCATE.

create table public.templates (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null check (length(trim(name)) between 1 and 120),
  description         text check (length(description) <= 500),
  file_path           text not null unique check (length(file_path) <= 100),
  file_name           text not null check (length(file_name) <= 255),
  file_size           int  check (file_size between 1 and 10485760),
  visible_to_facility boolean not null default false,
  is_active           boolean not null default true,
  uploaded_by         uuid not null references public.profiles (id),
  uploaded_at         timestamptz not null default now(),
  updated_by          uuid references public.profiles (id),
  updated_at          timestamptz
);
create index templates_list_idx on public.templates (is_active, uploaded_at desc);

alter table public.templates enable row level security;
revoke all on public.templates from anon;
revoke insert, update, delete, truncate on public.templates from authenticated;
-- PhilHealth: lahat (kasama ang retired, para sa FINMAREP); facility: active at visible lang
create policy templates_select on public.templates for select to authenticated
  using (
    (select public.app_user_is_philhealth())
    or ((select public.app_user_role()) in ('facility', 'facility_admin') and is_active and visible_to_facility)
  );

-- Para sa storage policy: makikita ba ng user ang file na ito? (security definer → walang RLS recursion)
create function public.template_file_visible(p_name text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce(public.app_user_is_philhealth(), false)
      or (public.app_user_role() in ('facility', 'facility_admin')
          and exists (select 1 from public.templates t
                       where t.file_path = p_name and t.is_active and t.visible_to_facility));
$$;
revoke execute on function public.template_file_visible(text) from public, anon;
grant  execute on function public.template_file_visible(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('templates', 'templates', false, 10485760,
        array['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/vnd.ms-excel'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Upload: FINMAREP lang, hugis "<uuid>.<xlsx|xls>" sa root ng bucket
create policy templates_files_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'templates'
    and (select public.app_user_role()) = 'finmarep'
    and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(xlsx|xls)$'
  );

-- Basa (signed URL): PhilHealth, o facility kung active at visible ang template
create policy templates_files_select on storage.objects for select to authenticated
  using (bucket_id = 'templates'
         and ((select public.app_user_is_philhealth()) or public.template_file_visible(name)));
-- Walang update/delete policy.

-- ---------------------------------------------------------------------------
-- RPC
-- ---------------------------------------------------------------------------
create function public.add_template(
  p_name                text,
  p_description         text,
  p_file_path           text,
  p_file_name           text,
  p_visible_to_facility boolean
)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id   uuid;
  v_size bigint;
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'Only FINMAREP can upload templates' using errcode = '42501';
  end if;
  if nullif(trim(p_name), '') is null then
    raise exception 'Template name is required' using errcode = '22023';
  end if;
  if p_file_path is null
     or p_file_path !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(xlsx|xls)$' then
    raise exception 'Invalid file' using errcode = '42501';
  end if;
  select (o.metadata->>'size')::bigint into v_size
    from storage.objects o
   where o.bucket_id = 'templates' and o.name = p_file_path and o.owner_id = auth.uid()::text;
  if not found then
    raise exception 'The file was not uploaded' using errcode = '22023';
  end if;

  insert into public.templates (name, description, file_path, file_name, file_size, visible_to_facility, uploaded_by)
  values (left(trim(p_name), 120), left(nullif(trim(p_description), ''), 500), p_file_path,
          left(coalesce(nullif(trim(p_file_name), ''), 'template.xlsx'), 255),
          least(greatest(coalesce(v_size, 1), 1), 10485760)::int, coalesce(p_visible_to_facility, false), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create function public.set_template_status(p_id uuid, p_is_active boolean, p_visible_to_facility boolean)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if public.app_user_role() is distinct from 'finmarep' then
    raise exception 'Only FINMAREP can change templates' using errcode = '42501';
  end if;
  update public.templates
     set is_active = coalesce(p_is_active, is_active),
         visible_to_facility = coalesce(p_visible_to_facility, visible_to_facility),
         updated_by = auth.uid(), updated_at = now()
   where id = p_id;
  if not found then
    raise exception 'Template not found' using errcode = '22023';
  end if;
end;
$$;

revoke execute on function public.add_template(text, text, text, text, boolean) from public, anon;
grant  execute on function public.add_template(text, text, text, text, boolean) to authenticated;
revoke execute on function public.set_template_status(uuid, boolean, boolean) from public, anon;
grant  execute on function public.set_template_status(uuid, boolean, boolean) to authenticated;
