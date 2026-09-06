-- =========================================================
-- Migration : quota de rendez-vous par jour réglable par le Cabinet
-- À exécuter UNE FOIS dans Supabase → SQL Editor, sur un projet où
-- schema.sql a déjà été exécuté (ne recrée pas les tables).
-- =========================================================

insert into settings (key, value) values ('max_per_day', '6'::jsonb)
  on conflict (key) do nothing;

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

grant execute on function rep_get_max_per_day() to anon, authenticated;

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
  v_max_per_day := greatest(1, least(9, v_max_per_day));

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
