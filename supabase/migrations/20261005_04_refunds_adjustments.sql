-- Group 3, module 4: Refunds, credit notes, patient credits and financial adjustments
create sequence if not exists public.acc_cn_seq;
create sequence if not exists public.acc_rrq_seq;
create sequence if not exists public.acc_cap_seq;
create sequence if not exists public.acc_adj_seq;

alter table public.acc_settings add column if not exists refund_approval_limit numeric(14,2) not null default 50 check (refund_approval_limit >= 0);

create table if not exists public.acc_credit_notes (
  id uuid primary key default gen_random_uuid(),
  cn_no text not null unique,
  kind text not null check (kind in ('credit_note','write_off')),
  invoice_id uuid not null references public.acc_invoices(id),
  patient_id uuid not null references public.profiles(id),
  cn_date date not null,
  account_id uuid not null references public.acc_accounts(id),
  amount numeric(14,2) not null check (amount > 0),
  reason text not null check (char_length(btrim(reason)) between 3 and 300),
  status text not null default 'posted' check (status in ('posted','reversed')),
  entry_id uuid not null unique references public.acc_journal_entries(id),
  reversal_entry_id uuid references public.acc_journal_entries(id),
  idempotency_key text not null unique check (char_length(idempotency_key) between 8 and 200),
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
create index if not exists acc_cn_invoice on public.acc_credit_notes (invoice_id);

create table if not exists public.acc_credit_applications (
  id uuid primary key default gen_random_uuid(),
  app_no text not null unique,
  patient_id uuid not null references public.profiles(id),
  invoice_id uuid not null references public.acc_invoices(id),
  amount numeric(14,2) not null check (amount > 0),
  app_date date not null,
  status text not null default 'posted' check (status in ('posted','reversed')),
  entry_id uuid not null unique references public.acc_journal_entries(id),
  reversal_entry_id uuid references public.acc_journal_entries(id),
  idempotency_key text not null unique check (char_length(idempotency_key) between 8 and 200),
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
create index if not exists acc_cap_invoice on public.acc_credit_applications (invoice_id);

create table if not exists public.acc_refund_requests (
  id uuid primary key default gen_random_uuid(),
  request_no text not null unique,
  patient_id uuid not null references public.profiles(id),
  invoice_id uuid references public.acc_invoices(id),
  amount numeric(14,2) not null check (amount > 0),
  method text not null check (method in ('cash','bank','card','ecocash','innbucks','other')),
  refund_date date not null,
  reason text not null check (char_length(btrim(reason)) between 3 and 300),
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  requested_by uuid default auth.uid(),
  decided_by uuid, decided_at timestamptz, decision_note text check (char_length(decision_note) <= 300),
  refund_id uuid references public.acc_refunds(id),
  idempotency_key text not null unique check (char_length(idempotency_key) between 8 and 200),
  created_at timestamptz not null default now()
);
create table if not exists public.acc_adjustments (
  id uuid primary key default gen_random_uuid(),
  adj_no text not null unique,
  adj_date date not null,
  debit_account_id uuid not null references public.acc_accounts(id),
  credit_account_id uuid not null references public.acc_accounts(id),
  amount numeric(14,2) not null check (amount > 0),
  reason text not null check (char_length(btrim(reason)) between 3 and 300),
  patient_id uuid references public.profiles(id),
  status text not null default 'posted' check (status in ('posted','reversed')),
  entry_id uuid not null unique references public.acc_journal_entries(id),
  reversal_entry_id uuid references public.acc_journal_entries(id),
  idempotency_key text not null unique check (char_length(idempotency_key) between 8 and 200),
  created_by uuid default auth.uid(), created_at timestamptz not null default now(),
  check (debit_account_id <> credit_account_id)
);

do $$ declare t text; begin
  foreach t in array array['acc_credit_notes','acc_credit_applications','acc_refund_requests','acc_adjustments'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy acc_read on public.%I for select using ((select public.acc_can_view()))', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('create trigger acc_audit after insert or update or delete on public.%I for each row execute function public.acc__audit()', t);
  end loop;
  foreach t in array array['acc_credit_notes','acc_credit_applications','acc_adjustments'] loop
    execute format('create trigger %I before update or delete on public.%I for each row execute function public.acc__doc_guard(''status'',''reversal_entry_id'')', t || '_guard', t);
  end loop;
end $$;

-- invoice balance now counts credit notes and applied patient credit
create or replace function public.acc__invoice_outstanding(p_inv uuid) returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select sum(amount) from public.acc_invoice_lines where invoice_id = p_inv and active), 0)
       - coalesce((select sum(amount) from public.acc_receipts where invoice_id = p_inv and status = 'posted'), 0)
       - coalesce((select sum(amount) from public.acc_credit_notes where invoice_id = p_inv and status = 'posted'), 0)
       - coalesce((select sum(amount) from public.acc_credit_applications where invoice_id = p_inv and status = 'posted'), 0)
       + coalesce((select sum(amount) from public.acc_refunds where invoice_id = p_inv and status = 'posted'), 0) $$;

create or replace function pg_temp.rep(t text, a text, b text) returns text language plpgsql as $$
begin
  if (length(t) - length(replace(t, a, ''))) / length(a) <> 1 then raise exception 'patch target not found exactly once: %', left(a, 70); end if;
  return replace(t, a, b);
end $$;

do $$ declare d text; begin
  d := pg_get_functiondef('public.acc_invoice_detail(uuid)'::regprocedure);
  d := pg_temp.rep(d, 'tot numeric; pd numeric; rf numeric; st text;', 'tot numeric; pd numeric; rf numeric; cn numeric; ap numeric; st text;');
  d := pg_temp.rep(d, 'select coalesce(sum(amount), 0) into rf from public.acc_refunds where invoice_id = p_id and status = ''posted'';',
    'select coalesce(sum(amount), 0) into rf from public.acc_refunds where invoice_id = p_id and status = ''posted'';
  select coalesce(sum(amount), 0) into cn from public.acc_credit_notes where invoice_id = p_id and status = ''posted'';
  select coalesce(sum(amount), 0) into ap from public.acc_credit_applications where invoice_id = p_id and status = ''posted'';
  pd := pd + ap;');
  d := pg_temp.rep(d, 'when pd > 0 and rf >= pd then ''refunded'' when tot - pd + rf <= 0 then ''paid''',
    'when cn >= tot and pd - rf <= 0 then ''credited'' when pd > 0 and rf >= pd then ''refunded'' when tot - cn - pd + rf <= 0 then ''paid''');
  d := pg_temp.rep(d, '''refunded'', rf, ''balance'', tot - pd + rf,', '''refunded'', rf, ''credited'', cn, ''applied'', ap, ''balance'', tot - cn - pd + rf,');
  d := pg_temp.rep(d, 'from public.acc_refunds f where f.invoice_id = p_id), ''[]''::jsonb));',
    'from public.acc_refunds f where f.invoice_id = p_id), ''[]''::jsonb),
    ''credit_notes'', coalesce((select jsonb_agg(jsonb_build_object(''id'', n.id, ''cn_no'', n.cn_no, ''kind'', n.kind, ''date'', n.cn_date, ''amount'', n.amount, ''reason'', n.reason, ''status'', n.status) order by n.cn_date, n.created_at) from public.acc_credit_notes n where n.invoice_id = p_id), ''[]''::jsonb),
    ''applications'', coalesce((select jsonb_agg(jsonb_build_object(''id'', c.id, ''app_no'', c.app_no, ''date'', c.app_date, ''amount'', c.amount, ''status'', c.status) order by c.app_date, c.created_at) from public.acc_credit_applications c where c.invoice_id = p_id), ''[]''::jsonb));');
  execute d;

  d := pg_get_functiondef('public.acc_invoices_list(text,text,date,date,integer,integer)'::regprocedure);
  d := pg_temp.rep(d, 'coalesce((select sum(amount) from public.acc_receipts r where r.invoice_id = i.id and r.status = ''posted''), 0) paid,',
    '(coalesce((select sum(amount) from public.acc_receipts r where r.invoice_id = i.id and r.status = ''posted''), 0) + coalesce((select sum(amount) from public.acc_credit_applications a where a.invoice_id = i.id and a.status = ''posted''), 0)) paid,');
  d := pg_temp.rep(d, 'coalesce((select sum(amount) from public.acc_refunds f where f.invoice_id = i.id and f.status = ''posted''), 0) refunded',
    'coalesce((select sum(amount) from public.acc_refunds f where f.invoice_id = i.id and f.status = ''posted''), 0) refunded,
        coalesce((select sum(amount) from public.acc_credit_notes n where n.invoice_id = i.id and n.status = ''posted''), 0) credited');
  d := pg_temp.rep(d, '(total - paid + refunded) balance,', '(total - credited - paid + refunded) balance,');
  d := pg_temp.rep(d, 'when paid > 0 and refunded >= paid then ''refunded''', 'when credited >= total and paid - refunded <= 0 then ''credited'' when paid > 0 and refunded >= paid then ''refunded''');
  d := pg_temp.rep(d, 'when (total - paid + refunded) <= 0 then ''paid''', 'when (total - credited - paid + refunded) <= 0 then ''paid''');
  d := pg_temp.rep(d, '''billed'', (select coalesce(sum(total), 0) from f where status <> ''void'')', '''billed'', (select coalesce(sum(total - credited), 0) from f where status <> ''void'')');
  d := pg_temp.rep(d, 'where status not in (''void'', ''paid'', ''refunded''))', 'where status not in (''void'', ''paid'', ''refunded'', ''credited''))');
  d := pg_temp.rep(d, '''total'', total, ''paid'', paid, ''refunded'', refunded,', '''total'', total, ''paid'', paid, ''refunded'', refunded, ''credited'', credited,');
  execute d;

  d := pg_get_functiondef('public.acc_record_refund(uuid,numeric,text,date,text,uuid,text)'::regprocedure);
  d := pg_temp.rep(d, 'perform pg_advisory_xact_lock(hashtextextended(''acc:patient:'' || p_patient, 0));',
    'if not public.acc_is_controller() and amt > coalesce((select refund_approval_limit from public.acc_settings where id), 0) then
    raise exception ''Refunds above % need the financial controller to approve them. Submit a refund request instead.'', to_char((select refund_approval_limit from public.acc_settings where id), ''FM999,999,999,990.00'');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(''acc:patient:'' || p_patient, 0));');
  execute d;

  d := pg_get_functiondef('public.acc_void_invoice(uuid,text)'::regprocedure);
  d := pg_temp.rep(d, 'or exists (select 1 from public.acc_refunds where invoice_id = p_id and status = ''posted'') then',
    'or exists (select 1 from public.acc_refunds where invoice_id = p_id and status = ''posted'') or exists (select 1 from public.acc_credit_notes where invoice_id = p_id and status = ''posted'') or exists (select 1 from public.acc_credit_applications where invoice_id = p_id and status = ''posted'') then');
  d := pg_temp.rep(d, '''Reverse the payments on this invoice before voiding it''', '''Reverse the payments, credit notes and applied credit on this invoice before voiding it''');
  execute d;
end $$;

create or replace function public.acc_set_refund_limit(p_limit numeric) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.acc__require('control');
  if p_limit is null or p_limit < 0 or p_limit > 1000000000 then raise exception 'Enter a valid limit'; end if;
  update public.acc_settings set refund_approval_limit = round(p_limit, 2), updated_at = now(), updated_by = auth.uid() where id;
end $$;

create or replace function public.acc_submit_refund(p_patient uuid, p_amount numeric, p_method text, p_date date, p_reason text, p_invoice uuid, p_idem text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ex public.acc_refund_requests; amt numeric; credit numeric; lim numeric; rid uuid; rno text; r jsonb;
begin
  perform public.acc__require('post');
  if coalesce(char_length(p_idem), 0) < 8 then raise exception 'Missing submission key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('acc:rrq:' || p_idem, 0));
  select * into ex from public.acc_refund_requests where idempotency_key = p_idem;
  if found then return jsonb_build_object('id', ex.id, 'request_no', ex.request_no, 'status', ex.status, 'refund_no', (select refund_no from public.acc_refunds where id = ex.refund_id)); end if;
  amt := public.acc__amount(p_amount, 'Refund amount');
  if p_method not in ('cash','bank','card','ecocash','innbucks','other') then raise exception 'Choose how the refund is paid'; end if;
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'Give a reason for the refund'; end if;
  if not exists (select 1 from public.profiles where id = p_patient and role = 'patient') then raise exception 'Choose a patient'; end if;
  if p_invoice is not null and not exists (select 1 from public.acc_invoices where id = p_invoice and patient_id = p_patient) then raise exception 'That invoice does not belong to this patient'; end if;
  perform pg_advisory_xact_lock(hashtextextended('acc:patient:' || p_patient, 0));
  credit := -public.acc__patient_ar(p_patient);
  if credit < amt then raise exception 'This patient has % in credit available to refund', to_char(greatest(credit, 0), 'FM999,999,999,990.00'); end if;
  select refund_approval_limit into lim from public.acc_settings where id;
  rid := gen_random_uuid(); rno := 'RRQ-' || lpad(nextval('public.acc_rrq_seq')::text, 6, '0');
  insert into public.acc_refund_requests (id, request_no, patient_id, invoice_id, amount, method, refund_date, reason, idempotency_key, requested_by)
  values (rid, rno, p_patient, p_invoice, amt, p_method, coalesce(p_date, public.acc__today()), btrim(p_reason), p_idem, auth.uid());
  if public.acc_is_controller() or amt <= lim then
    r := public.acc_record_refund(p_patient, amt, p_method, coalesce(p_date, public.acc__today()), btrim(p_reason), p_invoice, 'rrq:' || rid::text);
    update public.acc_refund_requests set status = 'approved', decided_by = auth.uid(), decided_at = now(), refund_id = (r->>'id')::uuid,
      decision_note = case when public.acc_is_controller() then 'Approved by the financial controller' else 'Within the approval limit' end where id = rid;
    return jsonb_build_object('id', rid, 'request_no', rno, 'status', 'approved', 'refund_no', r->>'refund_no');
  end if;
  return jsonb_build_object('id', rid, 'request_no', rno, 'status', 'pending');
end $$;

create or replace function public.acc_decide_refund(p_id uuid, p_approve boolean, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare q public.acc_refund_requests; r jsonb;
begin
  perform public.acc__require('control');
  select * into q from public.acc_refund_requests where id = p_id for update;
  if not found then raise exception 'Refund request not found'; end if;
  if q.status <> 'pending' then raise exception '% is already %', q.request_no, q.status; end if;
  if not p_approve then
    if coalesce(char_length(btrim(p_note)), 0) < 3 then raise exception 'Give the reason the refund was rejected'; end if;
    update public.acc_refund_requests set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_note = btrim(p_note) where id = q.id;
    return jsonb_build_object('id', q.id, 'status', 'rejected');
  end if;
  r := public.acc_record_refund(q.patient_id, q.amount, q.method, public.acc__today(), q.reason, q.invoice_id, 'rrq:' || q.id::text);
  update public.acc_refund_requests set status = 'approved', decided_by = auth.uid(), decided_at = now(), decision_note = nullif(btrim(p_note), ''), refund_id = (r->>'id')::uuid where id = q.id;
  return jsonb_build_object('id', q.id, 'status', 'approved', 'refund_no', r->>'refund_no');
end $$;

create or replace function public.acc_cancel_refund_request(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare q public.acc_refund_requests;
begin
  perform public.acc__require('post');
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'Give a reason'; end if;
  select * into q from public.acc_refund_requests where id = p_id for update;
  if not found then raise exception 'Refund request not found'; end if;
  if q.status <> 'pending' then raise exception '% is already %', q.request_no, q.status; end if;
  if q.requested_by <> auth.uid() and not public.acc_is_controller() then raise exception 'Only the person who asked for it or the financial controller can cancel this request'; end if;
  update public.acc_refund_requests set status = 'cancelled', decided_by = auth.uid(), decided_at = now(), decision_note = btrim(p_reason) where id = q.id;
  return jsonb_build_object('id', q.id, 'status', 'cancelled');
end $$;

create or replace function public.acc_refund_requests_list(p_status text default null, p_search text default null, p_from date default null, p_to date default null, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare qs text := nullif(btrim(p_search), '');
begin
  perform public.acc__require('view');
  return (with f as (select q.*, public.acc__pname(q.patient_id) patient, inv.invoice_no, rf.refund_no from public.acc_refund_requests q left join public.acc_invoices inv on inv.id = q.invoice_id left join public.acc_refunds rf on rf.id = q.refund_id
      where (p_status is null or q.status = p_status) and (p_from is null or q.created_at::date >= p_from) and (p_to is null or q.created_at::date <= p_to)
        and (qs is null or q.request_no ilike '%' || qs || '%' or public.acc__pname(q.patient_id) ilike '%' || qs || '%' or q.reason ilike '%' || qs || '%')),
    pg as (select * from f order by created_at desc limit least(coalesce(p_limit, 50), 200) offset greatest(coalesce(p_offset, 0), 0))
    select jsonb_build_object('total_count', (select count(*) from f), 'limit', (select refund_approval_limit from public.acc_settings where id),
      'pending_n', (select count(*) from f where status = 'pending'), 'pending', (select coalesce(sum(amount), 0) from f where status = 'pending'),
      'approved', (select coalesce(sum(amount), 0) from f where status = 'approved'),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'request_no', request_no, 'patient_id', patient_id, 'patient', patient, 'invoice_no', invoice_no, 'amount', amount, 'method', method, 'date', refund_date, 'reason', reason,
        'status', status, 'refund_no', refund_no, 'note', decision_note, 'created_at', created_at,
        'requested_by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = pg.requested_by), 'requested_by_id', requested_by,
        'decided_by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = pg.decided_by), 'decided_at', decided_at) order by created_at desc) from pg), '[]'::jsonb)));
end $$;

create or replace function public.acc_create_credit_note(p_kind text, p_invoice uuid, p_amount numeric, p_account uuid, p_date date, p_reason text, p_idem text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ex public.acc_credit_notes; inv public.acc_invoices; amt numeric; acct uuid; a public.acc_accounts; gross numeric; credited numeric; outst numeric; cid uuid; cno text; eid uuid; dt date; lim numeric;
begin
  perform public.acc__require('post');
  if coalesce(char_length(p_idem), 0) < 8 then raise exception 'Missing submission key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('acc:cn:' || p_idem, 0));
  select * into ex from public.acc_credit_notes where idempotency_key = p_idem;
  if found then return jsonb_build_object('id', ex.id, 'cn_no', ex.cn_no); end if;
  if p_kind not in ('credit_note','write_off') then raise exception 'Choose credit note or write-off'; end if;
  amt := public.acc__amount(p_amount);
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'Give a reason'; end if;
  select * into inv from public.acc_invoices where id = p_invoice for update;
  if not found or inv.status <> 'issued' then raise exception 'Choose an open invoice'; end if;
  dt := coalesce(p_date, public.acc__today());
  if dt < inv.issue_date then raise exception 'The date cannot be before the invoice date'; end if;
  select coalesce(sum(amount), 0) into gross from public.acc_invoice_lines where invoice_id = inv.id and active;
  select coalesce(sum(amount), 0) into credited from public.acc_credit_notes where invoice_id = inv.id and status = 'posted';
  outst := public.acc__invoice_outstanding(inv.id);
  select refund_approval_limit into lim from public.acc_settings where id;
  if p_kind = 'write_off' then
    perform public.acc__require('control');
    if amt > outst then raise exception 'Only % is outstanding on this invoice, so that is the most you can write off', to_char(greatest(outst, 0), 'FM999,999,999,990.00'); end if;
    acct := public.acc__acct_code('5920');
  else
    if amt > lim and not public.acc_is_controller() then raise exception 'Credit notes above % need the financial controller', to_char(lim, 'FM999,999,999,990.00'); end if;
    if amt > gross - credited then raise exception 'This invoice was billed % and has % credited already, so you can credit at most %', to_char(gross, 'FM999,999,999,990.00'), to_char(credited, 'FM999,999,999,990.00'), to_char(gross - credited, 'FM999,999,999,990.00'); end if;
    acct := p_account;
    if acct is null then
      select revenue_account_id into acct from public.acc_invoice_lines where invoice_id = inv.id and active order by amount desc limit 1;
    end if;
    select * into a from public.acc_accounts where id = acct;
    if not found or a.type <> 'revenue' or a.is_header or not a.is_active then raise exception 'Choose the revenue account the credit note reduces'; end if;
  end if;
  cid := gen_random_uuid(); cno := 'CN-' || lpad(nextval('public.acc_cn_seq')::text, 6, '0');
  eid := public.acc__post(dt, 'document', case when p_kind = 'write_off' then 'Write-off ' else 'Credit note ' end || cno || ' for ' || inv.invoice_no, cno, 'credit_note', cid,
    jsonb_build_array(jsonb_build_object('account_id', acct, 'debit', amt, 'description', btrim(p_reason)),
                      jsonb_build_object('account_id', public.acc__ar_account(), 'credit', amt, 'patient_id', inv.patient_id, 'description', cno || ' against ' || inv.invoice_no)), 'cn:' || p_idem);
  insert into public.acc_credit_notes (id, cn_no, kind, invoice_id, patient_id, cn_date, account_id, amount, reason, entry_id, idempotency_key, created_by)
  values (cid, cno, p_kind, inv.id, inv.patient_id, dt, acct, amt, btrim(p_reason), eid, p_idem, auth.uid());
  return jsonb_build_object('id', cid, 'cn_no', cno);
end $$;

create or replace function public.acc_reverse_credit_note(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare n public.acc_credit_notes; rid uuid;
begin
  perform public.acc__require('control');
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'Give a reason for the reversal'; end if;
  select * into n from public.acc_credit_notes where id = p_id for update;
  if not found then raise exception 'Credit note not found'; end if;
  if n.status <> 'posted' then raise exception '% has already been reversed', n.cn_no; end if;
  rid := public.acc__reverse(n.entry_id, public.acc__today(), n.cn_no || ' reversed: ' || btrim(p_reason), 'rvn:' || n.id::text);
  update public.acc_credit_notes set status = 'reversed', reversal_entry_id = rid where id = n.id;
  return jsonb_build_object('id', n.id, 'cn_no', n.cn_no);
end $$;

create or replace function public.acc_credit_notes_list(p_search text default null, p_kind text default null, p_status text default null, p_from date default null, p_to date default null, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare qs text := nullif(btrim(p_search), '');
begin
  perform public.acc__require('view');
  return (with f as (select n.*, inv.invoice_no, public.acc__pname(n.patient_id) patient, a.code || ' ' || a.name account from public.acc_credit_notes n join public.acc_invoices inv on inv.id = n.invoice_id join public.acc_accounts a on a.id = n.account_id
      where (p_kind is null or n.kind = p_kind) and (p_status is null or n.status = p_status) and (p_from is null or n.cn_date >= p_from) and (p_to is null or n.cn_date <= p_to)
        and (qs is null or n.cn_no ilike '%' || qs || '%' or inv.invoice_no ilike '%' || qs || '%' or public.acc__pname(n.patient_id) ilike '%' || qs || '%' or n.reason ilike '%' || qs || '%')),
    pg as (select * from f order by cn_date desc, created_at desc limit least(coalesce(p_limit, 50), 200) offset greatest(coalesce(p_offset, 0), 0))
    select jsonb_build_object('total_count', (select count(*) from f), 'credit_notes', (select coalesce(sum(amount), 0) from f where kind = 'credit_note' and status = 'posted'),
      'write_offs', (select coalesce(sum(amount), 0) from f where kind = 'write_off' and status = 'posted'),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'cn_no', cn_no, 'kind', kind, 'invoice_id', invoice_id, 'invoice_no', invoice_no, 'patient', patient, 'date', cn_date, 'account', account, 'amount', amount, 'reason', reason, 'status', status,
        'by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = pg.created_by)) order by cn_date desc, created_at desc) from pg), '[]'::jsonb)));
end $$;

create or replace function public.acc_patient_credits(p_search text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare qs text := nullif(btrim(p_search), '');
begin
  perform public.acc__require('view');
  return (with pts as (select p.id, public.acc__pname(p.id) name, p.patient_code code from public.profiles p where p.role = 'patient' and (qs is null or public.acc__pname(p.id) ilike '%' || qs || '%' or coalesce(p.patient_code, '') ilike '%' || qs || '%')),
    b as (select pts.*, public.acc__patient_ar(pts.id) ar,
      (select coalesce(sum(amount), 0) from public.acc_receipts r where r.patient_id = pts.id and r.invoice_id is null and r.status = 'posted')
        - (select coalesce(sum(amount), 0) from public.acc_credit_applications c where c.patient_id = pts.id and c.status = 'posted')
        - (select coalesce(sum(amount), 0) from public.acc_refunds f where f.patient_id = pts.id and f.status = 'posted') adv,
      (select coalesce(sum(greatest(public.acc__invoice_outstanding(i.id), 0)), 0) from public.acc_invoices i where i.patient_id = pts.id and i.status = 'issued') owing,
      (select count(*) from public.acc_invoices i where i.patient_id = pts.id and i.status = 'issued' and public.acc__invoice_outstanding(i.id) > 0) open_n from pts),
    f as (select * from b where greatest(-ar, 0) > 0 or adv > 0)
    select jsonb_build_object('total_credit', (select coalesce(sum(greatest(-ar, 0)), 0) from f), 'total_advance', (select coalesce(sum(greatest(adv, 0)), 0) from f),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('patient_id', id, 'patient', name, 'code', code, 'ar', ar, 'credit', greatest(-ar, 0), 'advance', greatest(adv, 0), 'owing', owing, 'open_invoices', open_n) order by greatest(-ar, 0) desc, name) from f), '[]'::jsonb)));
end $$;

create or replace function public.acc_patient_credit_history(p_patient uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.acc__require('view');
  return jsonb_build_object('patient', public.acc__pname(p_patient), 'balance', public.acc__patient_ar(p_patient),
    'open_invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'invoice_no', i.invoice_no, 'outstanding', public.acc__invoice_outstanding(i.id), 'due_date', i.due_date) order by i.issue_date)
        from public.acc_invoices i where i.patient_id = p_patient and i.status = 'issued' and public.acc__invoice_outstanding(i.id) > 0), '[]'::jsonb),
    'advance', (select greatest(coalesce(sum(amount), 0), 0) from public.acc_receipts r where r.patient_id = p_patient and r.invoice_id is null and r.status = 'posted')
        - (select coalesce(sum(amount), 0) from public.acc_credit_applications c where c.patient_id = p_patient and c.status = 'posted')
        - (select coalesce(sum(amount), 0) from public.acc_refunds f where f.patient_id = p_patient and f.status = 'posted'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('date', x.entry_date, 'entry_no', x.entry_no, 'description', x.description, 'debit', x.debit, 'credit', x.credit, 'balance', x.run) order by x.entry_date, x.id)
      from (select l.id, l.entry_date, e.entry_no, coalesce(nullif(l.description, ''), e.description) description, l.debit, l.credit, sum(l.debit - l.credit) over (order by l.entry_date, l.id) run
            from public.acc_journal_lines l join public.acc_journal_entries e on e.id = l.entry_id join public.acc_accounts a on a.id = l.account_id and a.subtype = 'receivable_patient' where l.patient_id = p_patient) x), '[]'::jsonb));
end $$;

create or replace function public.acc_apply_credit(p_patient uuid, p_invoice uuid, p_amount numeric, p_idem text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ex public.acc_credit_applications; inv public.acc_invoices; amt numeric; adv numeric; outst numeric; cid uuid; cno text; eid uuid; ar uuid := public.acc__ar_account(); dt date := public.acc__today();
begin
  perform public.acc__require('post');
  if coalesce(char_length(p_idem), 0) < 8 then raise exception 'Missing submission key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('acc:cap:' || p_idem, 0));
  select * into ex from public.acc_credit_applications where idempotency_key = p_idem;
  if found then return jsonb_build_object('id', ex.id, 'app_no', ex.app_no); end if;
  amt := public.acc__amount(p_amount, 'Amount');
  perform pg_advisory_xact_lock(hashtextextended('acc:patient:' || p_patient, 0));
  select * into inv from public.acc_invoices where id = p_invoice and patient_id = p_patient for update;
  if not found or inv.status <> 'issued' then raise exception 'Choose an open invoice for this patient'; end if;
  outst := public.acc__invoice_outstanding(inv.id);
  if amt > outst then raise exception 'Only % is outstanding on % ', to_char(greatest(outst, 0), 'FM999,999,999,990.00'), inv.invoice_no; end if;
  select coalesce(sum(amount), 0) into adv from public.acc_receipts where patient_id = p_patient and invoice_id is null and status = 'posted';
  adv := adv - (select coalesce(sum(amount), 0) from public.acc_credit_applications where patient_id = p_patient and status = 'posted') - (select coalesce(sum(amount), 0) from public.acc_refunds where patient_id = p_patient and status = 'posted');
  if amt > adv then raise exception 'This patient has only % in advance payments to apply', to_char(greatest(adv, 0), 'FM999,999,999,990.00'); end if;
  cid := gen_random_uuid(); cno := 'CAP-' || lpad(nextval('public.acc_cap_seq')::text, 6, '0');
  eid := public.acc__post(dt, 'document', 'Patient credit ' || cno || ' applied to ' || inv.invoice_no, cno, 'credit_application', cid,
    jsonb_build_array(jsonb_build_object('account_id', ar, 'debit', amt, 'patient_id', p_patient, 'description', 'Credit applied to ' || inv.invoice_no),
                      jsonb_build_object('account_id', ar, 'credit', amt, 'patient_id', p_patient, 'description', 'Advance payment used by ' || cno)), 'cap:' || p_idem);
  insert into public.acc_credit_applications (id, app_no, patient_id, invoice_id, amount, app_date, entry_id, idempotency_key, created_by) values (cid, cno, p_patient, inv.id, amt, dt, eid, p_idem, auth.uid());
  return jsonb_build_object('id', cid, 'app_no', cno);
end $$;

create or replace function public.acc_reverse_credit_application(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.acc_credit_applications; rid uuid;
begin
  perform public.acc__require('control');
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'Give a reason for the reversal'; end if;
  select * into c from public.acc_credit_applications where id = p_id for update;
  if not found then raise exception 'Application not found'; end if;
  if c.status <> 'posted' then raise exception '% has already been reversed', c.app_no; end if;
  rid := public.acc__reverse(c.entry_id, public.acc__today(), c.app_no || ' reversed: ' || btrim(p_reason), 'rvc2:' || c.id::text);
  update public.acc_credit_applications set status = 'reversed', reversal_entry_id = rid where id = c.id;
  return jsonb_build_object('id', c.id, 'app_no', c.app_no);
end $$;

create or replace function public.acc_create_adjustment(p_date date, p_debit uuid, p_credit uuid, p_amount numeric, p_reason text, p_patient uuid, p_idem text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ex public.acc_adjustments; d public.acc_accounts; c public.acc_accounts; amt numeric; aid uuid; ano text; eid uuid; dt date; ls jsonb;
begin
  perform public.acc__require('control');
  if coalesce(char_length(p_idem), 0) < 8 then raise exception 'Missing submission key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('acc:adj:' || p_idem, 0));
  select * into ex from public.acc_adjustments where idempotency_key = p_idem;
  if found then return jsonb_build_object('id', ex.id, 'adj_no', ex.adj_no); end if;
  amt := public.acc__amount(p_amount);
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'Give a reason for the adjustment'; end if;
  if p_debit = p_credit then raise exception 'Choose two different accounts'; end if;
  select * into d from public.acc_accounts where id = p_debit; select * into c from public.acc_accounts where id = p_credit;
  if d.id is null or c.id is null or d.is_header or c.is_header or not d.is_active or not c.is_active then raise exception 'Choose active accounts to adjust'; end if;
  if d.subtype in ('cash','bank','mobile_money') or c.subtype in ('cash','bank','mobile_money') then raise exception 'Cash, bank and mobile money balances change through the Cash and banks page, so they can be reconciled'; end if;
  if d.subtype in ('payable_supplier','receivable_insurance') or c.subtype in ('payable_supplier','receivable_insurance') then raise exception 'Supplier and insurer balances change through bills, claims and payments'; end if;
  if (d.subtype = 'receivable_patient' or c.subtype = 'receivable_patient') and (p_patient is null or not exists (select 1 from public.profiles where id = p_patient and role = 'patient')) then raise exception 'Choose the patient whose balance is adjusted'; end if;
  dt := coalesce(p_date, public.acc__today());
  aid := gen_random_uuid(); ano := 'ADJ-' || lpad(nextval('public.acc_adj_seq')::text, 6, '0');
  ls := jsonb_build_array(jsonb_build_object('account_id', d.id, 'debit', amt, 'description', btrim(p_reason), 'patient_id', case when d.subtype = 'receivable_patient' then p_patient end),
                          jsonb_build_object('account_id', c.id, 'credit', amt, 'description', btrim(p_reason), 'patient_id', case when c.subtype = 'receivable_patient' then p_patient end));
  eid := public.acc__post(dt, 'document', 'Adjustment ' || ano || ': ' || btrim(p_reason), ano, 'adjustment', aid, ls, 'adj:' || p_idem);
  insert into public.acc_adjustments (id, adj_no, adj_date, debit_account_id, credit_account_id, amount, reason, patient_id, entry_id, idempotency_key, created_by)
  values (aid, ano, dt, d.id, c.id, amt, btrim(p_reason), p_patient, eid, p_idem, auth.uid());
  return jsonb_build_object('id', aid, 'adj_no', ano);
end $$;

create or replace function public.acc_reverse_adjustment(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a public.acc_adjustments; rid uuid;
begin
  perform public.acc__require('control');
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'Give a reason for the reversal'; end if;
  select * into a from public.acc_adjustments where id = p_id for update;
  if not found then raise exception 'Adjustment not found'; end if;
  if a.status <> 'posted' then raise exception '% has already been reversed', a.adj_no; end if;
  rid := public.acc__reverse(a.entry_id, public.acc__today(), a.adj_no || ' reversed: ' || btrim(p_reason), 'rva:' || a.id::text);
  update public.acc_adjustments set status = 'reversed', reversal_entry_id = rid where id = a.id;
  return jsonb_build_object('id', a.id, 'adj_no', a.adj_no);
end $$;

create or replace function public.acc_adjustments_list(p_search text default null, p_status text default null, p_from date default null, p_to date default null, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare qs text := nullif(btrim(p_search), '');
begin
  perform public.acc__require('view');
  return (with f as (select a.*, d.code || ' ' || d.name dname, c.code || ' ' || c.name cname from public.acc_adjustments a join public.acc_accounts d on d.id = a.debit_account_id join public.acc_accounts c on c.id = a.credit_account_id
      where (p_status is null or a.status = p_status) and (p_from is null or a.adj_date >= p_from) and (p_to is null or a.adj_date <= p_to) and (qs is null or a.adj_no ilike '%' || qs || '%' or a.reason ilike '%' || qs || '%')),
    pg as (select * from f order by adj_date desc, created_at desc limit least(coalesce(p_limit, 50), 200) offset greatest(coalesce(p_offset, 0), 0))
    select jsonb_build_object('total_count', (select count(*) from f), 'total', (select coalesce(sum(amount), 0) from f where status = 'posted'),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'adj_no', adj_no, 'date', adj_date, 'debit', dname, 'credit', cname, 'amount', amount, 'reason', reason, 'patient', case when patient_id is not null then public.acc__pname(patient_id) end, 'status', status,
        'by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = pg.created_by)) order by adj_date desc, created_at desc) from pg), '[]'::jsonb)));
end $$;

do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
    and p.proname in ('acc_set_refund_limit','acc_submit_refund','acc_decide_refund','acc_cancel_refund_request','acc_refund_requests_list','acc_create_credit_note','acc_reverse_credit_note','acc_credit_notes_list',
      'acc_patient_credits','acc_patient_credit_history','acc_apply_credit','acc_reverse_credit_application','acc_create_adjustment','acc_reverse_adjustment','acc_adjustments_list',
      'acc_record_refund','acc_invoice_detail','acc_invoices_list','acc_void_invoice')
  loop execute format('revoke all on function %s from public, anon', r.sig); execute format('grant execute on function %s to authenticated', r.sig); end loop;
end $$;
