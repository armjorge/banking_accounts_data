// sql/017: Investments & Assets page. Accounts at an institution (Infonavit, Afore,
// Cetesdirecto, GBM, cash, a car...), their movements in master_closed_aaccandass_f,
// file upload with a column map (saved per account as a template), manual rows,
// reconciliation against the balance the institution shows, and month-end balances.
// Uses statementApi() and decodeBankCsv() from statements.js, strmXlsxToRows() from
// xlsx_to_csv.js, and dimEsc() / money() from dimensions.js.

const ASSET_DATE_FORMATS = [
  ["DMY", "Day/Month/Year (14/09/2026)"],
  ["MDY", "Month/Day/Year (09/14/2026)"],
  ["YMD", "Year-Month-Day (2026-09-14)"],
];

function assetToday() {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Mexico_City" }).formatToParts(new Date());
  const get = (type) => parts.find((part) => part.type === type)?.value;
  return `${get("year")}-${get("month")}-${get("day")}`;
}

function assetCsvParse(text, delimiter = ",") {
  // Small CSV reader for the preview headers (the database parses the file for real).
  const rows = [];
  let row = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        field += '"';
        i += 1;
      } else if (ch === '"') {
        quoted = false;
      } else {
        field += ch;
      }
    } else if (ch === '"') {
      quoted = true;
    } else if (ch === delimiter) {
      row.push(field);
      field = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i += 1;
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else {
      field += ch;
    }
  }
  if (field !== "" || row.length) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

function assetQuoteLiteral(text) {
  return `'${String(text).replaceAll("'", "''")}'`;
}

