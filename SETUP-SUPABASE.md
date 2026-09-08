# Mise en place — Version à distance (Supabase)

Suivez ces étapes dans l'ordre. Comptez environ 15 minutes. Aucune carte
bancaire n'est demandée (offre gratuite).

## 1. Créer le compte et le projet Supabase

1. Allez sur **https://supabase.com** → **Start your project** → créez un
   compte (email ou GitHub).
2. **New project** :
   - Nom : `medvisit` (ou ce que vous voulez)
   - Mot de passe de base de données : générez-en un et **conservez-le
     précieusement** (pas besoin de le ressaisir ensuite, mais gardez-le
     en cas de besoin).
   - Région : choisissez la plus proche du Maroc (ex. **Europe West**)
     pour la meilleure latence et un hébergement des données en Europe.
3. Attendez ~2 minutes que le projet soit provisionné.

## 2. Exécuter le script de base de données

1. Dans le menu de gauche du tableau de bord Supabase : **SQL Editor**.
2. **New query**.
3. Ouvrez le fichier [schema.sql](schema.sql) de ce dossier, copiez tout
   son contenu, collez-le dans l'éditeur.
4. Cliquez **Run**. Vous devez voir « Success. No rows returned ».

Cela crée les 4 tables, toutes les règles métier (quota, anti-doublon,
jours fériés) sous forme de fonctions côté serveur, et verrouille les
accès (row-level security).

## 3. Créer le compte du médecin (authentification)

1. Menu de gauche → **Authentication** → **Users** → **Add user** →
   **Create new user**.
2. Renseignez l'email et le mot de passe du Cabinet (ex.
   `cabinet@votredomaine.com`).
3. Cochez **Auto Confirm User** (pour ne pas avoir besoin de valider par
   email) → **Create user**.

C'est ce couple email/mot de passe qui sert à se connecter sur
`medecin.html`. Vous pourrez changer le mot de passe plus tard depuis
l'onglet Réglages de l'app elle-même.

## 4. ⚠️ Étape de sécurité obligatoire : bloquer les inscriptions publiques

Par défaut, Supabase autorise **n'importe qui** à créer un compte via
l'API (avec juste la clé publique `anon`). Or `schema.sql` donne à
**tout** utilisateur authentifié les droits du Cabinet (bannir un
représentant, générer des codes, voir toutes les données...). Sans cette
étape, un représentant un peu curieux pourrait créer son propre compte et
obtenir ces droits.

1. Menu de gauche → **Authentication** → **Sign In / Providers** (ou
   **Settings** selon la version de l'interface).
2. Trouvez l'option **« Allow new users to sign up »** (Email provider)
   et **désactivez-la**.

Résultat : seul le compte que vous avez créé manuellement à l'étape 3
(et ceux que vous créerez vous-même de la même façon) peut se connecter.
Personne ne peut s'auto-inscrire.

## 4bis. Autoriser le lien de réinitialisation de mot de passe

`medecin.html` propose un lien « Mot de passe oublié ? » qui envoie un
email de réinitialisation via Supabase. Pour que le lien reçu par email
ramène correctement vers l'app (au lieu d'être bloqué par Supabase) :

1. Menu de gauche → **Authentication** → **URL Configuration**.
2. Dans **Redirect URLs**, ajoutez l'URL exacte de votre `medecin.html`
   en ligne (ex. `https://VOTRE-PROJET.github.io/medvisit-remote/medecin.html`).
3. Enregistrez.

Sans cette étape, cliquer sur le lien reçu par email peut renvoyer vers
la mauvaise page ou afficher une erreur Supabase.

## 5. Récupérer les clés API

