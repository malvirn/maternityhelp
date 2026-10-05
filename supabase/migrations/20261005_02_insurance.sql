-- Group 3, module 2: Insurance (medical aid providers, coverage, claims, approvals, insurer payments)
create sequence if not exists public.acc_clm_seq;
create sequence if not exists public.acc_ipy_seq;

create table if not exists public.acc_insurers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 2 and 120),
  contact_person text check (char_length(contact_person) <= 120),
  phone text check (char_length(phone) <= 40),
  email text check (char_length(email) <= 160),
  address text check (char_length(address) <= 300),
  payment_terms_days int not null default 30 check (payment_terms_days between 0 and 365),
  is_active boolean not null default true,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists acc_insurers_name_uq on public.acc_insurers (lower(btrim(name)));

create table if not exists public.acc_coverages (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.profiles(id),
  insurer_id uuid not null references public.acc_insurers(id),
  member_number text not null check (char_length(btrim(member_number)) between 1 and 60),
  plan_name text check (char_length(plan_name) <= 120),
  coverage_percent numeric(5,2) not null check (coverage_percent between 0 and 100),
  annual_limit numeric(14,2) check (annual_limit > 0),
  valid_from date not null default current_date,
  valid_to date,
  is_active boolean not null default true,
  notes text check (char_length(notes) <= 300),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from)
);
create index if not exists acc_coverages_patient on public.acc_coverages (patient_id);