function renderAssets(root, session) {
  const status = document.getElementById("status");
  const state = {
    home: null,
    balances: null,
    selected: null,
    rows: null,
    file: null, // { name, format, csv, headers, sheets, sheet, buffer }
    mapping: { header_row: 1, date_format: "DMY", cargo: null },
    preview: null,
    lastCheck: null,
  };

  function setStatus(message, isError = false) {
    if (status) {
      status.textContent = message;
      status.className = isError ? "error" : "";
    }
  }

  function account() {
    return (state.home?.accounts || []).find((item) => item.account_id === state.selected) || null;
  }

  async function loadHome() {
    state.home = await statementApi(`/assets?as_of=${assetToday()}`);
    state.balances = await statementApi(`/assets/balances?as_of=${assetToday()}&months=6`);
    if (state.selected && !account()) state.selected = null;
    if (!state.selected && state.home.accounts?.length) state.selected = state.home.accounts[0].account_id;
  }

  async function loadRows() {
    if (!state.selected) {
      state.rows = null;
      return;
    }
    state.rows = await statementApi(`/assets/rows?account_id=${state.selected}&limit=300`);
  }

  async function refresh(message) {
    try {
      await loadHome();
      await loadRows();
      draw();
      if (message) setStatus(message);
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  // --- drawing ------------------------------------------------------------------------
  function accountsTable() {
    const accounts = state.home?.accounts || [];
    const body = accounts
      .map((item) => `
        <tr class="${item.account_id === state.selected ? "selected" : ""}">
          <td><input type="radio" name="asset-account" value="${item.account_id}" ${item.account_id === state.selected ? "checked" : ""} aria-label="Open account" /></td>
          <td>${dimEsc(item.bank_name)}</td>
          <td>${dimEsc(item.account_name)} <span class="muted">${dimEsc(item.account_number)}</span></td>
          <td>${dimEsc(item.type_name)}</td>
          <td class="num"><strong>${money(item.balance)}</strong></td>
          <td>${item.last_check ? `${dimEsc(item.last_check.as_of)} <span class="muted">(${Number(item.last_check.difference) === 0 ? "matched" : `adjusted ${money(item.last_check.difference)}`})</span>` : '<span class="muted">never</span>'}</td>
          <td class="num">${dimEsc(item.row_count)}</td>
        </tr>`)
      .join("");
    return `
      <table class="compact">
        <thead><tr><th></th><th>Institution</th><th>Account</th><th>Type</th><th>Balance today</th><th>Last balance check</th><th>Rows</th></tr></thead>
        <tbody>${body || '<tr><td colspan="7">No investment or asset accounts yet. Add one below.</td></tr>'}</tbody>
        ${accounts.length ? `<tfoot><tr><td></td><td colspan="3"><strong>Total</strong></td><td class="num"><strong>${money(state.home.total_balance)}</strong></td><td colspan="2"></td></tr></tfoot>` : ""}
      </table>`;
  }

  function newAccountForm() {
    const home = state.home || {};
    const used = home.asset_account_count ?? 0;
    const max = home.max_asset_accounts;
    const institutions = (home.institutions || [])
      .map((bank) => `<option value="${bank.bank_id}">${dimEsc(bank.bank_name)}${bank.is_institution ? "" : " (bank)"}</option>`)
      .join("");
    const types = (home.account_types || [])
      .map((kind) => `<option value="${kind.a_type_id}">${dimEsc(kind.type_name)}</option>`)
      .join("");
    return `
      <details class="dim-group" id="asset-new">
        <summary><strong>Add an account</strong> <span class="muted">${used} of ${max ?? "∞"} on your plan</span></summary>
        <form class="dim-edit" id="asset-new-form">
          <label>Institution <select name="bank_id"><option value="">— new institution —</option>${institutions}</select></label>
          <label>New institution <input name="institution" maxlength="60" placeholder="Only when it is not in the list" /></label>
          <label>Type <select name="a_type_id">${types}</select></label>
          <p class="muted">A file for the current month replaces the open period; earlier months are kept.</p>
          <label>Name <input name="account_name" required maxlength="100" placeholder="Subcuenta de vivienda" /></label>
          <label>Number <input name="account_number" inputmode="numeric" pattern="[0-9]*" maxlength="20" placeholder="Optional, digits only" /></label>
          <button type="submit">Add account</button>
        </form>
      </details>`;
  }

  function balancesTable() {
    const data = state.balances;
    if (!data || !data.accounts?.length) return "";
    const months = data.months || [];
    const rows = data.accounts
      .map((item) => `<tr><td>${dimEsc(item.bank_name)} · ${dimEsc(item.account_name)}</td>${(item.months || []).map((cell) => `<td class="num" title="+${money(cell.abonos)} / −${money(cell.cargos)}">${money(cell.balance)}</td>`).join("")}</tr>`)
      .join("");
    const total = `<tr><td><strong>Total</strong></td>${(data.total || []).map((cell) => `<td class="num"><strong>${money(cell.balance)}</strong></td>`).join("")}</tr>`;
    return `
      <details class="dim-group" open>
        <summary><strong>Balance at each month end</strong></summary>
        <table class="compact">
          <thead><tr><th>Account</th>${months.map((month) => `<th>${dimEsc(month)}</th>`).join("")}</tr></thead>
          <tbody>${rows}${total}</tbody>
        </table>
      </details>`;
  }

  function rowsTable() {
    const page = state.rows;
    if (!page) return "";
    const body = (page.rows || [])
      .map((row) => `
        <tr>
          <td>${dimEsc(row.txn_date)}</td>
          <td title="${dimEsc(row.note || "")}">${dimEsc(row.concept)}</td>
          <td class="num">${Number(row.abonos) ? money(row.abonos) : ""}</td>
          <td class="num">${Number(row.cargos) ? money(row.cargos) : ""}</td>
          <td class="num">${money(row.balance)}</td>
          <td><span class="tag${row.entry_source === "adjustment" ? " warn" : ""}">${dimEsc(row.entry_source)}</span>${row.file_name ? ` <span class="muted">${dimEsc(row.file_name)}</span>` : ""}</td>
          <td>${[row.attribute_1, row.attribute_2, row.attribute_3, row.attribute_4, row.attribute_5].filter(Boolean).map(dimEsc).join(" · ")}</td>
          <td>${row.entry_source === "upload" ? "" : `<button type="button" data-delete-row="${dimEsc(row.row_hash)}">Delete</button>`}</td>
        </tr>`)
      .join("");
    return `
      <table class="compact">
        <thead><tr><th>Date</th><th>Concept</th><th>Abono</th><th>Cargo</th><th>Balance</th><th>Source</th><th>Attributes</th><th></th></tr></thead>
        <tbody>${body || '<tr><td colspan="8">No rows yet: upload a file, add rows by hand, or type the current balance below.</td></tr>'}</tbody>
      </table>
      <p class="muted">${(page.rows || []).length} of ${page.total} rows. Label rows on the Dimensions page (Investments &amp; assets).</p>`;
  }

  function reconcileForm() {
    const check = state.lastCheck;
    return `
      <form class="dim-edit" id="asset-reconcile">
        <p><strong>Balance check</strong> <span class="muted">Type what the institution shows. The difference is stored as one adjustment row; uploaded rows are never changed.</span></p>
        <label>Balance date <input type="date" name="as_of" required value="${assetToday()}" /></label>
        <label>Balance shown <input name="reported_balance" required inputmode="decimal" placeholder="438225.05" /></label>
        <label>Adjustment date <input type="date" name="adjust_date" title="Blank = balance date. Use an earlier date to make it an opening balance." /></label>
        <label>Note <input name="note" maxlength="500" /></label>
        <button type="submit">Check balance</button>
      </form>
      ${check ? `<p class="${Number(check.difference) === 0 ? "" : "lede"}">On ${dimEsc(check.as_of)} the rows added up to ${money(check.tracked_balance)}; the institution shows ${money(check.reported_balance)}. ${Number(check.difference) === 0 ? "They match." : `Adjustment stored: ${Number(check.difference) > 0 ? "abono" : "cargo"} of ${money(Math.abs(Number(check.difference)))}.`}</p>` : ""}`;
  }

  // sql/018: Saldo inicial, dated before the first row (blank date = the day before it).
  function openingForm() {
    return `
      <form class="dim-edit" id="asset-opening">
        <p><strong>Opening balance</strong> <span class="muted">One per account, dated before its first row. Blank date = the day before the first row.</span></p>
        <label>Balance <input name="balance" required inputmode="decimal" /></label>
        <label>Date <input type="date" name="txn_date" /></label>
        <label>Note <input name="note" maxlength="500" /></label>
        <button type="submit">Add opening balance</button>
      </form>`;
  }

  function manualForm() {
    return `
      <form class="dim-edit" id="asset-manual">
        <p><strong>Add a row by hand</strong> <span class="muted">For PDF-only statements (e.g. CETES): opening balance, money in or out, the gain of the month.</span></p>
        <label>Date <input type="date" name="txn_date" required /></label>
        <label>Concept <input name="concept" maxlength="500" placeholder="Rendimiento octubre" /></label>
        <label>Abono (in / gain) <input name="abonos" inputmode="decimal" /></label>
        <label>Cargo (out / loss) <input name="cargos" inputmode="decimal" /></label>
        <label>Note <input name="note" maxlength="500" /></label>
        <button type="submit">Add row</button>
      </form>`;
  }

  function columnSelect(name, value, allowNone, noneLabel = "— none —") {
    const headers = state.file?.headers || [];
    const options = headers
      .filter((header) => header !== "")
      .map((header) => `<option value="${dimEsc(header)}" ${header === value ? "selected" : ""}>${dimEsc(header)}</option>`)
      .join("");
    return `<select name="${name}">${allowNone ? `<option value="">${noneLabel}</option>` : ""}${options}</select>`;
  }

  function conceptText() {
    const concept = state.mapping.concept;
    if (Array.isArray(concept)) return concept.join(" || ' - ' || ");
    return concept || "";
  }

  function uploadSection() {
    const current = account();
    const templates = current?.templates || [];
    const file = state.file;
    const map = state.mapping;
    const preview = state.preview;
    const lines = (preview?.lines || [])
      .map((line) => `<tr><td class="muted">${dimEsc(line.line_no)}</td>${(line.fields || []).map((cell) => `<td>${dimEsc(cell)}</td>`).join("")}</tr>`)
      .join("");
    const mapped = (preview?.rows || [])
      .map((row) => `
        <tr class="${row.status !== "ok" ? "review" : ""}">
          <td class="muted">${dimEsc(row.line_no)}</td>
          <td>${dimEsc(row.txn_date || "")}</td>
          <td>${dimEsc(row.concept || "")}</td>
          <td class="num">${row.status === "ok" && Number(row.abonos) ? money(row.abonos) : ""}</td>
          <td class="num">${row.status === "ok" && Number(row.cargos) ? money(row.cargos) : ""}</td>
          <td>${row.status === "ok" ? (row.already_stored ? '<span class="tag">already stored</span>' : '<span class="tag transfer">new</span>') : `<span class="tag warn">skipped: ${dimEsc(row.reason)}</span>`}</td>
        </tr>`)
      .join("");
    const totals = preview?.totals;
    return `
      <form class="dim-edit" id="asset-file">
        <p><strong>Upload a file</strong> <span class="muted">CSV or XLSX. Map its columns once and save the map as a template for this account.</span></p>
        <label>File <input type="file" name="file" accept=".csv,.txt,.xlsx,.xlsm" /></label>
        ${file?.sheets?.length > 1 ? `<label>Sheet <select name="sheet">${file.sheets.map((sheet) => `<option ${sheet === file.sheet ? "selected" : ""}>${dimEsc(sheet)}</option>`).join("")}</select></label>` : ""}
        ${templates.length ? `<label>Template <select name="template"><option value="">— none —</option>${templates.map((template) => `<option value="${template.template_id}">${dimEsc(template.template_name)}</option>`).join("")}</select></label> <button type="button" id="asset-template-delete">Delete template</button>` : ""}
      </form>
      ${file ? `
        <form class="dim-edit" id="asset-map">
          <p><strong>Column map</strong> · ${dimEsc(file.name)}</p>
          <label>Header line <input type="number" name="header_row" min="1" max="50" value="${dimEsc(map.header_row || 1)}" /></label>
          <label>Date ${columnSelect("txn_date", map.txn_date, true, "— pick —")}</label>
          <label>Date format <select name="date_format">${ASSET_DATE_FORMATS.map(([value, label]) => `<option value="${value}" ${value === map.date_format ? "selected" : ""}>${label}</option>`).join("")}</select></label>
          <label>Abono (in / gain) ${columnSelect("abono", map.abono, true)}</label>
          <label>Cargo (out / loss) ${columnSelect("cargo", map.cargo, true, "— none (0) —")}</label>
          <label>Or one signed amount ${columnSelect("amount", map.amount, true)}</label>
          <label class="asset-concept">Concept <input name="concept" size="60" value="${dimEsc(conceptText())}" placeholder="Num. De Registro Patronal || ' - ' || Nombre de la empresa" /></label>
          <span class="muted">Join columns with <code>||</code>; put fixed text in single quotes. Add: ${(file.headers || []).filter(Boolean).map((header) => `<button type="button" data-add-column="${dimEsc(header)}">${dimEsc(header)}</button>`).join(" ")}</span>
          <button type="submit">Preview</button>
        </form>` : ""}
      ${preview && !preview.ready ? `<p class="muted">Pick the date column and at least one amount column, then Preview.</p>` : ""}
      ${lines ? `<details><summary>First lines of the file</summary><table class="compact"><tbody>${lines}</tbody></table></details>` : ""}
      ${preview?.ready ? `
        <p>${totals.ok} rows read (${totals.new} new, ${totals.already_stored} already stored, ${totals.skipped} skipped) · abonos ${money(totals.abonos)} · cargos ${money(totals.cargos)} · ${dimEsc(totals.first_txn_date || "")} to ${dimEsc(totals.last_txn_date || "")}</p>
        <p>Balance now ${money(preview.balance_before)} → after saving <strong>${money(preview.balance_after)}</strong></p>
        <table class="compact">
          <thead><tr><th>Line</th><th>Date</th><th>Concept</th><th>Abono</th><th>Cargo</th><th></th></tr></thead>
          <tbody>${mapped}</tbody>
        </table>
        <form class="dim-edit" id="asset-save">
          <label>Save the map as <input name="template_name" maxlength="60" value="${dimEsc(state.templateName || "")}" placeholder="Template name (optional)" /></label>
          <button type="submit" ${totals.new ? "" : "disabled"}>Save ${totals.new} new row(s)</button>
        </form>` : ""}
      ${(current?.uploads || []).length ? `
        <h3>Files</h3>
        <table class="compact">
          <thead><tr><th>Uploaded</th><th>File</th><th>Dates</th><th>Rows</th><th>Abonos</th><th>Cargos</th><th></th></tr></thead>
          <tbody>${current.uploads.map((upload) => `
            <tr>
              <td>${dimEsc(String(upload.created_at || "").slice(0, 10))}</td>
              <td>${dimEsc(upload.chosen_filename)}${upload.storage_mode === "curated" ? ' <span class="tag">vault</span>' : ""}</td>
              <td>${dimEsc(upload.first_txn_date || "")} – ${dimEsc(upload.last_txn_date || "")}</td>
              <td class="num">${dimEsc(upload.inserted_count)}${upload.duplicate_count ? ` <span class="muted">(+${dimEsc(upload.duplicate_count)} dup)</span>` : ""}</td>
              <td class="num">${money(upload.total_abonos)}</td>
              <td class="num">${money(upload.total_cargos)}</td>
              <td><button type="button" data-delete-upload="${dimEsc(upload.upload_id)}">Delete</button></td>
            </tr>`).join("")}</tbody>
        </table>` : ""}`;
  }

  function draw() {
    const current = account();
    root.innerHTML = `
      <p class="lede">Investment and asset accounts: upload what the institution gives you, add PDF-only movements by hand, and type the real balance to keep every account in sync.</p>
      ${accountsTable()}
      ${newAccountForm()}
      ${balancesTable()}
      ${current ? `
        <h2>${dimEsc(current.bank_name)} · ${dimEsc(current.account_name)} <span class="muted">${money(current.balance)}</span></h2>
        <details class="dim-group" open><summary><strong>Rows</strong></summary><div class="dim-body">${rowsTable()}</div></details>
        <details class="dim-group" open><summary><strong>Balance check</strong></summary><div class="dim-body">${reconcileForm()}${openingForm()}</div></details>
        <details class="dim-group" ${state.file ? "open" : ""}><summary><strong>Upload a file</strong></summary><div class="dim-body">${uploadSection()}</div></details>
        <details class="dim-group"><summary><strong>Add a row by hand</strong></summary><div class="dim-body">${manualForm()}</div></details>` : ""}
    `;
    bind();
  }

  // --- actions ------------------------------------------------------------------------
  function formObject(form) {
    return Object.fromEntries(new FormData(form).entries());
  }

  function readMap(form) {
    const values = formObject(form);
    const pick = (name) => (values[name] ? String(values[name]) : null);
    const mapping = {
      header_row: Number(values.header_row) || 1,
      date_format: pick("date_format") || "DMY",
      txn_date: pick("txn_date"),
      abono: pick("abono"),
      cargo: pick("cargo"),
      amount: pick("amount"),
      concept: String(values.concept || "").trim() || null,
    };
    if (mapping.amount) {
      mapping.abono = null;
      mapping.cargo = null;
    }
    return mapping;
  }

  function headersFor(headerRow) {
    if (!state.file) return [];
    const rows = assetCsvParse(state.file.csv);
    return (rows[(headerRow || 1) - 1] || []).map((cell) => String(cell).trim());
  }

  async function readFile(file, sheet) {
    const name = file.name || "upload";
    if (/\.(xlsx|xlsm)$/i.test(name)) {
      const buffer = state.file?.buffer && state.file.name === name ? state.file.buffer : await file.arrayBuffer();
      const book = await window.strmXlsxToRows(buffer, { sheet });
      return { name, format: "xlsx", csv: book.csv, sheets: book.sheets, sheet: book.sheet, buffer, source: file };
    }
    const decoded = await decodeBankCsv(file);
    return { name, format: "csv", csv: decoded.text, sheets: [], sheet: null, source: file };
  }

  async function runPreview(mapping) {
    state.mapping = mapping;
    state.preview = await statementApi("/assets/preview", {
      method: "POST",
      body: JSON.stringify({ account_id: state.selected, csv: state.file.csv, mapping }),
    });
    if (!state.preview.ready && state.preview.suggested_mapping) {
      const guess = state.preview.suggested_mapping;
      state.mapping = { ...guess, ...Object.fromEntries(Object.entries(mapping).filter(([, value]) => value)) };
    }
    state.file.headers = state.preview.headers || headersFor(state.mapping.header_row);
  }

  function bind() {
    root.querySelectorAll('input[name="asset-account"]').forEach((input) => {
      input.addEventListener("change", async () => {
        state.selected = Number(input.value);
        state.file = null;
        state.preview = null;
        state.lastCheck = null;
        try {
          await loadRows();
          draw();
        } catch (error) {
          setStatus(error.message, true);
        }
      });
    });

    const newForm = document.getElementById("asset-new-form");
    newForm?.addEventListener("submit", async (event) => {
      event.preventDefault();
      const values = formObject(event.target);
      try {
        const created = await statementApi("/assets/accounts", {
          method: "POST",
          body: JSON.stringify({
            bank_id: values.bank_id ? Number(values.bank_id) : null,
            institution: values.bank_id ? null : String(values.institution || "").trim() || null,
            a_type_id: values.a_type_id ? Number(values.a_type_id) : null,
            account_name: String(values.account_name || "").trim(),
            account_number: String(values.account_number || "").trim() || null,
          }),
        });
        state.selected = created.account_id;
        await refresh(`Account ${created.account_name} added.`);
      } catch (error) {
        setStatus(error.message, true);
      }
    });

    root.querySelectorAll("[data-delete-row]").forEach((button) => {
      button.addEventListener("click", async () => {
        if (!window.confirm("Delete this row?")) return;
        try {
          await statementApi(`/assets/rows/${encodeURIComponent(button.dataset.deleteRow)}`, { method: "DELETE" });
          await refresh("Row deleted.");
        } catch (error) {
          setStatus(error.message, true);
        }
      });
    });

    document.getElementById("asset-reconcile")?.addEventListener("submit", async (event) => {
      event.preventDefault();
      const values = formObject(event.target);
      try {
        state.lastCheck = await statementApi("/assets/reconcile", {
          method: "POST",
          body: JSON.stringify({
            account_id: state.selected,
            as_of: values.as_of,
            reported_balance: String(values.reported_balance || "").replace(/[$\s]/g, ""),
            adjust_date: values.adjust_date || null,
            note: values.note || null,
          }),
        });
        await refresh(Number(state.lastCheck.difference) === 0 ? "The balance matches." : "Adjustment row stored.");
      } catch (error) {
        setStatus(error.message, true);
      }
    });

    document.getElementById("asset-opening")?.addEventListener("submit", async (event) => {
      event.preventDefault();
      const values = formObject(event.target);
      try {
        await statementApi("/balances/opening", {
          method: "POST",
          body: JSON.stringify({
            account_id: state.selected,
            balance: String(values.balance || "").replace(/[$\s]/g, ""),
            txn_date: values.txn_date || null,
            note: values.note || null,
          }),
        });
        await refresh("Opening balance stored.");
      } catch (error) {
        setStatus(error.message, true);
      }
    });

    document.getElementById("asset-manual")?.addEventListener("submit", async (event) => {
      event.preventDefault();
      const values = formObject(event.target);
      try {
        await statementApi("/assets/rows", {
          method: "POST",
          body: JSON.stringify({
            account_id: state.selected,
            txn_date: values.txn_date,
            concept: values.concept || null,
            abonos: String(values.abonos || "").replace(/[$\s]/g, "") || null,
            cargos: String(values.cargos || "").replace(/[$\s]/g, "") || null,
            note: values.note || null,
          }),
        });
        await refresh("Row added.");
      } catch (error) {
        setStatus(error.message, true);
      }
    });

    const fileForm = document.getElementById("asset-file");
    fileForm?.querySelector('input[name="file"]')?.addEventListener("change", async (event) => {
      const file = event.target.files?.[0];
      if (!file) return;
      try {
        state.file = await readFile(file);
        state.preview = null;
        const template = account()?.templates?.[0];
        await runPreview(template ? { ...template.mapping } : { header_row: 1, date_format: "DMY" });
        if (template) state.templateName = template.template_name;
        draw();
        setStatus(template ? `Using template ${template.template_name}. Check the preview, then save.` : "Map the columns, then Preview.");
      } catch (error) {
        setStatus(error.message, true);
      }
    });
    fileForm?.querySelector('select[name="sheet"]')?.addEventListener("change", async (event) => {
      try {
        state.file = await readFile(state.file.source, event.target.value);
        await runPreview(state.mapping);
        draw();
      } catch (error) {
        setStatus(error.message, true);
      }
    });
    fileForm?.querySelector('select[name="template"]')?.addEventListener("change", async (event) => {
      const template = (account()?.templates || []).find((item) => String(item.template_id) === event.target.value);
      if (!template) return;
      state.templateName = template.template_name;
      if (state.file) {
        try {
          await runPreview({ ...template.mapping });
          draw();
        } catch (error) {
          setStatus(error.message, true);
        }
      } else {
        state.mapping = { ...template.mapping };
        setStatus(`Template ${template.template_name} picked. Choose the file.`);
      }
    });
    document.getElementById("asset-template-delete")?.addEventListener("click", async () => {
      const select = fileForm.querySelector('select[name="template"]');
      if (!select?.value) {
        setStatus("Pick the template to delete.", true);
        return;
      }
      try {
        await statementApi(`/assets/templates/${encodeURIComponent(select.value)}`, { method: "DELETE" });
        await refresh("Template deleted.");
      } catch (error) {
        setStatus(error.message, true);
      }
    });

    const mapForm = document.getElementById("asset-map");
    mapForm?.querySelectorAll("[data-add-column]").forEach((button) => {
      button.addEventListener("click", () => {
        const input = mapForm.querySelector('input[name="concept"]');
        const column = button.dataset.addColumn;
        input.value = input.value.trim() ? `${input.value.trim()} || ${assetQuoteLiteral(" - ")} || ${column}` : column;
      });
    });
    mapForm?.querySelector('input[name="header_row"]')?.addEventListener("change", (event) => {
      state.mapping.header_row = Number(event.target.value) || 1;
      state.file.headers = headersFor(state.mapping.header_row);
      draw();
    });
    mapForm?.addEventListener("submit", async (event) => {
      event.preventDefault();
      try {
        await runPreview(readMap(event.target));
        draw();
        setStatus(state.preview.ready ? "Preview ready. Nothing is saved yet." : "Pick the date and an amount column.");
      } catch (error) {
        setStatus(error.message, true);
      }
    });

    document.getElementById("asset-save")?.addEventListener("submit", async (event) => {
      event.preventDefault();
      const values = formObject(event.target);
      try {
        const saved = await statementApi("/assets/uploads", {
          method: "POST",
          body: JSON.stringify({
            account_id: state.selected,
            filename: state.file.name.replace(/\.(xlsx|xlsm)$/i, ".csv"),
            chosen_filename: state.file.name,
            csv: state.file.csv,
            mapping: state.mapping,
            template_name: String(values.template_name || "").trim() || null,
            source_format: state.file.format,
          }),
        });
        state.file = null;
        state.preview = null;
        await refresh(`${saved.inserted} row(s) saved in ${saved.target_table || "master_closed_aaccandass_f"}${saved.duplicates ? `, ${saved.duplicates} already stored` : ""}. Balance ${money(saved.balance)}.${saved.backup_warning ? ` ${saved.backup_warning}` : ""}`);
      } catch (error) {
        setStatus(error.message, true);
      }
    });

    root.querySelectorAll("[data-delete-upload]").forEach((button) => {
      button.addEventListener("click", async () => {
        if (!window.confirm("Delete this file and the rows it added?")) return;
        try {
          const deleted = await statementApi(`/assets/uploads/${encodeURIComponent(button.dataset.deleteUpload)}`, { method: "DELETE" });
          await refresh(`File deleted with ${deleted.deleted_rows ?? 0} row(s).${deleted.backup_warning ? ` ${deleted.backup_warning}` : ""}`);
        } catch (error) {
          setStatus(error.message, true);
        }
      });
    });
  }

  root.innerHTML = "<p>Loading investments and assets…</p>";
  refresh().catch((error) => setStatus(error.message, true));
  return session;
}

window.renderAssets = renderAssets;
window.assetCsvParse = assetCsvParse;
