-- =====================================================================
-- MFC Coaching : espace coach (à coller après schema-4-coaching.sql)
-- SQL Editor > New query > coller > remplacer TON-CODE à la toute fin > Run.
-- Relançable sans risque.
-- =====================================================================

alter table public.mfc_coach_accounts add column if not exists is_coach boolean not null default false;
alter table public.mfc_coach_accounts add column if not exists coach_id uuid references public.mfc_coach_accounts(id) on delete set null;
alter table public.mfc_coach_accounts add column if not exists invite text unique;
create index if not exists mfc_coach_accounts_coach on public.mfc_coach_accounts (coach_id);

-- Compte de l'appareil connecté
create or replace function public.mfc_coach_me() returns public.mfc_coach_accounts
language sql stable security definer set search_path = public as $$
  select a.* from public.mfc_coach_accounts a
    join public.mfc_coach_devices d on d.account_id = a.id
   where d.uid = auth.uid()
$$;

-- Ouverture : renvoie aussi « est coach » et le prénom du coach
create or replace function public.mfc_coach_open() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := auth.uid();
  acc public.mfc_coach_accounts;
begin
  if u is null then raise exception 'auth'; end if;
  select a.* into acc from public.mfc_coach_accounts a
    join public.mfc_coach_devices d on d.account_id = a.id where d.uid = u;
  if not found then
    loop
      begin
        insert into public.mfc_coach_accounts(code) values (public.mfc_coach_newcode()) returning * into acc;
        exit;
      exception when unique_violation then
      end;
    end loop;
    insert into public.mfc_coach_devices(uid, account_id) values (u, acc.id);
  end if;
  return jsonb_build_object('code', acc.code, 'rev', acc.rev, 'data', acc.data, 'updated_at', acc.updated_at,
    'is_coach', acc.is_coach,
    'coach_name', (select c.name from public.mfc_coach_accounts c where c.id = acc.coach_id));
end $$;

-- Coach : clé d'invitation (différente du code de récupération)
create or replace function public.mfc_coach_invite() returns text
language plpgsql security definer set search_path = public as $$
declare
  me public.mfc_coach_accounts := public.mfc_coach_me();
  k text;
begin
  if me.id is null or not me.is_coach then raise exception 'not_coach'; end if;
  if me.invite is not null then return me.invite; end if;
  loop
    begin
      k := replace(public.mfc_coach_newcode(), '-', '');
      update public.mfc_coach_accounts set invite = k where id = me.id;
      exit;
    exception when unique_violation then
    end;
  end loop;
  return k;
end $$;

-- Client : se rattacher à un coach avec sa clé d'invitation
create or replace function public.mfc_coach_link(p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.mfc_coach_accounts := public.mfc_coach_me();
  c public.mfc_coach_accounts;
begin
  if me.id is null then raise exception 'no_account'; end if;
  select * into c from public.mfc_coach_accounts
   where invite = upper(regexp_replace(coalesce(p_key, ''), '[^A-Za-z0-9]', '', 'g')) and is_coach;
  if not found then return jsonb_build_object('error', 'key'); end if;
  if c.id = me.id then return jsonb_build_object('error', 'self'); end if;
  update public.mfc_coach_accounts set coach_id = c.id where id = me.id;
  return jsonb_build_object('coach_name', c.name);
end $$;

-- Client : se détacher de son coach
create or replace function public.mfc_coach_unlink() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.mfc_coach_accounts := public.mfc_coach_me();
begin
  if me.id is null then raise exception 'no_account'; end if;
  update public.mfc_coach_accounts set coach_id = null where id = me.id;
  return jsonb_build_object('ok', true);
end $$;

-- Coach : liste de ses clients avec leurs données
create or replace function public.mfc_coach_clients() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.mfc_coach_accounts := public.mfc_coach_me();
begin
  if me.id is null or not me.is_coach then raise exception 'not_coach'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'rev', a.rev, 'updated_at', a.updated_at, 'data', a.data) order by a.name)
      from public.mfc_coach_accounts a where a.coach_id = me.id), '[]'::jsonb);
end $$;

-- Coach : modifier les données d'un de ses clients (programme, mot du coach, commentaires)
create or replace function public.mfc_coach_client_push(p_id uuid, p_data jsonb, p_rev integer) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.mfc_coach_accounts := public.mfc_coach_me();
  c public.mfc_coach_accounts;
  r integer;
begin
  if me.id is null or not me.is_coach then raise exception 'not_coach'; end if;
  select * into c from public.mfc_coach_accounts where id = p_id and coach_id = me.id for update;
  if not found then raise exception 'not_your_client'; end if;
  if c.rev <> p_rev then
    return jsonb_build_object('conflict', true, 'rev', c.rev, 'data', c.data);
  end if;
  update public.mfc_coach_accounts set data = p_data, rev = rev + 1, updated_at = now()
   where id = c.id returning rev into r;
  return jsonb_build_object('rev', r);
end $$;

-- Coach : retirer un client de sa liste
create or replace function public.mfc_coach_drop(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.mfc_coach_accounts := public.mfc_coach_me();
begin
  if me.id is null or not me.is_coach then raise exception 'not_coach'; end if;
  update public.mfc_coach_accounts set coach_id = null where id = p_id and coach_id = me.id;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.mfc_coach_me() from public, anon, authenticated;
revoke all on function public.mfc_coach_open() from public, anon;
revoke all on function public.mfc_coach_invite() from public, anon;
revoke all on function public.mfc_coach_link(text) from public, anon;
revoke all on function public.mfc_coach_unlink() from public, anon;
revoke all on function public.mfc_coach_clients() from public, anon;
revoke all on function public.mfc_coach_client_push(uuid, jsonb, integer) from public, anon;
revoke all on function public.mfc_coach_drop(uuid) from public, anon;
grant execute on function public.mfc_coach_open() to authenticated;
grant execute on function public.mfc_coach_invite() to authenticated;
grant execute on function public.mfc_coach_link(text) to authenticated;
grant execute on function public.mfc_coach_unlink() to authenticated;
grant execute on function public.mfc_coach_clients() to authenticated;
grant execute on function public.mfc_coach_client_push(uuid, jsonb, integer) to authenticated;
grant execute on function public.mfc_coach_drop(uuid) to authenticated;

-- ▼▼▼ Remplace TON-CODE par ton code de récupération (appli > Profil > Sauvegarde en ligne) ▼▼▼
update public.mfc_coach_accounts set is_coach = true where code = upper('TON-CODE');
