/* Maternity Help accounts: Financial reports, Taxes, Budgets and Notifications.
   Loaded after the main accounting script. Uses its helpers (S, rpc, esc, money, openModal, pdfBuild ...). */
(function () {
"use strict";
const X = {
  rpt: { kind: "income", preset: "month", from: null, to: null, asOf: null, model: null },
  tax: { tab: "overview", preset: "lastmonth", from: null, to: null },
  bud: { year: null, id: null, tab: "lines" },
  nt: { filter: "all", kind: "", data: null, timer: null, seen: null }
};

/* ---------- small helpers ---------- */
const num = v => Number(v || 0);
const fp = (v, t) => t === "m" ? money(v) : t === "p" ? (v == null || v === "" ? "" : num(v).toFixed(1) + "%") : t === "n" ? String(v ?? "") : String(v == null || v === "" ? "" : v);
const fx = (v, t) => esc(fp(v, t));
const monthName = ym => { const [y, m] = String(ym).split("-").map(Number); return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString("en-GB", { month: "short", year: "numeric", timeZone: "UTC" }); };
function tabsHtml(list, cur) { return `<div class="tabs" role="tablist">${list.map(([k, l]) => `<button role="tab" type="button" data-tab="${k}" aria-selected="${cur === k}">${esc(l)}</button>`).join("")}</div>`; }
function lastMonthRange() { const t = parseISO(today()); const f = new Date(Date.UTC(t.getUTCFullYear(), t.getUTCMonth() - 1, 1)), e = new Date(Date.UTC(t.getUTCFullYear(), t.getUTCMonth(), 0)); return [toISO(f), toISO(e)]; }
function presetRange(p, from, to) {
  if (p === "lastmonth") return lastMonthRange();
  if (p === "custom") return [from || monthStart(today()), to || today()];
  return rangeFor(p);
}
const PRESETS = [["month", "This month"], ["lastmonth", "Last month"], ["quarter", "This quarter"], ["year", "This year"], ["custom", "Custom"]];
function periodControls(st, id) {
  const [f, t] = presetRange(st.preset, st.from, st.to);
  return `<form class="panel" id="${id}" style="margin-bottom:16px"><div class="row" style="flex-wrap:wrap;gap:8px;margin-bottom:10px">${PRESETS.map(([k, l]) => `<button type="button" class="btn small${st.preset === k ? " primary" : ""}" data-preset="${k}">${l}</button>`).join("")}</div>
    <div class="grid g4"><label class="f"><span>From</span><input type="date" name="from" value="${f}" required></label><label class="f"><span>To</span><input type="date" name="to" value="${t}" required></label>
    <div class="row" style="align-items:flex-end"><button class="btn primary" type="submit">Show</button></div></div></form>`;
}
function bindPeriod(st, id, reload) {
  const fm = $("#" + id); if (!fm) return;
  $$("[data-preset]", fm).forEach(b => b.addEventListener("click", () => { st.preset = b.dataset.preset; if (st.preset !== "custom") { [st.from, st.to] = presetRange(st.preset); } reload(true); }));
  fm.addEventListener("submit", ev => { ev.preventDefault(); const f = form(fm); if (f.from.value > f.to.value) return toast("The start date must be on or before the end date", true); st.preset = "custom"; st.from = f.from.value; st.to = f.to.value; reload(false); });
}
function csvDown(rows, name) {
  const q = v => { v = v == null ? "" : String(v); return /[",\n\r]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; };
  const blob = new Blob(["\ufeff" + rows.map(r => r.map(q).join(",")).join("\r\n")], { type: "text/csv;charset=utf-8" });
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = name; document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 4000);
}

/* ---------- report model: one source for the screen, the PDF and the CSV ---------- */
function modelHtml(m) {
  const secs = (m.sections || []).map(s => `<div class="panel" style="margin-bottom:16px"><h2>${esc(s.title)}</h2><div class="scroll"><table><thead><tr>${s.cols.map(c => `<th class="${c.t !== "t" ? "num" : ""}">${esc(c.h)}</th>`).join("")}</tr></thead><tbody>${
    s.rows.map(r => `<tr>${r.map((v, i) => `<td class="${s.cols[i].t !== "t" ? "num" : ""}">${fx(v, s.cols[i].t)}</td>`).join("")}</tr>`).join("") || `<tr><td colspan="${s.cols.length}" class="empty">${esc(s.empty || "Nothing to show.")}</td></tr>`}</tbody></table></div></div>`).join("");
  const tot = (m.totals || []).length ? `<div class="panel" style="margin-bottom:16px"><table><tbody>${m.totals.map(([k, v, st]) => `<tr><td>${st ? "<b>" : ""}${esc(k)}${st ? "</b>" : ""}</td><td class="num">${st ? "<b>" : ""}${esc(typeof v === "number" ? money(v) : v)}${st ? "</b>" : ""}</td></tr>`).join("")}</tbody></table></div>` : "";
  const notes = (m.notes || []).filter(Boolean).map(n => `<p class="muted" style="margin:6px 0">${esc(n)}</p>`).join("");
  const meta = (m.meta || []).length ? `<p class="muted" style="margin:0 0 12px">${m.meta.map(([k, v]) => `${esc(k)}: <b>${esc(v)}</b>`).join(" &nbsp;\u00b7&nbsp; ")}</p>` : "";
  return meta + secs + tot + notes;
}
function modelPdf(m) {
  return pdfBuild({ title: m.title, number: m.number, meta: m.meta, notes: m.notes,
    tables: (m.sections || []).map(s => ({ title: s.title, head: s.cols.map(c => c.h), widths: s.cols.map(c => c.w || (c.t === "t" ? 2 : 1)), align: s.cols.map(c => c.t === "t" ? "l" : "r"), rows: s.rows.map(r => r.map((v, i) => fp(v, s.cols[i].t))), empty: s.empty })),
    totals: (m.totals || []).map(([k, v, st]) => [k, typeof v === "number" ? money(v) : String(v), !!st]) });
}
function modelCsv(m) {
  const rows = [[m.title]]; (m.meta || []).forEach(([k, v]) => rows.push([k, v])); rows.push([]);
  (m.sections || []).forEach(s => { rows.push([s.title]); rows.push(s.cols.map(c => c.h)); s.rows.forEach(r => rows.push(r.map((v, i) => s.cols[i].t === "m" || s.cols[i].t === "p" ? (v === "" || v == null ? "" : num(v).toFixed(2)) : v))); rows.push([]); });
  (m.totals || []).forEach(([k, v]) => rows.push([k, typeof v === "number" ? num(v).toFixed(2) : v]));
  (m.notes || []).filter(Boolean).forEach(n => rows.push([n]));
  return rows;
}
function exportBar() { return `<div class="row" style="margin-bottom:12px;flex-wrap:wrap;gap:8px"><button class="btn" type="button" data-x="pdf">Download PDF</button><button class="btn" type="button" data-x="print">Print</button><button class="btn" type="button" data-x="csv">Download CSV</button></div>`; }
function bindExport(root, getModel, name) {
  const on = (k, fn) => { const b = $(`[data-x="${k}"]`, root); if (b) b.addEventListener("click", () => { try { fn(getModel()); } catch (e) { toast(e.message, true); } }); };
  on("pdf", m => modelPdf(m).save(name + ".pdf")); on("print", m => pdfPrint(modelPdf(m))); on("csv", m => csvDown(modelCsv(m), name + ".csv"));
}

/* ====================== FINANCIAL REPORTS ====================== */
const RKINDS = [["income", "Income statement"], ["balance", "Balance sheet"], ["cashflow", "Cash flow"], ["trial", "Trial balance"], ["revenue", "Revenue"], ["expenses", "Expenses"], ["outstanding", "Outstanding balances"]];
const AS_OF = ["balance", "trial", "outstanding"];
const accRows = (list, extra) => (list || []).map(a => [a.code, a.name, num(a.amount)].concat(extra ? extra(a) : []));
async function buildReport(kind, r) {
  const [f, t] = presetRange(r.preset, r.from, r.to), a = r.asOf || today();
  const per = [["Period", `${fd(f)} to ${fd(t)}`]];
  if (kind === "income") {
    const d = await rpc("acc_rpt_income_statement", { p_from: f, p_to: t });
    return { title: "Income statement", meta: per, sections: [
      { title: "Revenue", cols: [{ h: "Code", t: "t", w: 1 }, { h: "Account", t: "t", w: 4 }, { h: "Amount", t: "m", w: 2 }], rows: accRows(d.revenue), empty: "No revenue in this period." },
      { title: "Expenses", cols: [{ h: "Code", t: "t", w: 1 }, { h: "Account", t: "t", w: 4 }, { h: "Amount", t: "m", w: 2 }], rows: accRows(d.expenses), empty: "No expenses in this period." }],
      totals: [["Total revenue", num(d.total_revenue)], ["Total expenses", num(d.total_expenses)], [num(d.net_profit) >= 0 ? "Net profit" : "Net loss", num(d.net_profit), true]],
      notes: ["Prepared from posted journal entries. Year-end closing entries are left out so each period shows its own result."] };
  }
  if (kind === "balance") {
    const d = await rpc("acc_rpt_balance_sheet", { p_as_of: a }), eq = accRows(d.equity); eq.push(["", "Current period earnings (not yet closed)", num(d.current_earnings)]);
    const c = [{ h: "Code", t: "t", w: 1 }, { h: "Account", t: "t", w: 4 }, { h: "Amount", t: "m", w: 2 }];
    return { title: "Balance sheet", meta: [["As at", fd(a)]], sections: [
      { title: "Assets", cols: c, rows: accRows(d.assets), empty: "No assets recorded." }, { title: "Liabilities", cols: c, rows: accRows(d.liabilities), empty: "No liabilities recorded." }, { title: "Equity", cols: c, rows: eq }],
      totals: [["Total assets", num(d.total_assets), true], ["Total liabilities", num(d.total_liabilities)], ["Total equity", num(d.total_equity)], ["Liabilities plus equity", num(d.total_liabilities) + num(d.total_equity), true]],
      notes: [d.balanced ? "The balance sheet balances." : `The balance sheet is out by ${money(d.difference)}. Review recent journal entries.`, "A negative asset (for example patient receivables) means the patient has paid more than they owe, which is a credit balance."] };
  }
  if (kind === "cashflow") {
    const d = await rpc("acc_cashflow", { p_from: f, p_to: t });
    return { title: "Cash flow statement", meta: per, sections: [
      { title: "Cash, bank and mobile money accounts", cols: [{ h: "Account", t: "t", w: 4 }, { h: "Opening", t: "m" }, { h: "Received", t: "m" }, { h: "Paid out", t: "m" }, { h: "Closing", t: "m" }], rows: (d.accounts || []).map(x => [`${x.code} ${x.name}`, num(x.opening), num(x.inflow), num(x.outflow), num(x.closing)]) },
      { title: "Where cash came from and went", cols: [{ h: "Source", t: "t", w: 3 }, { h: "Received", t: "m" }, { h: "Paid out", t: "m" }, { h: "Net", t: "m" }], rows: (d.by_source || []).map(x => [SOURCE[x.source] || x.source || "Other", num(x.inflow), num(x.outflow), num(x.inflow) - num(x.outflow)]) },
      { title: "By month", cols: [{ h: "Month", t: "t", w: 2 }, { h: "Received", t: "m" }, { h: "Paid out", t: "m" }, { h: "Net", t: "m" }], rows: (d.by_month || []).map(x => [monthName(x.month), num(x.inflow), num(x.outflow), num(x.inflow) - num(x.outflow)]) }],
      totals: [["Opening cash", num(d.opening)], ["Cash received", num(d.inflow)], ["Cash paid out", num(d.outflow)], ["Closing cash", num(d.closing), true]],
      notes: ["Direct method, built from posted cash, bank and mobile money movements. Transfers between your own cash accounts are not counted (" + money(d.transfers) + " moved this period)."] };
  }
  if (kind === "trial") {
    const d = await rpc("acc_trial_balance", { p_as_of: a }), ok = num(d.total_debit) === num(d.total_credit);
    return { title: "Trial balance", meta: [["As at", fd(a)]], sections: [{ title: "Account balances", cols: [{ h: "Code", t: "t", w: 1 }, { h: "Account", t: "t", w: 4 }, { h: "Type", t: "t", w: 2 }, { h: "Debit", t: "m" }, { h: "Credit", t: "m" }],
      rows: (d.rows || []).map(x => [x.code, x.name, TYPES[x.type] || x.type, num(x.debit) || "", num(x.credit) || ""]), empty: "No balances yet." }],
      totals: [["Total debits", num(d.total_debit)], ["Total credits", num(d.total_credit), true]], notes: [ok ? "Debits equal credits." : "Debits and credits do not match. Review recent journal entries."] };
  }
  if (kind === "revenue" || kind === "expenses") {
    const rev = kind === "revenue", d = await rpc(rev ? "acc_rpt_revenue" : "acc_rpt_expenses", { p_from: f, p_to: t }), tot = num(d.total);
    const sections = [{ title: rev ? "Revenue by account" : "Expenses by account", cols: [{ h: "Code", t: "t", w: 1 }, { h: "Account", t: "t", w: 4 }, { h: "Amount", t: "m", w: 2 }, { h: "Share", t: "p", w: 1 }], rows: (d.by_account || []).map(x => [x.code, x.name, num(x.amount), tot ? num(x.amount) / tot * 100 : 0]), empty: "Nothing recorded in this period." }];
    if (rev) sections.push({ title: "Revenue by source", cols: [{ h: "Source", t: "t", w: 3 }, { h: "Amount", t: "m" }], rows: (d.by_source || []).map(x => [SOURCE[x.source] || x.source, num(x.amount)]) });
    else sections.push({ title: "Expenses by supplier", cols: [{ h: "Supplier", t: "t", w: 3 }, { h: "Amount", t: "m" }], rows: (d.by_supplier || []).map(x => [x.supplier, num(x.amount)]) });
    sections.push({ title: "By month", cols: [{ h: "Month", t: "t", w: 2 }, { h: "Amount", t: "m" }], rows: (d.by_month || []).map(x => [monthName(x.month), num(x.amount)]) });
    return { title: rev ? "Revenue report" : "Expense report", meta: per, sections, totals: [[rev ? "Total revenue" : "Total expenses", tot, true]] };
  }
  const d = await rpc("acc_rpt_outstanding", { p_as_of: a }), B = ["current", "1-30", "31-60", "61-90", "90+"], BL = { current: "Not yet due", "1-30": "1 to 30 days late", "31-60": "31 to 60 days late", "61-90": "61 to 90 days late", "90+": "Over 90 days late" };
  return { title: "Outstanding balances", meta: [["As at", fd(d.as_of)]], sections: [
    { title: "Ageing summary", cols: [{ h: "How late", t: "t", w: 3 }, { h: "Patients owe us", t: "m" }, { h: "We owe suppliers", t: "m" }], rows: B.map(k => [BL[k], num((d.patient_ageing || {})[k]), num((d.supplier_ageing || {})[k])]) },
    { title: "Patient invoices not fully paid", cols: [{ h: "Invoice", t: "t", w: 2 }, { h: "Patient", t: "t", w: 3 }, { h: "Due", t: "t", w: 2 }, { h: "Days late", t: "n", w: 1 }, { h: "Outstanding", t: "m", w: 2 }], rows: (d.patients || []).map(x => [x.invoice_no, x.patient, fd(x.due_date), x.days_overdue, num(x.outstanding)]), empty: "No unpaid patient invoices." },
    { title: "Supplier bills not fully paid", cols: [{ h: "Bill", t: "t", w: 2 }, { h: "Supplier", t: "t", w: 3 }, { h: "Due", t: "t", w: 2 }, { h: "Days late", t: "n", w: 1 }, { h: "Outstanding", t: "m", w: 2 }], rows: (d.suppliers || []).map(x => [x.bill_no, x.supplier, fd(x.due_date), x.days_overdue, num(x.outstanding)]), empty: "No unpaid supplier bills." }],
    totals: [["Patients owe us", num(d.total_receivable), true], ["We owe suppliers", num(d.total_payable), true]] };
}
async function renderReports() {
  setTitle("Financial reports"); const r = X.rpt, asof = AS_OF.includes(r.kind);
  if (!r.asOf) r.asOf = today();
  $("#view").innerHTML = tabsHtml(RKINDS, r.kind) + (asof
    ? `<form class="panel" id="rp-form" style="margin-bottom:16px"><div class="grid g4"><label class="f"><span>As at</span><input type="date" name="asof" value="${r.asOf}" required></label><div class="row" style="align-items:flex-end"><button class="btn primary" type="submit">Show</button></div></div></form>`
    : periodControls(r, "rp-form")) + `<div id="rp-out"><div class="loading">Loading\u2026</div></div>`;
  $$("[data-tab]").forEach(b => b.addEventListener("click", () => { r.kind = b.dataset.tab; renderReports(); }));
  if (asof) $("#rp-form").addEventListener("submit", ev => { ev.preventDefault(); r.asOf = form(ev.target).asof.value; loadReport(); }); else bindPeriod(r, "rp-form", () => renderReports());
  await loadReport();
}
async function loadReport() {
  const r = X.rpt, box = $("#rp-out"); if (!box) return; box.innerHTML = `<div class="loading">Loading\u2026</div>`;
  try {
    const m = await buildReport(r.kind, r); r.model = m; box.innerHTML = exportBar() + modelHtml(m);
    const [f, t] = presetRange(r.preset, r.from, r.to); bindExport(box, () => r.model, `${r.kind}-${AS_OF.includes(r.kind) ? r.asOf : f + "_to_" + t}`);
  } catch (e) { box.innerHTML = `<div class="panel"><b>Could not build this report.</b><p class="muted">${esc(e.message)}</p></div>`; }
}

/* ====================== TAXES ====================== */
const TKIND = { vat: "VAT", payroll: "Payroll tax", income: "Income tax", levy: "Levy", transfer: "Transfer tax", withholding: "Withholding tax", other: "Other" };
const FREQ = { monthly: "Monthly", quarterly: "Quarterly", annual: "Yearly", none: "Not filed" };
const TREAT = { standard: "Standard rated (VAT charged)", zero_rated: "Zero-rated (0%)", exempt: "Exempt (no VAT)" };
async function renderTaxes() {
  setTitle("Taxes"); const x = X.tax; if (!x.from) [x.from, x.to] = presetRange(x.preset);
  const ov = await rpc("acc_tax_overview"); x.ov = ov;
  const tabs = [["overview", "Tax types and rates"], ["vat", "VAT return"], ["exempt", "Exemptions"], ["payroll", "Payroll taxes"], ["income", "Income tax"], ["calendar", "Filing calendar"]];
  $("#view").innerHTML = tabsHtml(tabs, x.tab) + `<div id="tx-body"></div>`;
  $$("[data-tab]").forEach(b => b.addEventListener("click", () => { x.tab = b.dataset.tab; renderTaxes(); }));
  const fn = { overview: taxOverview, vat: taxVat, exempt: taxExempt, payroll: taxPayroll, income: taxIncome, calendar: taxCalendar }[x.tab];
  await fn(ov);
}
function taxStatusPill(t) { return t.status === "verified" ? `<span class="pill ok">Checked ${t.verified_on ? fd(t.verified_on) : ""}</span>` : `<span class="pill warn">To confirm</span>`; }
async function taxOverview(ov) {
  const s = ov.settings || {}, ctl = isCtl();
  $("#tx-body").innerHTML = `
  <div class="panel" style="margin-bottom:16px"><div class="panel-head"><h2>Hospital tax profile</h2>${ctl ? `<button class="btn small" id="tx-prof">Edit</button>` : ""}</div>
    <div class="grid g4"><div><span class="muted">VAT registered</span><br><b>${s.vat_registered ? "Yes" : "No"}</b></div><div><span class="muted">VAT number</span><br><b>${esc(s.vat_number || "-")}</b></div><div><span class="muted">Tax number (TIN)</span><br><b>${esc(s.tin || "-")}</b></div><div><span class="muted">Business partner number</span><br><b>${esc(s.bp_number || "-")}</b></div></div>
    <p class="muted" style="margin:12px 0 0">Prices ${s.prices_include_vat ? "include" : "do not include"} VAT when VAT applies. Medical services and medicines are exempt from VAT in Zimbabwe (ZIMRA), and a business that only makes exempt supplies cannot register for VAT. Confirm your position with ZIMRA before changing this.</p></div>
  <div class="panel"><div class="panel-head"><h2>Tax types and rates</h2>${ctl ? `<button class="btn small primary" id="tx-new">Add tax type</button>` : ""}</div>
    <div class="scroll"><table><thead><tr><th>Tax</th><th class="num">Rate now</th><th>Filing</th><th>Status</th><th>Source</th><th></th></tr></thead><tbody>${ov.types.map(t => `<tr class="${t.is_active ? "" : "inactive"}">
      <td><b>${esc(t.name)}</b><br><span class="muted">${esc(TKIND[t.kind] || t.kind)}${t.is_active ? "" : " \u00b7 switched off"}</span></td>
      <td class="num">${t.current_rate != null ? num(t.current_rate) + "%" + (t.current_ceiling ? `<br><span class="muted">up to ${money(t.current_ceiling)}</span>` : "") : "-"}</td>
      <td>${esc(FREQ[t.filing_frequency] || "")}${t.due_day ? `<br><span class="muted">due ${t.due_day}th of next month</span>` : ""}</td><td>${taxStatusPill(t)}</td>
      <td>${t.source_url ? `<a href="${esc(t.source_url)}" target="_blank" rel="noopener">${esc(t.source || "Source")}</a>` : esc(t.source || "")}</td>
      <td>${ctl ? `<button class="btn small" data-rates="${t.id}">Rates</button> <button class="btn small" data-edit="${t.id}">Edit</button>` : ""}</td></tr>
      ${t.description ? `<tr class="${t.is_active ? "" : "inactive"}"><td colspan="6" class="muted" style="padding-top:0">${esc(t.description)}</td></tr>` : ""}`).join("")}</tbody></table></div>
    <p class="muted" style="margin:12px 0 0">Rates are stored with a start date, so old periods keep the rate that applied then. Items marked "To confirm" could not be verified from official sources. Check them with ZIMRA or your tax adviser before relying on them.</p></div>`;
  if (!ctl) return;
  $("#tx-prof").addEventListener("click", () => profileModal(s));
  $("#tx-new").addEventListener("click", () => typeModal(null));
  $$("[data-edit]").forEach(b => b.addEventListener("click", () => typeModal(ov.types.find(t => t.id === b.dataset.edit))));
  $$("[data-rates]").forEach(b => b.addEventListener("click", () => ratesModal(ov.types.find(t => t.id === b.dataset.rates))));
}
function profileModal(s) {
  const b = openModal("Hospital tax profile", `<form id="pf" class="grid g2"><label class="f"><span>VAT registered</span><select name="reg">${opt("false", "No", String(!!s.vat_registered))}${opt("true", "Yes", String(!!s.vat_registered))}</select></label>
    <label class="f"><span>VAT number</span><input name="vat" maxlength="40" value="${esc(s.vat_number || "")}"></label><label class="f"><span>Tax number (TIN)</span><input name="tin" maxlength="40" value="${esc(s.tin || "")}"></label>
    <label class="f"><span>Business partner number</span><input name="bp" maxlength="40" value="${esc(s.bp_number || "")}"></label>
    <label class="f"><span>Are your prices VAT inclusive?</span><select name="inc">${opt("true", "Yes, prices include VAT", String(s.prices_include_vat !== false))}${opt("false", "No, VAT is added on top", String(s.prices_include_vat !== false))}</select></label>
    <div class="row" style="grid-column:1/-1"><button class="btn primary" type="submit">Save</button><button class="btn" type="button" data-close>Cancel</button></div></form>`);
  $("#pf", b).addEventListener("submit", ev => { ev.preventDefault(); const f = form(ev.target); busy($("button[type=submit]", ev.target), async () => {
    await rpc("acc_tax_save_settings", { p_vat_registered: f.reg.value === "true", p_vat_number: f.vat.value, p_tin: f.tin.value, p_bp: f.bp.value, p_prices_include: f.inc.value === "true" }); closeModal(); toast("Tax profile saved"); renderTaxes(); }); });
}
async function typeModal(t) {
  let items = []; try { items = await rpc("acc_pay_items_list"); } catch (e) { items = []; }
  const liab = S.look.accounts.filter(a => a.type === "liability" && postable(a)), ex = t || { kind: "other", filing_frequency: "monthly", status: "to_confirm", is_active: true };
  const b = openModal(t ? "Edit " + t.name : "Add tax type", `<form id="tf" class="grid g2">
    ${t ? "" : `<label class="f"><span>Code (capitals, no spaces)</span><input name="code" maxlength="20" pattern="[A-Z0-9_]{2,20}" required placeholder="e.g. WHT"></label>`}
    <label class="f"><span>Name</span><input name="name" maxlength="80" required value="${esc(ex.name || "")}"></label>
    <label class="f"><span>Kind</span><select name="kind">${Object.entries(TKIND).map(([k, v]) => opt(k, v, ex.kind)).join("")}</select></label>
    <label class="f"><span>Filing</span><select name="freq">${Object.entries(FREQ).map(([k, v]) => opt(k, v, ex.filing_frequency)).join("")}</select></label>
    <label class="f"><span>Due on day of next month</span><input name="due" type="number" min="1" max="31" value="${ex.due_day || ""}"></label>
    <label class="f"><span>Tax payable account</span><select name="liab">${opt("", "None", ex.liability_account_id)}${liab.map(a => opt(a.id, a.code + "  " + a.name, ex.liability_account_id)).join("")}</select></label>
    <label class="f"><span>Linked payroll item</span><select name="pitem">${opt("", "None", ex.payroll_item_id)}${(items || []).map(p => opt(p.id, p.name, ex.payroll_item_id)).join("")}</select></label>
    <label class="f"><span>Status</span><select name="status">${opt("to_confirm", "To confirm", ex.status)}${opt("verified", "Checked against an official source", ex.status)}</select></label>
    <label class="f"><span>Source</span><input name="source" maxlength="300" value="${esc(ex.source || "")}"></label><label class="f"><span>Source link</span><input name="url" maxlength="300" value="${esc(ex.source_url || "")}"></label>
    <label class="f"><span>Checked on</span><input name="ver" type="date" value="${ex.verified_on || ""}"></label><label class="f"><span>In use</span><select name="act">${opt("true", "Yes", String(ex.is_active !== false))}${opt("false", "No (switched off)", String(ex.is_active !== false))}</select></label>
    <label class="f" style="grid-column:1/-1"><span>Notes</span><textarea name="desc" rows="3" maxlength="600">${esc(ex.description || "")}</textarea></label>
    <div class="row" style="grid-column:1/-1"><button class="btn primary" type="submit">Save</button><button class="btn" type="button" data-close>Cancel</button></div></form>`);
  $("#tf", b).addEventListener("submit", ev => { ev.preventDefault(); const f = form(ev.target); busy($("button[type=submit]", ev.target), async () => {
    await rpc("acc_tax_save_type", { p_id: t ? t.id : null, p_code: t ? t.code : f.code.value, p_name: f.name.value, p_kind: f.kind.value, p_desc: f.desc.value, p_freq: f.freq.value, p_due_day: f.due.value ? Number(f.due.value) : null,
      p_liability: f.liab.value || null, p_payroll_item: f.pitem.value || null, p_status: f.status.value, p_source: f.source.value, p_url: f.url.value, p_verified_on: f.ver.value || null, p_active: f.act.value === "true" });
    closeModal(); toast("Tax type saved"); renderTaxes(); }); });
}
function ratesModal(t) {
  const draw = () => { const b = openModal(t.name + ": rates", `<div class="scroll"><table><thead><tr><th>Name</th><th class="num">Rate</th><th class="num">Ceiling</th><th>From</th><th>To</th><th></th></tr></thead><tbody>${(t.rates || []).map(r => `<tr><td>${esc(r.label)}</td><td class="num">${num(r.rate)}%</td><td class="num">${r.ceiling ? money(r.ceiling) : ""}</td><td>${fd(r.effective_from)}</td><td>${r.effective_to ? fd(r.effective_to) : "Current"}</td><td><button class="btn small danger" data-del="${r.id}">Delete</button></td></tr>`).join("") || `<tr><td colspan="6" class="empty">No rates yet.</td></tr>`}</tbody></table></div>
    <h3 style="margin:16px 0 8px">Add a new rate</h3><form id="rf" class="grid g2"><label class="f"><span>Name</span><input name="label" value="Standard" maxlength="60"></label><label class="f"><span>Rate (%)</span><input name="rate" type="number" step="0.0001" min="0" max="100" required></label>
    <label class="f"><span>Monthly ceiling (optional)</span><input name="ceil" type="number" step="0.01" min="0"></label><label class="f"><span>Applies from</span><input name="from" type="date" required></label>
    <label class="f" style="grid-column:1/-1"><span>Note</span><input name="note" maxlength="300" placeholder="Law or notice that set this rate"></label>
    <div class="row" style="grid-column:1/-1"><button class="btn primary" type="submit">Add rate</button><button class="btn" type="button" data-close>Close</button></div></form>
    <p class="muted">Adding a rate ends the previous one the day before it starts.</p>`);
    $$("[data-del]", b).forEach(x => x.addEventListener("click", () => { if (!confirm("Delete this rate?")) return; busy(x, async () => { await rpc("acc_tax_delete_rate", { p_id: x.dataset.del }); closeModal(); toast("Rate deleted"); renderTaxes(); }); }));
    $("#rf", b).addEventListener("submit", ev => { ev.preventDefault(); const f = form(ev.target); busy($("button[type=submit]", ev.target), async () => {
      await rpc("acc_tax_save_rate", { p_type: t.id, p_label: f.label.value, p_rate: Number(f.rate.value), p_ceiling: f.ceil.value ? Number(f.ceil.value) : null, p_from: f.from.value, p_note: f.note.value }); closeModal(); toast("Rate added"); renderTaxes(); }); });
  };
  draw();
}
let vatModel = null;
async function taxVat(ov) {
  const x = X.tax; $("#tx-body").innerHTML = periodControls(x, "tx-form") + `<div id="tx-out"><div class="loading">Loading\u2026</div></div>`;
  bindPeriod(x, "tx-form", () => renderTaxes());
  const [f, t] = presetRange(x.preset, x.from, x.to), d = await rpc("acc_tax_vat_return", { p_from: f, p_to: t }), entries = await rpc("acc_tax_entries_list", { p_from: f, p_to: t });
  const s = d.sales;
  vatModel = { title: "VAT return summary", meta: [["Period", `${fd(f)} to ${fd(t)}`], ["VAT number", d.vat_number || "Not registered"], ["Standard rate", d.rate != null ? d.rate + "%" : "not set"], ["Return and payment due", fd(d.due_date)]],
    sections: [{ title: "Sales", cols: [{ h: "Type of supply", t: "t", w: 4 }, { h: "Amount before VAT", t: "m", w: 2 }], rows: [["Standard rated", num(s.standard_base)], ["Zero-rated", num(s.zero_rated_base)], ["Exempt (medical services and medicines)", num(s.exempt_base)], ["Not yet classified", num(s.unclassified)]] },
      { title: "Income by account", cols: [{ h: "Code", t: "t", w: 1 }, { h: "Account", t: "t", w: 4 }, { h: "Treatment", t: "t", w: 2 }, { h: "Amount", t: "m" }, { h: "VAT", t: "m" }], rows: (d.accounts || []).map(a => [a.code, a.name, TREAT[a.treatment] ? TREAT[a.treatment].split(" (")[0] : "Not classified", num(a.amount), num(a.vat)]) },
      { title: "VAT entries recorded by hand", cols: [{ h: "Date", t: "t", w: 2 }, { h: "Type", t: "t", w: 2 }, { h: "Party", t: "t", w: 3 }, { h: "Invoice", t: "t", w: 2 }, { h: "Base", t: "m" }, { h: "VAT", t: "m" }], rows: entries.filter(e => !e.voided).map(e => [fd(e.date), e.direction === "input" ? "Input" : "Output", e.party || "", e.document_no || "", num(e.base), num(e.tax)]) }],
    totals: [["Output VAT on sales", num(s.output_vat)], ["Output VAT adjustments", num(d.output_adjustments)], ["Total output VAT", num(d.total_output), true], ["Input VAT recorded", num(d.input_recorded)], [`Input VAT you can claim (${(num(d.input_claim_share) * 100).toFixed(1)}%)`, num(d.input_claimable)], [num(d.net_payable) >= 0 ? "VAT payable to ZIMRA" : "VAT refundable by ZIMRA", num(d.net_payable), true]],
    notes: (d.warnings || []).concat(["This is a working summary from your ledger. Check it against the ZIMRA VAT return before you file."]) };
  $("#tx-out").innerHTML = `${(d.warnings || []).map(w => `<div class="panel" style="margin-bottom:12px;border-left:4px solid var(--warn)">${esc(w)}</div>`).join("")}
    <div class="figures" style="margin-bottom:16px"><div><div class="k">Total output VAT</div><div class="v">${money(d.total_output)}</div></div><div><div class="k">Input VAT you can claim</div><div class="v">${money(d.input_claimable)}</div></div>
      <div><div class="k">${num(d.net_payable) >= 0 ? "VAT payable" : "VAT refundable"}</div><div class="v">${money(Math.abs(num(d.net_payable)))}</div></div><div><div class="k">Due by</div><div class="v" style="font-size:1.1rem">${fd(d.due_date)}</div></div></div>
    ${exportBar()}${modelHtml(Object.assign({}, vatModel, { sections: vatModel.sections.slice(0, 2), totals: vatModel.totals, notes: vatModel.notes, meta: vatModel.meta }))}
    <div class="panel"><div class="panel-head"><h2>VAT entries recorded by hand</h2>${canPost() ? `<button class="btn small primary" id="te-new">Add VAT entry</button>` : ""}</div>
      <p class="muted" style="margin-top:0">Use these for VAT on supplier tax invoices you want to claim (input) or other output VAT not in the ledger. Sales VAT above is worked out automatically from income.</p>
      <div class="scroll"><table><thead><tr><th>Date</th><th>Type</th><th>Party</th><th>Invoice</th><th class="num">Before VAT</th><th class="num">VAT</th><th></th></tr></thead><tbody>${entries.map(e => `<tr class="${e.voided ? "inactive" : ""}"><td>${fd(e.date)}</td><td>${e.direction === "input" ? "Input" : "Output"}</td><td>${esc(e.party || "")}</td><td>${esc(e.document_no || "")}</td><td class="num">${money(e.base)}</td><td class="num">${money(e.tax)}</td>
        <td>${e.voided ? `<span class="muted">Voided: ${esc(e.void_reason || "")}</span>` : canPost() ? `<button class="btn small danger" data-void="${e.id}">Void</button>` : ""}</td></tr>`).join("") || `<tr><td colspan="7" class="empty">No entries in this period.</td></tr>`}</tbody></table></div></div>`;
  bindExport($("#tx-out"), () => vatModel, `vat-return-${f}_to_${t}`);
  const nb = $("#te-new"); if (nb) nb.addEventListener("click", () => vatEntryModal());
  $$("[data-void]").forEach(b => b.addEventListener("click", () => { const r = prompt("Reason for voiding this VAT entry?"); if (!r) return; busy(b, async () => { await rpc("acc_tax_entry_void", { p_id: b.dataset.void, p_reason: r }); toast("Entry voided"); renderTaxes(); }); }));
}
function vatEntryModal() {
  const b = openModal("Add VAT entry", `<form id="ef" class="grid g2"><label class="f"><span>Type</span><select name="dir"><option value="input">Input VAT (on a supplier invoice)</option><option value="output">Output VAT (not in the ledger)</option></select></label>
    <label class="f"><span>Invoice date</span><input type="date" name="date" max="${today()}" value="${today()}" required></label><label class="f"><span>Supplier</span><select name="sup">${supplierOptions("", true, "Not linked")}</select></label>
    <label class="f"><span>Name (if no supplier)</span><input name="party" maxlength="120"></label><label class="f"><span>Tax invoice number</span><input name="doc" maxlength="60"></label>
    <label class="f"><span>Amount before VAT</span><input name="base" inputmode="decimal" required></label><label class="f"><span>VAT amount</span><input name="tax" inputmode="decimal" required></label>
    <label class="f" style="grid-column:1/-1"><span>Description</span><input name="desc" maxlength="300"></label>
    <div class="row" style="grid-column:1/-1"><button class="btn primary" type="submit">Save</button><button class="btn" type="button" data-close>Cancel</button></div></form>`);
  $("#ef", b).addEventListener("submit", ev => { ev.preventDefault(); const f = form(ev.target), base = cents(f.base.value), tax = cents(f.tax.value);
    if (Number.isNaN(base) || Number.isNaN(tax) || tax <= 0) return toast("Enter the amounts as numbers, for example 100.50", true);
    busy($("button[type=submit]", ev.target), async () => { await rpc("acc_tax_entry_save", { p_date: f.date.value, p_direction: f.dir.value, p_party: f.party.value, p_supplier: f.sup.value || null, p_doc: f.doc.value, p_base: base / 100, p_tax: tax / 100, p_desc: f.desc.value }); closeModal(); toast("VAT entry saved"); renderTaxes(); }); });
}
async function taxExempt(ov) {
  const ctl = isCtl(), pats = S.look.patients, sups = S.look.suppliers;
  $("#tx-body").innerHTML = `<div class="panel" style="margin-bottom:16px"><h2>Income classification for VAT</h2><p class="muted" style="margin-top:0">Tell the system how each type of income is treated. Medical services and medicines are exempt under the VAT Act (ZIMRA); other income such as sundry sales may be standard rated. Income that is not classified is left out of the VAT return and flagged.</p>
    <div class="scroll"><table><thead><tr><th>Account</th><th>Treatment</th><th>Reason</th></tr></thead><tbody>${ov.revenue_accounts.map(a => `<tr><td>${esc(a.code)} ${esc(a.name)}</td><td>${ctl ? `<select data-acct="${a.id}"><option value="">Not classified</option>${Object.entries(TREAT).map(([k, v]) => opt(k, v, a.treatment)).join("")}</select>` : esc(TREAT[a.treatment] || "Not classified")}</td><td class="muted">${esc(a.reason || "")}</td></tr>`).join("")}</tbody></table></div></div>
    <div class="panel"><div class="panel-head"><h2>Exempt patients and suppliers</h2>${ctl ? `<button class="btn small primary" id="ex-new">Add exemption</button>` : ""}</div><p class="muted" style="margin-top:0">For example a diplomatic or government client with a certificate. Every exemption needs a reason.</p>
    <div class="scroll"><table><thead><tr><th>Name</th><th>Treatment</th><th>Reason</th><th>Certificate</th><th>Valid</th><th></th></tr></thead><tbody>${ov.exemptions.map(e => `<tr><td>${esc(e.name || "")}<br><span class="muted">${e.scope === "patient" ? "Patient" : "Supplier"}</span></td><td>${esc((TREAT[e.treatment] || "").split(" (")[0])}</td><td>${esc(e.reason || "")}</td><td>${esc(e.certificate_no || "")}</td><td>${e.valid_from ? fd(e.valid_from) : "Always"}${e.valid_to ? " to " + fd(e.valid_to) : ""}</td><td>${ctl ? `<button class="btn small danger" data-rm="${e.scope}:${e.ref_id}">Remove</button>` : ""}</td></tr>`).join("") || `<tr><td colspan="6" class="empty">No exemptions.</td></tr>`}</tbody></table></div></div>`;
  $$("[data-acct]").forEach(s => s.addEventListener("change", async () => { try { await rpc("acc_tax_set_treatment", { p_scope: "revenue_account", p_ref: s.dataset.acct, p_treatment: s.value, p_reason: null, p_cert: null, p_from: null, p_to: null }); toast("Saved"); } catch (e) { toast(e.message, true); renderTaxes(); } }));
  $$("[data-rm]").forEach(b => b.addEventListener("click", () => { if (!confirm("Remove this exemption?")) return; const [sc, id] = b.dataset.rm.split(":"); busy(b, async () => { await rpc("acc_tax_set_treatment", { p_scope: sc, p_ref: id, p_treatment: null, p_reason: null, p_cert: null, p_from: null, p_to: null }); toast("Exemption removed"); renderTaxes(); }); }));
  const nb = $("#ex-new"); if (!nb) return;
  nb.addEventListener("click", () => {
    const b = openModal("Add exemption", `<form id="xf" class="grid g2"><label class="f"><span>Applies to</span><select name="scope"><option value="patient">A patient</option><option value="supplier">A supplier</option></select></label>
      <label class="f"><span>Who</span><select name="who">${patientOptions("")}</select></label><label class="f"><span>Treatment</span><select name="tr"><option value="exempt">Exempt</option><option value="zero_rated">Zero-rated</option></select></label>
      <label class="f"><span>Certificate number</span><input name="cert" maxlength="60"></label><label class="f"><span>Valid from</span><input type="date" name="from"></label><label class="f"><span>Valid to</span><input type="date" name="to"></label>
      <label class="f" style="grid-column:1/-1"><span>Reason (required)</span><input name="reason" maxlength="300" required></label><div class="row" style="grid-column:1/-1"><button class="btn primary" type="submit">Save</button><button class="btn" type="button" data-close>Cancel</button></div></form>`);
    const f = form($("#xf", b)); f.scope.addEventListener("change", () => { f.who.innerHTML = f.scope.value === "patient" ? patientOptions("") : supplierOptions("", true, "Choose a supplier"); });
    $("#xf", b).addEventListener("submit", ev => { ev.preventDefault(); if (!f.who.value) return toast("Choose who the exemption is for", true);
      busy($("button[type=submit]", ev.target), async () => { await rpc("acc_tax_set_treatment", { p_scope: f.scope.value, p_ref: f.who.value, p_treatment: f.tr.value, p_reason: f.reason.value, p_cert: f.cert.value, p_from: f.from.value || null, p_to: f.to.value || null }); closeModal(); toast("Exemption saved"); renderTaxes(); }); });
  });
}
async function taxPayroll() {
  const x = X.tax; $("#tx-body").innerHTML = periodControls(x, "tx-form") + `<div id="tx-out"><div class="loading">Loading\u2026</div></div>`; bindPeriod(x, "tx-form", () => renderTaxes());
  const [f, t] = presetRange(x.preset, x.from, x.to), d = await rpc("acc_tax_payroll_report", { p_from: f, p_to: t }), tot = d.items.reduce((n, i) => n + num(i.amount), 0), unl = d.items.filter(i => !i.linked && i.status !== "none");
  const m = { title: "Payroll taxes and levies", meta: [["Period", `${fd(f)} to ${fd(t)}`]], sections: [
    { title: "Withheld and due to ZIMRA / NSSA", cols: [{ h: "Tax or levy", t: "t", w: 3 }, { h: "Linked payroll item", t: "t", w: 3 }, { h: "Employees", t: "n", w: 1 }, { h: "Amount", t: "m", w: 2 }, { h: "Due day", t: "t", w: 1 }], rows: d.items.map(i => [i.name, i.item || "Not linked", i.employees, num(i.amount), i.due_day ? i.due_day + "th" : ""]) },
    { title: "Approved and paid payroll runs", cols: [{ h: "Run", t: "t", w: 2 }, { h: "Period", t: "t", w: 3 }, { h: "Status", t: "t", w: 2 }, { h: "Gross", t: "m" }, { h: "Deductions", t: "m" }, { h: "Employer cost", t: "m" }], rows: d.runs.map(r => [r.run_no, r.period, r.status, num(r.gross), num(r.deductions), num(r.employer)]), empty: "No approved payroll runs in this period." }],
    totals: [["Total withheld and due", tot, true]],
    notes: ["PAYE is worked out in payroll from the pay items you set up. Public sources disagree on the 2026 USD PAYE bands, so none are preset. Enter the bands from the current ZIMRA table.", "NSSA contributions are 4.5% each for employee and employer up to an insurable earnings ceiling that is gazetted quarterly (USD 700 at last check). Confirm the current ceiling.", unl.length ? "Some taxes are not linked to a payroll item, so their amounts show zero. Link them under Tax types and rates." : ""] };
  $("#tx-out").innerHTML = exportBar() + modelHtml(m); bindExport($("#tx-out"), () => m, `payroll-taxes-${f}_to_${t}`);
}
async function taxIncome() {
  const x = X.tax; if (x.preset !== "custom" && x.preset !== "year") { x.preset = "year"; [x.from, x.to] = presetRange("year"); }
  $("#tx-body").innerHTML = periodControls(x, "tx-form") + `<div id="tx-out"><div class="loading">Loading\u2026</div></div>`; bindPeriod(x, "tx-form", () => renderTaxes());
  const [f, t] = presetRange(x.preset, x.from, x.to), d = await rpc("acc_tax_income_estimate", { p_from: f, p_to: t });
  const m = { title: "Income tax estimate", meta: [["Period", `${fd(f)} to ${fd(t)}`], ["Income tax rate", d.rate != null ? d.rate + "% (+" + (d.aids_rate || 0) + "% AIDS levy on the tax)" : "not set"]],
    sections: [{ title: "Accounting profit", cols: [{ h: "Line", t: "t", w: 4 }, { h: "Amount", t: "m", w: 2 }], rows: [["Revenue", num(d.revenue)], ["Expenses", num(d.expenses)], ["Profit before tax", num(d.profit)]] }],
    totals: d.active && d.rate != null ? [["Estimated income tax", num(d.income_tax)], ["AIDS levy", num(d.aids_levy)], ["Estimated total", num(d.total), true]] : [],
    notes: [d.active && d.rate != null ? "" : "Corporate income tax is switched off or has no confirmed rate. Public sources disagree on the base rate, so none is preset. Confirm it with ZIMRA, then enter it under Tax types and rates and switch the tax on. If the hospital is a registered not-for-profit, the position may differ.", d.note] };
  $("#tx-out").innerHTML = exportBar() + modelHtml(m); bindExport($("#tx-out"), () => m, `income-tax-estimate-${f}_to_${t}`);
}
async function taxCalendar() {
  const cal = await rpc("acc_tax_calendar", { p_months: 6 });
  $("#tx-body").innerHTML = `<div class="panel"><h2>Filing calendar</h2><p class="muted" style="margin-top:0">Returns and payments for recent periods. Record each one when you file or pay so it stops showing as outstanding.</p>
    <div class="scroll"><table><thead><tr><th>Tax</th><th>Period</th><th>Due</th><th>Status</th><th class="num">Due amount</th><th class="num">Paid</th><th></th></tr></thead><tbody>${cal.map(c => `<tr><td>${esc(c.name)}</td><td>${fd(c.period_start)} to ${fd(c.period_end)}</td><td>${fd(c.due_date)}</td>
      <td>${c.status === "paid" ? `<span class="pill ok">Paid ${fd(c.paid_on)}</span>` : c.status === "filed" ? `<span class="pill">Filed ${fd(c.filed_on)}</span>` : c.overdue ? `<span class="pill bad">Overdue</span>` : `<span class="pill warn">Open</span>`}</td>
      <td class="num">${c.amount_due != null ? money(c.amount_due) : ""}</td><td class="num">${c.amount_paid ? money(c.amount_paid) : ""}</td><td>${canPost() ? `<button class="btn small" data-rec="${c.tax_type_id}|${c.period_start}|${c.period_end}">Record</button>` : ""}</td></tr>`).join("") || `<tr><td colspan="7" class="empty">No filing periods yet.</td></tr>`}</tbody></table></div></div>`;
  $$("[data-rec]").forEach(b => b.addEventListener("click", () => { const [id, ps, pe] = b.dataset.rec.split("|"), c = cal.find(z => z.tax_type_id === id && z.period_start === ps && z.period_end === pe);
    const m = openModal(`${c.name}: ${fd(ps)} to ${fd(pe)}`, `<form id="ff" class="grid g2"><label class="f"><span>Amount due</span><input name="due" inputmode="decimal" value="${c.amount_due != null ? num(c.amount_due).toFixed(2) : ""}"></label>
      <label class="f"><span>Status</span><select name="st">${opt("open", "Open", c.status)}${opt("filed", "Filed", c.status)}${opt("paid", "Filed and paid", c.status)}</select></label><label class="f"><span>Date filed</span><input type="date" name="filed" max="${today()}" value="${c.filed_on || ""}"></label>
      <label class="f"><span>Date paid</span><input type="date" name="paidon" max="${today()}" value="${c.paid_on || ""}"></label><label class="f"><span>Amount paid</span><input name="paid" inputmode="decimal" value="${c.amount_paid ? num(c.amount_paid).toFixed(2) : ""}"></label>
      <label class="f"><span>Reference</span><input name="ref" maxlength="80" value="${esc(c.reference || "")}"></label><div class="row" style="grid-column:1/-1"><button class="btn primary" type="submit">Save</button><button class="btn" type="button" data-close>Cancel</button></div></form>`);
    $("#ff", m).addEventListener("submit", ev => { ev.preventDefault(); const f = form(ev.target), due = cents(f.due.value), paid = cents(f.paid.value);
      if (Number.isNaN(due) || Number.isNaN(paid)) return toast("Enter amounts as numbers, for example 100.50", true);
      busy($("button[type=submit]", ev.target), async () => { await rpc("acc_tax_filing_save", { p_tax: id, p_start: ps, p_end: pe, p_amount_due: due / 100, p_status: f.st.value, p_filed_on: f.filed.value || null, p_paid_on: f.paidon.value || null, p_amount_paid: paid / 100, p_reference: f.ref.value, p_note: null }); closeModal(); toast("Saved"); renderTaxes(); }); }); }));
}

/* ====================== BUDGETS ====================== */
const BSTAT = { draft: "Draft", active: "Active", closed: "Closed" };
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const meter = (pct, over) => `<div style="height:8px;border-radius:99px;background:var(--line);overflow:hidden;min-width:70px"><div style="height:100%;width:${Math.min(100, Math.max(0, pct || 0))}%;background:${over ? "var(--neg)" : pct >= 90 ? "var(--warn)" : "var(--pos)"}"></div></div>`;
async function renderBudgets() {
  setTitle("Budgets"); const b = X.bud;
  if (b.id) return budgetDetail();
  if (!b.year) b.year = Number(today().slice(0, 4));
  const list = await rpc("acc_budget_list", { p_year: b.year });
  $("#toolbar").innerHTML = `<label class="row"><span class="muted">Year</span><select id="bd-year">${[b.year - 1, b.year, b.year + 1].map(y => opt(y, y, b.year)).join("")}</select></label>${isCtl() ? `<button class="btn primary" id="bd-new">New budget</button>` : ""}`;
  $("#bd-year").addEventListener("change", e => { b.year = Number(e.target.value); renderBudgets(); });
  const nb = $("#bd-new"); if (nb) nb.addEventListener("click", () => budgetModal(list));
  $("#view").innerHTML = `<div class="panel"><div class="scroll"><table><thead><tr><th>Budget</th><th>Period</th><th>Status</th><th class="num">Revenue target</th><th class="num">Revenue so far</th><th class="num">Expense budget</th><th class="num">Spent so far</th><th>Used</th><th></th></tr></thead><tbody>${list.map(x => {
    const pct = num(x.budget_expense) ? num(x.actual_expense) / num(x.budget_expense) * 100 : 0;
    return `<tr class="click" data-open="${x.id}"><td><b>${esc(x.name)}</b></td><td>${x.period_type === "annual" ? "Year " + x.fiscal_year : MONTHS[x.month - 1] + " " + x.fiscal_year}</td><td><span class="pill${x.status === "active" ? " ok" : ""}">${BSTAT[x.status]}</span></td>
      <td class="num">${money(x.budget_revenue)}</td><td class="num">${money(x.actual_revenue)}</td><td class="num">${money(x.budget_expense)}</td><td class="num">${money(x.actual_expense)}</td><td>${num(x.budget_expense) ? meter(pct, pct > 100) + `<span class="muted">${pct.toFixed(0)}%</span>` : ""}</td><td><button class="btn small" data-open="${x.id}">Open</button></td></tr>`; }).join("") || `<tr><td colspan="9" class="empty">No budgets for ${b.year} yet.${isCtl() ? " Use New budget to create one." : ""}</td></tr>`}</tbody></table></div></div>`;
  $$("[data-open]").forEach(r => r.addEventListener("click", e => { e.stopPropagation(); b.id = r.dataset.open; b.tab = "lines"; renderBudgets(); }));
}
function budgetModal(list) {
  const m = openModal("New budget", `<form id="bf" class="grid g2"><label class="f"><span>Name</span><input name="name" required maxlength="80" value="Budget ${X.bud.year}"></label><label class="f"><span>Type</span><select name="type"><option value="annual">Annual</option><option value="month">Monthly</option></select></label>
    <label class="f"><span>Year (starting ${MONTHS[(((S.look && S.look.settings && S.look.settings.fiscal_year_start_month) || 1) - 1)]})</span><input name="year" type="number" min="2000" max="2100" value="${X.bud.year}" required></label>
    <label class="f" id="bm-wrap" hidden><span>Month</span><select name="month">${MONTHS.map((n, i) => opt(i + 1, n, Number(today().slice(5, 7)))).join("")}</select></label>
    <label class="f"><span>Copy amounts from</span><select name="copy">${opt("", "Start empty", "")}${list.map(x => opt(x.id, x.name, "")).join("")}</select></label>
    <label class="f"><span>Notes</span><input name="notes" maxlength="500"></label><div class="row" style="grid-column:1/-1"><button class="btn primary" type="submit">Create</button><button class="btn" type="button" data-close>Cancel</button></div></form>`);
  const f = form($("#bf", m)); f.type.addEventListener("change", () => { $("#bm-wrap", m).hidden = f.type.value !== "month"; });
  $("#bf", m).addEventListener("submit", ev => { ev.preventDefault(); busy($("button[type=submit]", ev.target), async () => {
    const id = await rpc("acc_budget_save", { p_id: null, p_name: f.name.value, p_year: Number(f.year.value), p_type: f.type.value, p_month: f.type.value === "month" ? Number(f.month.value) : null, p_status: "draft", p_notes: f.notes.value, p_copy_from: f.copy.value || null });
    closeModal(); X.bud.id = id; X.bud.tab = "lines"; toast("Budget created. Enter the amounts, then activate it."); renderBudgets(); }); });
}
let budModel = null;
async function budgetDetail() {
  const b = X.bud, d = await rpc("acc_budget_detail", { p_id: b.id }), bu = d.budget, ctl = isCtl() && bu.status !== "closed", T = d.totals;
  const title = `${bu.name} (${bu.period_type === "annual" ? "year " + bu.fiscal_year : MONTHS[bu.month - 1] + " " + bu.fiscal_year})`; setTitle(title);
  $("#toolbar").innerHTML = `<button class="btn" id="bd-back">All budgets</button>${isCtl() ? (bu.status === "draft" ? `<button class="btn primary" id="bd-act">Activate</button><button class="btn danger" id="bd-del">Delete</button>` : bu.status === "active" ? `<button class="btn" id="bd-close">Close budget</button>` : `<button class="btn" id="bd-reopen">Reopen</button>`) : ""}`;
  const st = async (s, msg) => { try { await rpc("acc_budget_save", { p_id: bu.id, p_name: bu.name, p_year: bu.fiscal_year, p_type: bu.period_type, p_month: bu.month, p_status: s, p_notes: bu.notes }); toast(msg); renderBudgets(); } catch (e) { toast(e.message, true); } };
  $("#bd-back").addEventListener("click", () => { b.id = null; renderBudgets(); });
  const on = (id, fn) => { const e = $("#" + id); if (e) e.addEventListener("click", fn); };
  on("bd-act", () => st("active", "Budget activated. Alerts will follow its limits.")); on("bd-close", () => { if (confirm("Close this budget? It can no longer be edited.")) st("closed", "Budget closed"); }); on("bd-reopen", () => st("active", "Budget reopened"));
  on("bd-del", () => { if (!confirm("Delete this draft budget?")) return; rpc("acc_budget_delete", { p_id: bu.id }).then(() => { b.id = null; toast("Budget deleted"); renderBudgets(); }).catch(e => toast(e.message, true)); });
  const rev = d.lines.filter(l => l.type === "revenue"), exp = d.lines.filter(l => l.type === "expense"), pct = (a, bb) => bb ? num(a) / num(bb) * 100 : null;
  budModel = { title: "Budget against actual", meta: [["Budget", bu.name], ["Period", `${fd(d.from)} to ${fd(d.to)}`], ["Status", BSTAT[bu.status]]], sections: [
    { title: "Revenue targets", cols: [{ h: "Account", t: "t", w: 4 }, { h: "Target", t: "m" }, { h: "Actual", t: "m" }, { h: "Difference", t: "m" }, { h: "Reached", t: "p" }], rows: rev.filter(l => num(l.budget) || num(l.actual)).map(l => [`${l.code} ${l.name}`, num(l.budget), num(l.actual), num(l.variance), l.pct]) },
    { title: "Expense budgets", cols: [{ h: "Account", t: "t", w: 4 }, { h: "Budget", t: "m" }, { h: "Actual", t: "m" }, { h: "Left", t: "m" }, { h: "Used", t: "p" }], rows: exp.filter(l => num(l.budget) || num(l.actual)).map(l => [`${l.code} ${l.name}`, num(l.budget), num(l.actual), num(l.variance), l.pct]) },
    { title: "Department spending limits", cols: [{ h: "Department", t: "t", w: 3 }, { h: "Limit", t: "m" }, { h: "Budgeted", t: "m" }, { h: "Spent", t: "m" }, { h: "Used", t: "p" }], rows: d.departments.filter(x => num(x.limit) || num(x.actual)).map(x => [x.name, x.limit != null ? num(x.limit) : "", num(x.budget), num(x.actual), x.pct]) }],
    totals: [["Revenue target", num(T.budget_revenue)], ["Revenue so far", num(T.actual_revenue)], ["Expense budget", num(T.budget_expense)], ["Spent so far", num(T.actual_expense)], ["Surplus target", num(T.budget_revenue) - num(T.budget_expense), true], ["Surplus so far", num(T.actual_revenue) - num(T.actual_expense), true]] };
  $("#view").innerHTML = tabsHtml([["lines", "Accounts"], ["depts", "Department limits"], ["targets", "Targets and progress"]], b.tab) + exportBar() + `<div id="bd-body"></div>`;
  $$("[data-tab]").forEach(t => t.addEventListener("click", () => { b.tab = t.dataset.tab; budgetDetail(); }));
  bindExport($("#view"), () => budModel, `budget-${bu.name.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}`);
  if (b.tab === "lines") budLines(d, ctl, rev, exp); else if (b.tab === "depts") budDepts(d, ctl); else budTargets(d);
}
function budLines(d, ctl, rev, exp) {
  const rows = ls => ls.map(l => `<tr><td>${esc(l.code)} ${esc(l.name)}${l.department ? `<br><span class="muted">${esc(l.department)}</span>` : ""}</td><td class="num">${ctl ? `<input class="num" style="width:110px" inputmode="decimal" data-acct="${l.account_id}" data-orig="${num(l.budget) ? num(l.budget).toFixed(2) : ""}" value="${num(l.budget) ? num(l.budget).toFixed(2) : ""}" aria-label="Budget for ${esc(l.name)}">` : money(l.budget)}</td>
    <td class="num">${money(l.actual)}</td><td class="num" style="${num(l.variance) < 0 ? "color:var(--neg)" : ""}">${money(l.variance)}</td><td>${l.pct != null ? meter(l.pct, l.type === "expense" && l.pct > 100) + `<span class="muted">${l.pct}%</span>` : ""}</td></tr>`).join("");
  const sec = (t, ls, h2) => `<div class="panel" style="margin-bottom:16px"><h2>${t}</h2><div class="scroll"><table><thead><tr><th>Account</th><th class="num">${h2[0]}</th><th class="num">Actual</th><th class="num">${h2[1]}</th><th>${h2[2]}</th></tr></thead><tbody>${rows(ls)}</tbody></table></div></div>`;
  $("#bd-body").innerHTML = (d.budget.status === "closed" ? `<p class="muted">This budget is closed and cannot be edited.</p>` : "") + sec("Revenue targets", rev, ["Target", "Difference", "Reached"]) + sec("Expense budgets", exp, ["Budget", "Left", "Used"]) + (ctl ? `<div class="row"><button class="btn primary" id="bl-save">Save budget amounts</button><span class="muted">Leave an amount empty or 0 to remove it.</span></div>` : "");
  const sb = $("#bl-save"); if (!sb) return;
  sb.addEventListener("click", () => busy(sb, async () => {
    const lines = [], bad = [];
    $$("[data-acct]").forEach(i => { const v = i.value.trim(); if (v === i.dataset.orig) return; const c = cents(v); if (Number.isNaN(c)) { bad.push(i); return; } lines.push({ account_id: i.dataset.acct, amount: c / 100 }); });
    if (bad.length) { bad[0].focus(); return toast("Enter amounts as numbers, for example 1500 or 1500.50", true); }
    if (!lines.length) return toast("Nothing has changed");
    await rpc("acc_budget_set_lines", { p_budget: d.budget.id, p_lines: lines }); toast("Budget saved"); budgetDetail();
  }));
}
function budDepts(d, ctl) {
  $("#bd-body").innerHTML = `<div class="panel"><div class="panel-head"><h2>Department spending limits</h2>${isCtl() ? `<button class="btn small" id="dp-manage">Manage departments</button>` : ""}</div><p class="muted" style="margin-top:0">A limit is the most a department should spend in this budget period. You get an alert at 90% and when it is passed. Actual spending is counted from the expense accounts assigned to the department.</p>
    <div class="scroll"><table><thead><tr><th>Department</th><th class="num">Limit</th><th class="num">Budgeted</th><th class="num">Spent</th><th>Used</th></tr></thead><tbody>${d.departments.map(x => `<tr><td>${esc(x.name)}</td><td class="num">${ctl ? `<input class="num" style="width:110px" inputmode="decimal" data-dept="${x.department_id}" data-orig="${x.limit != null ? num(x.limit).toFixed(2) : ""}" value="${x.limit != null ? num(x.limit).toFixed(2) : ""}" aria-label="Limit for ${esc(x.name)}">` : (x.limit != null ? money(x.limit) : "None")}</td>
      <td class="num">${money(x.budget)}</td><td class="num">${money(x.actual)}</td><td>${x.pct != null ? meter(x.pct, x.pct > 100) + `<span class="muted">${x.pct}%${x.pct > 100 ? " over" : ""}</span>` : `<span class="muted">No limit</span>`}</td></tr>`).join("")}</tbody></table></div>
    ${ctl ? `<div class="row" style="margin-top:12px"><button class="btn primary" id="dl-save">Save limits</button></div>` : ""}</div>`;
  const sv = $("#dl-save"); if (sv) sv.addEventListener("click", () => busy(sv, async () => {
    let n = 0; for (const i of $$("[data-dept]")) { const v = i.value.trim(); if (v === i.dataset.orig) continue; const c = cents(v); if (Number.isNaN(c)) { i.focus(); return toast("Enter limits as numbers, for example 5000", true); }
      await rpc("acc_budget_set_limit", { p_budget: d.budget.id, p_dept: i.dataset.dept, p_limit: c / 100 }); n++; }
    toast(n ? "Limits saved" : "Nothing has changed"); budgetDetail(); }));
  const mg = $("#dp-manage"); if (mg) mg.addEventListener("click", deptModal);
}
async function deptModal() {
  const L = await rpc("acc_departments_list");
  const m = openModal("Departments", `<h3 style="margin:0 0 8px">Departments</h3>${L.departments.map(x => `<div class="row" style="margin-bottom:6px;gap:8px"><input value="${esc(x.name)}" data-dn="${x.id}" maxlength="60" style="flex:1"><label class="check"><input type="checkbox" data-da="${x.id}" ${x.is_active ? "checked" : ""}> In use</label></div>`).join("")}
    <div class="row" style="margin:8px 0 16px;gap:8px"><input id="dn-new" placeholder="New department name" maxlength="60" style="flex:1"><button class="btn" id="dn-add">Add</button></div><button class="btn primary" id="dn-save">Save departments</button>
    <h3 style="margin:20px 0 8px">Which department does each expense account belong to?</h3><div class="scroll" style="max-height:320px"><table><tbody>${L.accounts.map(a => `<tr><td>${esc(a.code)} ${esc(a.name)}</td><td><select data-map="${a.id}">${opt("", "None", a.department_id)}${L.departments.filter(x => x.is_active || x.id === a.department_id).map(x => opt(x.id, x.name, a.department_id)).join("")}</select></td></tr>`).join("")}</tbody></table></div>
    <div class="row" style="margin-top:12px"><button class="btn primary" id="mp-save">Save assignments</button><button class="btn" data-close>Close</button></div>`);
  $("#dn-add", m).addEventListener("click", e => busy(e.target, async () => { const n = $("#dn-new", m).value.trim(); if (!n) return toast("Enter a name", true); await rpc("acc_department_save", { p_id: null, p_name: n, p_active: true }); closeModal(); toast("Department added"); budgetDetail(); }));
  $("#dn-save", m).addEventListener("click", e => busy(e.target, async () => { for (const i of $$("[data-dn]", m)) await rpc("acc_department_save", { p_id: i.dataset.dn, p_name: i.value, p_active: $(`[data-da="${i.dataset.dn}"]`, m).checked }); closeModal(); toast("Departments saved"); budgetDetail(); }));
  $("#mp-save", m).addEventListener("click", e => busy(e.target, async () => { for (const s of $$("[data-map]", m)) { const a = L.accounts.find(z => z.id === s.dataset.map); if ((a.department_id || "") !== s.value) await rpc("acc_department_map", { p_account: s.dataset.map, p_dept: s.value || null }); } closeModal(); toast("Assignments saved"); budgetDetail(); }));
}
function budTargets(d) {
  const T = d.totals, f = parseISO(d.from), t = parseISO(d.to), n = parseISO(today()), total = Math.round((t - f) / 864e5) + 1, done = Math.min(total, Math.max(0, Math.round((n - f) / 864e5) + 1)), el = done / total;
  const br = num(T.budget_revenue), ar = num(T.actual_revenue), be = num(T.budget_expense), ae = num(T.actual_expense), sb = br - be, sa = ar - ae, proj = el > 0 && el < 1 ? ae / el : ae;
  const card = (k, v, s) => `<div><div class="k">${k}</div><div class="v">${v}</div><div class="s">${s}</div></div>`;
  $("#bd-body").innerHTML = `<div class="figures" style="margin-bottom:16px">${card("Revenue target", money(br), br ? `${(ar / br * 100).toFixed(0)}% reached (${money(ar)})` : "No target set")}${card("Expense budget", money(be), be ? `${(ae / be * 100).toFixed(0)}% spent (${money(ae)})` : "No budget set")}
    ${card("Surplus target", money(sb), `So far ${money(sa)}`)}${card("Period elapsed", (el * 100).toFixed(0) + "%", `${done} of ${total} days`)}</div>
    <div class="panel" style="margin-bottom:16px"><h2>Pace</h2><p style="margin:0">${be ? (proj > be ? `At the current rate, spending would reach <b>${money(proj)}</b> by the end of the period, which is <b style="color:var(--neg)">${money(proj - be)} over</b> the budget of ${money(be)}.` : `At the current rate, spending would reach <b>${money(proj)}</b> by the end of the period, within the budget of ${money(be)}.`) : "Set expense budgets to see whether spending is on pace."}</p></div>
    <div class="panel"><h2>Budget compared with actual</h2><div style="height:280px"><canvas id="bd-chart" aria-label="Budget compared with actual"></canvas></div></div>`;
  chart("bd-chart", { type: "bar", data: { labels: ["Revenue", "Expenses", "Surplus"], datasets: [{ label: "Budget / target", data: [br, be, sb], backgroundColor: cssVar("--accent") }, { label: "Actual", data: [ar, ae, sa], backgroundColor: cssVar("--pos") }] }, options: { maintainAspectRatio: false, plugins: { legend: { position: "bottom" } }, scales: { y: { ticks: { callback: v => money(v) } } } } });
}

/* ====================== NOTIFICATIONS ====================== */
const NKIND = { overdue_invoice: "Overdue invoices", new_payment: "New payments", pending_approval: "Pending approvals", low_balance: "Low balances", failed_transaction: "Failed transactions", upcoming_bill: "Upcoming bills", tax_due: "Tax due", budget: "Budget limits" };
const NGO = { invoice: "invoices", receipt: "payments", insurer_payment: "payments", expense_request: "expenses", refund_request: "payments", payroll_run: "dashboard", account: "ledger", sync_error: "settings", bill: "suppliers", tax: "taxes", budget: "budgets" };
let audio;
function beep() { try { audio = audio || new (window.AudioContext || window.webkitAudioContext)(); if (audio.state === "suspended") audio.resume(); [[880, 0], [1320, .18]].forEach(([fq, t0]) => { const o = audio.createOscillator(), g = audio.createGain(), s = audio.currentTime + t0; o.frequency.value = fq; g.gain.setValueAtTime(.0001, s); g.gain.exponentialRampToValueAtTime(.2, s + .02); g.gain.exponentialRampToValueAtTime(.0001, s + .3); o.connect(g); g.connect(audio.destination); o.start(s); o.stop(s + .35); }); } catch (e) {} }
function badge(n) { const b = $('[data-nav="notifications"]'); if (!b) return; b.innerHTML = `Notifications${n ? ` <span class="nbadge" aria-label="${n} unread">${n > 99 ? "99+" : n}</span>` : ""}`; }
async function ntPoll(refresh) {
  if (!S.access) return clearInterval(X.nt.timer);
  try {
    if (refresh) await rpc("acc_notifications_refresh");
    const d = await rpc("acc_notifications_list", { p_filter: "all", p_kind: null, p_limit: 150 }); X.nt.data = d; badge(d.unread);
    if (X.nt.seen !== null && d.unread > X.nt.seen) { if (d.prefs.sound) beep(); const top = d.items.find(i => !i.read && !i.resolved); if (top) toast(top.title, top.severity === "critical"); }
    X.nt.seen = d.unread; if (S.page === "notifications" && !document.hidden && $("#nt-list")) drawNotifications();
  } catch (e) { /* quiet: the page itself shows errors */ }
}
function ntStart() { clearInterval(X.nt.timer); X.nt.seen = null; ntPoll(true); X.nt.timer = setInterval(() => ntPoll(true), 60000); }
function drawNotifications() {
  const d = X.nt.data, f = X.nt; if (!d) return;
  const items = d.items.filter(i => (f.filter === "unread" ? !i.read && !i.resolved : f.filter === "open" ? !i.resolved : true) && (!f.kind || i.kind === f.kind));
  $("#nt-list").innerHTML = items.map(i => `<div class="panel" style="margin-bottom:10px;border-left:4px solid ${i.severity === "critical" ? "var(--neg)" : i.severity === "warning" ? "var(--warn)" : "var(--accent)"};${i.read ? "opacity:.78" : ""}">
    <div class="row" style="justify-content:space-between;gap:8px;flex-wrap:wrap"><div><b>${i.read ? "" : `<span class="pill bad" style="margin-right:6px">New</span>`}${esc(i.title)}</b><div class="muted">${esc(NKIND[i.kind] || i.kind)} \u00b7 ${fdt(i.created_at)}${i.resolved ? " \u00b7 resolved" : ""}</div></div>
    <div class="row" style="gap:6px">${NGO[i.ref_type] && !i.resolved ? `<button class="btn small" data-go="${NGO[i.ref_type]}" data-id="${i.id}">Open</button>` : ""}<button class="btn small" data-mark="${i.id}" data-read="${i.read ? "0" : "1"}">${i.read ? "Mark unread" : "Mark read"}</button></div></div>
    ${i.body ? `<p style="margin:8px 0 0">${esc(i.body)}</p>` : ""}</div>`).join("") || `<div class="panel empty">Nothing here. You are all caught up.</div>`;
  $$("[data-mark]").forEach(b => b.addEventListener("click", async () => { try { await rpc("acc_notification_mark", { p_id: b.dataset.mark, p_read: b.dataset.read === "1" }); await ntPoll(false); } catch (e) { toast(e.message, true); } }));
  $$("[data-go]").forEach(b => b.addEventListener("click", async () => { try { await rpc("acc_notification_mark", { p_id: b.dataset.id, p_read: true }); } catch (e) {} ntPoll(false); window.go(b.dataset.go); }));
}
async function renderNotifications() {
  setTitle("Notifications"); const f = X.nt;
  $("#view").innerHTML = `<div class="loading">Loading\u2026</div>`; await ntPoll(true); const d = f.data; if (!d) return;
  const chips = [["all", "All"], ["unread", "Unread (" + d.unread + ")"], ["open", "Open"]];
  $("#toolbar").innerHTML = `<button class="btn" id="nt-all">Mark all as read</button><button class="btn" id="nt-set">Alert settings</button>`;
  $("#view").innerHTML = `<div class="row" style="flex-wrap:wrap;gap:8px;margin-bottom:12px">${chips.map(([k, l]) => `<button class="btn small${f.filter === k ? " primary" : ""}" data-f="${k}">${l}</button>`).join("")}<select id="nt-kind" aria-label="Type of alert">${opt("", "All types", f.kind)}${Object.entries(NKIND).map(([k, v]) => opt(k, v, f.kind)).join("")}</select></div><div id="nt-list"></div>`;
  $$("[data-f]").forEach(b => b.addEventListener("click", () => { f.filter = b.dataset.f; renderNotifications(); })); $("#nt-kind").addEventListener("change", e => { f.kind = e.target.value; drawNotifications(); });
  $("#nt-all").addEventListener("click", e => busy(e.target, async () => { await rpc("acc_notifications_mark_all"); await ntPoll(false); toast("All notifications marked as read"); renderNotifications(); }));
  $("#nt-set").addEventListener("click", () => { const p = d.prefs;
    const m = openModal("Alert settings", `<form id="ns"><label class="check" style="margin-bottom:10px"><input type="checkbox" name="sound" ${p.sound ? "checked" : ""}> Play a sound when a new alert arrives</label><p class="muted" style="margin-top:0">Alerts are checked every minute while this page is open. Your browser may ask you to click the page once before it allows sound.</p>
      <h3 style="margin:12px 0 6px">Show these alerts</h3>${Object.entries(NKIND).map(([k, v]) => `<label class="check" style="display:block;margin:4px 0"><input type="checkbox" name="k_${k}" ${p.muted_kinds.includes(k) ? "" : "checked"}> ${esc(v)}</label>`).join("")}
      <div class="row" style="margin-top:14px"><button class="btn primary" type="submit">Save</button><button class="btn" type="button" id="ns-test">Play test sound</button><button class="btn" type="button" data-close>Cancel</button></div></form>`);
    $("#ns-test", m).addEventListener("click", beep);
    $("#ns", m).addEventListener("submit", ev => { ev.preventDefault(); const fm = form(ev.target); busy($("button[type=submit]", ev.target), async () => { await rpc("acc_notification_prefs_set", { p_sound: fm.sound.checked, p_muted: Object.keys(NKIND).filter(k => !fm["k_" + k].checked) }); closeModal(); toast("Settings saved"); await ntPoll(false); renderNotifications(); }); }); });
  drawNotifications();
}

/* ====================== wiring ====================== */
const PAGES = { reports: renderReports, taxes: renderTaxes, budgets: renderBudgets, notifications: renderNotifications };
const at = NAV.findIndex(n => n[0] === "suppliers") + 1;
NAV.splice(at, 0, ["reports", "Reports"], ["budgets", "Budgets"], ["taxes", "Taxes"], ["notifications", "Notifications"]);
const origGo = window.go;
window.go = function (page) {
  const fn = PAGES[page]; if (!fn) return origGo(page);
  S.page = page; destroyCharts(); X.bud.id = page === "budgets" ? X.bud.id : null;
  $$("[data-nav]").forEach(b => { if (b.dataset.nav === page) b.setAttribute("aria-current", "page"); else b.removeAttribute("aria-current"); });
  $("#toolbar").innerHTML = ""; fn().catch(e => { $("#view").innerHTML = `<div class="panel"><b>Could not load this page.</b><p class="muted">${esc(e.message)}</p></div>`; });
};
const origShell = window.renderShell;
window.renderShell = function () { origShell(); ntStart(); };
const st = document.createElement("style");
st.textContent = `.nbadge{display:inline-block;min-width:20px;padding:1px 6px;margin-left:6px;border-radius:99px;background:var(--neg);color:#fff;font-size:.72rem;font-weight:700;text-align:center}
.pill.warn{background:color-mix(in srgb,var(--warn) 18%,transparent);border-color:var(--warn);color:var(--warn)}.tabs{flex-wrap:wrap}`;
document.head.appendChild(st);
})();