create table if not exists public.acc_claims (
  id uuid primary key default gen_random_uuid(),
  claim_no text not null unique,
  insurer_id uuid not null references public.acc_insurers(id),
  patient_id uuid not null references public.profiles(id),
  coverage_id uuid references public.acc_coverages(id),
  invoice_id uuid not null references public.acc_invoices(id),
  claim_date date not null,
  claimed_amount numeric(14,2) not null check (claimed_amount > 0),
  approved_amount numeric(14,2) check (approved_amount >= 0),
  status text not null default 'submitted' check (status in ('submitted','approved','rejected','cancelled')),
  decision_note text check (char_length(decision_note) <= 300),
  decided_by uuid, decided_at timestamptz,
  receipt_id uuid references public.acc_receipts(id),
  notes text check (char_length(notes) <= 300),
  idempotency_key text not null unique check (char_length(idempotency_key) between 8 and 200),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists acc_claims_invoice on public.acc_claims (invoice_id);
create index if not exists acc_claims_insurer on public.acc_claims (insurer_id, status);

create table if not exists public.acc_insurer_payments (
  id uuid primary key default gen_random_uuid(),
  payment_no text not null unique,
  insurer_id uuid not null references public.acc_insurers(id),
  claim_id uuid not null references public.acc_claims(id),
  amount numeric(14,2) not null check (amount > 0),
  paid_on date not null,
  deposit_account_id uuid not null references public.acc_accounts(id),
  reference text check (char_length(reference) <= 120),
  status text not null default 'posted' check (status in ('posted','reversed')),
  entry_id uuid not null unique references public.acc_journal_entries(id),
  reversal_entry_id uuid references public.acc_journal_entries(id),
  idempotency_key text not null unique check (char_length(idempotency_key) between 8 and 200),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists acc_ipay_claim on public.acc_insurer_payments (claim_id);

do $$ declare t text; begin
  foreach t in array array['acc_insurers','acc_coverages','acc_claims','acc_insurer_payments'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy acc_read on public.%I for select using ((select public.acc_can_view()))', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('create trigger acc_audit after insert or update or delete on public.%I for each row execute function public.acc__audit()', t);
  end loop;
end $$;
create trigger acc_ipay_guard before update or delete on public.acc_insurer_payments for each row execute function public.acc__doc_guard('status','reversal_entry_id');

create or replace function public.acc__ins_account() returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.acc_accounts where subtype = 'receivable_insurance' and is_active and not is_header order by code limit 1 $$;

create or replace function public.acc_save_insurer(p_id uuid, p_name text, p_contact text, p_phone text, p_email text, p_address text, p_terms int, p_active boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare rid uuid;
begin
  perform public.acc__require('post');
  if coalesce(char_length(btrim(p_name)), 0) < 2 then raise exception 'Enter the name of the medical aid or insurer'; end if;
  if p_terms is null or p_terms < 0 or p_terms > 365 then raise exception 'Payment terms must be between 0 and 365 days'; end if;
  if p_id is null then
    insert into public.acc_insurers (name, contact_person, phone, email, address, payment_terms_days, is_active)
    values (btrim(p_name), nullif(btrim(p_contact), ''), nullif(btrim(p_phone), ''), nullif(btrim(p_email), ''), nullif(btrim(p_address), ''), p_terms, coalesce(p_active, true)) returning id into rid;
  else
    update public.acc_insurers set name = btrim(p_name), contact_person = nullif(btrim(p_contact), ''), phone = nullif(btrim(p_phone), ''), email = nullif(btrim(p_email), ''),
      address = nullif(btrim(p_address), ''), payment_terms_days = p_terms, is_active = coalesce(p_active, true), updated_at = now() where id = p_id returning id into rid;
    if rid is null then raise exception 'Insurer not found'; end if;
  end if;
  return rid;
exception when unique_violation then raise exception 'An insurer with that name already exists';
end $$;

create or replace function public.acc_insurers_list()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare td date := public.acc__today();
begin
  perform public.acc__require('view');
  return (with p as (select claim_id, sum(amount) paid from public.acc_insurer_payments where status = 'posted' group by claim_id),
    c as (select c.insurer_id, c.status, c.claimed_amount, coalesce(c.approved_amount, 0) approved, coalesce(p.paid, 0) paid, c.decided_at, i.payment_terms_days terms
          from public.acc_claims c join public.acc_insurers i on i.id = c.insurer_id left join p on p.claim_id = c.id),
    a as (select insurer_id,
           count(*) filter (where status = 'submitted') pending_n, coalesce(sum(claimed_amount) filter (where status = 'submitted'), 0) pending_amt,
           coalesce(sum(approved) filter (where status = 'approved'), 0) approved, coalesce(sum(paid) filter (where status = 'approved'), 0) paid,
           coalesce(sum(approved - paid) filter (where status = 'approved' and decided_at::date + terms < td and approved - paid > 0), 0) overdue,
           count(*) filter (where status = 'rejected') rejected_n, count(*) n from c group by insurer_id)
    select jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'contact_person', i.contact_person, 'phone', i.phone, 'email', i.email, 'address', i.address,
        'terms', i.payment_terms_days, 'is_active', i.is_active, 'claims', coalesce(a.n, 0), 'pending_n', coalesce(a.pending_n, 0), 'pending', coalesce(a.pending_amt, 0),
        'approved', coalesce(a.approved, 0), 'paid', coalesce(a.paid, 0), 'outstanding', coalesce(a.approved, 0) - coalesce(a.paid, 0), 'overdue', coalesce(a.overdue, 0), 'rejected_n', coalesce(a.rejected_n, 0)) order by i.name)
      from public.acc_insurers i left join a on a.insurer_id = i.id), '[]'::jsonb),
      'outstanding', coalesce((select sum(approved - paid) from a), 0), 'overdue', coalesce((select sum(overdue) from a), 0)));
end $$;

