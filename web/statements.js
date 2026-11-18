function escapeStatementHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function localIsoDate() {
  const now = new Date();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  return `${now.getFullYear()}-${month}-${day}`;
}

async function statementApi(path, options = {}) {
  const cfg = window.STRM_CONFIG || {};
  if (!cfg.apiUrl) {
    throw new Error("The statements API is not published yet. Redeploy the environment, then publish the site again.");
  }
  const tokens = JSON.parse(sessionStorage.getItem("strm_tokens") || "{}");
  const response = await fetch(`${cfg.apiUrl}${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${tokens.id_token}`,
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `Request failed (${response.status})`);
  }
  return payload;
}

async function decodeBankCsv(file) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  let text;
  let encoding;
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    encoding = "utf-8";
    text = new TextDecoder("utf-8").decode(bytes.subarray(3));
  } else if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    encoding = "utf-16le";
    text = new TextDecoder("utf-16le").decode(bytes.subarray(2));
  } else if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    encoding = "utf-16be";
    text = new TextDecoder("utf-16be").decode(bytes.subarray(2));
  } else {
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
      encoding = "utf-8";
    } catch {
      text = new TextDecoder("windows-1252").decode(bytes);
      encoding = "windows-1252";
    }
  }
  const cleaned = text.replaceAll("\u00a0", " ").replace(/^\uFEFF/, "");
  return { text: cleaned, encoding };
}

function bytesToBase64(bytes) {
  let binary = "";
  const chunk = 0x8000;
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk));
  }
  return btoa(binary);
}

// sql/016: upload completeness colours. 0% grey; above 0 the hue runs red -> green and
// the colour gets stronger with the score; 100% is full green (docs/dimensions.md).
function completenessColor(pct) {
  const value = Math.max(0, Math.min(100, Number(pct) || 0));
  if (value === 0) {
    return "hsl(220, 9%, 62%)";
  }
  const hue = Math.round((value / 100) * 120);
  const saturation = Math.round(35 + (value / 100) * 40);
  const lightness = value === 100 ? 34 : 46;
  return `hsl(${hue}, ${saturation}%, ${lightness}%)`;
}

function completenessBadge(pct, band) {
  const value = Number(pct) || 0;
  return `<span class="fill-badge fill-${escapeStatementHtml(band || "empty")}" style="--fill:${completenessColor(value)}">
    <span class="fill-bar"><span style="width:${Math.max(0, Math.min(100, value))}%"></span></span>
    <strong>${escapeStatementHtml(value.toLocaleString("es-MX", { maximumFractionDigits: 1 }))}%</strong></span>`;
}

function completenessPeriod(period) {
  const label = period.period_label || "—";
  const state = period.state === "open" ? "open" : "closed";
  const files = [
    period.has_csv ? (period.csv_state === "open" && state === "closed" ? "CSV (open snapshot)" : "CSV") : "no CSV",
    period.pdf_expected ? (period.has_pdf ? "PDF" : "no PDF") : "",
  ].filter(Boolean).join(" · ");
  return `<li class="fill-period">
    ${completenessBadge(period.score, period.band)}
    <span>${escapeStatementHtml(label)} <span class="muted">(${state})</span> — ${escapeStatementHtml(files)}</span>
    ${period.missing ? `<span class="muted">${escapeStatementHtml(period.missing)}</span>` : ""}
  </li>`;
}

function completenessPanel(report, opened) {
  if (!report || !Array.isArray(report.kinds) || !report.kinds.length) {
    return "";
  }
  const open = (key) => (opened.has(key) ? "open" : "");
  const kinds = report.kinds
    .map((kind) => {
      const kindKey = `k:${kind.kind}`;
      const banks = (kind.banks || [])
        .map((bank) => {
          const bankKey = `${kindKey}:b:${bank.bank_name}`;
          const accounts = (bank.accounts || [])
            .map((account) => {
              const accountKey = `${bankKey}:a:${account.account_id}`;
              return `<details class="fill-account" data-fill-key="${escapeStatementHtml(accountKey)}" ${open(accountKey)}>
                <summary>${completenessBadge(account.pct, account.band)} ${escapeStatementHtml(account.account_name)}
                  <span class="muted">${escapeStatementHtml(account.account_number)}</span></summary>
                <ul class="fill-periods">${(account.periods || []).map(completenessPeriod).join("")}</ul>
              </details>`;
            })
            .join("");
          return `<details class="fill-bank" data-fill-key="${escapeStatementHtml(bankKey)}" ${open(bankKey)}>
            <summary>${completenessBadge(bank.pct, bank.band)} ${escapeStatementHtml(bank.bank_name)}</summary>
            ${accounts}
          </details>`;
        })
        .join("");
      return `<details class="fill-kind" data-fill-key="${escapeStatementHtml(kindKey)}" ${open(kindKey)}>
        <summary>${completenessBadge(kind.pct, kind.band)} <strong>${escapeStatementHtml(kind.title)}</strong>
          <span class="muted">${escapeStatementHtml(kind.accounts)} account(s)</span></summary>
        ${banks}
      </details>`;
    })
    .join("");
  const pdfNote = report.pdf_counts
    ? "A closed period with its CSV counts 75%; adding the PDF makes it 100%."
    : "A closed period with its CSV counts 100%.";
  return `<section class="card fill-card">
    <h2>Upload completeness ${completenessBadge(report.pct, report.band)}</h2>
    <p class="muted">Per account: the open period and the two closed periods before it. ${escapeStatementHtml(pdfNote)}</p>
    ${kinds}
  </section>`;
}

