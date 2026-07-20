-- Fixes 2026-07-20:
-- 1. agenda_safe_link ahora lanza errcode 22023 para que los RPCs devuelvan 'bad_link' limpio.
-- 2. agenda_get_workspace ya no expone folder ids, batch id ni email del uploader a los clientes.

create or replace function public.agenda_safe_link(raw text)
returns text
language plpgsql
immutable
as $$
declare
  v text;
begin
  if raw is null then
    return null;
  end if;

  v := trim(raw);
  if v = '' then
    return '';
  end if;

  if v ~* '^https?://' then
    return v;
  end if;

  if v ~* '^[a-z][a-z0-9+.-]*:' then
    raise exception 'bad_link' using errcode = '22023';
  end if;

  return 'https://' || v;
end;
$$;

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
