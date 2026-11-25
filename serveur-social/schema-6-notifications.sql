-- =====================================================================
-- MFC Coaching : notifications (à coller après schema-5-coach.sql)
-- Prérequis : la fonction Edge « mfc-push » est déployée (Verify JWT désactivé).
-- Relançable sans risque.
-- =====================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

create table if not exists public.mfc_push_keys (
  id    integer primary key default 1 check (id = 1),
  pub   text not null,
  priv  jsonb not null
);
create table if not exists public.mfc_push_subs (
  endpoint    text primary key,
  p256dh      text not null,
  auth        text not null,
  account_id  uuid not null references public.mfc_coach_accounts(id) on delete cascade,
  created_at  timestamptz not null default now()
);
create index if not exists mfc_push_subs_account on public.mfc_push_subs (account_id);
create table if not exists public.mfc_push_queue (
  id          bigserial primary key,
  account_id  uuid not null references public.mfc_coach_accounts(id) on delete cascade,
  send_at     timestamptz not null,
  title       text not null,
  body        text,
  url         text,
  tag         text,
  kind        text not null default 'seance',
  sent        boolean not null default false,
  sent_at     timestamptz
);
create index if not exists mfc_push_queue_due on public.mfc_push_queue (sent, send_at);
create index if not exists mfc_push_queue_acc on public.mfc_push_queue (account_id, sent);

alter table public.mfc_push_keys  enable row level security;
alter table public.mfc_push_subs  enable row level security;
alter table public.mfc_push_queue enable row level security;
revoke all on public.mfc_push_keys  from anon, authenticated;
revoke all on public.mfc_push_subs  from anon, authenticated;
revoke all on public.mfc_push_queue from anon, authenticated;

