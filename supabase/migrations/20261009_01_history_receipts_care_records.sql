-- Maternity Help: patient history, booking board, receipts, LMP, inventory types, nurse/midwife care records
-- Applied 2026-10-09

/* ===================== Booking board: every slot, free or booked ===================== */
create or replace function public.slot_board(p_from date, p_to date)
returns table(staff_id uuid, slot_date date, slot_time time, state text)
language sql stable security definer set search_path to '' as $$
  select a.staff_id, a.avail_date, s::time,
         case when x.patient_id = auth.uid() then 'mine' when x.id is not null then 'booked' else 'free' end
  from public.staff_availability a
  join public.profiles pr on pr.id = a.staff_id and pr.role = 'doctor' and coalesce(pr.active, true)
  cross join lateral generate_series(a.avail_date + a.start_time, a.avail_date + a.end_time - interval '30 minutes', interval '30 minutes') s
  left join lateral (select y.id, y.patient_id from public.appointments y
                      where y.staff_id = a.staff_id and y.appt_date = a.avail_date and y.appt_time = s::time
                        and y.status in ('pending','scheduled','waiting','with_nurse','with_doctor','lab') limit 1) x on true
  where auth.uid() is not null
    and a.avail_date between greatest(p_from, (now() at time zone 'Africa/Harare')::date + 1)
                         and least(p_to, (now() at time zone 'Africa/Harare')::date + 90)
    and not exists (select 1 from public.staff_leave l where l.staff_id = a.staff_id and a.avail_date between l.start_date and l.end_date)
  order by 2, 3, 1
$$;
revoke execute on function public.slot_board(date, date) from public, anon;
grant execute on function public.slot_board(date, date) to authenticated;

/* ===================== Booking notifications for every status ===================== */
create or replace function public.notify_appt()
 returns trigger language plpgsql security definer set search_path to '' as $function$
declare s text; k text; t text; body text; pr text := 'routine'; who text; wh text;
begin
  select name into s from public.services where id = new.service_id;
  select coalesce(staff_title, 'Doctor') || ' ' || full_name into who from public.profiles where id = new.staff_id;
  k := case when coalesce(s,new.kind) ilike '%ultra%' then 'ultrasound' when coalesce(s,new.kind) ilike '%lab%' then 'lab' when coalesce(s,new.kind) ilike '%follow%' then 'follow_up' else 'doctor_appointment' end;
  wh := coalesce(s, new.kind, 'Appointment') || ' on ' || to_char(new.appt_date, 'DD Mon YYYY') || coalesce(' at ' || to_char(new.appt_time, 'HH24:MI'), '') || coalesce(' with ' || who, '');
  if tg_op = 'INSERT' then
    if new.status = 'admitted' then
      t := 'Bed assigned'; pr := 'important';
      body := 'You have been given Bed ' || new.bed_no || ' from ' || to_char(new.appt_date, 'DD Mon YYYY') || ' for ' || new.bed_days || ' day(s).';
    elsif new.status = 'pending' then
      t := 'Booking received: Pending';
      body := 'We received your request for ' || wh || '. Status: Pending. You will get a confirmation when the administrator approves it.';
    elsif new.status = 'scheduled' then
      t := 'Appointment confirmed'; pr := 'important';
      body := wh || '. Status: Confirmed.';
    else return new; end if;
  elsif new.status is not distinct from old.status and new.appt_date = old.appt_date and new.appt_time is not distinct from old.appt_time then
    return new;
  elsif old.status = 'pending' and new.status = 'scheduled' then
    t := 'Appointment confirmed'; pr := 'important';
    body := wh || '. Status: Confirmed.' || coalesce(' Bed ' || new.bed_no || ' is reserved for ' || new.bed_days || ' day(s).', '') || coalesce(' ' || nullif(btrim(new.admin_comment), ''), '');
  elsif old.status = 'pending' and new.status = 'rejected' then
    t := 'Appointment request not accepted'; pr := 'important';
    body := 'Your request for ' || wh || ' was not accepted. Status: Cancelled.' || coalesce(' ' || nullif(btrim(new.admin_comment), ''), '') || ' Please book another time.';
  elsif new.status = 'cancelled' and old.status <> 'cancelled' then
    t := 'Appointment cancelled'; body := wh || '. Status: Cancelled.';
  elsif new.status = 'done' and old.status <> 'done' then
    t := 'Appointment completed'; body := wh || '. Status: Completed. Thank you for coming.';
  elsif new.status = 'missed' and old.status <> 'missed' then
    t := 'Missed appointment'; pr := 'important'; k := 'missed';
    body := wh || '. Status: Missed. Please book a new appointment.';
  elsif new.status = 'pending' and old.status = 'scheduled' then
    t := 'Reschedule request sent'; body := 'You asked to move your appointment to ' || wh || '. Status: Pending.';
  elsif new.status in ('scheduled','pending') and (new.appt_date <> old.appt_date or new.appt_time is distinct from old.appt_time) then
    t := 'Appointment rescheduled'; body := 'Your appointment is now ' || wh || '.';
  else return new; end if;
  insert into public.notifications (patient_id, kind, priority, title, body) values (new.patient_id, k, pr, t, left(body, 2000));
  return new;