function renderStatements(root, session) {
  const openedFill = new Set();
  const asOf = localIsoDate();
  let home = null;
  let mount = root;
  if (!session.embedded) {
    root.classList.add("wide");
    root.innerHTML = `
      <nav class="ribbon" aria-label="Account">
        <strong>Statements</strong>
        <button type="button" id="logout">Sign out</button>
      </nav>
      <h1>Statements</h1>
      <p id="statement-status" role="status"></p>
      <div id="statements-mount"></div>
    `;
    document.getElementById("logout").addEventListener("click", session.logout);
    mount = document.getElementById("statements-mount");
  }

  const status = session.embedded ? document.getElementById("status") : document.getElementById("statement-status");
  let banksOpen = false;
  let bankBusy = false;
  let bankNote = null;

  function applyBankNote() {
    const local = mount.querySelector("[data-banks-status]");
    if (!local) {
      return;
    }
    local.hidden = !bankNote;
    local.textContent = bankNote ? bankNote.message : "";
    local.className = bankNote && bankNote.isError ? "error" : "";
  }

  function setStatus(message, isError = false) {
    bankNote = null;
    if (status) {
      status.textContent = message;
      status.className = isError ? "error" : "";
    }
    applyBankNote();
  }

  // Bank add/rename feedback stays in the Banks section. A message only on the
  // page status sits above a long account list, and a successful reload used to
  // close that section, so the click looked like it did nothing.
  function showBanks(message, isError = false) {
    setStatus(message, isError);
    bankNote = message ? { message, isError: Boolean(isError) } : null;
    applyBankNote();
    const local = mount.querySelector("[data-banks-status]");
    if (local && message && !local.hidden) {
      local.scrollIntoView({ block: "nearest" });
    }
  }

  function planLine() {
    if (home.max_credit_accounts != null && home.max_debit_accounts != null) {
      return `${home.plan_name} allows ${home.max_credit_accounts} credit account and ${home.max_debit_accounts} debit account, plus savings, investments, assets and credit contracts accounts.`;
    }
    return `${home.plan_name} allows ${home.max_total_accounts} accounts. Beyond that, this becomes a private deployment in your own AWS account.`;
  }

  function dropZone(account, period, slot, label, accept) {
    return `
      <label class="dropzone">
        <span>${escapeStatementHtml(label)}</span>
        <input
          type="file"
          accept="${escapeStatementHtml(accept)}"
          data-account="${escapeStatementHtml(account.account_id)}"
          data-cutoff="${escapeStatementHtml(period.cutoff_id)}"
          data-slot="${escapeStatementHtml(slot)}"
          data-bank="${escapeStatementHtml(account.bank_name || "")}"
          data-account-number="${escapeStatementHtml(account.account_number || "")}"
          data-period="${escapeStatementHtml(period.period_label || "")}"
        />
      </label>
    `;
  }

  // filename is the name the user picked (sql/013); storedName is the working CSV name.
  function fileLine(filename, uploadId, rows, storedName) {
    const count = rows == null ? "" : ` <span class="muted">(${escapeStatementHtml(rows)} rows)</span>`;
    const stored =
      storedName && storedName !== filename
        ? ` <span class="muted">saved as ${escapeStatementHtml(storedName)}</span>`
        : "";
    return `
      <div class="file-line">
        <span>${escapeStatementHtml(filename)}${count}${stored}</span>
        <button type="button" data-delete-file="${escapeStatementHtml(uploadId)}">Delete file</button>
      </div>
    `;
  }

  // CSV or XLSX for every statement and installment slot (BBVA exports XLSX, Banorte CSV).
  const sheetAccept = ".csv,.xlsx,.xlsm,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

  function statementCell(account, period) {
    const baseLabel = account.ledger_kind === "credit" ? "Drop statement CSV/XLSX" : "Drop CSV/XLSX";
    const loaded = period.statement_upload_id
      ? fileLine(
          period.statement_filename,
          period.statement_upload_id,
          period.statement_row_count,
          period.statement_stored_filename,
        )
      : "";
    if (!period.show_statement_slot) {
      return loaded || `<span class="muted">Opens after ${escapeStatementHtml(period.period_end)}</span>`;
    }
    if (period.is_current) {
      // Current period: every upload replaces this account's open movements.
      const label = period.statement_upload_id ? "Replace current-period CSV/XLSX" : `${baseLabel} (current period)`;
      return `${loaded}${dropZone(account, period, "statement", label, sheetAccept)}`;
    }
    if (period.statement_upload_id) {
      // A current-period file whose cutoff has passed: the closed statement replaces it.
      return `${loaded}${dropZone(account, period, "statement", "Replace with the closed statement", sheetAccept)}`;
    }
    return dropZone(account, period, "statement", baseLabel, sheetAccept);
  }

  function installmentCell(account, period) {
    if (account.ledger_kind !== "credit") {
      return `<span class="muted">—</span>`;
    }
    const loaded = period.installment_upload_id
      ? fileLine(
          period.installment_filename,
          period.installment_upload_id,
          period.installment_row_count,
          period.installment_stored_filename,
        )
      : "";
    if (!period.show_installment_slot) {
      return loaded || `<span class="muted">Opens after ${escapeStatementHtml(period.period_end)}</span>`;
    }
    // Future payments: a new installment file replaces this card's remaining schedule.
    const label = period.installment_upload_id || account.future_row_count
      ? "Replace installment CSV/XLSX"
      : "Drop installment CSV/XLSX";
    return `${loaded}${dropZone(account, period, "installment", label, sheetAccept)}`;
  }

  function periodStatus(period) {
    if (period.is_current) {
      const state = period.statement_upload_id ? "Open · CSV loaded" : "Open · current period";
      return `<span class="muted">${state}</span>`;
    }
    return period.pending ? `<span class="muted">Pending</span>` : `<span class="muted">CSV loaded</span>`;
  }

  function futureLine(account) {
    if (account.ledger_kind !== "credit" || !account.future_row_count) {
      return "";
    }
    const total = Number(account.future_total || 0).toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
    return `<p class="muted">Future installments: ${escapeStatementHtml(account.future_row_count)} payments · ${escapeStatementHtml(total)} pending</p>`;
  }

  function pdfCell(account, period) {
    if (!home.curated_csv_backup) {
      return "";
    }
    if (period.pdf_upload_id) {
      return fileLine(period.pdf_filename, period.pdf_upload_id, null, period.pdf_stored_filename);
    }
    if (period.show_pdf_slot) {
      return dropZone(account, period, "pdf", "Drop PDF", ".pdf,application/pdf");
    }
    return `<span class="muted">Optional after ${escapeStatementHtml(period.period_end)}</span>`;
  }

  function accountCard(account) {
    const pdfHead = home.curated_csv_backup ? "<th>PDF</th>" : "";
    const rows = account.periods
      .map((period) => {
        const pdf = home.curated_csv_backup ? `<td>${pdfCell(account, period)}</td>` : "";
        const remove = period.removable
          ? `<button type="button" data-remove-period="${escapeStatementHtml(period.cutoff_id)}">Remove</button>`
          : "";
        const pending = periodStatus(period);
        return `
          <tr>
            <td>${escapeStatementHtml(period.period_label)}<br>${pending}</td>
            <td>${escapeStatementHtml(period.period_start)}</td>
            <td>${escapeStatementHtml(period.period_end)}</td>
            <td>${statementCell(account, period)}</td>
            <td>${installmentCell(account, period)}</td>
            ${pdf}
            <td>${remove}</td>
          </tr>`;
      })
      .join("");
    const payment =
      account.allows_cutoff && account.credit_days
        ? ` · cutoff day ${escapeStatementHtml(account.account_cutoff_day)} · payment window ${escapeStatementHtml(account.credit_days)} days`
        : "";
    return `
      <section class="page-section">
        <h2>${escapeStatementHtml(account.account_name)} · ${escapeStatementHtml(account.account_number)}</h2>
        <p class="muted">${escapeStatementHtml(account.bank_name)} · ${escapeStatementHtml(account.type_name)}${payment}</p>
        ${futureLine(account)}
        ${cutoffEditForm(account)}
        <table class="compact">
          <thead>
            <tr>
              <th>Period</th><th>Starts</th><th>Cutoff</th><th>Statement</th><th>Installments</th>${pdfHead}<th></th>
            </tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
        <button type="button" data-add-period="${escapeStatementHtml(account.account_id)}">Add the previous period</button>
        <div data-map-for="${escapeStatementHtml(account.account_id)}"></div>
        ${balanceBlock(account)}
        ${bankForm(account)}
      </section>
    `;
  }

  // Savings, investments, assets, credit contracts: the same period list as a debit
  // account (sql/023). A file shows in the period of its last movement date. Rows in the
  // current month go to master_open_aaccandass_f (replaced by the next file), other dates
  // to master_closed_aaccandass_f.
  function assetFileLine(upload) {
    const span = upload.first_txn_date
      ? ` <span class="muted">${escapeStatementHtml(upload.first_txn_date)} – ${escapeStatementHtml(upload.last_txn_date)}</span>`
      : "";
    return `
      <div class="file-line">
        <span>${escapeStatementHtml(upload.filename)} <span class="muted">(${escapeStatementHtml(upload.rows ?? 0)} rows)</span>${span}</span>
        <button type="button" data-delete-asset-file="${escapeStatementHtml(upload.upload_id)}">Delete file</button>
      </div>`;
  }

  function assetCard(account) {
    const periods = account.periods || [];
    const placed = new Set(periods.flatMap((period) => (period.files || []).map((file) => file.upload_id)));
    const outside = (account.uploads || []).filter((upload) => !placed.has(upload.upload_id));
    const rows = periods
      .map((period) => {
        const files = (period.files || []).map(assetFileLine).join("");
        const label = period.is_current ? "Drop CSV/XLSX (current period)" : "Drop CSV/XLSX";
        const status = period.is_current ? "Open · current period" : period.pending ? "Pending" : "File loaded";
        const remove = period.removable
          ? `<button type="button" data-remove-period="${escapeStatementHtml(period.cutoff_id)}">Remove</button>`
          : "";
        return `
          <tr>
            <td>${escapeStatementHtml(period.period_label)}<br><span class="muted">${status}</span></td>
            <td>${escapeStatementHtml(period.period_start)}</td>
            <td>${escapeStatementHtml(period.period_end)}</td>
            <td>${files}${dropZone(account, period, "asset", label, sheetAccept)}</td>
            <td>${remove}</td>
          </tr>`;
      })
      .join("");
    return `
      <section class="page-section">
        <p class="muted">${escapeStatementHtml(account.bank_name)} · ${escapeStatementHtml(account.type_name)} · ${escapeStatementHtml(account.open_row_count ?? 0)} open row(s) · ${escapeStatementHtml(account.closed_row_count ?? 0)} closed row(s)</p>
        <p class="muted">A file is listed in the period of its last movement date. Rows dated this month go to the open table and are replaced by the next file; earlier dates are added to the closed table.</p>
        <table class="compact">
          <thead><tr><th>Period</th><th>Starts</th><th>Ends</th><th>File</th><th></th></tr></thead>
          <tbody>${rows}</tbody>
        </table>
        <button type="button" data-add-period="${escapeStatementHtml(account.account_id)}">Add the previous period</button>
        ${outside.length ? `<p class="muted">Files dated before these periods:</p>${outside.map(assetFileLine).join("")}` : ""}
        <div data-map-for="${escapeStatementHtml(account.account_id)}"></div>
        ${balanceBlock(account)}
        ${bankForm(account)}
      </section>
    `;
  }

  const TYPE_ORDER = { credit: 0, debit: 1, asset: 2 };

  function accountGroups(accounts) {
    const isOpen = (key) => (openedFill.has(key) ? "open" : "");
    const groups = new Map();
    [...accounts]
      .sort((a, b) => (TYPE_ORDER[a.ledger_kind] ?? 9) - (TYPE_ORDER[b.ledger_kind] ?? 9))
      .forEach((account) => {
        if (!groups.has(account.type_name)) {
          groups.set(account.type_name, []);
        }
        groups.get(account.type_name).push(account);
      });
    return [...groups.entries()]
      .map(([typeName, list]) => {
        const typeKey = `type:${typeName}`;
        const cards = list
          .map((account) => {
            const key = `account:${account.account_id}`;
            const card = account.ledger_kind === "asset" ? assetCard(account) : accountCard(account);
            const label = `${account.account_name} · ${account.account_number}`;
            return `
              <details class="fill-account" data-fill-key="${escapeStatementHtml(key)}" ${isOpen(key)}>
                <summary>${escapeStatementHtml(account.account_name)} · ${escapeStatementHtml(account.account_number)} <span class="muted">${escapeStatementHtml(account.bank_name)}</span></summary>
                ${card}
                <p><button type="button" data-delete-account="${escapeStatementHtml(account.account_id)}" data-account-label="${escapeStatementHtml(label)}">Delete account</button>
                  <span class="muted">Deletes every file of every period, all its rows and balances, then the account.</span></p>
              </details>`;
          })
          .join("");
        return `
          <details class="fill-kind" data-fill-key="${escapeStatementHtml(typeKey)}" ${isOpen(typeKey)}>
            <summary><strong>${escapeStatementHtml(typeName)}</strong> <span class="muted">(${list.length})</span></summary>
            ${cards}
          </details>`;
      })
      .join("");
  }

  // sql/018: balance of any account, its opening balance (Saldo inicial) and the monthly
  // check that adds one adjustment row. Loaded when opened.
  function balanceBlock(account) {
    const id = escapeStatementHtml(account.account_id);
    return `
      <details class="cutoff-edit" data-balance="${id}">
        <summary>Balance · opening balance · monthly check</summary>
        <div data-balance-body="${id}"><p class="muted">Loading…</p></div>
      </details>
    `;
  }

  function money2(value) {
    return Number(value || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function monthEnd(isoDate) {
    const [year, month] = isoDate.split("-").map(Number);
    const last = new Date(Date.UTC(year, month, 0)).getUTCDate();
    return `${year}-${String(month).padStart(2, "0")}-${String(last).padStart(2, "0")}`;
  }

  function balanceBody(info) {
    const id = escapeStatementHtml(info.account_id);
    const owed = info.balance_meaning === "owed";
    const label = owed ? "Owed on the card" : "Balance";
    const opening = info.opening
      ? `<p>Opening balance ${escapeStatementHtml(info.opening.txn_date)}: ${money2(owed ? info.opening.cargos - info.opening.abonos : info.opening.abonos - info.opening.cargos)}</p>`
      : `<form class="add-form" data-opening-form="${id}">
          <label>Opening balance (${owed ? "owed" : "in the account"}) <input name="balance" inputmode="decimal" required /></label>
          <label>Dated <input name="txn_date" type="date" value="${escapeStatementHtml(info.default_opening_date || "")}" ${info.first_txn_date ? `max="${escapeStatementHtml(info.default_opening_date)}"` : "required"} /></label>
          <label>Note <input name="note" maxlength="500" /></label>
          <button type="submit">Add opening balance</button>
          <p class="muted">${info.first_txn_date ? `Must be before the first movement (${escapeStatementHtml(info.first_txn_date)}).` : "The account has no movements yet: pick the date."}</p>
        </form>`;
    const byMonth = new Map();
    for (const row of info.balance_rows || []) {
      const month = String(row.txn_date || "").slice(0, 7) || "undated";
      if (!byMonth.has(month)) {
        byMonth.set(month, []);
      }
      byMonth.get(month).push(row);
    }
    const rows = [...byMonth.entries()]
      .map(([month, monthRows]) => {
        const body = monthRows
          .map((row) => {
            const hash = escapeStatementHtml(row.row_hash);
            return `<tr><td>${escapeStatementHtml(row.entry_source)}</td><td>${escapeStatementHtml(row.concept)}</td>
              <td><input type="date" data-balance-date="${hash}" value="${escapeStatementHtml(row.txn_date)}" /></td>
              <td><input inputmode="decimal" data-balance-amount="${hash}" value="${escapeStatementHtml(row.amount)}" /></td>
              <td><button type="button" data-save-balance-row="${hash}">Save</button>
                <button type="button" data-delete-balance-row="${hash}">Delete</button></td></tr>`;
          })
          .join("");
        return `<h3>${escapeStatementHtml(month)}</h3>
          <table class="compact"><thead><tr><th>Kind</th><th>Concept</th><th>Date</th><th>Amount</th><th></th></tr></thead><tbody>${body}</tbody></table>`;
      })
      .join("");
    const ends = (info.month_ends || [])
      .slice(0, 6)
      .map((item) => `<span class="tag">${escapeStatementHtml(item.month_end)}: ${money2(item.balance)}</span>`)
      .join(" ");
    return `
      <p><strong>${label}: ${money2(info.balance)}</strong> <span class="muted">as of ${escapeStatementHtml(info.as_of)}</span></p>
      <p class="muted">Month ends: ${ends}</p>
      ${opening}
      <form class="add-form" data-reconcile-form="${id}">
        <label>Month end <input name="as_of" type="date" required value="${escapeStatementHtml(monthEnd(asOf))}" /></label>
        <label>${owed ? "Owed per the bank" : "Balance per the bank"} <input name="reported_balance" inputmode="decimal" required /></label>
        <label>Note <input name="note" maxlength="500" /></label>
        <button type="submit">Check and adjust</button>
        <p class="muted">The difference becomes one adjustment row on that date. Uploaded rows are never edited.</p>
      </form>
      ${rows || `<p class="muted">No opening or adjustment rows yet.</p>`}
    `;
  }

  async function loadBalance(accountId) {
    const body = mount.querySelector(`[data-balance-body="${accountId}"]`);
    if (!body) {
      return;
    }
    try {
      const info = await statementApi(`/balances/${accountId}?as_of=${asOf}`);
      body.innerHTML = balanceBody(info);
      body.querySelector("[data-opening-form]")?.addEventListener("submit", async (event) => {
        event.preventDefault();
        const data = new FormData(event.target);
        await balanceAction(accountId, "/balances/opening", {
          account_id: Number(accountId),
          balance: data.get("balance"),
          txn_date: data.get("txn_date") || null,
          note: data.get("note") || null,
        }, "Opening balance added.");
      });
      body.querySelector("[data-reconcile-form]")?.addEventListener("submit", async (event) => {
        event.preventDefault();
        const data = new FormData(event.target);
        await balanceAction(accountId, "/balances/reconcile", {
          account_id: Number(accountId),
          as_of: data.get("as_of"),
          reported_balance: data.get("reported_balance"),
          note: data.get("note") || null,
        }, null);
      });
      body.querySelectorAll("[data-save-balance-row]").forEach((button) => {
        button.addEventListener("click", async () => {
          const hash = button.dataset.saveBalanceRow;
          const txnDate = body.querySelector(`[data-balance-date="${hash}"]`)?.value;
          const amount = body.querySelector(`[data-balance-amount="${hash}"]`)?.value;
          if (!window.confirm(`Save this balance row as ${txnDate} ${amount}?`)) {
            return;
          }
          try {
            const result = await statementApi(`/balances/rows/${hash}`, {
              method: "POST",
              body: JSON.stringify({ txn_date: txnDate, amount }),
            });
            setStatus(`Balance row saved. Balance is ${money2(result.balance)}.`);
            await loadBalance(accountId);
          } catch (error) {
            setStatus(error.message, true);
          }
        });
      });
      body.querySelectorAll("[data-delete-balance-row]").forEach((button) => {
        button.addEventListener("click", async () => {
          if (!window.confirm("Delete this opening or adjustment row?")) {
            return;
          }
          try {
            const result = await statementApi(`/balances/rows/${button.dataset.deleteBalanceRow}`, { method: "DELETE" });
            setStatus(`Balance row deleted. Balance is ${money2(result.balance)}.`);
            await loadBalance(accountId);
          } catch (error) {
            setStatus(error.message, true);
          }
        });
      });
    } catch (error) {
      body.innerHTML = `<p class="error">${escapeStatementHtml(error.message)}</p>`;
    }
  }

  async function balanceAction(accountId, path, body, message) {
    try {
      const result = await statementApi(path, { method: "POST", body: JSON.stringify(body) });
      if (message) {
        setStatus(message);
      } else {
        setStatus(result.adjustment ? `Adjustment of ${money2(result.difference)} added.` : "No difference: nothing to adjust.");
      }
      await loadBalance(accountId);
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  // sql/018: move the account to another bank. Its rows are re-keyed; attributes, lists
  // and transfer links follow.
  function bankForm(account) {
    const id = escapeStatementHtml(account.account_id);
    const options = home.banks
      .map(
        (bank) =>
          `<option value="${escapeStatementHtml(bank.bank_id)}" ${bank.bank_name === account.bank_name ? "selected" : ""}>${escapeStatementHtml(bank.bank_name)}</option>`,
      )
      .join("");
    return `
      <details class="cutoff-edit">
        <summary>Change bank</summary>
        <form class="add-form" data-bank-form="${id}">
          <label>Bank <select name="bank_id">${options}</select></label>
          <button type="submit">Move account</button>
          <p data-move-status role="status" hidden></p>
          <p class="muted">Rows keep their attributes, lists and transfer links. Files already in the vault keep their names; new files use the new bank name.</p>
        </form>
      </details>
    `;
  }

  // sql/012: credit cards can change their cutoff day and payment window. Periods with a
  // loaded file keep their dates; the new day applies to empty and later periods.
  function cutoffEditForm(account) {
    if (!account.allows_cutoff) {
      return "";
    }
    const id = escapeStatementHtml(account.account_id);
    return `
      <details class="cutoff-edit">
        <summary>Change cutoff day</summary>
        <form class="add-form" data-cutoff-form="${id}">
          <label>Cutoff day
            <input name="account_cutoff_day" type="number" min="1" max="31" required value="${escapeStatementHtml(account.account_cutoff_day ?? "")}" />
          </label>
          <label>Payment window (days)
            <input name="credit_days" type="number" min="1" max="90" required value="${escapeStatementHtml(account.credit_days ?? "")}" />
          </label>
          <button type="submit">Save</button>
          <p class="muted">Periods that already have a file keep their dates. The new day applies to the current period if it is empty, and to the periods after it.</p>
        </form>
      </details>
    `;
  }

  function addForm() {
    if (!home.banks.length || !home.account_types.length) {
      return `<p>No banks are available yet. Apply the banking DDL from the config console.</p>`;
    }
    const banks = home.banks
      .map(
        (bank) =>
          `<option value="${escapeStatementHtml(bank.bank_id)}">${escapeStatementHtml(bank.bank_name)}</option>`,
      )
      .join("");
    const types = home.account_types
      .map(
        (type) =>
          `<option value="${escapeStatementHtml(type.a_type_id)}" data-cutoff="${type.allows_cutoff ? "yes" : "no"}">${escapeStatementHtml(type.type_name)}</option>`,
      )
      .join("");
    return `
      <section class="page-section">
        <h2>Open an account</h2>
        <form id="add-account" class="add-form">
          <label>Bank <select name="bank_id">${banks}</select></label>
          <label>Type <select name="a_type_id">${types}</select></label>
          <label>Name <input name="account_name" type="text" required /></label>
          <label>Account number <input name="account_number" type="text" inputmode="numeric" pattern="[0-9]+" required /></label>
          <label id="cutoff-field" hidden>Cutoff day
            <input name="account_cutoff_day" type="number" min="1" max="31" />
          </label>
          <label id="credit-days-field" hidden>Payment window (days)
            <input name="credit_days" type="number" min="1" max="90" />
          </label>
          <button type="submit">Open account</button>
        </form>
      </section>
    `;
  }

  // sql/018: banks catalogue. Rename is a button, not a submit control inside the
  // table: the listener lives on the page root (see the click handler below) so
  // it is already attached when these rows are drawn. A blocked bank shows the
  // same reason rename_bank raises, instead of an empty cell.
  function banksSection() {
    return `
      <section class="page-section">
        <details data-banks>
          <summary><strong>Banks</strong></summary>
          <p data-banks-status role="status" hidden></p>
          <div data-banks-body><p class="muted">Loading…</p></div>
        </details>
      </section>
    `;
  }

  function renameBlocked(bank) {
    if (bank.has_profile) {
      return "This bank has a built-in statement profile; its name stays as it is.";
    }
    return "Other customers have accounts at this bank; it cannot be renamed here.";
  }

  function removeControl(bank) {
    if (bank.can_remove) {
      return `<button type="button" data-remove-bank="${escapeStatementHtml(bank.bank_id)}">Remove bank</button>`;
    }
    if (bank.remove_block) {
      return `<p class="error bank-block">${escapeStatementHtml(bank.remove_block)}</p>`;
    }
    return "";
  }

  function bankActions(bank) {
    const id = escapeStatementHtml(bank.bank_id);
    const name = escapeStatementHtml(bank.bank_name);
    const rename = `<input name="bank_name" maxlength="60" value="${name}" aria-label="New name for ${name}" />
         <button type="button" data-rename-bank="${id}">Rename</button>`
      + (bank.can_rename ? "" : `<p class="error bank-block">${escapeStatementHtml(renameBlocked(bank))}</p>`);
    return `<div class="bank-actions">${rename}${removeControl(bank)}</div>`;
  }

  async function loadBanks() {
    const body = mount.querySelector("[data-banks-body]");
    if (!body) {
      return;
    }
    try {
      const listed = await statementApi("/banks");
      if (!Array.isArray(listed)) {
        throw new Error("The bank list did not come back from the API.");
      }
      const banks = listed;
      const rows = banks
        .map(
          (bank) => `<tr><td>${escapeStatementHtml(bank.bank_name)}</td>
            <td>${bank.has_profile ? "built-in layout" : '<span class="muted">column map</span>'}</td>
            <td>${escapeStatementHtml(bank.my_accounts)}</td>
            <td>${bankActions(bank)}</td></tr>`,
        )
        .join("");
      body.innerHTML = `
        <table class="compact"><thead><tr><th>Bank</th><th>Files</th><th>Your accounts</th><th></th></tr></thead><tbody>${rows}</tbody></table>
        <form class="add-form" data-add-bank>
          <label>New bank <input name="bank_name" maxlength="60" minlength="2" required /></label>
          <button type="submit">Add bank</button>
          <p class="muted">Banorte and BBVA keep their names, because a built-in layout reads them. A bank another customer already uses cannot be renamed here either. A bank without a built-in layout reads its files with a column map you set on the first upload.</p>
        </form>`;
      applyBankNote();
    } catch (error) {
      body.innerHTML = `<p class="error">${escapeStatementHtml(error.message)}</p>`;
      showBanks(error.message, true);
    }
  }

  async function addBank(name) {
    if (bankBusy) {
      return;
    }
    bankBusy = true;
    banksOpen = true;
    showBanks("Adding bank…", false);
    try {
      await statementApi("/banks", {
        method: "POST",
        body: JSON.stringify({ bank_name: name }),
      });
      showBanks("Bank added.", false);
      await load();
    } catch (error) {
      showBanks(error.message, true);
    } finally {
      bankBusy = false;
    }
  }

  async function removeBank(bankId) {
    if (bankBusy) {
      return;
    }
    if (!bankId) {
      showBanks("This bank cannot be removed from here.", true);
      return;
    }
    bankBusy = true;
    banksOpen = true;
    showBanks("Removing bank…", false);
    try {
      await statementApi(`/banks/${bankId}`, { method: "DELETE" });
      showBanks("Bank removed.", false);
      await load();
    } catch (error) {
      showBanks(error.message, true);
    } finally {
      bankBusy = false;
    }
  }

  async function renameBank(bankId, name) {
    if (bankBusy) {
      return;
    }
    if (!bankId) {
      showBanks("This bank cannot be renamed from here.", true);
      return;
    }
    bankBusy = true;
    banksOpen = true;
    showBanks("Renaming…", false);
    try {
      await statementApi(`/banks/${bankId}`, {
        method: "POST",
        body: JSON.stringify({ bank_name: name }),
      });
      showBanks("Bank renamed.", false);
      await load();
    } catch (error) {
      showBanks(error.message, true);
    } finally {
      bankBusy = false;
    }
  }

  function paint() {
    const backup = home.curated_csv_backup
      ? `<p class="muted">Premium can also keep the optional PDF statement. Deleting a file removes its rows and leaves the vault copy.</p>`
      : "";
    const accounts = home.accounts.length
      ? accountGroups(home.accounts)
      : `<p>No accounts yet. Open a bank account and the latest closed period appears here with the two before it, plus the current period.</p>`;
    mount.innerHTML = `
      <p class="lede">${escapeStatementHtml(planLine())} Signed in as <strong>${escapeStatementHtml(session.name)}</strong>.</p>
      ${backup}
      ${completenessPanel(home.completeness, openedFill)}
      ${accounts}
      ${addForm()}
      ${banksSection()}
    `;
    mount.querySelectorAll("details[data-fill-key]").forEach((element) => {
      element.addEventListener("toggle", () => {
        if (element.open) {
          openedFill.add(element.dataset.fillKey);
        } else {
          openedFill.delete(element.dataset.fillKey);
        }
      });
    });
    const form = document.getElementById("add-account");
    if (form) {
      const typeSelect = form.querySelector("[name=a_type_id]");
      const cutoffField = document.getElementById("cutoff-field");
      const daysField = document.getElementById("credit-days-field");
      const cutoffInput = form.querySelector("[name=account_cutoff_day]");
      const daysInput = form.querySelector("[name=credit_days]");
      const syncCutoff = () => {
        const option = typeSelect.selectedOptions[0];
        const show = option?.dataset.cutoff === "yes";
        cutoffField.hidden = !show;
        daysField.hidden = !show;
        cutoffInput.required = show;
        daysInput.required = show;
        if (!show) {
          cutoffInput.value = "";
          daysInput.value = "";
        }
      };
      typeSelect.addEventListener("change", syncCutoff);
      syncCutoff();
      form.addEventListener("submit", addAccount);
    }
    mount.querySelectorAll(".dropzone").forEach((zone) => {
      const input = zone.querySelector("input");
      zone.addEventListener("dragover", (event) => {
        event.preventDefault();
        zone.classList.add("drag");
      });
      zone.addEventListener("dragleave", () => zone.classList.remove("drag"));
      zone.addEventListener("drop", (event) => {
        event.preventDefault();
        zone.classList.remove("drag");
        const file = event.dataTransfer?.files?.[0];
        if (file) {
          uploadFile(file, input.dataset);
        }
      });
      input.addEventListener("change", () => {
        const file = input.files?.[0];
        if (file) {
          uploadFile(file, input.dataset);
        }
      });
    });
    mount.querySelectorAll("[data-delete-file]").forEach((button) => {
      button.addEventListener("click", () => deleteFile(button.dataset.deleteFile));
    });
    mount.querySelectorAll("[data-delete-account]").forEach((button) => {
      button.addEventListener("click", () => deleteAccount(button.dataset.deleteAccount, button.dataset.accountLabel));
    });
    mount.querySelectorAll("[data-delete-asset-file]").forEach((button) => {
      button.addEventListener("click", () => deleteFile(button.dataset.deleteAssetFile, "/assets/uploads"));
    });
    mount.querySelectorAll("[data-cutoff-form]").forEach((cutoffForm) => {
      cutoffForm.addEventListener("submit", updateCutoff);
    });
    mount.querySelectorAll("[data-add-period]").forEach((button) => {
      button.addEventListener("click", () => addEarlier(button.dataset.addPeriod));
    });
    mount.querySelectorAll("[data-remove-period]").forEach((button) => {
      button.addEventListener("click", () => removePeriod(button.dataset.removePeriod));
    });
    mount.querySelectorAll("details[data-balance]").forEach((element) => {
      element.addEventListener("toggle", () => {
        if (element.open) {
          loadBalance(element.dataset.balance);
        }
      });
    });
    const banksDetails = mount.querySelector("details[data-banks]");
    let restoringBanks = false;
    banksDetails?.addEventListener("toggle", (event) => {
      if (event.target !== banksDetails) {
        return;
      }
      banksOpen = banksDetails.open;
      if (banksDetails.open && !restoringBanks) {
        loadBanks();
      }
    });
    if (banksOpen && banksDetails) {
      restoringBanks = true;
      banksDetails.open = true;
      restoringBanks = false;
      loadBanks();
    }
    applyBankNote();
    mount.querySelectorAll("[data-bank-form]").forEach((bankFormElement) => {
      bankFormElement.addEventListener("submit", moveAccount);
    });
  }

  function showMove(form, message, isError) {
    setStatus(message, isError);
    const note = form.querySelector("[data-move-status]");
    if (!note) {
      return;
    }
    note.hidden = !message;
    note.textContent = message || "";
    note.className = isError ? "error" : "";
  }

  async function moveAccount(event) {
    event.preventDefault();
    const form = event.target;
    const accountId = Number(form.dataset.bankForm);
    const bankId = Number(new FormData(form).get("bank_id"));
    if (!window.confirm("Move this account and all of its rows to the selected bank?")) {
      return;
    }
    showMove(form, "Moving account…", false);
    try {
      const result = await statementApi(`/accounts/${accountId}/bank`, {
        method: "POST",
        body: JSON.stringify({ bank_id: bankId }),
      });
      const message = `Account moved. ${result.rows_rekeyed ?? 0} row(s) re-keyed.`;
      showMove(form, message, false);
      await load();
      setStatus(message, false);
      status?.scrollIntoView({ block: "nearest" });
    } catch (error) {
      showMove(form, error.message, true);
    }
  }

  async function load() {
    home = await statementApi(`/statements?as_of=${asOf}`);
    paint();
  }

  async function addAccount(event) {
    event.preventDefault();
    const data = new FormData(event.target);
    const type = event.target.querySelector("[name=a_type_id]").selectedOptions[0];
    const credit = type?.dataset.cutoff === "yes";
    const body = {
      bank_id: Number(data.get("bank_id")),
      a_type_id: Number(data.get("a_type_id")),
      account_name: data.get("account_name"),
      account_number: String(data.get("account_number") || ""),
      account_cutoff_day: credit ? Number(data.get("account_cutoff_day")) : null,
      credit_days: credit ? Number(data.get("credit_days")) : null,
      as_of: asOf,
    };
    try {
      await statementApi("/accounts", { method: "POST", body: JSON.stringify(body) });
      setStatus("Account opened.");
      await load();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function updateCutoff(event) {
    event.preventDefault();
    const accountId = Number(event.target.dataset.cutoffForm);
    const data = new FormData(event.target);
    const body = {
      account_cutoff_day: Number(data.get("account_cutoff_day")),
      credit_days: Number(data.get("credit_days")),
      as_of: asOf,
    };
    try {
      const result = await statementApi(`/accounts/${accountId}/cutoff`, {
        method: "POST",
        body: JSON.stringify(body),
      });
      const kept = result.frozen_periods ? ` ${result.frozen_periods} loaded period(s) kept their dates.` : "";
      setStatus(`Cutoff day saved.${kept}`);
      await load();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function uploadFile(file, dataset) {
    let mapFirst = false;
    try {
      const body = {
        account_id: Number(dataset.account),
        cutoff_id: Number(dataset.cutoff),
        slot: dataset.slot,
        filename: file.name,
        // Exact name the user picked; kept as-is (sql/013 chosen_filename).
        chosen_filename: file.name,
        as_of: asOf,
      };
      if (dataset.slot === "pdf") {
        body.pdf_base64 = bytesToBase64(new Uint8Array(await file.arrayBuffer()));
      } else {
        const name = (file.name || "").toLowerCase();
        const isXlsx =
          name.endsWith(".xlsx") ||
          name.endsWith(".xlsm") ||
          file.type === "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
        let text;
        let encoding = "utf-8";
        if (isXlsx) {
          if (typeof strmXlsxToCsv !== "function" || typeof strmXlsxToRows !== "function") {
            throw new Error("XLSX support is not loaded. Refresh the page and try again.");
          }
          const buffer = await file.arrayBuffer();
          // Bank layouts (FECHA/CARGO/ABONO, installments) first; any other sheet goes
          // to the column map with every row.
          if (dataset.slot === "asset") {
            text = (await strmXlsxToRows(buffer)).csv;
          } else {
            try {
              text = await strmXlsxToCsv(buffer);
            } catch (error) {
              if (dataset.slot !== "statement") {
                throw error;
              }
              text = (await strmXlsxToRows(buffer)).csv;
              mapFirst = true;
            }
          }
        } else {
          const decoded = await decodeBankCsv(file);
          text = decoded.text;
          encoding = decoded.encoding;
        }
        if (typeof strmStoredUploadFilename === "function") {
          body.filename = strmStoredUploadFilename(file.name, {
            bank: dataset.bank || "",
            accountNumber: dataset.accountNumber || "",
            period: dataset.period || "",
          });
        } else if (isXlsx) {
          body.filename = String(file.name || "statement").replace(/\.xlsx?$/i, ".csv").replace(/\.xlsm$/i, ".csv");
        }
        body.csv = text;
        body.encoding = encoding;
        const firstLine = text.split(/\r\n|\n|\r/)[0] || "";
        const commas = (firstLine.match(/,/g) || []).length;
        const semis = (firstLine.match(/;/g) || []).length;
        const tabs = (firstLine.match(/\t/g) || []).length;
        let delimiter = ",";
        if (semis > commas && semis > tabs) delimiter = ";";
        else if (tabs > commas && tabs > semis) delimiter = "\t";
        body.delimiter = delimiter;
        body.source_format = isXlsx ? "xlsx" : "csv";
      }
      if (dataset.slot === "asset") {
        openColumnMap(file, body, "/assets/uploads");
        return;
      }
      if (mapFirst) {
        openColumnMap(file, body);
        return;
      }
      try {
        const result = await statementApi("/uploads", { method: "POST", body: JSON.stringify(body) });
        const profileMsg = result.profile ? ` (${result.profile})` : "";
        setStatus(result.backup_warning || `File loaded${profileMsg}: ${result.row_count} row(s) in ${result.target_table}.`);
        await load();
      } catch (error) {
        // sql/018: unknown layout on a statement slot -> map the columns once.
        if (dataset.slot === "statement" && /map the columns/i.test(error.message) && body.csv) {
          openColumnMap(file, body);
          return;
        }
        throw error;
      }
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  function openColumnMap(file, body, route = "/uploads") {
    const container = mount.querySelector(`[data-map-for="${body.account_id}"]`);
    if (!container || typeof strmColumnMapWizard !== "function") {
      setStatus("This file matches no known layout and the column map could not open. Refresh the page.", true);
      return;
    }
    setStatus(
      route === "/uploads"
        ? "This file matches no known bank layout: map its columns below."
        : "Map the columns of this file below, then save.",
    );
    strmColumnMapWizard({
      container,
      api: statementApi,
      accountId: body.account_id,
      csv: body.csv,
      fileName: file.name,
      onSave: async (mapping, templateName) => {
        try {
          const result = await statementApi(route, {
            method: "POST",
            body: JSON.stringify({ ...body, mapping, template_name: templateName }),
          });
          const stored = result.inserted ?? result.row_count;
          setStatus(result.backup_warning || `File loaded with the column map: ${stored} row(s) in ${result.target_table}.`);
          await load();
        } catch (error) {
          setStatus(error.message, true);
        }
      },
    }).catch((error) => setStatus(error.message, true));
  }

  async function deleteAccount(accountId, label) {
    if (!window.confirm(`Delete ${label}? Every uploaded file of every period, all its rows and balances are deleted too. This cannot be undone.`)) {
      return;
    }
    try {
      const result = await statementApi(`/accounts/${accountId}`, { method: "DELETE" });
      setStatus(`Account ${label} deleted (${result.deleted_files ?? 0} file(s)).`);
      await load();
    } catch (error) {
      setStatus(error.message, true);
      window.alert(`${label} was not deleted: ${error.message}`);
    }
  }

  async function deleteFile(uploadId, route = "/uploads") {
    if (!window.confirm("Delete this uploaded file and all of its rows?")) {
      return;
    }
    try {
      await statementApi(`${route}/${uploadId}`, { method: "DELETE" });
      setStatus("File deleted.");
      await load();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function addEarlier(accountId) {
    try {
      await statementApi("/periods", {
        method: "POST",
        body: JSON.stringify({ account_id: Number(accountId), as_of: asOf }),
      });
      setStatus("Previous period added.");
      await load();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function removePeriod(cutoffId) {
    try {
      await statementApi(`/periods/${cutoffId}?as_of=${asOf}`, { method: "DELETE" });
      setStatus("Period removed.");
      await load();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  if (mount._renameClick) {
    mount.removeEventListener("click", mount._renameClick);
    mount.removeEventListener("keydown", mount._renameKey);
    mount.removeEventListener("submit", mount._addBankSubmit);
  }
  mount._renameClick = (event) => {
    const remove = event.target.closest("button[data-remove-bank]");
    if (remove && mount.contains(remove)) {
      event.preventDefault();
      const name = remove.closest("tr")?.cells?.[0]?.textContent?.trim() || "this bank";
      if (!window.confirm(`Remove ${name}? This cannot be undone.`)) {
        return;
      }
      removeBank(remove.dataset.removeBank);
      return;
    }
    const button = event.target.closest("button[data-rename-bank]");
    if (!button || !mount.contains(button)) {
      return;
    }
    event.preventDefault();
    const input = button.closest(".bank-actions")?.querySelector("input[name=bank_name]");
    renameBank(button.dataset.renameBank, input ? input.value : "");
  };
  mount._renameKey = (event) => {
    if (event.key !== "Enter") {
      return;
    }
    const input = event.target.closest?.(".bank-actions input[name=bank_name]");
    if (!input || !mount.contains(input)) {
      return;
    }
    event.preventDefault();
    const button = input.closest(".bank-actions")?.querySelector("button[data-rename-bank]");
    renameBank(button?.dataset.renameBank, input.value);
  };
  mount._addBankSubmit = (event) => {
    const form = event.target;
    if (!form?.matches?.("[data-add-bank]")) {
      return;
    }
    event.preventDefault();
    addBank(new FormData(form).get("bank_name"));
  };
  mount.addEventListener("click", mount._renameClick);
  mount.addEventListener("keydown", mount._renameKey);
  mount.addEventListener("submit", mount._addBankSubmit);

  mount.innerHTML = `<p>Loading statements…</p>`;
  load().catch((error) => setStatus(error.message, true));
}

window.renderStatements = renderStatements;
