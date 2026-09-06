-- =========================================================
-- Migration : choix de la date de visite par le représentant via un
-- calendrier (au lieu de l'attribution automatique du prochain jour libre)
-- À exécuter UNE FOIS dans Supabase → SQL Editor, sur un projet où
-- schema.sql (+ migrations précédentes) a déjà été exécuté.
-- =========================================================

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

-- Ces trois fonctions sont destinées aux représentants (comme
-- rep_book_appointment) : accès public via la clé anon, aucune donnée
-- personnelle exposée (rep_get_availability ne renvoie que des compteurs).
grant execute on function rep_get_existing_appointment(text) to anon, authenticated;
grant execute on function rep_get_availability(date, int) to anon, authenticated;
grant execute on function rep_book_appointment_on_date(text, date) to anon, authenticated;

-- =========================================================
-- Fin. Côté index.html, le bouton "Choisir ma date de visite" ouvre
-- désormais un calendrier au lieu de réserver automatiquement.
-- =========================================================
