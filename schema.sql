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

-- Réglages ponctuels par jour précis (fermeture exceptionnelle, ou quota de
-- représentants différent du réglage global) : une ligne par date concernée
-- seulement, absence de ligne = comportement par défaut pour ce jour.
create table day_overrides (
  date date primary key,
  closed boolean not null default false,
  max_per_day int,
  updated_at timestamptz not null default now()
);

-- ---------- Jours ouvrables (week-ends + jours fériés marocains) ----------

create or replace function is_business_day(d date)
returns boolean language plpgsql stable as $$
declare
  dow int;
  mmdd text;
  mobile jsonb;
  v_closed boolean;
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

  -- Fermeture exceptionnelle décidée par le Cabinet pour ce jour précis
  -- (voir day_overrides / effective_max_per_day) : traitée comme un jour
  -- férié, les représentants sont automatiquement redirigés au jour ouvrable
  -- suivant.
  select closed into v_closed from day_overrides where date = d;
  if v_closed then return false; end if;

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

-- Quota effectif pour un jour donné : le réglage spécifique à ce jour
-- (day_overrides.max_per_day) prime sur le réglage global (settings), pour
-- permettre au Cabinet de réduire/augmenter ponctuellement le nombre de
-- représentants un jour précis sans changer le réglage par défaut des
-- autres jours.
create or replace function effective_max_per_day(p_date date)
returns int language plpgsql stable as $$
declare
  v_override int;
  v_default int;
begin
  select max_per_day into v_override from day_overrides where date = p_date;
  if v_override is not null then
    return greatest(1, least(9, v_override));
  end if;
  select (value::text)::int into v_default from settings where key = 'max_per_day';
  if v_default is null then v_default := 6; end if;
  return greatest(1, least(9, v_default));
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

-- Lecture publique du quota effectif d'un jour donné (par défaut aujourd'hui) :
-- settings/day_overrides ne sont pas lisibles directement par la clé anon ;
-- ce petit RPC en expose juste la valeur calculée, sans rien d'autre du
-- contenu des tables.
create or replace function rep_get_max_per_day(p_date date default current_date)
returns int
language plpgsql security definer set search_path = public stable as $$
begin
  return effective_max_per_day(p_date);
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

    -- Quota recalculé à chaque date candidate : un réglage ponctuel
    -- (day_overrides) peut différer du réglage global d'un jour à l'autre.
    v_max_per_day := effective_max_per_day(v_date);

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

-- Renvoie le rendez-vous actif du représentant s'il en a déjà un, sans en
-- créer un nouveau — utilisé pour afficher directement son ticket existant
-- avant même d'ouvrir le calendrier de choix de date.
create or replace function rep_get_existing_appointment(p_rep_code text)
returns appointments
language plpgsql security definer set search_path = public stable as $$
declare
  v_rep representatives%rowtype;
  v_existing appointments%rowtype;
begin
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
  return v_existing;
end;
$$;

-- Disponibilité jour par jour sur une période, pour afficher le calendrier
-- de choix de date côté représentant. Ne renvoie que des compteurs — jamais
-- les noms des représentants déjà inscrits (confidentialité).
create or replace function rep_get_availability(p_from date default current_date, p_days int default 60)
returns table(day date, is_open boolean, max_per_day int, taken int, places_restantes int)
language plpgsql security definer set search_path = public stable as $$
declare
  d date;
  i int;
  v_max int;
  v_count int;
begin
  for i in 0..(greatest(1, least(p_days, 90)) - 1) loop
    d := p_from + i;
    if is_business_day(d) then
      v_max := effective_max_per_day(d);
      select count(*) into v_count from appointments where date = d and status = 'confirmed';
      day := d; is_open := true; max_per_day := v_max; taken := v_count; places_restantes := greatest(0, v_max - v_count);
    else
      day := d; is_open := false; max_per_day := 0; taken := 0; places_restantes := 0;
    end if;
    return next;
  end loop;
end;
$$;