end $function$;

/* ===================== Patient history: consultations ===================== */
create or replace function public.my_consultations()
returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', v.id, 'visit_date', v.visit_date,
    'staff', (select coalesce(p.staff_title, 'Doctor') || ' ' || p.full_name from public.profiles p where p.id = v.recorded_by),
    'weight_kg', v.weight_kg, 'bp_sys', v.bp_sys, 'bp_dia', v.bp_dia, 'temp_c', v.temp_c, 'pulse', v.pulse,
    'fetal_heart_rate', v.fetal_heart_rate, 'fundal_height_cm', v.fundal_height_cm,
    'symptoms', v.symptoms, 'treatment_plan', v.treatment_plan, 'next_appointment', v.next_appointment)
    order by v.visit_date desc, v.created_at desc), '[]'::jsonb)
  from public.visits v where v.patient_id = auth.uid()
$$;
revoke execute on function public.my_consultations() from public, anon;
grant execute on function public.my_consultations() to authenticated;

/* ===================== Receipts ===================== */
create or replace function public.my_receipts()
returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'date' desc, x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object('kind', 'receipt', 'id', r.id, 'no', r.receipt_no, 'date', r.received_on, 'created_at', r.created_at,
      'amount', r.amount, 'method', r.method, 'status', r.status, 'source', r.source_type) x
      from public.acc_receipts r where r.patient_id = auth.uid()
    union all
    select jsonb_build_object('kind', 'refund', 'id', f.id, 'no', f.refund_no, 'date', f.refunded_on, 'created_at', f.created_at,
      'amount', f.amount, 'method', f.method, 'status', f.status, 'source', 'refund')
      from public.acc_refunds f where f.patient_id = auth.uid()) q
$$;
revoke execute on function public.my_receipts() from public, anon;
grant execute on function public.my_receipts() to authenticated;

