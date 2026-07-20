-- Upload-aware fields for the local Agenda Uploader integration.
alter table public.agenda_jobs
  add column if not exists status text not null default 'ready',
  add column if not exists submitted_by uuid references public.agenda_clients(id) on delete set null,
  add column if not exists source_links jsonb not null default '[]'::jsonb,
  add column if not exists source_folder_id text,
  add column if not exists delivery_links jsonb not null default '[]'::jsonb,
  add column if not exists delivery_folder_id text,
  add column if not exists upload_batch_id text,
  add column if not exists updated_at timestamptz not null default now();

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'agenda_jobs_status_check'
      and conrelid = 'public.agenda_jobs'::regclass
  ) then
    alter table public.agenda_jobs
      add constraint agenda_jobs_status_check
      check (status in ('uploading', 'ready', 'editing', 'needs_info', 'review', 'delivered'));
  end if;
end $$;

create unique index if not exists agenda_jobs_upload_batch_id_uq
  on public.agenda_jobs(upload_batch_id)
  where upload_batch_id is not null;

create or replace function public.agenda_register_upload(
  tok text,
  p_client_id uuid,
  p_title text,
  p_source_links jsonb,
  p_source_folder_id text default null,
  p_deadline date default null,
  p_notes text default '',
  p_videos integer default 0,
  p_upload_batch_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me agenda_clients;
  target agenda_clients;
  new_steps jsonb;
  existing_job agenda_jobs;
  created_job agenda_jobs;
  clean_source_links jsonb;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then
    return jsonb_build_object('error', 'invalid_token');
  end if;

  if not (me.is_admin or me.is_partner) then
    return jsonb_build_object('error', 'partner_or_admin_required');
  end if;

  select * into target from agenda_clients
  where id = p_client_id and not is_admin and not is_partner;
  if target.id is null then
    return jsonb_build_object('error', 'invalid_client');
  end if;

  if p_upload_batch_id is not null then
    select * into existing_job from agenda_jobs where upload_batch_id = p_upload_batch_id;
    if existing_job.id is not null then
      return jsonb_build_object('ok', true, 'duplicate', true, 'job_id', existing_job.id);
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('label', s, 'done', false, 'link', null)), '[]'::jsonb)
  into new_steps
  from jsonb_array_elements_text(target.steps) as s;

  select coalesce(jsonb_agg(public.agenda_safe_link(value)), '[]'::jsonb)
  into clean_source_links
  from jsonb_array_elements_text(coalesce(p_source_links, '[]'::jsonb)) as source(value);

  insert into agenda_jobs (
    client_id, title, links, deadline, steps, notes, videos_total,
    status, submitted_by, source_links, source_folder_id, upload_batch_id, updated_at
  )
  values (
    target.id, nullif(trim(p_title), ''), '[]'::jsonb, p_deadline, new_steps,
    coalesce(p_notes, ''), greatest(coalesce(p_videos, 0), 0),
    'ready', me.id, clean_source_links, nullif(trim(p_source_folder_id), ''),
    nullif(trim(p_upload_batch_id), ''), now()
  )
  returning * into created_job;

  return jsonb_build_object('ok', true, 'duplicate', false, 'job_id', created_job.id);
exception when others then
  if sqlstate = '22023' then
    return jsonb_build_object('error', 'bad_link');
  end if;
  raise;
end $function$;

create or replace function public.agenda_set_job_status(
  tok text,
  p_job_id uuid,
  p_status text,
  p_block_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me agenda_clients;
  job agenda_jobs;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;

  select * into job from agenda_jobs where id = p_job_id;
  if job.id is null then return jsonb_build_object('error', 'job_not_found'); end if;
  if not me.is_admin and not me.is_partner and job.client_id <> me.id then
    return jsonb_build_object('error', 'forbidden');
  end if;

  update agenda_jobs
  set status = p_status,
      notes = case when p_block_reason is null or trim(p_block_reason) = '' then notes else trim(p_block_reason) end,
      updated_at = now()
  where id = p_job_id;

  return jsonb_build_object('ok', true);
exception when check_violation then
  return jsonb_build_object('error', 'invalid_status');
end $function$;

create or replace function public.agenda_register_delivery(
  tok text,
  p_job_id uuid,
  p_delivery_links jsonb,
  p_delivery_folder_id text default null,
  p_status text default 'review'
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me agenda_clients;
  job agenda_jobs;
  clean_delivery_links jsonb;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  if not me.is_admin then return jsonb_build_object('error', 'admin_required'); end if;

  select * into job from agenda_jobs where id = p_job_id;
  if job.id is null then return jsonb_build_object('error', 'job_not_found'); end if;

  select coalesce(jsonb_agg(public.agenda_safe_link(value)), '[]'::jsonb)
  into clean_delivery_links
  from jsonb_array_elements_text(coalesce(p_delivery_links, '[]'::jsonb)) as delivery(value);

  update agenda_jobs
  set delivery_links = clean_delivery_links,
      delivery_folder_id = nullif(trim(p_delivery_folder_id), ''),
      status = p_status,
      updated_at = now()
  where id = p_job_id;

  return jsonb_build_object('ok', true);
exception when check_violation then
  return jsonb_build_object('error', 'invalid_status');
when others then
  if sqlstate = '22023' then
    return jsonb_build_object('error', 'bad_link');
  end if;
  raise;
end $function$;