-- Réservation sur une date choisie par le représentant lui-même (au lieu
-- de l'attribution automatique de rep_book_appointment). Mêmes règles
-- (quota du jour, un seul représentant par labo et par jour) mais avec un
-- message d'erreur explicite si la date choisie n'est pas disponible,
-- plutôt qu'un report silencieux vers un autre jour.
create or replace function rep_book_appointment_on_date(p_rep_code text, p_date date)
returns appointments
language plpgsql security definer set search_path = public as $$
declare
  v_rep representatives%rowtype;
  v_existing appointments%rowtype;
  v_count int;
  v_lab_used boolean;
  v_slot int;
  v_tracking text;
  v_result appointments%rowtype;
  v_max_per_day int;
begin
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

  if p_date < current_date then
    raise exception 'DATE_PASSEE';
  end if;
  if not is_business_day(p_date) then
    raise exception 'JOUR_FERME';
  end if;

  -- Même verrou que rep_book_appointment : sérialise les réservations
  -- concurrentes sur cette date précise.
  perform pg_advisory_xact_lock(hashtext(p_date::text));

  v_max_per_day := effective_max_per_day(p_date);
  select count(*) into v_count from appointments where date = p_date and status = 'confirmed';
  select exists(
    select 1 from appointments
    where date = p_date and status = 'confirmed' and lower(laboratoire) = lower(v_rep.laboratoire)
  ) into v_lab_used;

  if v_lab_used then
    raise exception 'LABO_DEJA_PRIS';
  end if;
  if v_count >= v_max_per_day then
    raise exception 'JOUR_COMPLET';
  end if;

  v_slot := 600 + v_count * 30;
  v_tracking := 'RDV-' || (100000 + floor(random() * 900000))::int;
  insert into appointments (tracking, rep_code, nom, prenom, laboratoire, date, slot_minutes, status)
    values (v_tracking, v_rep.code, v_rep.nom, v_rep.prenom, v_rep.laboratoire, p_date, v_slot, 'confirmed')
    returning * into v_result;
  return v_result;
end;
$$;

-- ---------- Fonction Cabinet (réservée aux utilisateurs authentifiés) ----------

-- Génère un code unique à partir du nom du laboratoire (préfixe) + un
-- nombre aléatoire — logique partagée par admin_approve_request (demande
-- en ligne validée) et admin_create_representative (création directe au
-- comptoir du cabinet).
create or replace function generate_rep_code(p_laboratoire text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_prefix text;
  v_code text;
  v_exists boolean;
begin
  v_prefix := upper(regexp_replace(coalesce(p_laboratoire, 'REP'), '[^A-Za-zÀ-ÿ]', '', 'g'));
  v_prefix := regexp_replace(v_prefix, '[^A-Z]', '', 'g');
  if v_prefix = '' then v_prefix := 'REP'; end if;
  v_prefix := left(v_prefix, 8);

  loop
    v_code := v_prefix || '-' || (10 + floor(random() * 80))::int;
    select exists(select 1 from representatives where code = v_code) into v_exists;
    exit when not v_exists;
  end loop;
  return v_code;
end;
$$;

create or replace function admin_approve_request(p_request_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_req code_requests%rowtype;
  v_code text;
begin
  select * into v_req from code_requests where id = p_request_id;
  if not found then
    raise exception 'DEMANDE_INTROUVABLE';
  end if;

  v_code := generate_rep_code(v_req.laboratoire);

  insert into representatives (code, nom, prenom, laboratoire, telephone, banned)
    values (v_code, v_req.nom, v_req.prenom, v_req.laboratoire, v_req.telephone, false);

  update code_requests set status = 'approved', generated_code = v_code where id = p_request_id;

  return v_code;
end;
$$;

-- Création directe d'un représentant par le Cabinet (accueil physique) :
-- pour les représentants qui préfèrent obtenir leur code sur place plutôt
-- que de passer par la demande en ligne (index.html → "Demander un accès").
create or replace function admin_create_representative(p_nom text, p_prenom text, p_laboratoire text, p_telephone text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_code text;
begin
  v_code := generate_rep_code(p_laboratoire);
  insert into representatives (code, nom, prenom, laboratoire, telephone, banned)
    values (v_code, trim(p_nom), trim(p_prenom), trim(p_laboratoire), trim(p_telephone), false);
  return v_code;
end;
$$;

-- ---------- Sécurité : RLS + droits ----------

alter table representatives enable row level security;
alter table code_requests enable row level security;
alter table appointments enable row level security;
alter table settings enable row level security;
alter table day_overrides enable row level security;

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
create policy "cabinet full access day_overrides" on day_overrides
  for all to authenticated using (true) with check (true);

revoke all on all tables in schema public from anon;
-- Postgres accorde EXECUTE à PUBLIC par défaut sur toute nouvelle fonction,
-- et Supabase accorde en plus EXECUTE directement au rôle "anon" par
-- défaut sur les objets du schéma public (indépendamment de PUBLIC) : il
-- faut donc révoquer explicitement des DEUX (public ET anon), sinon "anon"
-- garde un accès direct même après un "revoke ... from public" — vérifié
-- en pratique sur admin_approve_request, qui restait appelable sans
-- authentification malgré la ligne "from public" ci-dessous à elle seule.
revoke all on all functions in schema public from public, anon;

grant execute on function rep_find_by_code(text) to anon, authenticated;
grant execute on function rep_create_code_request(text, text, text, text) to anon, authenticated;
grant execute on function rep_book_appointment(text) to anon, authenticated;
grant execute on function rep_cancel_appointment(text) to anon, authenticated;
grant execute on function rep_get_max_per_day(date) to anon, authenticated;
grant execute on function rep_get_existing_appointment(text) to anon, authenticated;
grant execute on function rep_get_availability(date, int) to anon, authenticated;
grant execute on function rep_book_appointment_on_date(text, date) to anon, authenticated;
grant execute on function admin_approve_request(uuid) to authenticated;
grant execute on function admin_create_representative(text, text, text, text) to authenticated;
-- generate_rep_code() n'est volontairement accordée à personne directement :
-- elle n'est utilisée qu'en interne par les deux fonctions ci-dessus
-- (SECURITY DEFINER, donc exécutée avec les droits du propriétaire même
-- pour cet appel interne).

grant select, insert, update, delete on representatives, code_requests, appointments, settings, day_overrides to authenticated;

-- =========================================================
-- Fin du script. Étape suivante : créez le compte du médecin dans
-- Authentication → Users → Add user (voir SETUP-SUPABASE.md).
-- =========================================================
