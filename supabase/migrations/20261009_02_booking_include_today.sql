-- Booking includes today: slots later today can be booked; slots whose time has passed show as 'past'.
-- Applied 2026-10-09

create or replace function public.slot_board(p_from date, p_to date)
returns table(staff_id uuid, slot_date date, slot_time time, state text)
language sql stable security definer set search_path to '' as $$
  select a.staff_id, a.avail_date, s::time,
         case when x.patient_id = auth.uid() then 'mine' when x.id is not null then 'booked'
              when a.avail_date = (now() at time zone 'Africa/Harare')::date and s::time <= (now() at time zone 'Africa/Harare')::time then 'past'
              else 'free' end
  from public.staff_availability a
  join public.profiles pr on pr.id = a.staff_id and pr.role = 'doctor' and coalesce(pr.active, true)
  cross join lateral generate_series(a.avail_date + a.start_time, a.avail_date + a.end_time - interval '30 minutes', interval '30 minutes') s
  left join lateral (select y.id, y.patient_id from public.appointments y
                      where y.staff_id = a.staff_id and y.appt_date = a.avail_date and y.appt_time = s::time
                        and y.status in ('pending','scheduled','waiting','with_nurse','with_doctor','lab') limit 1) x on true
  where auth.uid() is not null
    and a.avail_date between greatest(p_from, (now() at time zone 'Africa/Harare')::date)
                         and least(p_to, (now() at time zone 'Africa/Harare')::date + 90)
    and not exists (select 1 from public.staff_leave l where l.staff_id = a.staff_id and a.avail_date between l.start_date and l.end_date)
  order by 2, 3, 1
$$;

create or replace function public.open_slots(p_from date, p_to date, p_staff uuid default null)
returns table(staff_id uuid, slot_date date, slot_time time without time zone)
language sql stable security definer set search_path to '' as $$
  select a.staff_id, a.avail_date, s::time
  from public.staff_availability a
  join public.profiles pr on pr.id = a.staff_id and pr.role = 'doctor' and coalesce(pr.active, true)
  cross join lateral generate_series(a.avail_date + a.start_time, a.avail_date + a.end_time - interval '30 minutes', interval '30 minutes') s
  where a.avail_date between greatest(p_from, (now() at time zone 'Africa/Harare')::date) and least(p_to, (now() at time zone 'Africa/Harare')::date + 90)
    and (p_staff is null or a.staff_id = p_staff)
    and not (a.avail_date = (now() at time zone 'Africa/Harare')::date and s::time <= (now() at time zone 'Africa/Harare')::time)
    and not exists (select 1 from public.staff_leave l where l.staff_id = a.staff_id and a.avail_date between l.start_date and l.end_date)
    and not exists (select 1 from public.appointments x where x.staff_id = a.staff_id and x.appt_date = a.avail_date and x.appt_time = s::time
                    and x.status in ('pending','scheduled','waiting','with_nurse','with_doctor','lab'))
  order by 2, 3, 1
$$;

create or replace function public.public_availability(p_from date, p_to date)
returns table(staff_id uuid, avail_date date, start_time time, end_time time, total_slots int, free_slots int)
language sql stable security definer set search_path to '' as $$
  select a.staff_id, a.avail_date, a.start_time, a.end_time,
         (extract(epoch from (a.end_time - a.start_time)) / 1800)::int,
         (select count(*)::int from public.open_slots(a.avail_date, a.avail_date, a.staff_id) s
           where s.slot_time >= a.start_time and s.slot_time < a.end_time)
  from public.staff_availability a
  join public.profiles pr on pr.id = a.staff_id and pr.role = 'doctor' and coalesce(pr.active, true)
  where auth.uid() is not null
    and a.avail_date between greatest(p_from, (now() at time zone 'Africa/Harare')::date)
                         and least(p_to, (now() at time zone 'Africa/Harare')::date + 90)
    and not exists (select 1 from public.staff_leave l where l.staff_id = a.staff_id and a.avail_date between l.start_date and l.end_date)
  order by 2, 3, 1
$$;

create or replace function public.appt_guard()
 returns trigger language plpgsql security definer set search_path to '' as $function$
declare t date := (now() at time zone 'Africa/Harare')::date; nt time := (now() at time zone 'Africa/Harare')::time;
begin
  if public.is_doctor() then
    if not public.is_physician() and new.status in ('lab','done') and (tg_op = 'INSERT' or old.status is distinct from new.status) then
      raise exception 'Only a doctor can send a patient to the lab or complete a visit';
    end if;
    return new;
  end if;
  if new.patient_id is distinct from auth.uid() then raise exception 'Not allowed'; end if;
  if tg_op = 'UPDATE' then
    if old.patient_id <> new.patient_id then raise exception 'Not allowed'; end if;
    if old.status not in ('pending','scheduled') then raise exception 'This appointment can no longer be changed'; end if;
    if old.status = 'scheduled' and old.appt_date <= t then raise exception 'This appointment can no longer be changed'; end if;
    if new.status not in ('pending','cancelled') then raise exception 'Not allowed'; end if;
    if new.triage_level is distinct from old.triage_level or new.complaint is distinct from old.complaint or new.handover_note is distinct from old.handover_note or new.handover_by is distinct from old.handover_by or new.triaged_at is distinct from old.triaged_at then raise exception 'Not allowed'; end if;
    if new.status = 'pending' and (new.appt_date < t or (new.appt_date = t and (new.appt_time is null or new.appt_time <= nt))) then raise exception 'Choose a time that has not passed yet'; end if;
  else
    if new.status <> 'pending' or new.triage_level is not null or new.complaint is not null or new.handover_note is not null or new.handover_by is not null or new.triaged_at is not null then raise exception 'Not allowed'; end if;
    if new.appt_date < t or (new.appt_date = t and (new.appt_time is null or new.appt_time <= nt)) then raise exception 'Choose a time that has not passed yet'; end if;
  end if;
  return new;
end $function$;
