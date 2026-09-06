-- =========================================================
-- MedVisit — Schéma Supabase (version à distance, multi-appareils)
-- À exécuter une seule fois dans Supabase → SQL Editor → New query → Run
-- =========================================================

create extension if not exists pgcrypto;

-- Les fonctions ci-dessous utilisent current_date pour trouver le prochain
-- jour disponible : on fixe le fuseau horaire de la base sur celui du
-- cabinet pour que "aujourd'hui" corresponde toujours à la date locale
-- au Maroc, même pour les appels reçus juste après minuit UTC.
alter database postgres set timezone to 'Africa/Casablanca';

-- ---------- Tables ----------

create table representatives (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  nom text not null,
  prenom text not null,
  laboratoire text not null,
  telephone text not null,
  banned boolean not null default false,
  created_at timestamptz not null default now()
);

create table code_requests (
  id uuid primary key default gen_random_uuid(),
  nom text not null,
  prenom text not null,
  laboratoire text not null,
  telephone text not null,
  status text not null default 'pending',
  generated_code text,
  created_at timestamptz not null default now()
);

create table appointments (
  id uuid primary key default gen_random_uuid(),
  tracking text unique not null,
  rep_code text not null,
  nom text not null,
  prenom text not null,
  laboratoire text not null,
  date date not null,
  slot_minutes int not null,
  status text not null default 'confirmed',
  created_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancel_reason text
);

-- Un seul représentant confirmé par laboratoire et par jour : appliqué
-- au niveau de la base (impossible à contourner, même en cas de double
-- réservation simultanée depuis deux téléphones différents).
create unique index one_lab_per_day on appointments (date, lower(laboratoire))
  where status = 'confirmed';

create table settings (
  key text primary key,
  value jsonb not null
);

insert into settings (key, value) values
  ('mobile_holidays', '["2026-03-19","2026-03-20","2026-05-26","2026-05-27","2026-06-16","2026-08-25"]'::jsonb),
  ('max_per_day', '6'::jsonb);

-- ---------- Jours ouvrables (week-ends + jours fériés marocains) ----------

create or replace function is_business_day(d date)
returns boolean language plpgsql stable as $$
declare
  dow int;
  mmdd text;
  mobile jsonb;
begin
  dow := extract(dow from d); -- 0 = dimanche, 6 = samedi
  if dow = 0 or dow = 6 then return false; end if;

  mmdd := to_char(d, 'MM-DD');
  if mmdd in ('01-01','01-11','05-01','07-30','08-14','08-20','08-21','11-06','11-18') then
    return false;
  end if;

  select value into mobile from settings where key = 'mobile_holidays';
  if mobile is not null and mobile ? to_char(d, 'YYYY-MM-DD') then
    return false;
  end if;

  return true;
end;
$$;

create or replace function next_business_day(d date)
returns date language plpgsql stable as $$
declare
  nd date := d + 1;
  guard int := 0;
begin
  while not is_business_day(nd) and guard < 60 loop
    nd := nd + 1;
    guard := guard + 1;
  end loop;
  return nd;
end;
$$;

-- ---------- Fonctions représentant (exposées à la clé publique "anon") ----------

create or replace function rep_find_by_code(p_code text)
returns representatives
language sql security definer set search_path = public stable as $$
  select * from representatives where code = upper(trim(p_code)) limit 1;
$$;

create or replace function rep_create_code_request(p_nom text, p_prenom text, p_laboratoire text, p_telephone text)
returns void
language sql security definer set search_path = public as $$
  insert into code_requests (nom, prenom, laboratoire, telephone)
  values (trim(p_nom), trim(p_prenom), trim(p_laboratoire), trim(p_telephone));
$$;

