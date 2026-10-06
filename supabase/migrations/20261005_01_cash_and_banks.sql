-- Group 3, module 1: Cash and banks (deposits, withdrawals, transfers, reconciliation, cash flow)
create sequence if not exists public.acc_cash_seq;
create sequence if not exists public.acc_rec_seq;

create table if not exists public.acc_cash_txns (
  id uuid primary key default gen_random_uuid(),
  txn_no text not null unique,
  kind text not null check (kind in ('deposit','withdrawal','transfer')),
  txn_date date not null,
  account_id uuid not null references public.acc_accounts(id),
  counter_account_id uuid not null references public.acc_accounts(id),
  amount numeric(14,2) not null check (amount > 0),
  description text not null check (char_length(btrim(description)) between 3 and 300),
  reference text check (char_length(reference) <= 120),
  status text not null default 'posted' check (status in ('posted','reversed')),
  entry_id uuid not null unique references public.acc_journal_entries(id),
  reversal_entry_id uuid references public.acc_journal_entries(id),
  idempotency_key text not null unique check (char_length(idempotency_key) between 8 and 200),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (account_id <> counter_account_id)
);
create index if not exists acc_cash_txns_date on public.acc_cash_txns (txn_date desc);
create index if not exists acc_cash_txns_acct on public.acc_cash_txns (account_id);

create table if not exists public.acc_bank_recs (
  id uuid primary key default gen_random_uuid(),
  rec_no text not null unique,
  account_id uuid not null references public.acc_accounts(id),
  statement_date date not null,
  statement_balance numeric(14,2) not null,
  opening_balance numeric(14,2) not null,
  cleared_total numeric(14,2) not null,
  line_count int not null,
  note text check (char_length(note) <= 300),
  status text not null default 'completed' check (status in ('completed','undone')),
  idempotency_key text not null unique check (char_length(idempotency_key) between 8 and 200),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  undone_by uuid, undone_at timestamptz
);
create table if not exists public.acc_bank_rec_items (
  rec_id uuid not null references public.acc_bank_recs(id) on delete cascade,
  line_id bigint not null unique references public.acc_journal_lines(id),
  primary key (rec_id, line_id)
);

alter table public.acc_cash_txns enable row level security;
alter table public.acc_bank_recs enable row level security;
alter table public.acc_bank_rec_items enable row level security;
create policy acc_read on public.acc_cash_txns for select using ((select public.acc_can_view()));
create policy acc_read on public.acc_bank_recs for select using ((select public.acc_can_view()));
create policy acc_read on public.acc_bank_rec_items for select using ((select public.acc_can_view()));
revoke all on public.acc_cash_txns, public.acc_bank_recs, public.acc_bank_rec_items from anon, authenticated;
grant select on public.acc_cash_txns, public.acc_bank_recs, public.acc_bank_rec_items to authenticated;

create trigger acc_audit after insert or update or delete on public.acc_cash_txns for each row execute function public.acc__audit();
create trigger acc_cash_guard before update or delete on public.acc_cash_txns for each row execute function public.acc__doc_guard('status','reversal_entry_id');
create trigger acc_audit after insert or update or delete on public.acc_bank_recs for each row execute function public.acc__audit();
create trigger acc_audit after insert or delete on public.acc_bank_rec_items for each row execute function public.acc__audit();