-- Abonner / désabonner cet appareil
create or replace function public.mfc_push_subscribe(p_endpoint text, p_p256dh text, p_auth text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.mfc_coach_accounts := public.mfc_coach_me();
begin
  if me.id is null then raise exception 'no_account'; end if;
  if p_endpoint !~ '^https://' then raise exception 'endpoint'; end if;
  insert into public.mfc_push_subs(endpoint, p256dh, auth, account_id) values (p_endpoint, p_p256dh, p_auth, me.id)
    on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, account_id = excluded.account_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.mfc_push_unsubscribe(p_endpoint text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.mfc_coach_accounts := public.mfc_coach_me();
begin
  delete from public.mfc_push_subs where endpoint = p_endpoint and account_id = me.id;
  return jsonb_build_object('ok', true);
end $$;

-- Rappels de séances / de bilan préparés par l'appli (remplace les rappels pas encore envoyés)
create or replace function public.mfc_push_plan(p_items jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare me public.mfc_coach_accounts := public.mfc_coach_me(); n integer;
begin
  if me.id is null then raise exception 'no_account'; end if;
  delete from public.mfc_push_queue where account_id = me.id and not sent and kind in ('seance', 'bilan');
  insert into public.mfc_push_queue(account_id, send_at, title, body, url, tag, kind)
  select me.id, (i->>'at')::timestamptz, left(i->>'title', 90), left(i->>'body', 200), './', left(i->>'tag', 60),
         case when i->>'kind' in ('bilan', 'test') then i->>'kind' else 'seance' end
    from (select i from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i limit 60) x
   where (i->>'at')::timestamptz > now() and (i->>'at')::timestamptz < now() + interval '16 days' and coalesce(i->>'title', '') <> '';
  get diagnostics n = row_count;
  return n;
end $$;

-- Envoi des données du client + notification « bilan reçu » au coach
create or replace function public.mfc_coach_push(p_data jsonb, p_rev integer, p_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := auth.uid();
  acc public.mfc_coach_accounts;
  r integer;
  nm text;
begin
  if u is null then raise exception 'auth'; end if;
  select a.* into acc from public.mfc_coach_accounts a
    join public.mfc_coach_devices d on d.account_id = a.id where d.uid = u
    for update of a;
  if not found then raise exception 'no_account'; end if;
  if acc.rev <> p_rev then
    return jsonb_build_object('conflict', true, 'rev', acc.rev, 'data', acc.data);
  end if;
  nm := coalesce(nullif(left(trim(p_name), 40), ''), acc.name, 'Un client');
  if acc.coach_id is not null and jsonb_typeof(p_data->'bilans') = 'array' and exists (
       select 1 from jsonb_array_elements(p_data->'bilans') b
        where not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(acc.data->'bilans') = 'array' then acc.data->'bilans' else '[]'::jsonb end) o
                           where o->>'id' = b->>'id')) then
    delete from public.mfc_push_queue where account_id = acc.coach_id and not sent and tag = 'bilan-' || acc.id;
    insert into public.mfc_push_queue(account_id, send_at, title, body, url, tag, kind)
    values (acc.coach_id, now(), '📋 ' || nm || ' a envoyé son bilan', 'Ouvre l’onglet Clients pour le lire.', './', 'bilan-' || acc.id, 'coach');
  end if;
  update public.mfc_coach_accounts
     set data = p_data, rev = rev + 1, updated_at = now(), name = coalesce(nullif(left(trim(p_name), 40), ''), name)
   where id = acc.id
   returning rev into r;
  return jsonb_build_object('rev', r);
end $$;

-- Écriture du coach chez un client + notifications « mot du coach » et « commentaire de séance »
create or replace function public.mfc_coach_client_push(p_id uuid, p_data jsonb, p_rev integer) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.mfc_coach_accounts := public.mfc_coach_me();
  c public.mfc_coach_accounts;
  r integer;
  cn text;
  s record;
begin
  if me.id is null or not me.is_coach then raise exception 'not_coach'; end if;
  select * into c from public.mfc_coach_accounts where id = p_id and coach_id = me.id for update;
  if not found then raise exception 'not_your_client'; end if;
  if c.rev <> p_rev then
    return jsonb_build_object('conflict', true, 'rev', c.rev, 'data', c.data);
  end if;
  cn := coalesce(me.name, 'Ton coach');
  -- mot du coach modifié (envoyé 2 min après la dernière modification)
  if coalesce(p_data->'coach'->>'note', '') <> '' and coalesce(p_data->'coach'->>'note', '') <> coalesce(c.data->'coach'->>'note', '') then
    delete from public.mfc_push_queue where account_id = c.id and not sent and tag = 'note';
    insert into public.mfc_push_queue(account_id, send_at, title, body, url, tag, kind)
    values (c.id, now() + interval '2 minutes', '💬 ' || cn || ' t’a laissé un mot', left(p_data->'coach'->>'note', 180), './', 'note', 'coach');
  end if;
  -- commentaires de séance nouveaux ou modifiés
  if jsonb_typeof(p_data->'sessions') = 'array' then
    for s in
      select x->>'id' as sid, x->>'cc' as cc, regexp_replace(coalesce(x->>'name', 'ta séance'), '^S[0-9]+\s*·[^—–]*[—–]\s*', '') as nm
        from jsonb_array_elements(p_data->'sessions') x
       where coalesce(x->>'cc', '') <> ''
         and coalesce(x->>'cc', '') <> coalesce((select o->>'cc' from jsonb_array_elements(case when jsonb_typeof(c.data->'sessions') = 'array' then c.data->'sessions' else '[]'::jsonb end) o where o->>'id' = x->>'id' limit 1), '')
       limit 10
    loop
      delete from public.mfc_push_queue where account_id = c.id and not sent and tag = 'cc-' || s.sid;
      insert into public.mfc_push_queue(account_id, send_at, title, body, url, tag, kind)
      values (c.id, now() + interval '2 minutes', '💬 ' || cn || ' a commenté « ' || left(s.nm, 40) || ' »', left(s.cc, 180), './', 'cc-' || s.sid, 'coach');
    end loop;
  end if;
  update public.mfc_coach_accounts set data = p_data, rev = rev + 1, updated_at = now()
   where id = c.id returning rev into r;
  return jsonb_build_object('rev', r);
end $$;

revoke all on function public.mfc_push_subscribe(text, text, text) from public, anon;
revoke all on function public.mfc_push_unsubscribe(text) from public, anon;
revoke all on function public.mfc_push_plan(jsonb) from public, anon;
revoke all on function public.mfc_coach_push(jsonb, integer, text) from public, anon;
revoke all on function public.mfc_coach_client_push(uuid, jsonb, integer) from public, anon;
grant execute on function public.mfc_push_subscribe(text, text, text) to authenticated;
grant execute on function public.mfc_push_unsubscribe(text) to authenticated;
grant execute on function public.mfc_push_plan(jsonb) to authenticated;
grant execute on function public.mfc_coach_push(jsonb, integer, text) to authenticated;
grant execute on function public.mfc_coach_client_push(uuid, jsonb, integer) to authenticated;

-- Toutes les minutes : s'il y a des notifications à envoyer, on appelle la fonction mfc-push
select cron.unschedule(jobid) from cron.job where jobname = 'mfc-push';
select cron.schedule('mfc-push', '* * * * *', $cron$
  select net.http_post(
    url := 'https://eodjnceukxokexwwocxm.supabase.co/functions/v1/mfc-push',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := '{}'::jsonb)
  where exists (select 1 from public.mfc_push_queue where not sent and send_at <= now());
$cron$);