-- Lecture publique du quota du jour (settings n'est pas lisible directement
-- par la clé anon ; ce petit RPC en expose juste la valeur, sans rien
-- d'autre du contenu de la table).
create or replace function rep_get_max_per_day()
returns int
language plpgsql security definer set search_path = public stable as $$
declare
  v int;
begin
  select (value::text)::int into v from settings where key = 'max_per_day';
  if v is null then v := 6; end if;
  return greatest(1, least(9, v));
end;
$$;

-- Réservation atomique : verrou par date pour empêcher deux représentants
-- de dépasser le quota du jour en réservant au même instant. L'anti-doublon
-- labo est en plus garanti par l'index unique ci-dessus, indépendamment de
-- ce verrou (double sécurité). Le quota lui-même est lu dans settings
-- (réglable par le Cabinet, voir set_max_per_day), avec 6 par défaut.
create or replace function rep_book_appointment(p_rep_code text)
returns appointments
language plpgsql security definer set search_path = public as $$
declare
  v_rep representatives%rowtype;
  v_existing appointments%rowtype;
  v_date date;
  v_count int;
  v_lab_used boolean;
  v_slot int;
  v_tracking text;
  v_result appointments%rowtype;
  v_guard int := 0;
  v_max_per_day int;
begin
  select (value::text)::int into v_max_per_day from settings where key = 'max_per_day';
  if v_max_per_day is null then v_max_per_day := 6; end if;
  v_max_per_day := greatest(1, least(9, v_max_per_day)); -- 9 créneaux possibles max entre 10h00 et 14h30

  select * into v_rep from representatives where code = upper(trim(p_rep_code));
  if not found then
    raise exception 'CODE_INVALIDE';
  end if;
  if v_rep.banned then
    raise exception 'BANNI';
  end if;

  select * into v_existing from appointments
    where rep_code = v_rep.code and status = 'confirmed' and date >= current_date
    order by date, slot_minutes limit 1;
  if found then
    return v_existing;
  end if;

  v_date := current_date;
  loop
    v_guard := v_guard + 1;
    exit when v_guard > 120;

    if not is_business_day(v_date) then
      v_date := next_business_day(v_date);
      continue;
    end if;

    -- Sérialise les réservations concurrentes pour cette même date.
    perform pg_advisory_xact_lock(hashtext(v_date::text));

    select count(*) into v_count from appointments where date = v_date and status = 'confirmed';
    select exists(
      select 1 from appointments
      where date = v_date and status = 'confirmed'
        and lower(laboratoire) = lower(v_rep.laboratoire)
    ) into v_lab_used;

    if v_count < v_max_per_day and not v_lab_used then
      v_slot := 600 + v_count * 30; -- 600 min = 10h00, pas de 30 min
      v_tracking := 'RDV-' || (100000 + floor(random() * 900000))::int;
      insert into appointments (tracking, rep_code, nom, prenom, laboratoire, date, slot_minutes, status)
        values (v_tracking, v_rep.code, v_rep.nom, v_rep.prenom, v_rep.laboratoire, v_date, v_slot, 'confirmed')
        returning * into v_result;
      return v_result;
    end if;

    v_date := next_business_day(v_date);
  end loop;

  raise exception 'AUCUN_CRENEAU';
end;
$$;

create or replace function rep_cancel_appointment(p_tracking text)
returns appointments
language plpgsql security definer set search_path = public as $$
declare
  v_appt appointments%rowtype;
begin
  select * into v_appt from appointments where tracking = upper(trim(p_tracking));
  if not found then
    raise exception 'INTROUVABLE';
  end if;
  if v_appt.status = 'cancelled' then
    raise exception 'DEJA_ANNULE';
  end if;
  update appointments set status = 'cancelled', cancelled_at = now()
    where id = v_appt.id returning * into v_appt;
  return v_appt;
end;
$$;

-- ---------- Fonction Cabinet (réservée aux utilisateurs authentifiés) ----------

create or replace function admin_approve_request(p_request_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_req code_requests%rowtype;
  v_prefix text;
  v_code text;
  v_exists boolean;
begin
  select * into v_req from code_requests where id = p_request_id;
  if not found then
    raise exception 'DEMANDE_INTROUVABLE';
  end if;

  v_prefix := upper(regexp_replace(coalesce(v_req.laboratoire, 'REP'), '[^A-Za-zÀ-ÿ]', '', 'g'));
  v_prefix := regexp_replace(v_prefix, '[^A-Z]', '', 'g');
  if v_prefix = '' then v_prefix := 'REP'; end if;
  v_prefix := left(v_prefix, 8);

  loop
    v_code := v_prefix || '-' || (10 + floor(random() * 80))::int;
    select exists(select 1 from representatives where code = v_code) into v_exists;
    exit when not v_exists;
  end loop;

  insert into representatives (code, nom, prenom, laboratoire, telephone, banned)
    values (v_code, v_req.nom, v_req.prenom, v_req.laboratoire, v_req.telephone, false);

  update code_requests set status = 'approved', generated_code = v_code where id = p_request_id;

  return v_code;
end;
$$;

-- ---------- Sécurité : RLS + droits ----------

alter table representatives enable row level security;
alter table code_requests enable row level security;
alter table appointments enable row level security;
alter table settings enable row level security;

-- Par défaut (RLS activée, aucune policy pour "anon") : accès direct aux
-- tables totalement bloqué pour la clé publique. Les représentants ne
-- passent QUE par les fonctions RPC ci-dessus.
create policy "cabinet full access representatives" on representatives
  for all to authenticated using (true) with check (true);
create policy "cabinet full access code_requests" on code_requests
  for all to authenticated using (true) with check (true);
create policy "cabinet full access appointments" on appointments
  for all to authenticated using (true) with check (true);
create policy "cabinet full access settings" on settings
  for all to authenticated using (true) with check (true);

revoke all on all tables in schema public from anon;
-- Postgres accorde EXECUTE à PUBLIC par défaut sur toute nouvelle fonction :
-- il faut révoquer PUBLIC explicitement, sinon "anon" en hérite quand même
-- et pourrait appeler admin_approve_request sans être authentifié.
revoke all on all functions in schema public from public;

grant execute on function rep_find_by_code(text) to anon, authenticated;
grant execute on function rep_create_code_request(text, text, text, text) to anon, authenticated;
grant execute on function rep_book_appointment(text) to anon, authenticated;
grant execute on function rep_cancel_appointment(text) to anon, authenticated;
grant execute on function rep_get_max_per_day() to anon, authenticated;
grant execute on function admin_approve_request(uuid) to authenticated;

grant select, insert, update, delete on representatives, code_requests, appointments, settings to authenticated;

-- =========================================================
-- Fin du script. Étape suivante : créez le compte du médecin dans
-- Authentication → Users → Add user (voir SETUP-SUPABASE.md).
-- =========================================================
