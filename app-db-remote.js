/*
 * Couche de données — version À DISTANCE (Supabase).
 * Expose exactement la même interface que app-db.js (version locale
 * IndexedDB) afin que index.html / medecin.html n'aient presque rien à
 * changer : seules les pages de ce dossier remote/ chargent ce fichier
 * à la place de ../app-db.js.
 *
 * Toute la logique métier (quota, anti-doublon labo, jours fériés,
 * créneaux) est appliquée côté serveur (fonctions SQL dans schema.sql) —
 * ce fichier ne fait que transmettre les appels réseau.
 */
(function (global) {
  "use strict";

  if (!window.SUPABASE_URL || window.SUPABASE_URL.includes("VOTRE-PROJET")) {
    console.warn("⚠️ supabase-config.js n'est pas encore renseigné. Voir SETUP-SUPABASE.md.");
  }

  const client = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);

  const SLOT_MINUTES = 30;
  const MAX_PER_DAY = 6;
  const DAY_SLOTS = [600, 630, 660, 690, 720, 750, 780, 810, 840];

  function pad2(n) { return String(n).padStart(2, "0"); }
  function toDateKey(d) { return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`; }
  function fromDateKey(key) { const [y, m, d] = key.split("-").map(Number); return new Date(y, m - 1, d); }
  function formatDateFR(key) { return fromDateKey(key).toLocaleDateString("fr-FR", { weekday: "long", year: "numeric", month: "long", day: "numeric" }); }
  function minutesToLabel(min) { return `${pad2(Math.floor(min / 60))}h${pad2(min % 60)}`; }

  function registrationWindowStatus(now = new Date()) {
    const minutesNow = now.getHours() * 60 + now.getMinutes();
    const open = minutesNow >= 600 && minutesNow < 840;
    return { open, startLabel: "10h00", endLabel: "14h00", minutesNow };
  }

  function mapAppointment(row) {
    if (!row) return null;
    return {
      id: row.id,
      tracking: row.tracking,
      repCode: row.rep_code,
      nom: row.nom,
      prenom: row.prenom,
      laboratoire: row.laboratoire,
      date: row.date,
      slotMinutes: row.slot_minutes,
      status: row.status,
      createdAt: row.created_at,
      cancelledAt: row.cancelled_at,
      cancelReason: row.cancel_reason,
    };
  }
  function mapRep(row) {
    // rep_find_by_code renvoie un "row type" Postgres : quand aucune ligne
    // ne correspond, certaines versions de PostgREST sérialisent la
    // composite NULL en { id: null, code: null, ... } plutôt qu'en JSON
    // null. "code" est NOT NULL dans le schéma, donc code === null signifie
    // sans ambiguïté "aucun représentant trouvé".
    if (!row || row.code === null || row.code === undefined) return null;
    return { id: row.id, code: row.code, nom: row.nom, prenom: row.prenom, laboratoire: row.laboratoire, telephone: row.telephone, banned: row.banned, createdAt: row.created_at };
  }
  function mapRequest(row) {
    return { id: row.id, nom: row.nom, prenom: row.prenom, laboratoire: row.laboratoire, telephone: row.telephone, status: row.status, generatedCode: row.generated_code, createdAt: row.created_at };
  }

  // Exécute un appel Supabase et normalise TOUTE défaillance (erreur
  // renvoyée dans { error }, mais aussi une exception réseau brute comme
  // "TypeError: Failed to fetch" quand le serveur est injoignable) en un
  // objet { data, error } homogène, jamais en exception non interceptée.
  async function safe(promise) {
    try {
      return await promise;
    } catch (e) {
      return { data: null, error: { message: String(e && e.message || e), network: true } };
    }
  }

  function throwIfError(error) {
    if (!error) return;
    const msg = (error.message || "").toUpperCase();
    if (msg.includes("CODE_INVALIDE")) throw new Error("Code invalide.");
    if (msg.includes("BANNI")) throw new Error("Accès suspendu.");
    if (msg.includes("AUCUN_CRENEAU")) throw new Error("Aucun créneau disponible dans les prochains mois.");
    if (msg.includes("INTROUVABLE") && !msg.includes("DEMANDE")) throw new Error("Aucun rendez-vous trouvé avec ce numéro de suivi.");
    if (msg.includes("DEJA_ANNULE")) throw new Error("Ce rendez-vous est déjà annulé.");
    if (msg.includes("DEMANDE_INTROUVABLE")) throw new Error("Demande introuvable");
    // Toute autre défaillance (réseau, configuration, erreur serveur
    // imprévue) : message générique, jamais le détail technique brut.
    throw new Error("Connexion au serveur impossible. Vérifiez votre connexion Internet et réessayez.");
  }

  // ---------- Représentant (clé publique anon, via fonctions RPC) ----------

  async function findRepByCode(code) {
    const { data, error } = await safe(client.rpc("rep_find_by_code", { p_code: code }));
    if (error) throwIfError(error);
    return mapRep(data);
  }

  async function createCodeRequest({ nom, prenom, laboratoire, telephone }) {
    const { error } = await safe(client.rpc("rep_create_code_request", { p_nom: nom, p_prenom: prenom, p_laboratoire: laboratoire, p_telephone: telephone }));
    if (error) throwIfError(error);
  }

  async function bookAppointment({ repCode }) {
    const { data, error } = await safe(client.rpc("rep_book_appointment", { p_rep_code: repCode }));
    if (error) throwIfError(error);
    return mapAppointment(data);
  }

  async function cancelAppointment(tracking) {
    const { data, error } = await safe(client.rpc("rep_cancel_appointment", { p_tracking: tracking }));
    if (error) throwIfError(error);
    return mapAppointment(data);
  }

  async function listAllAppointments() {
    // Utilisé côté représentant uniquement pour vérifier un rendez-vous
    // déjà actif ; côté anon cette table n'est pas lisible directement
    // (RLS), donc on redérive l'info depuis rep_find_by_code + tracking
    // n'est pas nécessaire ici : l'app représentant appelle plutôt
    // bookAppointment(), qui renvoie déjà le rendez-vous existant s'il y
    // en a un (voir schema.sql). Cette fonction n'est utile que côté
    // Cabinet (utilisateur authentifié) — voir listAllAppointmentsAdmin.
    throw new Error("Non disponible côté représentant en mode distant.");
  }

  // ---------- Cabinet (utilisateur authentifié Supabase Auth) ----------

  async function adminLogin(email, password) {
    const { error } = await safe(client.auth.signInWithPassword({ email, password }));
    if (error) throw new Error(error.network ? "Connexion au serveur impossible. Vérifiez votre connexion Internet et réessayez." : "Email ou mot de passe incorrect.");
  }
  async function adminLogout() { await safe(client.auth.signOut()); }
  async function adminSession() { const { data } = await safe(client.auth.getSession()); return data ? data.session : null; }
  async function adminChangePassword(newPassword) {
    const { error } = await safe(client.auth.updateUser({ password: newPassword }));
    if (error) throwIfError(error);
  }

  async function listAllAppointmentsAdmin() {
    const { data, error } = await safe(client.from("appointments").select("*").order("date").order("slot_minutes"));
    if (error) throwIfError(error);
    return data.map(mapAppointment);
  }
  async function appointmentsForDay(dateKey) {
    const { data, error } = await safe(client.from("appointments").select("*").eq("date", dateKey).eq("status", "confirmed"));
    if (error) throwIfError(error);
    return data.map(mapAppointment);
  }
  async function cancelAppointmentById(id, reason) {
    const { error } = await safe(client.from("appointments").update({ status: "cancelled", cancelled_at: new Date().toISOString(), cancel_reason: reason || "Annulé par le cabinet" }).eq("id", id));
    if (error) throwIfError(error);
  }

  async function listCodeRequests(status = "pending") {
    let q = client.from("code_requests").select("*").order("created_at", { ascending: false });
    if (status) q = q.eq("status", status);
    const { data, error } = await safe(q);
    if (error) throwIfError(error);
    return data.map(mapRequest);
  }
  async function approveCodeRequest(requestId) {
    const { data, error } = await safe(client.rpc("admin_approve_request", { p_request_id: requestId }));
    if (error) throwIfError(error);
    return data;
  }
  async function rejectCodeRequest(requestId) {
    const { error } = await safe(client.from("code_requests").update({ status: "rejected" }).eq("id", requestId));
    if (error) throwIfError(error);
  }

  async function listRepresentatives() {
    const { data, error } = await safe(client.from("representatives").select("*").order("created_at", { ascending: false }));
    if (error) throwIfError(error);
    return data.map(mapRep);
  }
  async function setRepBanned(repId, banned) {
    const { error } = await safe(client.from("representatives").update({ banned }).eq("id", repId));
    if (error) throwIfError(error);
  }

  async function getMobileHolidays() {
    const { data, error } = await safe(client.from("settings").select("value").eq("key", "mobile_holidays").maybeSingle());
    if (error) throwIfError(error);
    return data ? data.value : [];
  }
  async function setMobileHolidays(list) {
    const { error } = await safe(client.from("settings").upsert({ key: "mobile_holidays", value: list }));
    if (error) throwIfError(error);
  }

  async function getMaxPerDay(dateKey) {
    // Passe par une fonction RPC (pas un accès direct à la table settings,
    // bloqué par RLS pour la clé anon) : lisible aussi bien côté
    // représentant que côté Cabinet. Sans date, renvoie le quota du jour
    // même (côté serveur : current_date) ; avec date, celui de ce jour
    // précis (tient compte d'un éventuel réglage ponctuel, voir day_overrides).
    const { data, error } = await safe(client.rpc("rep_get_max_per_day", dateKey ? { p_date: dateKey } : {}));
    if (error) throwIfError(error);
    const n = Number(data);
    return Number.isFinite(n) ? n : MAX_PER_DAY;
  }
  async function setMaxPerDay(n) {
    const clamped = Math.max(1, Math.min(DAY_SLOTS.length, Math.round(n)));
    const { error } = await safe(client.from("settings").upsert({ key: "max_per_day", value: clamped }));
    if (error) throwIfError(error);
    return clamped;
  }

  // ---------- Réglages ponctuels par jour précis (fermeture, quota) ----------
  // Nécessite migration-002-day-overrides.sql sur le projet Supabase — tant
  // qu'elle n'a pas été exécutée, ces appels échouent proprement (message
  // générique via throwIfError), sans casser le reste de l'application.

  async function getDayInfo(dateKey) {
    const { data, error } = await safe(client.from("day_overrides").select("*").eq("date", dateKey).maybeSingle());
    if (error) throwIfError(error);
    const closed = !!(data && data.closed);
    const customQuota = !!(data && data.max_per_day !== null && data.max_per_day !== undefined);
    const [maxPerDay, appts] = await Promise.all([getMaxPerDay(dateKey), appointmentsForDay(dateKey)]);
    return { closed, customQuota, maxPerDay, count: appts.length };
  }
  async function setDayClosed(dateKey, closed) {
    const { error } = await safe(client.from("day_overrides").upsert({ date: dateKey, closed }));
    if (error) throwIfError(error);
  }
  async function setDayMaxPerDay(dateKey, n) {
    const clamped = Math.max(1, Math.min(DAY_SLOTS.length, Math.round(n)));
    const { error } = await safe(client.from("day_overrides").upsert({ date: dateKey, max_per_day: clamped }));
    if (error) throwIfError(error);
    return clamped;
  }
  async function clearDayMaxPerDay(dateKey) {
    const { error } = await safe(client.from("day_overrides").upsert({ date: dateKey, max_per_day: null }));
    if (error) throwIfError(error);
  }

  global.CabinetDB = {
    SLOT_MINUTES, MAX_PER_DAY, DAY_SLOTS,
    toDateKey, fromDateKey, formatDateFR, minutesToLabel, registrationWindowStatus,
    findRepByCode, createCodeRequest, bookAppointment, cancelAppointment,
    listAllAppointments, // volontairement indisponible côté représentant (voir ci-dessus)
    // API additionnelle spécifique au mode distant, utilisée par medecin.html :
    adminLogin, adminLogout, adminSession, adminChangePassword,
    listAllAppointmentsAdmin, appointmentsForDay, cancelAppointmentById,
    listCodeRequests, approveCodeRequest, rejectCodeRequest,
    listRepresentatives, setRepBanned,
    getMobileHolidays, setMobileHolidays, getMaxPerDay, setMaxPerDay,
    getDayInfo, setDayClosed, setDayMaxPerDay, clearDayMaxPerDay,
  };
})(window);
