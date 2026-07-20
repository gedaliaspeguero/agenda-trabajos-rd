-- Web uploader state and client folder mappings.
alter table public.agenda_clients
  add column if not exists source_folder_id text,
  add column if not exists delivery_folder_id text;

alter table public.agenda_jobs
  add column if not exists upload_kind text,
  add column if not exists upload_files_total integer not null default 0,
  add column if not exists upload_files_done integer not null default 0,
  add column if not exists upload_bytes_total bigint not null default 0,
  add column if not exists upload_bytes_done bigint not null default 0,
  add column if not exists uploader_email text;

alter table public.agenda_jobs drop constraint if exists agenda_jobs_status_check;
alter table public.agenda_jobs
  add constraint agenda_jobs_status_check
  check (status in (
    'uploading', 'delivery_uploading', 'ready', 'editing',
    'needs_info', 'review', 'delivered'
  ));

create or replace function public.agenda_get_workspace(tok text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me agenda_clients;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then
    return jsonb_build_object('error', 'invalid_token');
  end if;

  if me.is_admin or me.is_partner then
    return jsonb_build_object(
      'role', case when me.is_admin then 'admin' else 'partner' end,
      'client', jsonb_build_object('id', me.id, 'name', me.name),
      'clients', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', c.id,
          'name', c.name,
          'token', case when me.is_admin then c.token else null end,
          'steps', c.steps,
          'source_folder_id', c.source_folder_id,
          'delivery_folder_id', case when me.is_admin then c.delivery_folder_id else null end
        ) order by c.created_at), '[]'::jsonb)
        from agenda_clients c where not c.is_admin and not c.is_partner
      ),
      'jobs', (
        select coalesce(jsonb_agg(to_jsonb(j) order by j.deadline asc nulls last, j.created_at desc), '[]'::jsonb)
        from agenda_jobs j
      )
    );
  end if;

  return jsonb_build_object(
    'role', 'client',
    'client', jsonb_build_object('id', me.id, 'name', me.name, 'steps', me.steps),
    'jobs', (
      select coalesce(jsonb_agg(
        (to_jsonb(j) - 'source_folder_id' - 'delivery_folder_id' - 'upload_batch_id' - 'uploader_email')
        order by j.deadline asc nulls last, j.created_at desc), '[]'::jsonb)
      from agenda_jobs j where j.client_id = me.id
    )
  );
end $function$;

create or replace function public.agenda_set_client_drive_folders(
  tok text,
  p_client_id uuid,
  p_source_folder_id text default null,
  p_delivery_folder_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me agenda_clients;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  if not me.is_admin then return jsonb_build_object('error', 'admin_required'); end if;

  update agenda_clients
  set source_folder_id = nullif(trim(p_source_folder_id), ''),
      delivery_folder_id = nullif(trim(p_delivery_folder_id), '')
  where id = p_client_id and not is_admin and not is_partner;

  if not found then return jsonb_build_object('error', 'invalid_client'); end if;
  return jsonb_build_object('ok', true);
end $function$;

create or replace function public.agenda_start_web_upload(
  tok text,
  p_kind text,
  p_client_id uuid,
  p_title text default null,
  p_deadline date default null,
  p_notes text default '',
  p_videos integer default 0,
  p_files_total integer default 0,
  p_bytes_total bigint default 0,
  p_upload_batch_id text default null,
  p_job_id uuid default null,
  p_uploader_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me agenda_clients;
  target agenda_clients;
  job agenda_jobs;
  new_steps jsonb;
  destination_folder_id text;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  if p_kind not in ('source', 'delivery') then return jsonb_build_object('error', 'invalid_upload_kind'); end if;

  if p_kind = 'delivery' then
    if not me.is_admin then return jsonb_build_object('error', 'admin_required'); end if;
    select * into job from agenda_jobs where id = p_job_id;
    if job.id is null then return jsonb_build_object('error', 'job_not_found'); end if;
    select * into target from agenda_clients where id = job.client_id;
    destination_folder_id := target.delivery_folder_id;
    if destination_folder_id is null then return jsonb_build_object('error', 'delivery_folder_not_configured'); end if;

    update agenda_jobs
    set status = 'delivery_uploading',
        upload_kind = 'delivery',
        upload_files_total = greatest(coalesce(p_files_total, 0), 0),
        upload_files_done = 0,
        upload_bytes_total = greatest(coalesce(p_bytes_total, 0), 0),
        upload_bytes_done = 0,
        uploader_email = nullif(trim(p_uploader_email), ''),
        updated_at = now()
    where id = job.id;
    return jsonb_build_object('ok', true, 'job_id', job.id, 'folder_id', destination_folder_id);
  end if;

  if not (me.is_admin or me.is_partner) then
    return jsonb_build_object('error', 'partner_or_admin_required');
  end if;
  select * into target from agenda_clients where id = p_client_id and not is_admin and not is_partner;
  if target.id is null then return jsonb_build_object('error', 'invalid_client'); end if;
  destination_folder_id := target.source_folder_id;
  if destination_folder_id is null then return jsonb_build_object('error', 'source_folder_not_configured'); end if;

  if p_upload_batch_id is not null then
    select * into job from agenda_jobs where upload_batch_id = p_upload_batch_id;
    if job.id is not null then
      return jsonb_build_object('ok', true, 'duplicate', true, 'job_id', job.id, 'folder_id', destination_folder_id);
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('label', s, 'done', false, 'link', null)), '[]'::jsonb)
  into new_steps
  from jsonb_array_elements_text(target.steps) as s;

  insert into agenda_jobs (
    client_id, title, links, deadline, steps, notes, videos_total,
    status, submitted_by, source_folder_id, upload_batch_id, upload_kind,
    upload_files_total, upload_files_done, upload_bytes_total, upload_bytes_done,
    uploader_email, updated_at
  ) values (
    target.id, nullif(trim(p_title), ''), '[]'::jsonb, p_deadline, new_steps,
    coalesce(p_notes, ''), greatest(coalesce(p_videos, 0), 0),
    'uploading', me.id, destination_folder_id, nullif(trim(p_upload_batch_id), ''), 'source',
    greatest(coalesce(p_files_total, 0), 0), 0,
    greatest(coalesce(p_bytes_total, 0), 0), 0,
    nullif(trim(p_uploader_email), ''), now()
  ) returning * into job;

  return jsonb_build_object('ok', true, 'duplicate', false, 'job_id', job.id, 'folder_id', destination_folder_id);
