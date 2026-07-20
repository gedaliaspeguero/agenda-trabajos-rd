-- Monthly production model: Client -> Month -> Numbered video.
create table if not exists public.agenda_months (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.agenda_clients(id) on delete cascade,
  month_key date not null,
  raw_month_folder_id text,
  edits_month_folder_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (client_id, month_key)
);

create table if not exists public.agenda_month_videos (
  id uuid primary key default gen_random_uuid(),
  month_id uuid not null references public.agenda_months(id) on delete cascade,
  sequence integer not null check (sequence > 0),
  raw_folder_id text,
  raw_links jsonb not null default '[]'::jsonb,
  edit_link text,
  edit_file_name text,
  status text not null default 'needs_info' check (status in (
    'uploading', 'delivery_uploading', 'ready', 'editing',
    'needs_info', 'review', 'delivered'
  )),
  notes text not null default '',
  deadline date,
  upload_kind text,
  upload_files_total integer not null default 0,
  upload_files_done integer not null default 0,
  upload_bytes_total bigint not null default 0,
  upload_bytes_done bigint not null default 0,
  submitted_by uuid references public.agenda_clients(id),
  uploader_email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (month_id, sequence)
);

create index if not exists agenda_months_client_month_idx on public.agenda_months(client_id, month_key desc);
create index if not exists agenda_month_videos_month_sequence_idx on public.agenda_month_videos(month_id, sequence);

create or replace function public.agenda_get_workspace(tok text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me agenda_clients;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;

  if me.is_admin or me.is_partner then
    return jsonb_build_object(
      'role', case when me.is_admin then 'admin' else 'partner' end,
      'client', jsonb_build_object('id', me.id, 'name', me.name),
      'clients', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', c.id, 'name', c.name,
          'token', case when me.is_admin then c.token else null end,
          'steps', c.steps,
          'source_folder_id', c.source_folder_id,
          'delivery_folder_id', c.delivery_folder_id
        ) order by c.created_at), '[]'::jsonb)
        from agenda_clients c where not c.is_admin and not c.is_partner
      ),
      'jobs', (
        select coalesce(jsonb_agg(to_jsonb(j) order by j.deadline asc nulls last, j.created_at desc), '[]'::jsonb)
        from agenda_jobs j
      ),
      'months', (
        select coalesce(jsonb_agg(to_jsonb(m) order by m.month_key desc), '[]'::jsonb)
        from agenda_months m
      ),
      'month_videos', (
        select coalesce(jsonb_agg(
          to_jsonb(v) || jsonb_build_object('client_id', m.client_id, 'month_key', m.month_key)
          order by m.month_key desc, v.sequence asc
        ), '[]'::jsonb)
        from agenda_month_videos v join agenda_months m on m.id = v.month_id
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
    ),
    'months', '[]'::jsonb,
    'month_videos', '[]'::jsonb
  );
end $function$;

