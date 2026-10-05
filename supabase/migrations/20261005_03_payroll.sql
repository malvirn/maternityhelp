-- Group 3, module 3: Payroll (financial controller only)
create sequence if not exists public.acc_emp_seq;
create sequence if not exists public.acc_prn_seq;
create sequence if not exists public.acc_spy_seq;

create table if not exists public.acc_pay_items (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 2 and 80),
  kind text not null check (kind in ('allowance','deduction','employer')),
  calc text not null check (calc in ('fixed','percent')),
  default_value numeric(12,4) not null default 0 check (default_value >= 0 and (calc = 'fixed' or default_value <= 100)),
  destination text check (destination in ('statutory','advance','other')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  check ((kind = 'deduction') = (destination is not null))
);
create unique index if not exists acc_pay_items_name_uq on public.acc_pay_items (lower(btrim(name)));

create table if not exists public.acc_employees (
  id uuid primary key default gen_random_uuid(),
  emp_no text not null unique,
  full_name text not null check (char_length(btrim(full_name)) between 2 and 120),
  job_title text check (char_length(job_title) <= 120),
  department text check (char_length(department) <= 80),
  profile_id uuid references public.profiles(id),
  start_date date not null,
  end_date date,
  base_salary numeric(14,2) not null check (base_salary > 0),
  pay_note text check (char_length(pay_note) <= 200),
  is_active boolean not null default true,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date is null or end_date >= start_date)
);
create table if not exists public.acc_employee_items (
  employee_id uuid not null references public.acc_employees(id) on delete cascade,
  item_id uuid not null references public.acc_pay_items(id),
  value numeric(12,4) check (value >= 0),
  primary key (employee_id, item_id)
);