create or replace function public.acc_save_coverage(p_id uuid, p_patient uuid, p_insurer uuid, p_member text, p_plan text, p_percent numeric, p_limit numeric, p_from date, p_to date, p_active boolean, p_notes text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare rid uuid;
begin
  perform public.acc__require('post');
  if not exists (select 1 from public.profiles where id = p_patient and role = 'patient') then raise exception 'Choose a patient'; end if;
  if not exists (select 1 from public.acc_insurers where id = p_insurer and is_active) then raise exception 'Choose an active medical aid or insurer'; end if;
  if coalesce(char_length(btrim(p_member)), 0) < 1 then raise exception 'Enter the member number'; end if;
  if p_percent is null or p_percent < 0 or p_percent > 100 then raise exception 'Coverage must be between 0 and 100 percent'; end if;
  if p_limit is not null and p_limit <= 0 then raise exception 'The annual limit must be more than zero, or left blank for no limit'; end if;
  if p_from is null then raise exception 'Enter the date the cover starts'; end if;
  if p_to is not null and p_to < p_from then raise exception 'The end date cannot be before the start date'; end if;
  if p_id is null then
    insert into public.acc_coverages (patient_id, insurer_id, member_number, plan_name, coverage_percent, annual_limit, valid_from, valid_to, is_active, notes)
    values (p_patient, p_insurer, btrim(p_member), nullif(btrim(p_plan), ''), round(p_percent, 2), p_limit, p_from, p_to, coalesce(p_active, true), nullif(btrim(p_notes), '')) returning id into rid;
  else
    update public.acc_coverages set patient_id = p_patient, insurer_id = p_insurer, member_number = btrim(p_member), plan_name = nullif(btrim(p_plan), ''), coverage_percent = round(p_percent, 2),
      annual_limit = p_limit, valid_from = p_from, valid_to = p_to, is_active = coalesce(p_active, true), notes = nullif(btrim(p_notes), ''), updated_at = now() where id = p_id returning id into rid;
    if rid is null then raise exception 'Coverage not found'; end if;
  end if;
  return rid;
end $$;

create or replace function public.acc_coverages_list(p_patient uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.acc__require('view');
  return coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'patient_id', v.patient_id, 'patient', public.acc__pname(v.patient_id), 'insurer_id', v.insurer_id, 'insurer', i.name,
      'member_number', v.member_number, 'plan_name', v.plan_name, 'percent', v.coverage_percent, 'annual_limit', v.annual_limit, 'valid_from', v.valid_from, 'valid_to', v.valid_to,
      'is_active', v.is_active, 'notes', v.notes,
      'used', (select coalesce(sum(c.approved_amount), 0) from public.acc_claims c where c.coverage_id = v.id and c.status = 'approved'),
      'current', v.is_active and v.valid_from <= public.acc__today() and (v.valid_to is null or v.valid_to >= public.acc__today())) order by public.acc__pname(v.patient_id), i.name)
    from public.acc_coverages v join public.acc_insurers i on i.id = v.insurer_id where p_patient is null or v.patient_id = p_patient), '[]'::jsonb);
end $$;