-- accounts with balances
create or replace function public.acc_cash_accounts(p_as_of date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare d date := coalesce(p_as_of, public.acc__today());
begin
  perform public.acc__require('view');
  return (with a as (select * from public.acc_accounts where subtype in ('cash','bank','mobile_money') and not is_header),
    b as (select a.id, a.code, a.name, a.subtype, a.payment_method, a.is_active,
      (select coalesce(sum(debit - credit), 0) from public.acc_journal_lines l where l.account_id = a.id and l.entry_date <= d) balance,
      (select coalesce(sum(l.debit - l.credit), 0) from public.acc_bank_rec_items i join public.acc_journal_lines l on l.id = i.line_id where l.account_id = a.id) reconciled,
      (select max(statement_date) from public.acc_bank_recs r where r.account_id = a.id and r.status = 'completed') last_rec,
      (select count(*) from public.acc_journal_lines l where l.account_id = a.id and not exists (select 1 from public.acc_bank_rec_items i where i.line_id = l.id)) unreconciled
      from a)
    select jsonb_build_object('as_of', d, 'total', coalesce((select sum(balance) from b where is_active), 0),
      'rows', coalesce((select jsonb_agg(to_jsonb(b) order by b.code) from b), '[]'::jsonb)));
end $$;

create or replace function public.acc_cash_txn(p_kind text, p_date date, p_account uuid, p_counter uuid, p_amount numeric, p_description text, p_reference text, p_idem text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare amt numeric; a public.acc_accounts; c public.acc_accounts; tid uuid; tno text; eid uuid; dt date; lines jsonb; ex public.acc_cash_txns; lbl text;
begin
  perform public.acc__require('post');
  if coalesce(char_length(p_idem), 0) < 8 then raise exception 'Missing submission key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('acc:csh:' || p_idem, 0));
  select * into ex from public.acc_cash_txns where idempotency_key = p_idem;
  if found then return jsonb_build_object('id', ex.id, 'txn_no', ex.txn_no); end if;
  amt := public.acc__amount(p_amount);
  if p_kind not in ('deposit','withdrawal','transfer') then raise exception 'Choose deposit, withdrawal or transfer'; end if;
  if coalesce(char_length(btrim(p_description)), 0) < 3 then raise exception 'Describe the transaction'; end if;
  dt := coalesce(p_date, public.acc__today());
  select * into a from public.acc_accounts where id = p_account;
  if not found or a.is_header or not a.is_active or a.subtype not in ('cash','bank','mobile_money') then raise exception 'Choose an active cash, bank or mobile money account'; end if;
  select * into c from public.acc_accounts where id = p_counter;
  if not found or c.is_header or not c.is_active then raise exception 'Choose the other account'; end if;
  if c.id = a.id then raise exception 'Choose two different accounts'; end if;
  tid := gen_random_uuid();
  tno := 'CSH-' || lpad(nextval('public.acc_cash_seq')::text, 6, '0');
  lbl := initcap(p_kind) || ' ' || tno || ': ' || btrim(p_description);
  if p_kind = 'transfer' then
    if c.subtype not in ('cash','bank','mobile_money') then raise exception 'Choose the cash, bank or mobile money account to transfer to'; end if;
    perform public.acc__payment_account(a.id, amt, dt);
    lines := jsonb_build_array(jsonb_build_object('account_id', c.id, 'debit', amt, 'description', lbl), jsonb_build_object('account_id', a.id, 'credit', amt, 'description', lbl));
  else
    if c.subtype in ('cash','bank','mobile_money') then raise exception 'Use a transfer to move money between your own accounts'; end if;
    if c.subtype in ('receivable_patient','payable_supplier') then raise exception 'Patient and supplier balances change through invoices, receipts and bills'; end if;
    if c.subtype = 'receivable_insurance' then raise exception 'Insurance claims and insurer payments are recorded on the Insurance page'; end if;
    if p_kind = 'deposit' then
      lines := jsonb_build_array(jsonb_build_object('account_id', a.id, 'debit', amt, 'description', lbl), jsonb_build_object('account_id', c.id, 'credit', amt, 'description', lbl));
    else
      perform public.acc__payment_account(a.id, amt, dt);
      lines := jsonb_build_array(jsonb_build_object('account_id', c.id, 'debit', amt, 'description', lbl), jsonb_build_object('account_id', a.id, 'credit', amt, 'description', lbl));
    end if;
  end if;
  eid := public.acc__post(dt, 'document', initcap(p_kind) || ' ' || tno || ' - ' || btrim(p_description), coalesce(nullif(btrim(p_reference), ''), tno), 'cash_txn', tid, lines, 'csh:' || p_idem);
  insert into public.acc_cash_txns (id, txn_no, kind, txn_date, account_id, counter_account_id, amount, description, reference, entry_id, idempotency_key, created_by)
  values (tid, tno, p_kind, dt, a.id, c.id, amt, btrim(p_description), nullif(btrim(p_reference), ''), eid, p_idem, auth.uid());
  return jsonb_build_object('id', tid, 'txn_no', tno);
end $$;

create or replace function public.acc_reverse_cash_txn(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare t public.acc_cash_txns; rid uuid;
begin
  perform public.acc__require('control');
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'Give a reason for the reversal'; end if;
  select * into t from public.acc_cash_txns where id = p_id for update;
  if not found then raise exception 'Transaction not found'; end if;
  if t.status <> 'posted' then raise exception '% has already been reversed', t.txn_no; end if;
  rid := public.acc__reverse(t.entry_id, public.acc__today(), t.txn_no || ' reversed: ' || btrim(p_reason), 'rvc:' || t.id::text);
  update public.acc_cash_txns set status = 'reversed', reversal_entry_id = rid where id = t.id;
  return jsonb_build_object('id', t.id, 'txn_no', t.txn_no);
end $$;

create or replace function public.acc_cash_txns_list(p_search text default null, p_kind text default null, p_account uuid default null, p_status text default null, p_from date default null, p_to date default null, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare q text := nullif(btrim(p_search), '');
begin
  perform public.acc__require('view');
  return (with f as (select t.*, a.code a_code, a.name a_name, c.code c_code, c.name c_name from public.acc_cash_txns t
        join public.acc_accounts a on a.id = t.account_id join public.acc_accounts c on c.id = t.counter_account_id
      where (p_kind is null or t.kind = p_kind) and (p_account is null or t.account_id = p_account or t.counter_account_id = p_account) and (p_status is null or t.status = p_status)
        and (p_from is null or t.txn_date >= p_from) and (p_to is null or t.txn_date <= p_to)
        and (q is null or t.txn_no ilike '%' || q || '%' or t.description ilike '%' || q || '%' or coalesce(t.reference, '') ilike '%' || q || '%')),
    pg as (select * from f order by txn_date desc, created_at desc limit least(coalesce(p_limit, 50), 200) offset greatest(coalesce(p_offset, 0), 0))
    select jsonb_build_object('total_count', (select count(*) from f),
      'deposits', (select coalesce(sum(amount), 0) from f where kind = 'deposit' and status = 'posted'),
      'withdrawals', (select coalesce(sum(amount), 0) from f where kind = 'withdrawal' and status = 'posted'),
      'transfers', (select coalesce(sum(amount), 0) from f where kind = 'transfer' and status = 'posted'),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'txn_no', txn_no, 'kind', kind, 'date', txn_date, 'account_id', account_id, 'account', a_code || ' ' || a_name,
        'counter_id', counter_account_id, 'counter', c_code || ' ' || c_name, 'amount', amount, 'description', description, 'reference', reference, 'status', status,
        'by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = pg.created_by)) order by txn_date desc, created_at desc) from pg), '[]'::jsonb)));
end $$;

-- reconciliation
create or replace function public.acc_rec_candidates(p_account uuid, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.acc_accounts; opening numeric; last_r public.acc_bank_recs;
begin
  perform public.acc__require('view');
  select * into a from public.acc_accounts where id = p_account and subtype in ('cash','bank','mobile_money') and not is_header;
  if not found then raise exception 'Choose a cash, bank or mobile money account'; end if;
  select coalesce(sum(l.debit - l.credit), 0) into opening from public.acc_bank_rec_items i join public.acc_journal_lines l on l.id = i.line_id where l.account_id = p_account;
  select * into last_r from public.acc_bank_recs where account_id = p_account and status = 'completed' order by statement_date desc, created_at desc, rec_no desc limit 1;
  return jsonb_build_object('account', a.code || ' ' || a.name, 'opening', opening, 'last_date', last_r.statement_date, 'last_balance', last_r.statement_balance,
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'date', l.entry_date, 'entry_no', e.entry_no, 'reference', e.reference, 'description', coalesce(nullif(l.description, ''), e.description),
        'debit', l.debit, 'credit', l.credit) order by l.entry_date, l.id)
      from public.acc_journal_lines l join public.acc_journal_entries e on e.id = l.entry_id
      where l.account_id = p_account and l.entry_date <= coalesce(p_to, public.acc__today()) and not exists (select 1 from public.acc_bank_rec_items i where i.line_id = l.id)), '[]'::jsonb));
end $$;

create or replace function public.acc_reconcile(p_account uuid, p_statement_date date, p_statement_balance numeric, p_line_ids bigint[], p_note text, p_idem text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a public.acc_accounts; ex public.acc_bank_recs; opening numeric; cleared numeric; n int; ids bigint[]; rid uuid; rno text; last_d date; diff numeric;
begin
  perform public.acc__require('post');
  if coalesce(char_length(p_idem), 0) < 8 then raise exception 'Missing submission key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('acc:rec:' || p_account::text, 0));
  select * into ex from public.acc_bank_recs where idempotency_key = p_idem;
  if found then return jsonb_build_object('id', ex.id, 'rec_no', ex.rec_no); end if;
  select * into a from public.acc_accounts where id = p_account and subtype in ('cash','bank','mobile_money') and not is_header;
  if not found then raise exception 'Choose a cash, bank or mobile money account'; end if;
  if p_statement_date is null or p_statement_balance is null then raise exception 'Enter the statement date and closing balance'; end if;
  if p_statement_balance <> round(p_statement_balance, 2) then raise exception 'Use at most two decimal places'; end if;
  select max(statement_date) into last_d from public.acc_bank_recs where account_id = p_account and status = 'completed';
  if last_d is not null and p_statement_date < last_d then raise exception 'A reconciliation up to % is already done. Choose a later statement date.', to_char(last_d, 'DD Mon YYYY'); end if;
  select array_agg(distinct x) into ids from unnest(coalesce(p_line_ids, '{}'::bigint[])) x;
  n := coalesce(cardinality(ids), 0);
  if n = 0 then raise exception 'Tick at least one transaction that appears on the statement'; end if;
  select count(*), coalesce(sum(debit - credit), 0) into n, cleared from public.acc_journal_lines where id = any(ids) and account_id = p_account and entry_date <= p_statement_date;
  if n <> cardinality(ids) then raise exception 'Some selected transactions do not belong to this account or are dated after the statement date'; end if;
  if exists (select 1 from public.acc_bank_rec_items where line_id = any(ids)) then raise exception 'Some selected transactions are already reconciled'; end if;
  select coalesce(sum(l.debit - l.credit), 0) into opening from public.acc_bank_rec_items i join public.acc_journal_lines l on l.id = i.line_id where l.account_id = p_account;
  diff := round(p_statement_balance - (opening + cleared), 2);
  if diff <> 0 then raise exception 'The statement does not balance. Difference: %', to_char(diff, 'FM999,999,999,990.00'); end if;
  rid := gen_random_uuid(); rno := 'REC-' || lpad(nextval('public.acc_rec_seq')::text, 6, '0');
  insert into public.acc_bank_recs (id, rec_no, account_id, statement_date, statement_balance, opening_balance, cleared_total, line_count, note, idempotency_key, created_by)
  values (rid, rno, p_account, p_statement_date, p_statement_balance, opening, cleared, n, nullif(btrim(p_note), ''), p_idem, auth.uid());
  insert into public.acc_bank_rec_items (rec_id, line_id) select rid, x from unnest(ids) x;
  return jsonb_build_object('id', rid, 'rec_no', rno, 'lines', n);
end $$;

create or replace function public.acc_undo_reconciliation(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.acc_bank_recs; latest uuid;
begin
  perform public.acc__require('control');
  select * into r from public.acc_bank_recs where id = p_id for update;
  if not found then raise exception 'Reconciliation not found'; end if;
  if r.status <> 'completed' then raise exception '% has already been undone', r.rec_no; end if;
  select id into latest from public.acc_bank_recs where account_id = r.account_id and status = 'completed' order by statement_date desc, created_at desc, rec_no desc limit 1;
  if latest <> r.id then raise exception 'Only the latest reconciliation of an account can be undone'; end if;
  delete from public.acc_bank_rec_items where rec_id = r.id;
  update public.acc_bank_recs set status = 'undone', undone_by = auth.uid(), undone_at = now() where id = r.id;
  return jsonb_build_object('id', r.id, 'rec_no', r.rec_no);
end $$;

create or replace function public.acc_recs_list(p_account uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.acc__require('view');
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'rec_no', r.rec_no, 'account_id', r.account_id, 'account', a.code || ' ' || a.name, 'statement_date', r.statement_date,
      'statement_balance', r.statement_balance, 'opening', r.opening_balance, 'cleared', r.cleared_total, 'lines', r.line_count, 'status', r.status, 'note', r.note, 'created_at', r.created_at,
      'by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = r.created_by)) order by r.created_at desc)
    from public.acc_bank_recs r join public.acc_accounts a on a.id = r.account_id where p_account is null or r.account_id = p_account), '[]'::jsonb);
end $$;

create or replace function public.acc_rec_detail(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.acc__require('view');
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('date', l.entry_date, 'entry_no', e.entry_no, 'description', coalesce(nullif(l.description, ''), e.description), 'debit', l.debit, 'credit', l.credit) order by l.entry_date, l.id)
    from public.acc_bank_rec_items i join public.acc_journal_lines l on l.id = i.line_id join public.acc_journal_entries e on e.id = l.entry_id where i.rec_id = p_id), '[]'::jsonb));
end $$;

-- cash flow summary
create or replace function public.acc_cashflow(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare f date := coalesce(p_from, date_trunc('month', public.acc__today())::date); t date := coalesce(p_to, public.acc__today());
begin
  perform public.acc__require('view');
  if t < f then raise exception 'The end date cannot be before the start date'; end if;
  return (with ca as (select * from public.acc_accounts where subtype in ('cash','bank','mobile_money') and not is_header),
    ea as (select l.entry_id, e.source_type, e.entry_type, e.entry_date, sum(l.debit - l.credit) net, sum(l.debit) dr
           from public.acc_journal_lines l join public.acc_journal_entries e on e.id = l.entry_id
           where l.account_id in (select id from ca) and l.entry_date between f and t group by 1, 2, 3, 4),
    pa as (select ca.id, ca.code, ca.name, ca.subtype,
             (select coalesce(sum(debit - credit), 0) from public.acc_journal_lines l where l.account_id = ca.id and l.entry_date < f) opening,
             (select coalesce(sum(debit), 0) from public.acc_journal_lines l where l.account_id = ca.id and l.entry_date between f and t) inflow,
             (select coalesce(sum(credit), 0) from public.acc_journal_lines l where l.account_id = ca.id and l.entry_date between f and t) outflow from ca),
    src as (select case when entry_type = 'reversal' then 'reversal' else source_type end source, sum(case when net > 0 then net else 0 end) inflow, sum(case when net < 0 then -net else 0 end) outflow
            from ea group by 1),
    mon as (select to_char(entry_date, 'YYYY-MM') m, sum(case when net > 0 then net else 0 end) inflow, sum(case when net < 0 then -net else 0 end) outflow from ea group by 1)
    select jsonb_build_object('from', f, 'to', t,
      'opening', (select coalesce(sum(opening), 0) from pa), 'inflow', (select coalesce(sum(case when net > 0 then net else 0 end), 0) from ea),
      'outflow', (select coalesce(sum(case when net < 0 then -net else 0 end), 0) from ea),
      'transfers', (select coalesce(sum(dr), 0) from ea where net = 0),
      'closing', (select coalesce(sum(opening + inflow - outflow), 0) from pa),
      'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name, 'subtype', subtype, 'opening', opening, 'inflow', inflow, 'outflow', outflow, 'closing', opening + inflow - outflow) order by code) from pa), '[]'::jsonb),
      'by_source', coalesce((select jsonb_agg(jsonb_build_object('source', source, 'inflow', inflow, 'outflow', outflow) order by inflow + outflow desc) from src), '[]'::jsonb),
      'by_month', coalesce((select jsonb_agg(jsonb_build_object('month', m, 'inflow', inflow, 'outflow', outflow) order by m) from mon), '[]'::jsonb)));
end $$;

do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
    and p.proname in ('acc_cash_accounts','acc_cash_txn','acc_reverse_cash_txn','acc_cash_txns_list','acc_rec_candidates','acc_reconcile','acc_undo_reconciliation','acc_recs_list','acc_rec_detail','acc_cashflow')
  loop execute format('revoke all on function %s from public, anon', r.sig); execute format('grant execute on function %s to authenticated', r.sig); end loop;
end $$;