create or replace function public.receipt_doc(p_kind text, p_id uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare r public.acc_receipts; f public.acc_refunds; items jsonb; pid uuid; inv public.acc_invoices; hosp jsonb;
begin
  if auth.uid() is null then raise exception 'Not allowed'; end if;
  select jsonb_build_object('name', 'Maternity Help', 'currency', coalesce((select currency from public.acc_settings limit 1), 'USD'),
                            'tin', t.tin, 'vat_number', t.vat_number, 'bp_number', t.bp_number)
    into hosp from public.acc_tax_settings t limit 1;
  hosp := coalesce(hosp, jsonb_build_object('name', 'Maternity Help', 'currency', 'USD'));
  if p_kind = 'refund' then
    select * into f from public.acc_refunds where id = p_id;
    if not found then raise exception 'Receipt not found'; end if;
    pid := f.patient_id;
    if pid is distinct from auth.uid() and not public.is_admin() and not public.acc_can_view() then raise exception 'Not allowed'; end if;
    return jsonb_build_object('kind', 'refund', 'hospital', hosp,
      'doc', jsonb_build_object('no', f.refund_no, 'date', f.refunded_on, 'created_at', f.created_at, 'amount', f.amount, 'method', f.method, 'status', f.status, 'reason', f.reason),
      'patient', (select jsonb_build_object('name', coalesce(nullif(btrim(p.full_name), ''), f.patient_name), 'code', p.patient_code, 'phone', p.phone) from public.profiles p where p.id = pid),
      'invoice', (select jsonb_build_object('no', i.invoice_no) from public.acc_invoices i where i.id = f.invoice_id),
      'items', jsonb_build_array(jsonb_build_object('desc', 'Refund' || coalesce(': ' || nullif(btrim(f.reason), ''), ''), 'qty', 1, 'unit', f.amount, 'amount', f.amount, 'date', f.refunded_on)),
      'by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = f.created_by));
  end if;
  select * into r from public.acc_receipts where id = p_id;
  if not found then raise exception 'Receipt not found'; end if;
  pid := r.patient_id;
  if pid is distinct from auth.uid() and not public.is_admin() and not public.acc_can_view() then raise exception 'Not allowed'; end if;
  if r.source_type = 'bed_charge' then
    select jsonb_agg(jsonb_build_object('desc', c.item_name, 'qty', c.qty, 'unit', c.unit_price, 'amount', c.total, 'date', c.charged_on)) into items
      from public.bed_charges c where c.id = r.source_id;
  elsif r.source_type = 'ambulance' then
    select jsonb_build_array(jsonb_build_object('desc', 'Ambulance call-out', 'qty', 1, 'unit', r.amount, 'amount', r.amount, 'date', (a.requested_at at time zone 'Africa/Harare')::date)) into items
      from public.ambulance_requests a where a.id = r.source_id;
  elsif r.source_type = 'appointment' then
    select jsonb_build_array(jsonb_build_object('desc', coalesce(a.kind, 'Appointment') || ' fees', 'qty', 1, 'unit', r.amount, 'amount', r.amount, 'date', a.appt_date)) into items
      from public.appointments a where a.id = r.source_id;
  end if;
  select * into inv from public.acc_invoices where id = r.invoice_id;
  if items is null and inv.id is not null then
    select jsonb_agg(jsonb_build_object('desc', l.description, 'qty', coalesce(l.qty, 1), 'unit', coalesce(l.unit_price, l.amount), 'amount', l.amount, 'date', inv.issue_date) order by l.id) into items
      from public.acc_invoice_lines l where l.invoice_id = inv.id and l.active;
  end if;
  items := coalesce(items, jsonb_build_array(jsonb_build_object('desc', 'Payment received', 'qty', 1, 'unit', r.amount, 'amount', r.amount, 'date', r.received_on)));
  return jsonb_build_object('kind', 'receipt', 'hospital', hosp,
    'doc', jsonb_build_object('no', r.receipt_no, 'date', r.received_on, 'created_at', r.created_at, 'amount', r.amount, 'method', r.method, 'reference', r.reference, 'status', r.status),
    'patient', (select jsonb_build_object('name', coalesce(nullif(btrim(p.full_name), ''), r.patient_name), 'code', p.patient_code, 'phone', p.phone) from public.profiles p where p.id = pid),
    'invoice', case when inv.id is null then null else jsonb_build_object('no', inv.invoice_no,
                 'total', (select coalesce(sum(amount), 0) from public.acc_invoice_lines where invoice_id = inv.id and active),
                 'balance', public.acc__invoice_outstanding(inv.id)) end,
    'items', items,
    'by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = r.created_by));
end $$;
revoke execute on function public.receipt_doc(text, uuid) from public, anon;
grant execute on function public.receipt_doc(text, uuid) to authenticated;

/* ===================== Last menstrual period ===================== */
create or replace function public.set_lmp(p_patient uuid, p_lmp date)
returns date language plpgsql security definer set search_path to '' as $$
declare t date := (now() at time zone 'Africa/Harare')::date;
begin
  if auth.uid() is null or (p_patient is distinct from auth.uid() and not public.is_doctor()) then raise exception 'Not allowed'; end if;
  if not exists (select 1 from public.profiles where id = p_patient and role = 'patient') then raise exception 'Patient not found'; end if;
  if p_lmp is null then raise exception 'Enter the first day of the last menstrual period'; end if;
  if p_lmp > t then raise exception 'The LMP cannot be in the future'; end if;
  if p_lmp < t - 308 then raise exception 'The LMP must be within the last 44 weeks'; end if;
  update public.profiles set lmp = p_lmp where id = p_patient;
  return p_lmp;
end $$;
revoke execute on function public.set_lmp(uuid, date) from public, anon;
grant execute on function public.set_lmp(uuid, date) to authenticated;

/* ===================== Inventory: consumables, equipment and services ===================== */
alter table public.charge_items
  add column if not exists item_type text not null default 'consumable',
  add column if not exists expiry_date date,
  add column if not exists location text,
  add column if not exists batch_no text;
alter table public.charge_items add constraint charge_items_type_check check (item_type in ('consumable', 'equipment', 'service'));
alter table public.charge_items add constraint charge_items_location_check check (char_length(location) <= 60);
alter table public.charge_items add constraint charge_items_batch_check check (char_length(batch_no) <= 40);
update public.charge_items set item_type = 'service' where not track_stock;

create or replace function public.inv_items_guard()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if tg_op = 'INSERT' then
    new.track_stock := new.item_type <> 'service';
    new.stock_qty := case when new.track_stock then coalesce(new.stock_qty, 0) else 0 end;
    return new;
  end if;
  if new.item_type is distinct from old.item_type then raise exception 'The item type cannot be changed. Add a new item instead.'; end if;
  new.track_stock := old.track_stock;
  if new.stock_qty is distinct from old.stock_qty and coalesce(current_setting('mh.inv', true), '') <> '1' then
    raise exception 'Use Receive stock or Stock count to change quantities';
  end if;
  new.updated_at := now();
  return new;
end $$;

-- Equipment is counted but not used up when it is charged to a patient
create or replace function public.inv_charge_stock()
returns trigger language plpgsql security definer set search_path to '' as $$
declare it public.charge_items; d numeric;
begin
  if tg_op = 'INSERT' then
    if new.item_id is null then return new; end if;
    select * into it from public.charge_items where id = new.item_id for update;
    if not found then raise exception 'That item no longer exists'; end if;
    if not it.active then raise exception '% is no longer available', it.name; end if;
    new.item_name := it.name; new.category := it.category; new.unit_price := it.unit_price;
    if it.track_stock and it.item_type = 'consumable' then
      if it.stock_qty < new.qty then
        raise exception 'Not enough stock of %: % % left', it.name, public.acc__qty(it.stock_qty), it.unit;
      end if;
      perform set_config('mh.inv', '1', true);
      update public.charge_items set stock_qty = stock_qty - new.qty where id = it.id;
      perform set_config('mh.inv', '', true);
      insert into public.inv_movements (item_id, change, balance_after, reason, patient_id, charge_id)
        values (it.id, -new.qty, it.stock_qty - new.qty, 'used', new.patient_id, new.id);
    end if;
    return new;
  elsif tg_op = 'UPDATE' then
    if new.item_id is distinct from old.item_id then raise exception 'Void this charge and add a new one instead'; end if;
    if old.item_id is null then return new; end if;
    select * into it from public.charge_items where id = old.item_id for update;
    if not found or not it.track_stock or it.item_type <> 'consumable' then return new; end if;
    d := (case when old.voided then 0 else old.qty end) - (case when new.voided then 0 else new.qty end);
    if d = 0 then return new; end if;
    if d < 0 and it.stock_qty < -d then
      raise exception 'Not enough stock of %: % % left', it.name, public.acc__qty(it.stock_qty), it.unit;
    end if;
    perform set_config('mh.inv', '1', true);
    update public.charge_items set stock_qty = stock_qty + d where id = it.id;
    perform set_config('mh.inv', '', true);
    insert into public.inv_movements (item_id, change, balance_after, reason, patient_id, charge_id, note)
      values (it.id, d, it.stock_qty + d, case when d > 0 then 'returned' else 'used' end, new.patient_id, new.id,
              case when new.voided and not old.voided then 'Charge voided' else 'Charge changed' end);
    return new;
  else
    if old.item_id is null or old.voided then return old; end if;
    select * into it from public.charge_items where id = old.item_id for update;
    if not found or not it.track_stock or it.item_type <> 'consumable' then return old; end if;
    perform set_config('mh.inv', '1', true);
    update public.charge_items set stock_qty = stock_qty + old.qty where id = it.id;
    perform set_config('mh.inv', '', true);
    insert into public.inv_movements (item_id, change, balance_after, reason, patient_id, charge_id, note)
      values (it.id, old.qty, it.stock_qty + old.qty, 'returned', old.patient_id, old.id, 'Charge deleted');
    return old;
  end if;
end $$;

-- New categories post to the matching income accounts
insert into public.acc_revenue_map (source_kind, match_value, account_id)
select 'charge_category', v.cat, (select account_id from public.acc_revenue_map where source_kind = 'charge_category' and match_value = v.src)
from (values ('equipment', 'procedure'), ('ppe', 'supplies'), ('linen', 'supplies'), ('iv_fluids', 'medication'), ('vaccine', 'medication')) v(cat, src)
where not exists (select 1 from public.acc_revenue_map m where m.source_kind = 'charge_category' and m.match_value = v.cat)
  and exists (select 1 from public.acc_revenue_map where source_kind = 'charge_category' and match_value = v.src);

/* ===================== Nurse and midwife care records ===================== */
create or replace function public.profiles_guard()
 returns trigger language plpgsql security definer set search_path to '' as $function$
begin
  if auth.uid() is null then return new; end if;
  if coalesce(current_setting('mh.sys', true), '') = '1' then return new; end if;
  if public.is_admin() and new.id = auth.uid()
     and (new.full_name is distinct from old.full_name or new.phone is distinct from old.phone) then
    raise exception 'The administrator name and phone number cannot be changed from the app';
  end if;
  if public.is_admin() then return new; end if;
  if new.role is distinct from old.role or new.staff_title is distinct from old.staff_title or new.email is distinct from old.email or new.patient_code is distinct from old.patient_code or new.active is distinct from old.active then
    raise exception 'Not allowed';
  end if;
  if (new.admitted_at is distinct from old.admitted_at or new.status is distinct from old.status or new.delivered_on is distinct from old.delivered_on) and not public.is_physician() then
    raise exception 'Only a doctor can admit, discharge or mark a delivery';
  end if;
  return new;
end $function$;

create table if not exists public.deliveries (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.profiles(id) on delete cascade,
  pregnancy_id uuid references public.pregnancies(id) on delete set null,
  delivered_at timestamptz not null,
  mode text not null check (mode in ('svd', 'assisted', 'caesarean', 'breech', 'other')),
  outcome text not null default 'live_birth' check (outcome in ('live_birth', 'stillbirth', 'neonatal_death')),
  baby_sex text check (baby_sex in ('female', 'male', 'unknown')),
  birth_weight_g int check (birth_weight_g between 300 and 7000),
  apgar_1 int check (apgar_1 between 0 and 10),
  apgar_5 int check (apgar_5 between 0 and 10),
  blood_loss_ml int check (blood_loss_ml between 0 and 10000),
  perineum text check (perineum in ('intact', 'first', 'second', 'third', 'fourth', 'episiotomy', 'na')),
  complications text check (char_length(complications) <= 2000),
  notes text check (char_length(notes) <= 2000),
  attended_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists deliveries_patient_idx on public.deliveries (patient_id, delivered_at desc);
alter table public.deliveries enable row level security;
create policy "staff read deliveries" on public.deliveries for select to authenticated using (public.is_doctor());
create policy "patient reads own deliveries" on public.deliveries for select to authenticated using (patient_id = auth.uid());

create or replace function public.record_delivery(p jsonb)
returns uuid language plpgsql security definer set search_path to '' as $$
declare pid uuid := (p->>'patient_id')::uuid; at timestamptz := (p->>'delivered_at')::timestamptz; preg uuid; nid uuid;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'doctor' and active and coalesce(staff_title, 'Doctor') in ('Doctor', 'Midwife')) then
    raise exception 'Only a doctor or midwife can record a delivery';
  end if;
  if not exists (select 1 from public.profiles where id = pid and role = 'patient') then raise exception 'Patient not found'; end if;
  if at is null or at > now() + interval '5 minutes' then raise exception 'The delivery time cannot be in the future'; end if;
  if at < now() - interval '60 days' then raise exception 'The delivery time must be within the last 60 days'; end if;
  select id into preg from public.pregnancies where patient_id = pid and status = 'active' order by created_at desc limit 1;
  insert into public.deliveries (patient_id, pregnancy_id, delivered_at, mode, outcome, baby_sex, birth_weight_g, apgar_1, apgar_5, blood_loss_ml, perineum, complications, notes, attended_by)
  values (pid, preg, at, p->>'mode', coalesce(p->>'outcome', 'live_birth'), nullif(p->>'baby_sex', ''), nullif(p->>'birth_weight_g', '')::int,
          nullif(p->>'apgar_1', '')::int, nullif(p->>'apgar_5', '')::int, nullif(p->>'blood_loss_ml', '')::int, nullif(p->>'perineum', ''),
          nullif(btrim(coalesce(p->>'complications', '')), ''), nullif(btrim(coalesce(p->>'notes', '')), ''), auth.uid())
  returning id into nid;
  perform set_config('mh.sys', '1', true);
  update public.profiles set status = 'delivered', delivered_on = (at at time zone 'Africa/Harare')::date where id = pid;
  perform set_config('mh.sys', '', true);
  return nid;
end $$;
revoke execute on function public.record_delivery(jsonb) from public, anon;
grant execute on function public.record_delivery(jsonb) to authenticated;

create table if not exists public.postnatal_checks (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.profiles(id) on delete cascade,
  check_date date not null default ((now() at time zone 'Africa/Harare')::date),
  mother_bp_sys int check (mother_bp_sys between 50 and 260),
  mother_bp_dia int check (mother_bp_dia between 30 and 160),
  mother_temp numeric check (mother_temp between 30 and 43),
  mother_pulse int check (mother_pulse between 30 and 220),
  bleeding text check (bleeding in ('none', 'light', 'normal', 'heavy')),
  breastfeeding text check (breastfeeding in ('well', 'difficulty', 'not')),
  wound text check (char_length(wound) <= 200),
  mood text check (mood in ('good', 'low', 'concern')),
  baby_weight_g int check (baby_weight_g between 300 and 8000),
  baby_temp numeric check (baby_temp between 30 and 43),
  baby_feeding text check (baby_feeding in ('well', 'poor')),
  jaundice text check (jaundice in ('none', 'mild', 'significant')),
  cord text check (cord in ('clean', 'red', 'discharge', 'off')),
  notes text check (char_length(notes) <= 2000),
  recorded_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists postnatal_patient_idx on public.postnatal_checks (patient_id, check_date desc);
alter table public.postnatal_checks enable row level security;
create policy "staff read postnatal" on public.postnatal_checks for select to authenticated using (public.is_doctor());
create policy "staff add postnatal" on public.postnatal_checks for insert to authenticated with check (public.is_doctor() and recorded_by = auth.uid());
create policy "patient reads own postnatal" on public.postnatal_checks for select to authenticated using (patient_id = auth.uid());

create table if not exists public.med_admin (
  id bigint generated always as identity primary key,
  prescription_id uuid not null references public.prescriptions(id) on delete cascade,
  patient_id uuid not null references public.profiles(id) on delete cascade,
  given_at timestamptz not null default now(),
  status text not null check (status in ('given', 'refused', 'held', 'missed')),
  dose_given text check (char_length(dose_given) <= 120),
  note text check (char_length(note) <= 500),
  given_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists med_admin_rx_idx on public.med_admin (prescription_id, given_at desc);
create index if not exists med_admin_patient_idx on public.med_admin (patient_id, given_at desc);
alter table public.med_admin enable row level security;
create or replace function public.med_admin_guard()
returns trigger language plpgsql security definer set search_path to '' as $$
declare rx public.prescriptions;
begin
  select * into rx from public.prescriptions where id = new.prescription_id;
  if not found then raise exception 'Prescription not found'; end if;
  if rx.status <> 'active' then raise exception 'This prescription is no longer active'; end if;
  new.patient_id := rx.patient_id;
  if new.given_at > now() + interval '5 minutes' then raise exception 'The time cannot be in the future'; end if;
  return new;
end $$;
create trigger med_admin_guard_trg before insert on public.med_admin for each row execute function public.med_admin_guard();
create policy "staff read med admin" on public.med_admin for select to authenticated using (public.is_doctor());
create policy "staff record med admin" on public.med_admin for insert to authenticated with check (public.is_doctor() and given_by = auth.uid());
create policy "patient reads own med admin" on public.med_admin for select to authenticated using (patient_id = auth.uid());

create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.profiles(id) on delete cascade,
  referred_to text not null check (char_length(btrim(referred_to)) between 2 and 160),
  department text check (char_length(department) <= 120),
  reason text not null check (char_length(btrim(reason)) between 3 and 2000),
  clinical_summary text check (char_length(clinical_summary) <= 4000),
  urgency text not null default 'routine' check (urgency in ('routine', 'urgent', 'emergency')),
  status text not null default 'sent' check (status in ('sent', 'accepted', 'completed', 'cancelled')),
  transport text check (char_length(transport) <= 120),
  referred_on date not null default ((now() at time zone 'Africa/Harare')::date),
  referred_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists referrals_patient_idx on public.referrals (patient_id, referred_on desc);
alter table public.referrals enable row level security;
create policy "staff read referrals" on public.referrals for select to authenticated using (public.is_doctor());
create policy "staff add referrals" on public.referrals for insert to authenticated with check (public.is_doctor() and referred_by = auth.uid());
create policy "staff update referrals" on public.referrals for update to authenticated using (public.is_doctor()) with check (public.is_doctor());
create policy "patient reads own referrals" on public.referrals for select to authenticated using (patient_id = auth.uid());
create or replace function public.referrals_touch()
returns trigger language plpgsql set search_path to '' as $$
begin
  new.updated_at := now(); new.patient_id := old.patient_id; new.referred_by := old.referred_by; new.created_at := old.created_at;
  return new;
end $$;
create trigger referrals_touch_trg before update on public.referrals for each row execute function public.referrals_touch();

/* ===================== Inventory categories (applied as a separate step) ===================== */
alter table public.charge_items drop constraint if exists charge_items_category_check;
alter table public.charge_items add constraint charge_items_category_check check (category in ('medication','iv_fluids','vaccine','supplies','dressing','ppe','linen','equipment','lab','procedure','room','food','other'));
alter table public.bed_charges drop constraint if exists bed_charges_category_check;
alter table public.bed_charges add constraint bed_charges_category_check check (category in ('medication','iv_fluids','vaccine','supplies','dressing','ppe','linen','equipment','lab','procedure','room','food','other'));