create table if not exists public.acc_payroll_runs (
  id uuid primary key default gen_random_uuid(),
  run_no text not null unique,
  period_label text not null check (period_label ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  period_start date not null, period_end date not null, pay_date date not null,
  status text not null default 'draft' check (status in ('draft','approved','paid','cancelled')),
  gross numeric(14,2) not null default 0, deductions numeric(14,2) not null default 0, net numeric(14,2) not null default 0, employer numeric(14,2) not null default 0,
  notes text check (char_length(notes) <= 300),
  accrual_entry_id uuid references public.acc_journal_entries(id),
  idempotency_key text not null unique check (char_length(idempotency_key) between 8 and 200),
  created_by uuid default auth.uid(), created_at timestamptz not null default now(),
  approved_by uuid, approved_at timestamptz, cancelled_by uuid, cancelled_at timestamptz, cancel_reason text check (char_length(cancel_reason) <= 300)
);
create unique index if not exists acc_payroll_runs_period_uq on public.acc_payroll_runs (period_label) where status <> 'cancelled';

create table if not exists public.acc_payroll_payments (
  id uuid primary key default gen_random_uuid(),
  pay_no text not null unique,
  run_id uuid not null references public.acc_payroll_runs(id),
  account_id uuid not null references public.acc_accounts(id),
  amount numeric(14,2) not null check (amount > 0),
  paid_on date not null,
  reference text check (char_length(reference) <= 120),
  status text not null default 'posted' check (status in ('posted','reversed')),
  entry_id uuid not null unique references public.acc_journal_entries(id),
  reversal_entry_id uuid references public.acc_journal_entries(id),
  idempotency_key text not null unique check (char_length(idempotency_key) between 8 and 200),
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
create table if not exists public.acc_payslips (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.acc_payroll_runs(id),
  employee_id uuid not null references public.acc_employees(id),
  emp_no text not null, employee_name text not null, job_title text, department text,
  basic numeric(14,2) not null default 0, allowances numeric(14,2) not null default 0, deductions numeric(14,2) not null default 0, employer numeric(14,2) not null default 0,
  gross numeric(14,2) not null default 0, net numeric(14,2) not null default 0,
  payment_id uuid references public.acc_payroll_payments(id), paid_on date,
  unique (run_id, employee_id)
);
create table if not exists public.acc_payslip_lines (
  id bigserial primary key,
  payslip_id uuid not null references public.acc_payslips(id) on delete cascade,
  kind text not null check (kind in ('basic','allowance','deduction','employer')),
  label text not null check (char_length(btrim(label)) between 2 and 80),
  amount numeric(14,2) not null check (amount > 0),
  destination text check (destination in ('statutory','advance','other')),
  item_id uuid references public.acc_pay_items(id),
  one_off boolean not null default false
);
create index if not exists acc_payslips_run on public.acc_payslips (run_id);
create index if not exists acc_payslip_lines_slip on public.acc_payslip_lines (payslip_id);

do $$ declare t text; begin
  foreach t in array array['acc_pay_items','acc_employees','acc_employee_items','acc_payroll_runs','acc_payroll_payments','acc_payslips','acc_payslip_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy acc_ctl_read on public.%I for select using ((select public.acc_is_controller()))', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('create trigger acc_audit after insert or update or delete on public.%I for each row execute function public.acc__audit()', t);
  end loop;
end $$;
revoke all on sequence public.acc_payslip_lines_id_seq from anon, authenticated;

insert into public.acc_pay_items (name, kind, calc, default_value, destination) values
  ('Housing allowance','allowance','fixed',0,null), ('Transport allowance','allowance','fixed',0,null),
  ('NSSA (employee)','deduction','percent',4.5,'statutory'), ('PAYE','deduction','fixed',0,'statutory'), ('Staff loan recovery','deduction','fixed',0,'advance'),
  ('NSSA (employer)','employer','percent',4.5,null)
on conflict do nothing;

create or replace function public.acc__acct_code(p_code text) returns uuid language plpgsql stable security definer set search_path = '' as $$
declare a public.acc_accounts;
begin
  select * into a from public.acc_accounts where code = p_code;
  if not found or a.is_header or not a.is_active then raise exception 'Account % is missing or inactive in the chart of accounts', p_code; end if;
  return a.id;
end $$;

create or replace function public.acc__payslip_recalc(p_slip uuid) returns void language plpgsql security definer set search_path = '' as $$
declare v_basic numeric; v_all numeric; v_ded numeric; v_emp numeric; v_name text; v_run uuid;
begin
  select coalesce(sum(amount) filter (where kind = 'basic'), 0), coalesce(sum(amount) filter (where kind = 'allowance'), 0),
         coalesce(sum(amount) filter (where kind = 'deduction'), 0), coalesce(sum(amount) filter (where kind = 'employer'), 0)
    into v_basic, v_all, v_ded, v_emp from public.acc_payslip_lines where payslip_id = p_slip;
  select employee_name, run_id into v_name, v_run from public.acc_payslips where id = p_slip;
  if v_ded > v_basic + v_all then raise exception 'Deductions for % are more than the gross pay', v_name; end if;
  update public.acc_payslips set basic = v_basic, allowances = v_all, deductions = v_ded, employer = v_emp, gross = v_basic + v_all, net = v_basic + v_all - v_ded where id = p_slip;
  update public.acc_payroll_runs r set gross = t.g, deductions = t.d, net = t.n, employer = t.e
    from (select coalesce(sum(gross), 0) g, coalesce(sum(deductions), 0) d, coalesce(sum(net), 0) n, coalesce(sum(employer), 0) e from public.acc_payslips where run_id = v_run) t where r.id = v_run;
end $$;

create or replace function public.acc_pay_items_list() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.acc__require('control');
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kind', kind, 'calc', calc, 'value', default_value, 'destination', destination, 'is_active', is_active) order by kind, name) from public.acc_pay_items), '[]'::jsonb);
end $$;

create or replace function public.acc_save_pay_item(p_id uuid, p_name text, p_kind text, p_calc text, p_value numeric, p_dest text, p_active boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare rid uuid;
begin
  perform public.acc__require('control');
  if coalesce(char_length(btrim(p_name)), 0) < 2 then raise exception 'Enter a name'; end if;
  if p_kind not in ('allowance','deduction','employer') then raise exception 'Choose allowance, deduction or employer contribution'; end if;
  if p_calc not in ('fixed','percent') then raise exception 'Choose a fixed amount or a percentage'; end if;
  if p_value is null or p_value < 0 or (p_calc = 'percent' and p_value > 100) then raise exception 'Enter a valid amount or percentage'; end if;
  if p_kind = 'deduction' and p_dest not in ('statutory','advance','other') then raise exception 'Choose where the deducted money goes'; end if;
  if p_id is null then
    insert into public.acc_pay_items (name, kind, calc, default_value, destination, is_active) values (btrim(p_name), p_kind, p_calc, p_value, case when p_kind = 'deduction' then p_dest end, coalesce(p_active, true)) returning id into rid;
  else
    update public.acc_pay_items set name = btrim(p_name), kind = p_kind, calc = p_calc, default_value = p_value, destination = case when p_kind = 'deduction' then p_dest end, is_active = coalesce(p_active, true) where id = p_id returning id into rid;
    if rid is null then raise exception 'Item not found'; end if;
  end if;
  return rid;
exception when unique_violation then raise exception 'An item with that name already exists';
end $$;

create or replace function public.acc_employees_list() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.acc__require('control');
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'emp_no', e.emp_no, 'full_name', e.full_name, 'job_title', e.job_title, 'department', e.department, 'start_date', e.start_date, 'end_date', e.end_date,
      'base_salary', e.base_salary, 'pay_note', e.pay_note, 'is_active', e.is_active,
      'items', coalesce((select jsonb_agg(jsonb_build_object('item_id', i.id, 'name', i.name, 'kind', i.kind, 'calc', i.calc, 'value', coalesce(ei.value, i.default_value), 'override', ei.value is not null) order by i.kind, i.name)
                         from public.acc_employee_items ei join public.acc_pay_items i on i.id = ei.item_id where ei.employee_id = e.id), '[]'::jsonb)) order by e.is_active desc, e.full_name)
    from public.acc_employees e), '[]'::jsonb);