create or replace function public.agenda_prepare_month_video_upload(
  tok text,
  p_client_id uuid,
  p_month_key date,
  p_notes text default '',
  p_deadline date default null,
  p_files_total integer default 0,
  p_bytes_total bigint default 0,
  p_uploader_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me agenda_clients; target agenda_clients; workspace agenda_months; video agenda_month_videos; next_sequence integer;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  if not (me.is_admin or me.is_partner) then return jsonb_build_object('error', 'partner_or_admin_required'); end if;
  if p_month_key is null then return jsonb_build_object('error', 'month_required'); end if;
  select * into target from agenda_clients where id = p_client_id and not is_admin and not is_partner;
  if target.id is null then return jsonb_build_object('error', 'invalid_client'); end if;
  if target.source_folder_id is null or target.delivery_folder_id is null then
    return jsonb_build_object('error', 'client_drive_folders_not_configured');
  end if;

  insert into agenda_months (client_id, month_key)
  values (target.id, date_trunc('month', p_month_key)::date)
  on conflict (client_id, month_key) do update set updated_at = now()
  returning * into workspace;

  select coalesce(max(sequence), 0) + 1 into next_sequence from agenda_month_videos where month_id = workspace.id;
  insert into agenda_month_videos (
    month_id, sequence, status, notes, deadline, upload_kind,
    upload_files_total, upload_bytes_total, submitted_by, uploader_email
  ) values (
    workspace.id, next_sequence, 'uploading', coalesce(p_notes, ''), p_deadline, 'source',
    greatest(coalesce(p_files_total, 0), 0), greatest(coalesce(p_bytes_total, 0), 0),
    me.id, nullif(trim(p_uploader_email), '')
  ) returning * into video;

  return jsonb_build_object(
    'ok', true, 'video_id', video.id, 'month_id', workspace.id, 'sequence', video.sequence,
    'raw_root_folder_id', target.source_folder_id,
    'edits_root_folder_id', target.delivery_folder_id,
    'raw_month_folder_id', workspace.raw_month_folder_id,
    'edits_month_folder_id', workspace.edits_month_folder_id
  );
end $function$;

create or replace function public.agenda_set_month_drive_folders(
  tok text,
  p_month_id uuid,
  p_raw_month_folder_id text,
  p_edits_month_folder_id text,
  p_video_id uuid default null,
  p_raw_folder_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me agenda_clients; workspace agenda_months; video agenda_month_videos;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  if not (me.is_admin or me.is_partner) then return jsonb_build_object('error', 'partner_or_admin_required'); end if;
  select * into workspace from agenda_months where id = p_month_id;
  if workspace.id is null then return jsonb_build_object('error', 'month_not_found'); end if;

  update agenda_months
  set raw_month_folder_id = coalesce(nullif(trim(p_raw_month_folder_id), ''), raw_month_folder_id),
      edits_month_folder_id = coalesce(nullif(trim(p_edits_month_folder_id), ''), edits_month_folder_id),
      updated_at = now()
  where id = workspace.id;

  if p_video_id is not null then
    select * into video from agenda_month_videos where id = p_video_id and month_id = workspace.id;
    if video.id is null then return jsonb_build_object('error', 'video_not_found'); end if;
    update agenda_month_videos
    set raw_folder_id = coalesce(nullif(trim(p_raw_folder_id), ''), raw_folder_id), updated_at = now()
    where id = video.id;
  end if;
  return jsonb_build_object('ok', true);
end $function$;

create or replace function public.agenda_start_month_edit_upload(
  tok text,
  p_video_id uuid,
  p_files_total integer default 1,
  p_bytes_total bigint default 0,
  p_uploader_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me agenda_clients; video agenda_month_videos; workspace agenda_months;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  if not (me.is_admin or me.is_partner) then return jsonb_build_object('error', 'partner_or_admin_required'); end if;
  select v.* into video from agenda_month_videos v where v.id = p_video_id;
  if video.id is null then return jsonb_build_object('error', 'video_not_found'); end if;
  select * into workspace from agenda_months where id = video.month_id;
  if workspace.edits_month_folder_id is null then return jsonb_build_object('error', 'edits_month_folder_not_ready'); end if;

  update agenda_month_videos
  set status = 'delivery_uploading', upload_kind = 'delivery',
      upload_files_total = greatest(coalesce(p_files_total, 0), 0), upload_files_done = 0,
      upload_bytes_total = greatest(coalesce(p_bytes_total, 0), 0), upload_bytes_done = 0,
      uploader_email = nullif(trim(p_uploader_email), ''), updated_at = now()
  where id = video.id;
  return jsonb_build_object('ok', true, 'video_id', video.id, 'sequence', video.sequence, 'folder_id', workspace.edits_month_folder_id);
end $function$;

create or replace function public.agenda_update_month_video_progress(
  tok text, p_video_id uuid, p_files_done integer, p_files_total integer, p_bytes_done bigint, p_bytes_total bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me agenda_clients; video agenda_month_videos;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  select * into video from agenda_month_videos where id = p_video_id;
  if video.id is null then return jsonb_build_object('error', 'video_not_found'); end if;
  if not me.is_admin and not (me.is_partner and video.upload_kind = 'delivery') and video.submitted_by <> me.id then return jsonb_build_object('error', 'forbidden'); end if;
  update agenda_month_videos
  set upload_files_done = greatest(coalesce(p_files_done, 0), 0),
      upload_files_total = greatest(coalesce(p_files_total, 0), 0),
      upload_bytes_done = greatest(coalesce(p_bytes_done, 0), 0),
      upload_bytes_total = greatest(coalesce(p_bytes_total, 0), 0), updated_at = now()
  where id = video.id;
  return jsonb_build_object('ok', true);
end $function$;

create or replace function public.agenda_finish_month_video_upload(
  tok text, p_video_id uuid, p_kind text, p_links jsonb, p_file_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me agenda_clients; video agenda_month_videos; clean_links jsonb;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  select * into video from agenda_month_videos where id = p_video_id;
  if video.id is null then return jsonb_build_object('error', 'video_not_found'); end if;
  if not me.is_admin and not (me.is_partner and p_kind = 'delivery') and video.submitted_by <> me.id then return jsonb_build_object('error', 'forbidden'); end if;
  if p_kind not in ('source', 'delivery') then return jsonb_build_object('error', 'invalid_upload_kind'); end if;
  if p_kind = 'delivery' and not (me.is_admin or me.is_partner) then return jsonb_build_object('error', 'partner_or_admin_required'); end if;
  select coalesce(jsonb_agg(public.agenda_safe_link(value)), '[]'::jsonb)
  into clean_links from jsonb_array_elements_text(coalesce(p_links, '[]'::jsonb)) as item(value);

  if p_kind = 'source' then
    update agenda_month_videos
    set raw_links = clean_links, status = 'ready', upload_files_done = upload_files_total,
        upload_bytes_done = upload_bytes_total, updated_at = now()
    where id = video.id;
  else
    update agenda_month_videos
    set edit_link = clean_links ->> 0, edit_file_name = nullif(trim(p_file_name), ''), status = 'review',
        upload_files_done = upload_files_total, upload_bytes_done = upload_bytes_total, updated_at = now()
    where id = video.id;
  end if;
  return jsonb_build_object('ok', true);
exception when others then
  if sqlstate = '22023' then return jsonb_build_object('error', 'bad_link'); end if;
  raise;
end $function$;

create or replace function public.agenda_abort_month_video_upload(tok text, p_video_id uuid, p_kind text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me agenda_clients; video agenda_month_videos; next_status text;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then return jsonb_build_object('error', 'invalid_token'); end if;
  select * into video from agenda_month_videos where id = p_video_id;
  if video.id is null then return jsonb_build_object('error', 'video_not_found'); end if;
  if not me.is_admin and not (me.is_partner and p_kind = 'delivery') and video.submitted_by <> me.id then return jsonb_build_object('error', 'forbidden'); end if;
  if p_kind = 'delivery' and not (me.is_admin or me.is_partner) then return jsonb_build_object('error', 'partner_or_admin_required'); end if;
  next_status := case when p_kind = 'delivery' then 'editing' else 'needs_info' end;
  update agenda_month_videos
  set status = next_status,
      notes = case when nullif(trim(coalesce(p_reason, '')), '') is null then notes else concat_ws(E'\n', nullif(notes, ''), 'Subida pendiente: ' || trim(p_reason)) end,
      updated_at = now()
  where id = video.id;
  return jsonb_build_object('ok', true, 'status', next_status);
end $function$;

create or replace function public.agenda_set_month_video_status(tok text, p_video_id uuid, p_status text)
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
  if p_status not in ('ready', 'editing', 'needs_info', 'review', 'delivered') then return jsonb_build_object('error', 'invalid_status'); end if;
  update agenda_month_videos set status = p_status, updated_at = now() where id = p_video_id;
  if not found then return jsonb_build_object('error', 'video_not_found'); end if;
  return jsonb_build_object('ok', true);
end $function$;
