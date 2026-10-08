-- Maternity Help: booking, admin settings lock, inventory, reviews and voice notes
-- Applied 2026-10-08

/* ===================== 1. Booking ===================== */

-- Patients can describe complicated reasons in full
alter table public.appointments drop constraint if exists appointments_reason_check;
alter table public.appointments add constraint appointments_reason_check check (char_length(reason) <= 2000);

-- Doctor availability that patients may see (hours plus free 30-minute slots)
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
    and a.avail_date between greatest(p_from, (now() at time zone 'Africa/Harare')::date + 1)
                         and least(p_to, (now() at time zone 'Africa/Harare')::date + 90)
    and not exists (select 1 from public.staff_leave l where l.staff_id = a.staff_id and a.avail_date between l.start_date and l.end_date)
  order by 2, 3, 1
$$;
revoke execute on function public.public_availability(date, date) from public, anon;
grant execute on function public.public_availability(date, date) to authenticated;

/* ===================== 2. Admin profile and settings lock ===================== */

-- The administrator cannot change their own name or phone number from the app
create or replace function public.profiles_guard()
 returns trigger language plpgsql security definer set search_path to '' as $function$
begin
  if auth.uid() is null then return new; end if;
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

-- Security confirmation for the admin Settings page (same credential as accounting, separate lockout)
create table if not exists public.settings_access (
  id int primary key check (id = 1),
  username text not null,
  pass_hash text not null,
  failed int not null default 0,
  locked_until timestamptz
);
alter table public.settings_access enable row level security;
insert into public.settings_access (id, username, pass_hash)
  select 1, username, pass_hash from public.accounting_access where id = 1
  on conflict (id) do nothing;