1. Menu de gauche → **Project Settings** (icône ⚙️) → **API**.
2. Copiez :
   - **Project URL** (ex. `https://abcdefgh.supabase.co`)
   - **anon / public key** (⚠️ pas la `service_role` — celle-ci ne doit
     jamais être utilisée dans le code de l'application)

## 6. Configurer l'application

Ouvrez [supabase-config.js](supabase-config.js) et remplacez :

```js
window.SUPABASE_URL = "https://VOTRE-PROJET.supabase.co";
window.SUPABASE_ANON_KEY = "VOTRE_CLE_ANON_PUBLIQUE";
```

par vos propres valeurs copiées à l'étape 4.

## 7. Tester en local

```bash
cd Representants/remote
python -m http.server 8080
```

- `http://localhost:8080/index.html` → espace représentant
- `http://localhost:8080/medecin.html` → espace Cabinet (connectez-vous
  avec l'email/mot de passe créés à l'étape 3)

Essayez : demander un code depuis `index.html`, l'approuver depuis
`medecin.html`, puis réserver avec le code généré. Vérifiez que le
rendez-vous apparaît bien dans l'onglet Planning.

> Rappel : contrairement à la version locale (IndexedDB), la réservation
> nécessite une connexion Internet active au moment de l'action — c'est
> normal, c'est le prix de la synchronisation entre plusieurs appareils.

## 8. Déployer et générer les APK

Une fois testé, hébergez le dossier `remote/` sur HTTPS (GitHub Pages,
Netlify, Vercel — voir [README.md](../README.md) pour le détail), puis
suivez la même procédure PWABuilder décrite dans le README pour générer
un APK à partir de `remote/index.html` (côté représentants) — le résultat
est un APK que vous pouvez distribuer à **tous les représentants**, sur
**leurs propres téléphones**, et ils verront tous le même planning en
temps réel.

Si vous voulez aussi un APK dédié pour le médecin (raccourci direct vers
`medecin.html` au lieu de `index.html`), générez un second package
PWABuilder pointant vers l'URL de `remote/medecin.html`, avec son propre
`manifest.json` (dupliquez `manifest.json` en changeant `start_url` vers
`./medecin.html` et le `name`).

## Sécurité — ce qui protège l'application

- **Le keystore Android** (généré par PWABuilder lors de la création de
  l'APK) est la vraie clé secrète à protéger : c'est elle qui signe
  l'app et prouve qu'une mise à jour vient bien de vous. À sauvegarder
  précieusement (gestionnaire de mots de passe, coffre numérique) —
  jamais sur GitHub, jamais partagée. Sa perte empêche toute mise à jour
  future sous la même identité d'app.
- **La clé Supabase `anon`** n'est pas un secret : elle est conçue pour
  être visible dans le code client (donc aussi dans l'APK décompilé).
  Ce qui protège réellement les données, ce sont les politiques RLS et
  les fonctions de `schema.sql`, pas la confidentialité de cette clé.
- **La clé `service_role`** (à récupérer sur le même écran que la clé
  `anon`) est un vrai secret qui contourne toutes les protections —
  elle n'est utilisée nulle part dans ce projet et ne doit jamais être
  mise dans un fichier client.
- **L'étape 4 ci-dessus** (bloquer les inscriptions publiques) est
  indispensable : sans elle, n'importe qui pourrait créer un compte et
  obtenir les droits du Cabinet.

## Limites à connaître

- **Offre Supabase gratuite** : le projet peut se mettre en pause après
  7 jours sans aucune requête. Comme le cabinet est utilisé chaque jour
  ouvrable, cela ne devrait jamais arriver en pratique ; si ça arrive,
  un simple clic sur « Restore » dans le tableau de bord Supabase suffit
  (les données ne sont pas perdues).
- **Pas de mode hors-ligne pour réserver** : consulter un ticket déjà
  obtenu fonctionne hors-ligne (mis en cache), mais réserver ou annuler
  nécessite une connexion Internet au moment de l'action.
- **anon key visible dans le code** : c'est normal et voulu — c'est une
  clé publique conçue pour être exposée côté client. La sécurité réelle
  vient des politiques RLS et des fonctions définies dans `schema.sql`,
  pas du secret de cette clé.