create or replace function public.acc_create_claim(p_invoice uuid, p_coverage uuid, p_amount numeric, p_claim_date date, p_notes text, p_idem text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare inv public.acc_invoices; cov public.acc_coverages; ex public.acc_claims; amt numeric; outst numeric; pending numeric; cap numeric; gross numeric; cid uuid; cno text; dt date; taken numeric;
begin
  perform public.acc__require('post');
  if coalesce(char_length(p_idem), 0) < 8 then raise exception 'Missing submission key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('acc:clm:' || p_idem, 0));
  select * into ex from public.acc_claims where idempotency_key = p_idem;
  if found then return jsonb_build_object('id', ex.id, 'claim_no', ex.claim_no); end if;
  amt := public.acc__amount(p_amount, 'Claim amount');
  select * into inv from public.acc_invoices where id = p_invoice for update;
  if not found or inv.status <> 'issued' then raise exception 'Choose an open invoice'; end if;
  select * into cov from public.acc_coverages where id = p_coverage;
  if not found or cov.patient_id <> inv.patient_id then raise exception 'That cover does not belong to the invoice''s patient'; end if;
  if not cov.is_active then raise exception 'That cover is switched off'; end if;
  if not exists (select 1 from public.acc_insurers where id = cov.insurer_id and is_active) then raise exception 'That insurer is inactive'; end if;
  dt := coalesce(p_claim_date, public.acc__today());
  if dt < cov.valid_from or (cov.valid_to is not null and dt > cov.valid_to) then raise exception 'The claim date is outside the period this cover is valid'; end if;
  outst := public.acc__invoice_outstanding(inv.id);
  select coalesce(sum(claimed_amount), 0) into pending from public.acc_claims where invoice_id = inv.id and status = 'submitted';
  if amt > outst - pending then raise exception 'Only % of this invoice can still be claimed', to_char(greatest(outst - pending, 0), 'FM999,999,999,990.00'); end if;
  select coalesce(sum(amount), 0) into gross from public.acc_invoice_lines where invoice_id = inv.id and active;
  select coalesce(sum(coalesce(approved_amount, 0)), 0) into taken from public.acc_claims where invoice_id = inv.id and status = 'approved';
  cap := round(gross * cov.coverage_percent / 100, 2);
  if pending + taken + amt > cap then raise exception 'This cover pays % percent of the invoice, up to %. Other claims already use %.', cov.coverage_percent::text, to_char(cap, 'FM999,999,999,990.00'), to_char(pending + taken, 'FM999,999,999,990.00'); end if;
  cid := gen_random_uuid(); cno := 'CLM-' || lpad(nextval('public.acc_clm_seq')::text, 6, '0');
  insert into public.acc_claims (id, claim_no, insurer_id, patient_id, coverage_id, invoice_id, claim_date, claimed_amount, notes, idempotency_key, created_by)
  values (cid, cno, cov.insurer_id, inv.patient_id, cov.id, inv.id, dt, amt, nullif(btrim(p_notes), ''), p_idem, auth.uid());
  return jsonb_build_object('id', cid, 'claim_no', cno);
end $$;

create or replace function public.acc_decide_claim(p_id uuid, p_approve boolean, p_amount numeric, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.acc_claims; inv public.acc_invoices; cov public.acc_coverages; amt numeric; outst numeric; used numeric; rid uuid; rno text; eid uuid; ins uuid; today date := public.acc__today();
begin
  perform public.acc__require('control');
  select * into c from public.acc_claims where id = p_id for update;
  if not found then raise exception 'Claim not found'; end if;
  if c.status <> 'submitted' then raise exception '% is already %', c.claim_no, c.status; end if;
  if not p_approve then
    if coalesce(char_length(btrim(p_note)), 0) < 3 then raise exception 'Give the reason the claim was rejected'; end if;
    update public.acc_claims set status = 'rejected', approved_amount = 0, decision_note = btrim(p_note), decided_by = auth.uid(), decided_at = now() where id = c.id;
    return jsonb_build_object('id', c.id, 'status', 'rejected');
  end if;
  amt := public.acc__amount(coalesce(p_amount, c.claimed_amount), 'Approved amount');
  if amt > c.claimed_amount then raise exception 'The approved amount cannot be more than the amount claimed (%)', to_char(c.claimed_amount, 'FM999,999,999,990.00'); end if;
  select * into inv from public.acc_invoices where id = c.invoice_id for update;
  if inv.status <> 'issued' then raise exception 'The invoice is void'; end if;
  outst := public.acc__invoice_outstanding(inv.id);
  if amt > outst then raise exception 'The invoice now has only % outstanding', to_char(greatest(outst, 0), 'FM999,999,999,990.00'); end if;
  if c.coverage_id is not null then
    select * into cov from public.acc_coverages where id = c.coverage_id;
    if cov.annual_limit is not null then
      select coalesce(sum(approved_amount), 0) into used from public.acc_claims where coverage_id = cov.id and status = 'approved';
      if used + amt > cov.annual_limit then raise exception 'This would exceed the cover''s annual limit of % (already approved: %)', to_char(cov.annual_limit, 'FM999,999,999,990.00'), to_char(used, 'FM999,999,999,990.00'); end if;
    end if;
  end if;
  ins := public.acc__ins_account();
  if ins is null then raise exception 'There is no active insurance receivable account in the chart of accounts'; end if;
  rid := gen_random_uuid(); rno := 'RCT-' || lpad(nextval('public.acc_rct_seq')::text, 6, '0');
  eid := public.acc__post(today, 'document', 'Medical aid approval ' || c.claim_no || ' - ' || public.acc__patient_name(c.patient_id), rno, 'claim', c.id,
    jsonb_build_array(jsonb_build_object('account_id', ins, 'debit', amt, 'description', 'Claim ' || c.claim_no),
                      jsonb_build_object('account_id', public.acc__ar_account(), 'credit', amt, 'patient_id', c.patient_id, 'description', 'Claim ' || c.claim_no || ' approved by medical aid')), 'clm:' || c.id::text);
  insert into public.acc_receipts (id, receipt_no, patient_id, patient_name, invoice_id, amount, method, deposit_account_id, received_on, reference, source_type, source_id, entry_id, idempotency_key, created_by)
  values (rid, rno, c.patient_id, public.acc__patient_name(c.patient_id), c.invoice_id, amt, 'insurance', ins, today, c.claim_no, 'claim', c.id, eid, 'clm:' || c.id::text, auth.uid());
  update public.acc_claims set status = 'approved', approved_amount = amt, receipt_id = rid, decision_note = nullif(btrim(p_note), ''), decided_by = auth.uid(), decided_at = now() where id = c.id;
  return jsonb_build_object('id', c.id, 'status', 'approved', 'approved_amount', amt);
end $$;

create or replace function public.acc_cancel_claim(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.acc_claims; r public.acc_receipts;
begin
  perform public.acc__require('post');
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'Give a reason'; end if;
  select * into c from public.acc_claims where id = p_id for update;
  if not found then raise exception 'Claim not found'; end if;
  if c.status = 'submitted' then
    if c.created_by <> auth.uid() and not public.acc_is_controller() then raise exception 'Only the person who submitted it or the financial controller can cancel this claim'; end if;
    update public.acc_claims set status = 'cancelled', decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where id = c.id;
    return jsonb_build_object('id', c.id, 'status', 'cancelled');
  elsif c.status = 'approved' then
    perform public.acc__require('control');
    if exists (select 1 from public.acc_insurer_payments where claim_id = c.id and status = 'posted') then raise exception 'Reverse the insurer payments on % first', c.claim_no; end if;
    select * into r from public.acc_receipts where id = c.receipt_id for update;
    if r.status = 'posted' then perform public.acc__reverse(r.entry_id, public.acc__today(), c.claim_no || ' approval withdrawn: ' || btrim(p_reason), 'clmx:' || c.id::text); end if;
    update public.acc_claims set status = 'cancelled', decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where id = c.id;
    return jsonb_build_object('id', c.id, 'status', 'cancelled');
  end if;
  raise exception 'This claim is %, so it cannot be cancelled', c.status;
end $$;

create or replace function public.acc_record_insurer_payment(p_claim uuid, p_amount numeric, p_paid_on date, p_deposit uuid, p_reference text, p_idem text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.acc_claims; a public.acc_accounts; ex public.acc_insurer_payments; amt numeric; paid numeric; pid uuid; pno text; eid uuid; dt date; ins uuid;
begin
  perform public.acc__require('post');
  if coalesce(char_length(p_idem), 0) < 8 then raise exception 'Missing submission key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('acc:ipy:' || p_idem, 0));
  select * into ex from public.acc_insurer_payments where idempotency_key = p_idem;
  if found then return jsonb_build_object('id', ex.id, 'payment_no', ex.payment_no); end if;
  amt := public.acc__amount(p_amount);
  select * into c from public.acc_claims where id = p_claim for update;
  if not found or c.status <> 'approved' then raise exception 'Only approved claims can be paid'; end if;
  select coalesce(sum(amount), 0) into paid from public.acc_insurer_payments where claim_id = c.id and status = 'posted';
  if amt > c.approved_amount - paid then raise exception 'Only % is still owed on %', to_char(c.approved_amount - paid, 'FM999,999,999,990.00'), c.claim_no; end if;
  select * into a from public.acc_accounts where id = p_deposit and subtype in ('cash','bank','mobile_money') and is_active and not is_header;
  if not found then raise exception 'Choose the cash, bank or mobile money account the money went into'; end if;
  ins := public.acc__ins_account(); dt := coalesce(p_paid_on, public.acc__today());
  pid := gen_random_uuid(); pno := 'IPY-' || lpad(nextval('public.acc_ipy_seq')::text, 6, '0');
  eid := public.acc__post(dt, 'document', 'Insurer payment ' || pno || ' for ' || c.claim_no, coalesce(nullif(btrim(p_reference), ''), pno), 'insurer_payment', pid,
    jsonb_build_array(jsonb_build_object('account_id', a.id, 'debit', amt, 'description', 'Payment ' || pno), jsonb_build_object('account_id', ins, 'credit', amt, 'description', 'Payment of ' || c.claim_no)), 'ipy:' || p_idem);
  insert into public.acc_insurer_payments (id, payment_no, insurer_id, claim_id, amount, paid_on, deposit_account_id, reference, entry_id, idempotency_key, created_by)
  values (pid, pno, c.insurer_id, c.id, amt, dt, a.id, nullif(btrim(p_reference), ''), eid, p_idem, auth.uid());
  return jsonb_build_object('id', pid, 'payment_no', pno);
end $$;

create or replace function public.acc_reverse_insurer_payment(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.acc_insurer_payments; rid uuid;
begin
  perform public.acc__require('control');
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'Give a reason for the reversal'; end if;
  select * into p from public.acc_insurer_payments where id = p_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if p.status <> 'posted' then raise exception '% has already been reversed', p.payment_no; end if;
  rid := public.acc__reverse(p.entry_id, public.acc__today(), p.payment_no || ' reversed: ' || btrim(p_reason), 'rvi:' || p.id::text);
  update public.acc_insurer_payments set status = 'reversed', reversal_entry_id = rid where id = p.id;
  return jsonb_build_object('id', p.id, 'payment_no', p.payment_no);
end $$;

create or replace function public.acc_claims_list(p_search text default null, p_status text default null, p_insurer uuid default null, p_from date default null, p_to date default null, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare q text := nullif(btrim(p_search), ''); td date := public.acc__today();
begin
  perform public.acc__require('view');
  return (with p as (select claim_id, sum(amount) paid from public.acc_insurer_payments where status = 'posted' group by claim_id),
    b as (select c.id, c.claim_no, c.insurer_id, i.name insurer, c.patient_id, public.acc__pname(c.patient_id) patient, c.invoice_id, inv.invoice_no, c.claim_date, c.claimed_amount, coalesce(c.approved_amount, 0) approved,
            coalesce(p.paid, 0) paid, c.status raw, c.decision_note, c.decided_at, i.payment_terms_days terms, cv.member_number, c.created_at
          from public.acc_claims c join public.acc_insurers i on i.id = c.insurer_id join public.acc_invoices inv on inv.id = c.invoice_id left join p on p.claim_id = c.id left join public.acc_coverages cv on cv.id = c.coverage_id),
    s as (select b.*, case when raw = 'approved' then (case when paid >= approved then 'paid' when paid > 0 then 'part_paid' else 'approved' end) else raw end status,
            case when raw = 'approved' then approved - paid else 0 end outstanding,
            (raw = 'approved' and approved - paid > 0 and decided_at::date + terms < td) overdue from b),
    f as (select * from s where (p_status is null or status = p_status or (p_status = 'overdue' and overdue)) and (p_insurer is null or insurer_id = p_insurer) and (p_from is null or claim_date >= p_from) and (p_to is null or claim_date <= p_to)
          and (q is null or claim_no ilike '%' || q || '%' or patient ilike '%' || q || '%' or invoice_no ilike '%' || q || '%' or coalesce(member_number, '') ilike '%' || q || '%')),
    pg as (select * from f order by claim_date desc, claim_no desc limit least(coalesce(p_limit, 50), 200) offset greatest(coalesce(p_offset, 0), 0))
    select jsonb_build_object('total_count', (select count(*) from f),
      'submitted', (select coalesce(sum(claimed_amount), 0) from f where status = 'submitted'), 'submitted_n', (select count(*) from f where status = 'submitted'),
      'approved', (select coalesce(sum(approved), 0) from f where raw = 'approved'), 'paid', (select coalesce(sum(paid), 0) from f where raw = 'approved'),
      'outstanding', (select coalesce(sum(outstanding), 0) from f), 'overdue', (select coalesce(sum(outstanding), 0) from f where overdue),
      'rejected', (select coalesce(sum(claimed_amount), 0) from f where status = 'rejected'),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'claim_no', claim_no, 'insurer_id', insurer_id, 'insurer', insurer, 'patient_id', patient_id, 'patient', patient, 'invoice_id', invoice_id, 'invoice_no', invoice_no,
        'claim_date', claim_date, 'claimed', claimed_amount, 'approved', approved, 'paid', paid, 'outstanding', outstanding, 'status', status, 'overdue', overdue, 'member_number', member_number, 'note', decision_note) order by claim_date desc, claim_no desc) from pg), '[]'::jsonb)));
end $$;

create or replace function public.acc_claim_detail(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.acc_claims; paid numeric;
begin
  perform public.acc__require('view');
  select * into c from public.acc_claims where id = p_id;
  if not found then raise exception 'Claim not found'; end if;
  select coalesce(sum(amount), 0) into paid from public.acc_insurer_payments where claim_id = c.id and status = 'posted';
  return jsonb_build_object(
    'claim', jsonb_build_object('id', c.id, 'claim_no', c.claim_no, 'claim_date', c.claim_date, 'claimed', c.claimed_amount, 'approved', coalesce(c.approved_amount, 0), 'paid', paid,
      'status', case when c.status = 'approved' then (case when paid >= c.approved_amount then 'paid' when paid > 0 then 'part_paid' else 'approved' end) else c.status end,
      'note', c.decision_note, 'notes', c.notes, 'decided_at', c.decided_at, 'decided_by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = c.decided_by),
      'created_by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = c.created_by), 'created_at', c.created_at),
    'insurer', (select jsonb_build_object('id', i.id, 'name', i.name, 'terms', i.payment_terms_days, 'phone', i.phone, 'email', i.email) from public.acc_insurers i where i.id = c.insurer_id),
    'patient', (select jsonb_build_object('id', p.id, 'name', coalesce(nullif(btrim(p.full_name), ''), p.email), 'code', p.patient_code) from public.profiles p where p.id = c.patient_id),
    'invoice', (select jsonb_build_object('id', i.id, 'invoice_no', i.invoice_no, 'balance', public.acc__invoice_outstanding(i.id),
       'total', (select coalesce(sum(amount), 0) from public.acc_invoice_lines where invoice_id = i.id and active)) from public.acc_invoices i where i.id = c.invoice_id),
    'coverage', (select jsonb_build_object('member_number', v.member_number, 'plan_name', v.plan_name, 'percent', v.coverage_percent, 'annual_limit', v.annual_limit) from public.acc_coverages v where v.id = c.coverage_id),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'payment_no', x.payment_no, 'date', x.paid_on, 'amount', x.amount, 'reference', x.reference, 'status', x.status,
        'account', (select name from public.acc_accounts where id = x.deposit_account_id)) order by x.paid_on, x.created_at) from public.acc_insurer_payments x where x.claim_id = c.id), '[]'::jsonb));
end $$;

do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
    and p.proname in ('acc__ins_account','acc_save_insurer','acc_insurers_list','acc_save_coverage','acc_coverages_list','acc_create_claim','acc_decide_claim','acc_cancel_claim','acc_record_insurer_payment','acc_reverse_insurer_payment','acc_claims_list','acc_claim_detail')
  loop execute format('revoke all on function %s from public, anon', r.sig); execute format('grant execute on function %s to authenticated', r.sig); end loop;
end $$;