end $$;

create or replace function public.acc_save_employee(p_id uuid, p_name text, p_title text, p_dept text, p_start date, p_end date, p_salary numeric, p_note text, p_active boolean, p_items jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare rid uuid; it jsonb; v numeric;
begin
  perform public.acc__require('control');
  if coalesce(char_length(btrim(p_name)), 0) < 2 then raise exception 'Enter the employee''s name'; end if;
  if p_start is null then raise exception 'Enter the start date'; end if;
  if p_end is not null and p_end < p_start then raise exception 'The end date cannot be before the start date'; end if;
  p_salary := public.acc__amount(p_salary, 'Basic salary');
  if p_id is null then
    insert into public.acc_employees (emp_no, full_name, job_title, department, start_date, end_date, base_salary, pay_note, is_active)
    values ('EMP-' || lpad(nextval('public.acc_emp_seq')::text, 4, '0'), btrim(p_name), nullif(btrim(p_title), ''), nullif(btrim(p_dept), ''), p_start, p_end, p_salary, nullif(btrim(p_note), ''), coalesce(p_active, true)) returning id into rid;
  else
    update public.acc_employees set full_name = btrim(p_name), job_title = nullif(btrim(p_title), ''), department = nullif(btrim(p_dept), ''), start_date = p_start, end_date = p_end, base_salary = p_salary,
      pay_note = nullif(btrim(p_note), ''), is_active = coalesce(p_active, true), updated_at = now() where id = p_id returning id into rid;
    if rid is null then raise exception 'Employee not found'; end if;
  end if;
  delete from public.acc_employee_items where employee_id = rid;
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    for it in select value from jsonb_array_elements(p_items) loop
      if not exists (select 1 from public.acc_pay_items where id = (it->>'item_id')::uuid) then raise exception 'An allowance or deduction was not found'; end if;
      v := nullif(it->>'value', '')::numeric;
      if v is not null and v < 0 then raise exception 'Amounts cannot be negative'; end if;
      insert into public.acc_employee_items (employee_id, item_id, value) values (rid, (it->>'item_id')::uuid, v) on conflict (employee_id, item_id) do update set value = excluded.value;
    end loop;
  end if;
  return rid;
end $$;

create or replace function public.acc_create_payroll_run(p_month text, p_pay_date date, p_notes text, p_idem text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ex public.acc_payroll_runs; ps date; pe date; rid uuid; e public.acc_employees; sid uuid; it record; v_amt numeric; v_gross numeric; n int := 0; v_val numeric;
begin
  perform public.acc__require('control');
  if coalesce(char_length(p_idem), 0) < 8 then raise exception 'Missing submission key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('acc:prn:' || p_idem, 0));
  select * into ex from public.acc_payroll_runs where idempotency_key = p_idem;
  if found then return jsonb_build_object('id', ex.id, 'run_no', ex.run_no); end if;
  if p_month is null or p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Choose the month to pay'; end if;
  ps := (p_month || '-01')::date; pe := (ps + interval '1 month - 1 day')::date;
  if exists (select 1 from public.acc_payroll_runs where period_label = p_month and status <> 'cancelled') then raise exception 'A payroll run for % already exists', p_month; end if;
  rid := gen_random_uuid();
  insert into public.acc_payroll_runs (id, run_no, period_label, period_start, period_end, pay_date, notes, idempotency_key, created_by)
  values (rid, 'PRN-' || lpad(nextval('public.acc_prn_seq')::text, 6, '0'), p_month, ps, pe, coalesce(p_pay_date, pe), nullif(btrim(p_notes), ''), p_idem, auth.uid());
  for e in select * from public.acc_employees where is_active and start_date <= pe and (end_date is null or end_date >= ps) order by full_name loop
    sid := gen_random_uuid(); n := n + 1;
    insert into public.acc_payslips (id, run_id, employee_id, emp_no, employee_name, job_title, department) values (sid, rid, e.id, e.emp_no, e.full_name, e.job_title, e.department);
    insert into public.acc_payslip_lines (payslip_id, kind, label, amount) values (sid, 'basic', 'Basic salary', e.base_salary);
    v_gross := e.base_salary;
    for it in select i.*, coalesce(ei.value, i.default_value) val from public.acc_employee_items ei join public.acc_pay_items i on i.id = ei.item_id where ei.employee_id = e.id and i.is_active and i.kind = 'allowance' order by i.name loop
      v_amt := case when it.calc = 'fixed' then round(it.val, 2) else round(e.base_salary * it.val / 100, 2) end;
      if v_amt > 0 then insert into public.acc_payslip_lines (payslip_id, kind, label, amount, item_id) values (sid, 'allowance', it.name, v_amt, it.id); v_gross := v_gross + v_amt; end if;
    end loop;
    for it in select i.*, coalesce(ei.value, i.default_value) val from public.acc_employee_items ei join public.acc_pay_items i on i.id = ei.item_id where ei.employee_id = e.id and i.is_active and i.kind in ('deduction','employer') order by i.kind, i.name loop
      v_amt := case when it.calc = 'fixed' then round(it.val, 2) else round(v_gross * it.val / 100, 2) end;
      if v_amt > 0 then insert into public.acc_payslip_lines (payslip_id, kind, label, amount, destination, item_id) values (sid, it.kind, it.name, v_amt, it.destination, it.id); end if;
    end loop;
    perform public.acc__payslip_recalc(sid);
  end loop;
  if n = 0 then raise exception 'There are no active employees to pay for %', p_month; end if;
  return jsonb_build_object('id', rid, 'run_no', (select run_no from public.acc_payroll_runs where id = rid), 'payslips', n);
exception when unique_violation then raise exception 'A payroll run for % already exists', p_month;
end $$;

create or replace function public.acc_payslip_add_line(p_slip uuid, p_kind text, p_label text, p_amount numeric, p_dest text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.acc_payslips; r public.acc_payroll_runs; amt numeric;
begin
  perform public.acc__require('control');
  select * into s from public.acc_payslips where id = p_slip for update;
  if not found then raise exception 'Payslip not found'; end if;
  select * into r from public.acc_payroll_runs where id = s.run_id for update;
  if r.status <> 'draft' then raise exception 'Only a draft payroll run can be changed'; end if;
  if p_kind not in ('allowance','deduction','employer') then raise exception 'Choose allowance, deduction or employer contribution'; end if;
  if coalesce(char_length(btrim(p_label)), 0) < 2 then raise exception 'Describe the line'; end if;
  if p_kind = 'deduction' and p_dest not in ('statutory','advance','other') then raise exception 'Choose where the deducted money goes'; end if;
  amt := public.acc__amount(p_amount);
  insert into public.acc_payslip_lines (payslip_id, kind, label, amount, destination, one_off) values (p_slip, p_kind, btrim(p_label), amt, case when p_kind = 'deduction' then p_dest end, true);
  perform public.acc__payslip_recalc(p_slip);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.acc_payslip_remove_line(p_line bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare l public.acc_payslip_lines; s public.acc_payslips; r public.acc_payroll_runs;
begin
  perform public.acc__require('control');
  select * into l from public.acc_payslip_lines where id = p_line;
  if not found then raise exception 'Line not found'; end if;
  if l.kind = 'basic' then raise exception 'The basic salary line cannot be removed'; end if;
  select * into s from public.acc_payslips where id = l.payslip_id for update;
  select * into r from public.acc_payroll_runs where id = s.run_id for update;
  if r.status <> 'draft' then raise exception 'Only a draft payroll run can be changed'; end if;
  delete from public.acc_payslip_lines where id = p_line;
  perform public.acc__payslip_recalc(s.id);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.acc_approve_payroll(p_run uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.acc_payroll_runs; b numeric; al numeric; er numeric; st numeric; ad numeric; ot numeric; nt numeric; ls jsonb; eid uuid;
begin
  perform public.acc__require('control');
  select * into r from public.acc_payroll_runs where id = p_run for update;
  if not found then raise exception 'Payroll run not found'; end if;
  if r.status <> 'draft' then raise exception '% is already %', r.run_no, r.status; end if;
  if not exists (select 1 from public.acc_payslips where run_id = r.id) then raise exception 'This run has no payslips'; end if;
  select coalesce(sum(l.amount) filter (where l.kind = 'basic'), 0), coalesce(sum(l.amount) filter (where l.kind = 'allowance'), 0), coalesce(sum(l.amount) filter (where l.kind = 'employer'), 0),
         coalesce(sum(l.amount) filter (where l.kind = 'deduction' and l.destination = 'statutory'), 0), coalesce(sum(l.amount) filter (where l.kind = 'deduction' and l.destination = 'advance'), 0),
         coalesce(sum(l.amount) filter (where l.kind = 'deduction' and l.destination = 'other'), 0)
    into b, al, er, st, ad, ot from public.acc_payslip_lines l join public.acc_payslips s on s.id = l.payslip_id where s.run_id = r.id;
  select coalesce(sum(net), 0) into nt from public.acc_payslips where run_id = r.id;
  ls := jsonb_build_array(jsonb_build_object('account_id', public.acc__acct_code('5110'), 'debit', b, 'description', 'Basic salaries ' || r.period_label));
  if al > 0 then ls := ls || jsonb_build_object('account_id', public.acc__acct_code('5120'), 'debit', al, 'description', 'Allowances ' || r.period_label); end if;
  if er > 0 then ls := ls || jsonb_build_object('account_id', public.acc__acct_code('5130'), 'debit', er, 'description', 'Employer contributions ' || r.period_label); end if;
  if nt > 0 then ls := ls || jsonb_build_object('account_id', public.acc__acct_code('2130'), 'credit', nt, 'description', 'Net pay ' || r.period_label); end if;
  if st + er > 0 then ls := ls || jsonb_build_object('account_id', public.acc__acct_code('2140'), 'credit', st + er, 'description', 'PAYE, NSSA and statutory amounts ' || r.period_label); end if;
  if ad > 0 then ls := ls || jsonb_build_object('account_id', public.acc__acct_code('1230'), 'credit', ad, 'description', 'Staff advance recoveries ' || r.period_label); end if;
  if ot > 0 then ls := ls || jsonb_build_object('account_id', public.acc__acct_code('2120'), 'credit', ot, 'description', 'Other deductions payable ' || r.period_label); end if;
  eid := public.acc__post(r.period_end, 'document', 'Payroll ' || r.run_no || ' for ' || r.period_label, r.run_no, 'payroll', r.id, ls, 'prnA:' || r.id::text);
  update public.acc_payroll_runs set status = 'approved', accrual_entry_id = eid, approved_by = auth.uid(), approved_at = now() where id = r.id;
  return jsonb_build_object('id', r.id, 'status', 'approved', 'net', nt);
end $$;

create or replace function public.acc_pay_payroll(p_run uuid, p_account uuid, p_date date, p_slips uuid[], p_reference text, p_idem text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.acc_payroll_runs; a public.acc_accounts; ex public.acc_payroll_payments; ids uuid[]; amt numeric; pid uuid; pno text; eid uuid; dt date;
begin
  perform public.acc__require('control');
  if coalesce(char_length(p_idem), 0) < 8 then raise exception 'Missing submission key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('acc:spy:' || p_idem, 0));
  select * into ex from public.acc_payroll_payments where idempotency_key = p_idem;
  if found then return jsonb_build_object('id', ex.id, 'pay_no', ex.pay_no); end if;
  select * into r from public.acc_payroll_runs where id = p_run for update;
  if not found or r.status not in ('approved') then raise exception 'Only an approved payroll run can be paid'; end if;
  select array_agg(id), coalesce(sum(net), 0) into ids, amt from public.acc_payslips where run_id = r.id and payment_id is null and net > 0 and (p_slips is null or id = any(p_slips));
  if ids is null or amt <= 0 then raise exception 'There is nothing left to pay on this run'; end if;
  if p_slips is not null and cardinality(ids) <> (select count(distinct x) from unnest(p_slips) x) then raise exception 'Some selected payslips are already paid or do not belong to this run'; end if;
  select * into a from public.acc_accounts where id = p_account and subtype in ('cash','bank','mobile_money') and is_active and not is_header;
  if not found then raise exception 'Choose the cash, bank or mobile money account the salaries are paid from'; end if;
  dt := coalesce(p_date, public.acc__today());
  perform public.acc__payment_account(a.id, amt, dt);
  pid := gen_random_uuid(); pno := 'SPY-' || lpad(nextval('public.acc_spy_seq')::text, 6, '0');
  eid := public.acc__post(dt, 'document', 'Salary payment ' || pno || ' for ' || r.run_no, coalesce(nullif(btrim(p_reference), ''), pno), 'payroll_payment', pid,
    jsonb_build_array(jsonb_build_object('account_id', public.acc__acct_code('2130'), 'debit', amt, 'description', 'Salaries paid ' || r.period_label),
                      jsonb_build_object('account_id', a.id, 'credit', amt, 'description', 'Salary payment ' || pno)), 'spy:' || p_idem);
  insert into public.acc_payroll_payments (id, pay_no, run_id, account_id, amount, paid_on, reference, entry_id, idempotency_key, created_by) values (pid, pno, r.id, a.id, amt, dt, nullif(btrim(p_reference), ''), eid, p_idem, auth.uid());
  update public.acc_payslips set payment_id = pid, paid_on = dt where id = any(ids);
  if not exists (select 1 from public.acc_payslips where run_id = r.id and payment_id is null and net > 0) then update public.acc_payroll_runs set status = 'paid' where id = r.id; end if;
  return jsonb_build_object('id', pid, 'pay_no', pno, 'amount', amt, 'payslips', cardinality(ids));
end $$;

create or replace function public.acc_reverse_payroll_payment(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.acc_payroll_payments; rid uuid;
begin
  perform public.acc__require('control');
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'Give a reason for the reversal'; end if;
  select * into p from public.acc_payroll_payments where id = p_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if p.status <> 'posted' then raise exception '% has already been reversed', p.pay_no; end if;
  rid := public.acc__reverse(p.entry_id, public.acc__today(), p.pay_no || ' reversed: ' || btrim(p_reason), 'rvs:' || p.id::text);
  update public.acc_payroll_payments set status = 'reversed', reversal_entry_id = rid where id = p.id;
  update public.acc_payslips set payment_id = null, paid_on = null where payment_id = p.id;
  update public.acc_payroll_runs set status = 'approved' where id = p.run_id and status = 'paid';
  return jsonb_build_object('id', p.id, 'pay_no', p.pay_no);
end $$;

create or replace function public.acc_cancel_payroll(p_run uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.acc_payroll_runs;
begin
  perform public.acc__require('control');
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'Give a reason'; end if;
  select * into r from public.acc_payroll_runs where id = p_run for update;
  if not found then raise exception 'Payroll run not found'; end if;
  if r.status = 'cancelled' then raise exception '% is already cancelled', r.run_no; end if;
  if exists (select 1 from public.acc_payroll_payments where run_id = r.id and status = 'posted') then raise exception 'Reverse the salary payments on % first', r.run_no; end if;
  if r.status = 'approved' then perform public.acc__reverse(r.accrual_entry_id, public.acc__today(), r.run_no || ' cancelled: ' || btrim(p_reason), 'prnX:' || r.id::text); end if;
  update public.acc_payroll_runs set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = btrim(p_reason) where id = r.id;
  return jsonb_build_object('id', r.id, 'status', 'cancelled');
end $$;

create or replace function public.acc_payroll_runs_list() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.acc__require('control');
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'run_no', r.run_no, 'period', r.period_label, 'pay_date', r.pay_date, 'status', r.status, 'gross', r.gross, 'deductions', r.deductions, 'net', r.net, 'employer', r.employer,
      'payslips', (select count(*) from public.acc_payslips s where s.run_id = r.id), 'paid_net', (select coalesce(sum(s.net), 0) from public.acc_payslips s where s.run_id = r.id and s.payment_id is not null),
      'approved_by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = r.approved_by), 'approved_at', r.approved_at, 'notes', r.notes) order by r.period_label desc, r.created_at desc)
    from public.acc_payroll_runs r), '[]'::jsonb);
end $$;

create or replace function public.acc_payroll_run_detail(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.acc_payroll_runs;
begin
  perform public.acc__require('control');
  select * into r from public.acc_payroll_runs where id = p_id;
  if not found then raise exception 'Payroll run not found'; end if;
  return jsonb_build_object(
    'run', jsonb_build_object('id', r.id, 'run_no', r.run_no, 'period', r.period_label, 'period_start', r.period_start, 'period_end', r.period_end, 'pay_date', r.pay_date, 'status', r.status,
      'gross', r.gross, 'deductions', r.deductions, 'net', r.net, 'employer', r.employer, 'notes', r.notes, 'cancel_reason', r.cancel_reason, 'approved_at', r.approved_at,
      'approved_by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = r.approved_by), 'created_by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = r.created_by)),
    'payslips', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'emp_no', s.emp_no, 'name', s.employee_name, 'job_title', s.job_title, 'department', s.department, 'basic', s.basic, 'allowances', s.allowances,
        'deductions', s.deductions, 'employer', s.employer, 'gross', s.gross, 'net', s.net, 'paid_on', s.paid_on, 'paid', s.payment_id is not null) order by s.employee_name) from public.acc_payslips s where s.run_id = r.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'pay_no', p.pay_no, 'date', p.paid_on, 'amount', p.amount, 'reference', p.reference, 'status', p.status, 'account', (select name from public.acc_accounts where id = p.account_id),
        'by', (select coalesce(nullif(full_name, ''), email) from public.profiles where id = p.created_by)) order by p.created_at) from public.acc_payroll_payments p where p.run_id = r.id), '[]'::jsonb),
    'remit', jsonb_build_object(
      'statutory', (select coalesce(sum(l.amount), 0) from public.acc_payslip_lines l join public.acc_payslips s on s.id = l.payslip_id where s.run_id = r.id and l.kind = 'deduction' and l.destination = 'statutory'),
      'employer', r.employer,
      'advance', (select coalesce(sum(l.amount), 0) from public.acc_payslip_lines l join public.acc_payslips s on s.id = l.payslip_id where s.run_id = r.id and l.kind = 'deduction' and l.destination = 'advance'),
      'other', (select coalesce(sum(l.amount), 0) from public.acc_payslip_lines l join public.acc_payslips s on s.id = l.payslip_id where s.run_id = r.id and l.kind = 'deduction' and l.destination = 'other')));
