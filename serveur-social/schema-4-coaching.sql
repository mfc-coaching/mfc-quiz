-- =====================================================================
-- MFC Coaching : sauvegarde en ligne et synchronisation entre appareils
-- À coller UNE fois dans Supabase : SQL Editor > New query > Run.
-- Relançable sans risque. Utilise la connexion anonyme déjà activée pour MFC Quiz.
--
-- Principe : chaque utilisateur a un « compte coaching » avec un code de
-- récupération (ex. 7KQ2-9XHD-PL3M). Ses données (programme, séances,
-- bilans) sont stockées dans ce compte. Sur un nouveau téléphone, le code
-- permet de rattacher l'appareil au compte et de tout retrouver.
-- Les tables ne sont accessibles QUE via les fonctions ci-dessous.
-- =====================================================================

create table if not exists public.mfc_coach_accounts (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text,
  data        jsonb,
  rev         integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint mfc_coach_data_size check (data is null or pg_column_size(data) < 4000000)
);

create table if not exists public.mfc_coach_devices (
  uid         uuid primary key references auth.users(id) on delete cascade,
  account_id  uuid not null references public.mfc_coach_accounts(id) on delete cascade,
  created_at  timestamptz not null default now()
);
create index if not exists mfc_coach_devices_account on public.mfc_coach_devices (account_id);

alter table public.mfc_coach_accounts enable row level security;
alter table public.mfc_coach_devices  enable row level security;
revoke all on public.mfc_coach_accounts from anon, authenticated;
revoke all on public.mfc_coach_devices  from anon, authenticated;

-- Code de récupération : 12 caractères faciles à lire (sans 0/O, 1/I), format XXXX-XXXX-XXXX
create or replace function public.mfc_coach_newcode() returns text
language plpgsql volatile set search_path = public as $$
declare
  alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
  r text := '';
  i int;
begin
  for i in 0..11 loop
    r := r || substr(alpha, (get_byte(b, i) % 32) + 1, 1);
    if i in (3, 7) then r := r || '-'; end if;
  end loop;
  return r;
end $$;

-- Ouvre (ou crée) le compte de l'appareil connecté
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
        -- code déjà pris (très improbable) : on recommence
      end;
    end loop;
    insert into public.mfc_coach_devices(uid, account_id) values (u, acc.id);
  end if;
  return jsonb_build_object('code', acc.code, 'rev', acc.rev, 'data', acc.data, 'updated_at', acc.updated_at);
end $$;

-- Envoie les données. Si quelqu'un (un autre appareil) a écrit entre-temps,
-- renvoie conflict = true avec la version du serveur pour que l'appli fusionne.
create or replace function public.mfc_coach_push(p_data jsonb, p_rev integer, p_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := auth.uid();
  acc public.mfc_coach_accounts;
  r integer;
begin
  if u is null then raise exception 'auth'; end if;
  select a.* into acc from public.mfc_coach_accounts a
    join public.mfc_coach_devices d on d.account_id = a.id where d.uid = u
    for update of a;
  if not found then raise exception 'no_account'; end if;
  if acc.rev <> p_rev then
    return jsonb_build_object('conflict', true, 'rev', acc.rev, 'data', acc.data);
  end if;
  update public.mfc_coach_accounts
     set data = p_data, rev = rev + 1, updated_at = now(),
         name = coalesce(nullif(left(trim(p_name), 40), ''), name)
   where id = acc.id
   returning rev into r;
  return jsonb_build_object('rev', r);
end $$;

-- Rattache cet appareil au compte d'un code de récupération (nouveau téléphone)
create or replace function public.mfc_coach_claim(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := auth.uid();
  acc public.mfc_coach_accounts;
  c text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if u is null then raise exception 'auth'; end if;
  if char_length(c) <> 12 then return jsonb_build_object('error', 'code'); end if;
  c := substr(c, 1, 4) || '-' || substr(c, 5, 4) || '-' || substr(c, 9, 4);
  select * into acc from public.mfc_coach_accounts where code = c;
  if not found then return jsonb_build_object('error', 'code'); end if;
  -- L'ancien compte de cet appareil n'est PAS supprimé : il reste récupérable avec son propre code.
  insert into public.mfc_coach_devices(uid, account_id) values (u, acc.id)
    on conflict (uid) do update set account_id = excluded.account_id, created_at = now();
  return jsonb_build_object('code', acc.code, 'rev', acc.rev, 'data', acc.data);
end $$;

revoke all on function public.mfc_coach_newcode() from public, anon, authenticated;
revoke all on function public.mfc_coach_open() from public, anon;
revoke all on function public.mfc_coach_push(jsonb, integer, text) from public, anon;
revoke all on function public.mfc_coach_claim(text) from public, anon;
grant execute on function public.mfc_coach_open() to authenticated;
grant execute on function public.mfc_coach_push(jsonb, integer, text) to authenticated;
grant execute on function public.mfc_coach_claim(text) to authenticated;
