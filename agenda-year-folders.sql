-- Codex Drive hierarchy: Raw/Edit root -> year -> month -> numbered video/file.
alter table public.agenda_months
  add column if not exists raw_year_folder_id text,
  add column if not exists edits_year_folder_id text;

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
    'raw_year_folder_id', workspace.raw_year_folder_id,
    'edits_year_folder_id', workspace.edits_year_folder_id,
    'raw_month_folder_id', workspace.raw_month_folder_id,
    'edits_month_folder_id', workspace.edits_month_folder_id
  );
end $function$;

create or replace function public.agenda_set_month_drive_structure(
  tok text,
  p_month_id uuid,
  p_raw_year_folder_id text,
  p_edits_year_folder_id text,
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
  set raw_year_folder_id = coalesce(nullif(trim(p_raw_year_folder_id), ''), raw_year_folder_id),
      edits_year_folder_id = coalesce(nullif(trim(p_edits_year_folder_id), ''), edits_year_folder_id),
      raw_month_folder_id = coalesce(nullif(trim(p_raw_month_folder_id), ''), raw_month_folder_id),
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

-- Some edits arrive after the raw material was handled outside the agenda.
-- Register a numbered video so the final file still has a clear home.
create or replace function public.agenda_prepare_month_edit_upload(
  tok text,
  p_client_id uuid,
  p_month_key date,
  p_files_total integer default 1,
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
  if target.delivery_folder_id is null then return jsonb_build_object('error', 'client_drive_folders_not_configured'); end if;

  insert into agenda_months (client_id, month_key)
  values (target.id, date_trunc('month', p_month_key)::date)
  on conflict (client_id, month_key) do update set updated_at = now()
  returning * into workspace;

  select coalesce(max(sequence), 0) + 1 into next_sequence
  from agenda_month_videos where month_id = workspace.id;
  insert into agenda_month_videos (
    month_id, sequence, status, upload_kind, upload_files_total,
    upload_bytes_total, submitted_by, uploader_email
  ) values (
    workspace.id, next_sequence, 'delivery_uploading', 'delivery',
    greatest(coalesce(p_files_total, 0), 0), greatest(coalesce(p_bytes_total, 0), 0),
    me.id, nullif(trim(p_uploader_email), '')
  ) returning * into video;

  return jsonb_build_object(
    'ok', true, 'video_id', video.id, 'month_id', workspace.id, 'sequence', video.sequence,
    'edits_root_folder_id', target.delivery_folder_id,
    'edits_year_folder_id', workspace.edits_year_folder_id,
    'edits_month_folder_id', workspace.edits_month_folder_id
  );
end $function$;
