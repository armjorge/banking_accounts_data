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
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    text = new TextDecoder("windows-1252").decode(bytes);
  }
  return text.replaceAll("\u00a0", " ").replace(/^\uFEFF/, "");
}

function bytesToBase64(bytes) {
  let binary = "";
  const chunk = 0x8000;
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk));
  }
  return btoa(binary);
}

function renderStatements(root, session) {
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

  function setStatus(message, isError = false) {
    if (!status) {
      return;
    }
    status.textContent = message;
    status.className = isError ? "error" : "";
  }

  function planLine() {
    if (home.max_credit_accounts != null && home.max_debit_accounts != null) {
      return `${home.plan_name} allows ${home.max_credit_accounts} credit account and ${home.max_debit_accounts} debit account. Savings uses the debit slot.`;
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
        />
      </label>
    `;
  }

  function fileLine(filename, uploadId, rows) {
    const count = rows == null ? "" : ` <span class="muted">(${escapeStatementHtml(rows)} rows)</span>`;
    return `
      <div class="file-line">
        <span>${escapeStatementHtml(filename)}${count}</span>
        <button type="button" data-delete-file="${escapeStatementHtml(uploadId)}">Delete file</button>
      </div>
    `;
  }

  function statementCell(account, period) {
    if (period.statement_upload_id) {
      return fileLine(period.statement_filename, period.statement_upload_id, period.statement_row_count);
    }
    if (period.show_statement_slot) {
      const label = account.ledger_kind === "credit" ? "Drop statement CSV" : "Drop CSV";
      return dropZone(account, period, "statement", label, ".csv,text/csv");
    }
    return `<span class="muted">Opens after ${escapeStatementHtml(period.period_end)}</span>`;
  }

  function installmentCell(account, period) {
    if (account.ledger_kind !== "credit") {
      return `<span class="muted">—</span>`;
    }
    if (period.installment_upload_id) {
      return fileLine(period.installment_filename, period.installment_upload_id, period.installment_row_count);
    }
    if (period.show_installment_slot) {
      return dropZone(account, period, "installment", "Drop installment CSV", ".csv,text/csv");
    }
    return `<span class="muted">Opens after ${escapeStatementHtml(period.period_end)}</span>`;
  }

  function pdfCell(account, period) {
    if (!home.curated_csv_backup) {
      return "";
    }
    if (period.pdf_upload_id) {
      return fileLine(period.pdf_filename, period.pdf_upload_id, null);
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
        const pending = period.pending ? `<span class="muted">Pending</span>` : `<span class="muted">CSV loaded</span>`;
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
        <table class="compact">
          <thead>
            <tr>
              <th>Period</th><th>Starts</th><th>Cutoff</th><th>Statement</th><th>Installments</th>${pdfHead}<th></th>
            </tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
        <button type="button" data-add-period="${escapeStatementHtml(account.account_id)}">Add the previous period</button>
      </section>
    `;
  }

  function addForm() {
    if (!home.banks.length || !home.account_types.length) {
      return `<p>Banorte is not available yet. Apply the banking DDL from the config console.</p>`;
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

  function paint() {
    const backup = home.curated_csv_backup
      ? `<p class="muted">Premium can also keep the optional PDF statement. Deleting a file removes its rows and leaves the vault copy.</p>`
      : "";
    const accounts = home.accounts.length
      ? home.accounts.map(accountCard).join("")
      : `<p>No accounts yet. Open a Banorte account and the periods whose cutoff has passed appear here, plus the two before that.</p>`;
    mount.innerHTML = `
      <p class="lede">${escapeStatementHtml(planLine())} Signed in as <strong>${escapeStatementHtml(session.name)}</strong>.</p>
      ${backup}
      ${accounts}
      ${addForm()}
    `;
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
    mount.querySelectorAll("[data-add-period]").forEach((button) => {
      button.addEventListener("click", () => addEarlier(button.dataset.addPeriod));
    });
    mount.querySelectorAll("[data-remove-period]").forEach((button) => {
      button.addEventListener("click", () => removePeriod(button.dataset.removePeriod));
    });
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

  async function uploadFile(file, dataset) {
    try {
      const body = {
        account_id: Number(dataset.account),
        cutoff_id: Number(dataset.cutoff),
        slot: dataset.slot,
        filename: file.name,
        as_of: asOf,
      };
      if (dataset.slot === "pdf") {
        body.pdf_base64 = bytesToBase64(new Uint8Array(await file.arrayBuffer()));
      } else {
        body.csv = await decodeBankCsv(file);
      }
      const result = await statementApi("/uploads", { method: "POST", body: JSON.stringify(body) });
      setStatus(result.backup_warning || "File loaded.");
      await load();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function deleteFile(uploadId) {
    if (!window.confirm("Delete this uploaded file and all of its rows?")) {
      return;
    }
    try {
      await statementApi(`/uploads/${uploadId}`, { method: "DELETE" });
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

  mount.innerHTML = `<p>Loading statements…</p>`;
  load().catch((error) => setStatus(error.message, true));
}

window.renderStatements = renderStatements;
