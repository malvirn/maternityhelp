-- Group 3 follow-up: credit held on a patient's account = what they owe on open invoices minus the ledger balance
create or replace function public.acc__patient_unalloc(p uuid) returns numeric language sql stable security definer set search_path = '' as $$
  select greatest(
    coalesce((select sum(greatest(public.acc__invoice_outstanding(i.id), 0)) from public.acc_invoices i where i.patient_id = p and i.status = 'issued'), 0) - public.acc__patient_ar(p), 0) $$;

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
  if amt > outst then raise exception 'Only % is outstanding on %', to_char(greatest(outst, 0), 'FM999,999,999,990.00'), inv.invoice_no; end if;
  adv := public.acc__patient_unalloc(p_patient);
  if amt > adv then raise exception 'This patient has only % in advance payments to apply', to_char(greatest(adv, 0), 'FM999,999,999,990.00'); end if;
  cid := gen_random_uuid(); cno := 'CAP-' || lpad(nextval('public.acc_cap_seq')::text, 6, '0');
  eid := public.acc__post(dt, 'document', 'Patient credit ' || cno || ' applied to ' || inv.invoice_no, cno, 'credit_application', cid,
    jsonb_build_array(jsonb_build_object('account_id', ar, 'debit', amt, 'patient_id', p_patient, 'description', 'Credit applied to ' || inv.invoice_no),
                      jsonb_build_object('account_id', ar, 'credit', amt, 'patient_id', p_patient, 'description', 'Advance payment used by ' || cno)), 'cap:' || p_idem);
  insert into public.acc_credit_applications (id, app_no, patient_id, invoice_id, amount, app_date, entry_id, idempotency_key, created_by) values (cid, cno, p_patient, inv.id, amt, dt, eid, p_idem, auth.uid());
  return jsonb_build_object('id', cid, 'app_no', cno);
end $$;
-- acc_patient_credits and acc_patient_credit_history use acc__patient_unalloc (see the applied migration group3_patient_credit_pool_fix)