end $function$;

create or replace function public.agenda_update_upload_progress(
  tok text,
  p_job_id uuid,
  p_files_done integer,
  p_files_total integer,
  p_bytes_done bigint,
  p_bytes_total bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me agenda_clients; job agenda_jobs;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  select * into job from agenda_jobs where id = p_job_id;
  if job.id is null then return jsonb_build_object('error', 'job_not_found'); end if;
  if not me.is_admin and job.submitted_by <> me.id then return jsonb_build_object('error', 'forbidden'); end if;

  update agenda_jobs
  set upload_files_done = greatest(coalesce(p_files_done, 0), 0),
      upload_files_total = greatest(coalesce(p_files_total, 0), 0),
      upload_bytes_done = greatest(coalesce(p_bytes_done, 0), 0),
      upload_bytes_total = greatest(coalesce(p_bytes_total, 0), 0),
      updated_at = now()
  where id = job.id;
  return jsonb_build_object('ok', true);
end $function$;

create or replace function public.agenda_finish_web_upload(
  tok text,
  p_job_id uuid,
  p_kind text,
  p_links jsonb,
  p_folder_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me agenda_clients; job agenda_jobs; clean_links jsonb;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  select * into job from agenda_jobs where id = p_job_id;
  if job.id is null then return jsonb_build_object('error', 'job_not_found'); end if;
  if not me.is_admin and job.submitted_by <> me.id then return jsonb_build_object('error', 'forbidden'); end if;
  if p_kind not in ('source', 'delivery') then return jsonb_build_object('error', 'invalid_upload_kind'); end if;

  select coalesce(jsonb_agg(public.agenda_safe_link(value)), '[]'::jsonb)
  into clean_links
  from jsonb_array_elements_text(coalesce(p_links, '[]'::jsonb)) as item(value);

  if p_kind = 'source' then
    update agenda_jobs
    set source_links = clean_links,
        source_folder_id = coalesce(nullif(trim(p_folder_id), ''), source_folder_id),
        status = 'ready',
        upload_files_done = upload_files_total,
        upload_bytes_done = upload_bytes_total,
        updated_at = now()
    where id = job.id;
  else
    if not me.is_admin then return jsonb_build_object('error', 'admin_required'); end if;
    update agenda_jobs
    set delivery_links = clean_links,
        delivery_folder_id = coalesce(nullif(trim(p_folder_id), ''), delivery_folder_id),
        status = 'review',
        upload_files_done = upload_files_total,
        upload_bytes_done = upload_bytes_total,
        updated_at = now()
    where id = job.id;
  end if;
  return jsonb_build_object('ok', true);
exception when others then
  if sqlstate = '22023' then return jsonb_build_object('error', 'bad_link'); end if;
  raise;
end $function$;

create or replace function public.agenda_abort_web_upload(
  tok text,
  p_job_id uuid,
  p_kind text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me agenda_clients; job agenda_jobs; next_status text;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  select * into job from agenda_jobs where id = p_job_id;
  if job.id is null then return jsonb_build_object('error', 'job_not_found'); end if;
  if not me.is_admin and job.submitted_by <> me.id then return jsonb_build_object('error', 'forbidden'); end if;
  if p_kind not in ('source', 'delivery') then return jsonb_build_object('error', 'invalid_upload_kind'); end if;
  if p_kind = 'delivery' and not me.is_admin then return jsonb_build_object('error', 'admin_required'); end if;

  next_status := case when p_kind = 'delivery' then 'editing' else 'needs_info' end;
  update agenda_jobs
  set status = next_status,
      notes = case
        when nullif(trim(coalesce(p_reason, '')), '') is null then notes
        else concat_ws(E'\n', nullif(notes, ''), 'Subida pendiente: ' || trim(p_reason))
      end,
      updated_at = now()
  where id = job.id;
  return jsonb_build_object('ok', true, 'status', next_status);
end $function$;
