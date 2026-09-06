-- =========================================================
-- Migration : création directe d'un représentant par le Cabinet
-- (accueil physique, sans passer par une demande en ligne)
-- À exécuter UNE FOIS dans Supabase → SQL Editor, sur un projet où
-- schema.sql (+ migrations précédentes) a déjà été exécuté.
-- =========================================================

-- Génère un code unique à partir du nom du laboratoire (préfixe) + un
-- nombre aléatoire — logique reprise de admin_approve_request, désormais
-- partagée avec admin_create_representative.
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

-- admin_approve_request réutilise désormais generate_rep_code (même
-- comportement qu'avant, juste factorisé).
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

-- Nouvelle fonction : création directe (accueil physique du cabinet).
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

grant execute on function admin_create_representative(text, text, text, text) to authenticated;

-- =========================================================
-- Fin. Dans le tableau de bord Cabinet (medecin.html), onglet
-- Représentants, utilisez la carte "Ajouter un représentant sur place"
-- pour générer un code immédiatement, sans demande en ligne préalable.
-- =========================================================