create or replace function public.settings_unlock(p_user text, p_pass text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare r public.settings_access%rowtype; okk boolean;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Not allowed'; end if;
  select * into r from public.settings_access where id = 1 for update;
  if not found then raise exception 'Settings confirmation is not set up'; end if;
  if r.locked_until is not null and r.locked_until > now() then
    return jsonb_build_object('ok', false, 'locked_minutes', ceil(extract(epoch from (r.locked_until - now())) / 60)::int);
  end if;
  okk := lower(coalesce(p_user, '')) = lower(r.username) and extensions.crypt(coalesce(p_pass, ''), r.pass_hash) = r.pass_hash;
  if okk then
    update public.settings_access set failed = 0, locked_until = null where id = 1;
    return jsonb_build_object('ok', true);
  end if;
  update public.settings_access set
    locked_until = case when failed + 1 >= 5 then now() + interval '15 minutes' else null end,
    failed = case when failed + 1 >= 5 then 0 else failed + 1 end where id = 1;
  return jsonb_build_object('ok', false, 'left', greatest(0, 5 - (r.failed + 1)));
end $$;
revoke execute on function public.settings_unlock(text, text) from public, anon;
grant execute on function public.settings_unlock(text, text) to authenticated;

/* ===================== 3. Inventory ===================== */

alter table public.charge_items
  add column if not exists stock_qty numeric not null default 0,
  add column if not exists track_stock boolean not null default true,
  add column if not exists reorder_level numeric not null default 5,
  add column if not exists description text,
  add column if not exists updated_at timestamptz not null default now();
alter table public.charge_items add constraint charge_items_stock_check check (stock_qty >= 0 and stock_qty <= 1000000);
alter table public.charge_items add constraint charge_items_reorder_check check (reorder_level >= 0 and reorder_level <= 1000000);
alter table public.charge_items add constraint charge_items_desc_check check (char_length(description) <= 300);
-- Services (rooms, meals, procedures, tests) are not counted. Physical items are.
update public.charge_items set track_stock = false where category not in ('medication', 'dressing', 'supplies') or name = 'Linen change';

create table if not exists public.inv_movements (
  id bigint generated always as identity primary key,
  item_id uuid not null references public.charge_items(id) on delete cascade,
  change numeric not null,
  balance_after numeric not null,
  reason text not null check (reason in ('opening', 'received', 'used', 'returned', 'adjusted')),
  patient_id uuid references public.profiles(id) on delete set null,
  charge_id uuid,
  note text check (char_length(note) <= 300),
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists inv_movements_item_idx on public.inv_movements (item_id, created_at desc);
alter table public.inv_movements enable row level security;
drop policy if exists "staff read stock movements" on public.inv_movements;
create policy "staff read stock movements" on public.inv_movements for select to authenticated using (public.is_doctor());

-- Stock can only change through the stock functions and charges
create or replace function public.inv_items_guard()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if tg_op = 'INSERT' then
    new.stock_qty := coalesce(new.stock_qty, 0);
    if not new.track_stock then new.stock_qty := 0; end if;
    return new;
  end if;
  if new.stock_qty is distinct from old.stock_qty and coalesce(current_setting('mh.inv', true), '') <> '1' then
    raise exception 'Use Receive stock or Stock count to change quantities';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists inv_items_guard_trg on public.charge_items;
create trigger inv_items_guard_trg before insert or update on public.charge_items for each row execute function public.inv_items_guard();

create or replace function public.inv_items_opening()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.track_stock and new.stock_qty > 0 then
    insert into public.inv_movements (item_id, change, balance_after, reason, note) values (new.id, new.stock_qty, new.stock_qty, 'opening', 'Opening stock');
  end if;
  return null;
end $$;
drop trigger if exists inv_items_opening_trg on public.charge_items;
create trigger inv_items_opening_trg after insert on public.charge_items for each row execute function public.inv_items_opening();

-- Using an item for a patient takes it out of stock; voiding or deleting the charge puts it back
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
    if it.track_stock then
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
    if not found or not it.track_stock then return new; end if;
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
    if not found or not it.track_stock then return old; end if;
    perform set_config('mh.inv', '1', true);
    update public.charge_items set stock_qty = stock_qty + old.qty where id = it.id;
    perform set_config('mh.inv', '', true);
    insert into public.inv_movements (item_id, change, balance_after, reason, patient_id, charge_id, note)
      values (it.id, old.qty, it.stock_qty + old.qty, 'returned', old.patient_id, old.id, 'Charge deleted');
    return old;
  end if;
end $$;
drop trigger if exists inv_stock_trg on public.bed_charges;
create trigger inv_stock_trg before insert or update or delete on public.bed_charges for each row execute function public.inv_charge_stock();

create or replace function public.inv_receive(p_item uuid, p_qty numeric, p_note text default null)
returns numeric language plpgsql security definer set search_path to '' as $$
declare it public.charge_items;
begin
  if not public.is_admin() then raise exception 'Only the administrator can add stock'; end if;
  if p_qty is null or p_qty <= 0 or p_qty > 100000 then raise exception 'Enter a quantity between 0.01 and 100000'; end if;
  select * into it from public.charge_items where id = p_item for update;
  if not found then raise exception 'Item not found'; end if;
  if not it.track_stock then raise exception '% is a service and has no stock count', it.name; end if;
  perform set_config('mh.inv', '1', true);
  update public.charge_items set stock_qty = stock_qty + p_qty where id = p_item;
  perform set_config('mh.inv', '', true);
  insert into public.inv_movements (item_id, change, balance_after, reason, note) values (p_item, p_qty, it.stock_qty + p_qty, 'received', nullif(btrim(p_note), ''));
  return it.stock_qty + p_qty;
end $$;

create or replace function public.inv_count(p_item uuid, p_count numeric, p_note text default null)
returns numeric language plpgsql security definer set search_path to '' as $$
declare it public.charge_items;
begin
  if not public.is_admin() then raise exception 'Only the administrator can correct stock'; end if;
  if p_count is null or p_count < 0 or p_count > 1000000 then raise exception 'Enter the number counted (0 or more)'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Give a reason for the correction'; end if;
  select * into it from public.charge_items where id = p_item for update;
  if not found then raise exception 'Item not found'; end if;
  if not it.track_stock then raise exception '% is a service and has no stock count', it.name; end if;
  if p_count = it.stock_qty then return p_count; end if;
  perform set_config('mh.inv', '1', true);
  update public.charge_items set stock_qty = p_count where id = p_item;
  perform set_config('mh.inv', '', true);
  insert into public.inv_movements (item_id, change, balance_after, reason, note) values (p_item, p_count - it.stock_qty, p_count, 'adjusted', btrim(p_note));
  return p_count;
end $$;
revoke execute on function public.inv_receive(uuid, numeric, text) from public, anon;
revoke execute on function public.inv_count(uuid, numeric, text) from public, anon;
grant execute on function public.inv_receive(uuid, numeric, text) to authenticated;
grant execute on function public.inv_count(uuid, numeric, text) to authenticated;

/* ===================== 4. Ratings and reviews ===================== */

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  display_name text not null default 'Patient' check (char_length(display_name) <= 60),
  anonymous boolean not null default false,
  rating int not null check (rating between 1 and 5),
  comment text check (char_length(comment) <= 1000),
  status text not null default 'published' check (status in ('published', 'hidden')),
  admin_reply text check (char_length(admin_reply) <= 1000),
  replied_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (patient_id)
);
create index if not exists reviews_status_idx on public.reviews (status, created_at desc);
alter table public.reviews enable row level security;

create or replace function public.reviews_guard()
returns trigger language plpgsql security definer set search_path to '' as $$
declare nm text;
begin
  if tg_op = 'INSERT' and not public.is_admin() then
    new.patient_id := auth.uid(); new.status := 'published'; new.admin_reply := null; new.replied_at := null;
  end if;
  if tg_op = 'UPDATE' then
    new.patient_id := old.patient_id; new.created_at := old.created_at;
    if not public.is_admin() then
      new.status := old.status; new.admin_reply := old.admin_reply; new.replied_at := old.replied_at;
    elsif new.admin_reply is distinct from old.admin_reply then
      new.replied_at := case when nullif(btrim(coalesce(new.admin_reply, '')), '') is null then null else now() end;
      new.admin_reply := nullif(btrim(coalesce(new.admin_reply, '')), '');
    end if;
    new.updated_at := now();
  end if;
  new.comment := nullif(btrim(coalesce(new.comment, '')), '');
  if new.anonymous then
    new.display_name := 'Anonymous patient';
  else
    select btrim(full_name) into nm from public.profiles where id = new.patient_id;
    nm := coalesce(nullif(nm, ''), 'Patient');
    new.display_name := left((regexp_match(nm, '^\S+'))[1] || coalesce(' ' || left((regexp_match(nm, '\s(\S+)\s*$'))[1], 1) || '.', ''), 60);
  end if;
  return new;
end $$;
drop trigger if exists reviews_guard_trg on public.reviews;
create trigger reviews_guard_trg before insert or update on public.reviews for each row execute function public.reviews_guard();

drop policy if exists "read published or own reviews" on public.reviews;
drop policy if exists "patients write own review" on public.reviews;
drop policy if exists "patients edit own review" on public.reviews;
drop policy if exists "patients delete own review" on public.reviews;
drop policy if exists "admin manages reviews" on public.reviews;
create policy "read published or own reviews" on public.reviews for select to authenticated
  using (status = 'published' or patient_id = auth.uid() or public.is_admin());
create policy "patients write own review" on public.reviews for insert to authenticated
  with check (patient_id = auth.uid() and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'patient' and p.active));