end $$;

create or replace function public.acc_payslip_detail(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.acc_payslips; r public.acc_payroll_runs;
begin
  perform public.acc__require('control');
  select * into s from public.acc_payslips where id = p_id;
  if not found then raise exception 'Payslip not found'; end if;
  select * into r from public.acc_payroll_runs where id = s.run_id;
  return jsonb_build_object(
    'payslip', jsonb_build_object('id', s.id, 'emp_no', s.emp_no, 'name', s.employee_name, 'job_title', s.job_title, 'department', s.department, 'basic', s.basic, 'allowances', s.allowances, 'deductions', s.deductions,
      'employer', s.employer, 'gross', s.gross, 'net', s.net, 'paid_on', s.paid_on, 'paid', s.payment_id is not null,
      'method', (select a.name from public.acc_payroll_payments p join public.acc_accounts a on a.id = p.account_id where p.id = s.payment_id)),
    'run', jsonb_build_object('id', r.id, 'run_no', r.run_no, 'period', r.period_label, 'period_start', r.period_start, 'period_end', r.period_end, 'pay_date', r.pay_date, 'status', r.status),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind, 'label', l.label, 'amount', l.amount, 'destination', l.destination, 'one_off', l.one_off) order by case l.kind when 'basic' then 0 when 'allowance' then 1 when 'deduction' then 2 else 3 end, l.id)
                       from public.acc_payslip_lines l where l.payslip_id = s.id), '[]'::jsonb));
end $$;

do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
    and p.proname in ('acc__acct_code','acc__payslip_recalc','acc_pay_items_list','acc_save_pay_item','acc_employees_list','acc_save_employee','acc_create_payroll_run','acc_payslip_add_line','acc_payslip_remove_line',
      'acc_approve_payroll','acc_pay_payroll','acc_reverse_payroll_payment','acc_cancel_payroll','acc_payroll_runs_list','acc_payroll_run_detail','acc_payslip_detail')
  loop execute format('revoke all on function %s from public, anon', r.sig); execute format('grant execute on function %s to authenticated', r.sig); end loop;
end $$;
