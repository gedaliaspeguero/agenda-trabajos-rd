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

create or replace function public.agenda_set_step(tok text, p_job_id uuid, p_index integer, p_done boolean, p_link text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me agenda_clients;
  j agenda_jobs;
  step jsonb;
  safe text;
begin
  select * into me from agenda_clients where token = tok;
  if me.id is null then
    return jsonb_build_object('error', 'invalid_token');
  end if;

  select * into j from agenda_jobs where id = p_job_id;
  if j.id is null or not me.is_admin then
    return jsonb_build_object('error', 'not_allowed');
  end if;

  if p_index < 0 or p_index >= jsonb_array_length(j.steps) then
    return jsonb_build_object('error', 'bad_index');
  end if;

  begin
    safe := agenda_safe_link(p_link);
  exception when others then
    return jsonb_build_object('error', 'bad_link');
  end;

  step := j.steps -> p_index;
  step := jsonb_set(step, '{done}', to_jsonb(p_done));
  if p_link is not null then
    step := jsonb_set(step, '{link}', case when safe = '' then 'null'::jsonb else to_jsonb(safe) end);
  end if;

  update agenda_jobs set steps = jsonb_set(steps, array[p_index::text], step) where id = p_job_id;
  return jsonb_build_object('ok', true);
end
$function$;
