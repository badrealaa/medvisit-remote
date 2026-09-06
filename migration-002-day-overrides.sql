-- =========================================================
-- Migration : gestion d'un jour précis (fermeture exceptionnelle,
-- quota de représentants différent du réglage global pour ce jour)
-- À exécuter UNE FOIS dans Supabase → SQL Editor, sur un projet où
-- schema.sql (et éventuellement migration-001) a déjà été exécuté.
-- =========================================================

-- ---------- Table ----------

create table if not exists day_overrides (
  date date primary key,
  closed boolean not null default false,
  max_per_day int,
  updated_at timestamptz not null default now()
);

alter table day_overrides enable row level security;

drop policy if exists "cabinet full access day_overrides" on day_overrides;
create policy "cabinet full access day_overrides" on day_overrides
  for all to authenticated using (true) with check (true);

revoke all on day_overrides from anon;
grant select, insert, update, delete on day_overrides to authenticated;

-- ---------- Jours ouvrables : prend en compte une fermeture ponctuelle ----------

create or replace function is_business_day(d date)
returns boolean language plpgsql stable as $$
declare
  dow int;
  mmdd text;
  mobile jsonb;
  v_closed boolean;
begin
  dow := extract(dow from d);
  if dow = 0 or dow = 6 then return false; end if;

  mmdd := to_char(d, 'MM-DD');
  if mmdd in ('01-01','01-11','05-01','07-30','08-14','08-20','08-21','11-06','11-18') then
    return false;
  end if;

  select value into mobile from settings where key = 'mobile_holidays';
  if mobile is not null and mobile ? to_char(d, 'YYYY-MM-DD') then
    return false;
  end if;

  select closed into v_closed from day_overrides where date = d;
  if v_closed then return false; end if;

  return true;
end;
$$;

-- ---------- Quota effectif par jour (réglage ponctuel > réglage global) ----------

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

-- rep_get_max_per_day passe de 0 à 1 paramètre (avec valeur par défaut) :
-- signature différente, donc "create or replace" ne suffit pas, il faut
-- explicitement supprimer l'ancienne version d'abord.
drop function if exists rep_get_max_per_day();

create or replace function rep_get_max_per_day(p_date date default current_date)
returns int
language plpgsql security definer set search_path = public stable as $$
begin
  return effective_max_per_day(p_date);
end;
$$;

grant execute on function rep_get_max_per_day(date) to anon, authenticated;

-- ---------- Réservation : quota recalculé par date candidate ----------

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

    perform pg_advisory_xact_lock(hashtext(v_date::text));

    v_max_per_day := effective_max_per_day(v_date);

    select count(*) into v_count from appointments where date = v_date and status = 'confirmed';
    select exists(
      select 1 from appointments
      where date = v_date and status = 'confirmed'
        and lower(laboratoire) = lower(v_rep.laboratoire)
    ) into v_lab_used;

    if v_count < v_max_per_day and not v_lab_used then
      v_slot := 600 + v_count * 30;
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

-- =========================================================
-- Fin. Dans le tableau de bord Cabinet (medecin.html), onglet Planning,
-- utilisez la carte "Gérer une journée précise" pour fermer un jour ou
-- lui appliquer un quota différent.
-- =========================================================
