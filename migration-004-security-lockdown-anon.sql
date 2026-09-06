-- =========================================================
-- Migration : verrouillage des fonctions réservées au Cabinet
-- (correctif de sécurité — déjà appliqué manuellement le 2026-09-06,
-- ce fichier documente le correctif pour l'historique et pour tout
-- nouveau projet qui repartirait d'une base créée avant cette date)
-- =========================================================

-- Constat : Supabase accorde par défaut le droit d'exécution directement
-- au rôle "anon" sur les nouvelles fonctions du schéma public,
-- indépendamment du rôle PUBLIC. Un simple "revoke ... from public" (utilisé
-- dans les versions précédentes de schema.sql) ne suffit donc PAS à bloquer
-- "anon" — il faut révoquer explicitement "anon" en plus de "public".
--
-- Conséquence avant ce correctif : admin_approve_request (dès la création
-- du projet), puis admin_create_representative et generate_rep_code (dès
-- migration-003) étaient appelables par n'importe quel visiteur anonyme
-- muni de la clé publique "anon" — sans authentification Cabinet.

revoke execute on function admin_approve_request(uuid) from anon, public;
revoke execute on function admin_create_representative(text, text, text, text) from anon, public;
revoke execute on function generate_rep_code(text) from anon, authenticated, public;

grant execute on function admin_approve_request(uuid) to authenticated;
grant execute on function admin_create_representative(text, text, text, text) to authenticated;
-- generate_rep_code() n'est réaccordée à personne : usage interne uniquement.

-- =========================================================
-- Vérification recommandée après exécution (avec la clé "anon", sans
-- authentification) — chacun de ces appels doit renvoyer une erreur
-- "permission denied" (code 42501) :
--   POST /rest/v1/rpc/admin_approve_request
--   POST /rest/v1/rpc/admin_create_representative
--   POST /rest/v1/rpc/generate_rep_code
-- =========================================================