create policy "patients edit own review" on public.reviews for update to authenticated
  using (patient_id = auth.uid()) with check (patient_id = auth.uid());
create policy "patients delete own review" on public.reviews for delete to authenticated using (patient_id = auth.uid());
create policy "admin manages reviews" on public.reviews for all to authenticated using (public.is_admin()) with check (public.is_admin());

/* ===================== 5. Voice notes in chat ===================== */

alter table public.chat_messages add column if not exists audio_path text, add column if not exists audio_secs int;
alter table public.chat_messages add constraint chat_messages_audio_check check (
  (audio_path is null and audio_secs is null) or
  (audio_path like 'chat/' || patient_id::text || '/%' and char_length(audio_path) <= 200 and audio_secs between 1 and 300));
alter table public.group_messages add column if not exists audio_path text, add column if not exists audio_secs int;
alter table public.group_messages add constraint group_messages_audio_check check (
  (audio_path is null and audio_secs is null) or
  (audio_path like 'group/' || group_id::text || '/%' and char_length(audio_path) <= 200 and audio_secs between 1 and 300));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('voice-notes', 'voice-notes', false, 5242880,
        array['audio/webm', 'audio/ogg', 'audio/mp4', 'audio/mpeg', 'audio/aac', 'audio/x-m4a', 'audio/wav'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "voice read chat" on storage.objects;
drop policy if exists "voice upload chat" on storage.objects;
drop policy if exists "voice read group" on storage.objects;
drop policy if exists "voice upload group" on storage.objects;
create policy "voice read chat" on storage.objects for select to authenticated using (
  bucket_id = 'voice-notes' and (storage.foldername(name))[1] = 'chat'
  and ((storage.foldername(name))[2] = auth.uid()::text or public.is_doctor()));
create policy "voice upload chat" on storage.objects for insert to authenticated with check (
  bucket_id = 'voice-notes' and (storage.foldername(name))[1] = 'chat'
  and ((storage.foldername(name))[2] = auth.uid()::text or public.is_doctor()));
create policy "voice read group" on storage.objects for select to authenticated using (
  bucket_id = 'voice-notes' and (storage.foldername(name))[1] = 'group');
create policy "voice upload group" on storage.objects for insert to authenticated with check (
  bucket_id = 'voice-notes' and (storage.foldername(name))[1] = 'group'
  and exists (select 1 from public.profiles p where p.id = auth.uid() and p.active)
  and exists (select 1 from public.chat_groups g where g.id::text = (storage.foldername(name))[2] and (public.is_admin() or not g.admin_only)));
