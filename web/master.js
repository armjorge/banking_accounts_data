function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function isAdmin(claims) {
  const groups = claims["cognito:groups"];
  const raw = Array.isArray(groups) ? groups.join(" ") : String(groups || "");
  return raw.split(/[^A-Za-z0-9_-]+/).includes("admin");
}

const ADMIN_PAGES = [
  {
    id: "statements",
    title: "Statements",
    blurb: "Which Banorte statement file is still missing for each account and period.",
    listed: true,
  },
  {
    id: "data-admin",
    title: "Data admin",
    blurb: "Banks, account types, and the header list for each pair.",
    listed: true,
  },
];

async function api(path, options = {}) {
  const cfg = window.STRM_CONFIG;
  if (!cfg.apiUrl) {
    throw new Error("The admin API is not published yet. Redeploy the environment, then publish the site again.");
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

function renderMasterBanking(root, session) {
  root.classList.add("wide");
  root.innerHTML = `
    <nav class="ribbon" aria-label="Pages">
      <button type="button" id="back-to-pages">Pages</button>
      <span id="ribbon-pages"></span>
      <button type="button" id="logout">Sign out</button>
    </nav>
    <h1 id="heading">Pages</h1>
    <p id="status"></p>
    <div id="panel"></div>
  `;
  document.getElementById("logout").addEventListener("click", session.logout);
  document.getElementById("back-to-pages").addEventListener("click", () => openPage(""));
  const status = document.getElementById("status");
  const panel = document.getElementById("panel");
  const heading = document.getElementById("heading");
  const ribbonPages = document.getElementById("ribbon-pages");
  let catalog = { banks: [], accountTypes: [], templates: [] };
  let pageId = "";

  function setStatus(message, isError = false) {
    status.textContent = message;
    status.className = isError ? "error" : "";
  }

  function paintRibbon() {
    const pagesButton = document.getElementById("back-to-pages");
    if (pageId) {
      pagesButton.removeAttribute("aria-current");
    } else {
      pagesButton.setAttribute("aria-current", "page");
    }
    ribbonPages.innerHTML = ADMIN_PAGES.map(
      (page) => `
        <button type="button" data-open="${page.id}" ${page.id === pageId ? 'aria-current="page"' : ""}>
          ${escapeHtml(page.title)}
        </button>`,
    ).join("");
    ribbonPages.querySelectorAll("[data-open]").forEach((button) => {
      button.addEventListener("click", () => openPage(button.dataset.open || ""));
    });
  }

  function previewRows() {
    const banks = catalog.banks
      .map((row) => `<tr><td>${escapeHtml(row.bank_id)}</td><td>${escapeHtml(row.bank_name)}</td></tr>`)
      .join("");
    const types = catalog.accountTypes
      .map((row) => `<tr><td>${escapeHtml(row.a_type_id)}</td><td>${escapeHtml(row.type_name)}</td></tr>`)
      .join("");
    const templates = catalog.templates
      .map(
        (row) =>
          `<tr><td>${escapeHtml(row.bank_name)}</td><td>${escapeHtml(row.type_name)}</td><td>${escapeHtml(row.headers)}</td></tr>`,
      )
      .join("");
    return `
      <h3>Banks</h3>
      ${compactTable(["Id", "Bank name"], banks, 2)}
      <h3>Account types</h3>
      ${compactTable(["Id", "Type name"], types, 2)}
      <h3>Templates</h3>
      ${compactTable(["Bank", "Account type", "Headers"], templates, 3)}
    `;
  }

  function compactTable(headers, body, span) {
    const head = headers.map((header) => `<th>${escapeHtml(header)}</th>`).join("");
    const empty = `<tr><td colspan="${span}">No records yet.</td></tr>`;
    return `<table class="compact"><thead><tr>${head}</tr></thead><tbody>${body || empty}</tbody></table>`;
  }

  function drawList() {
    heading.textContent = "Pages";
    panel.innerHTML = `
      <p class="lede">Signed in as <strong>${escapeHtml(session.name)}</strong>. You can open every page, including ones that are not listed for other people.</p>
      <div class="page-list">
        ${ADMIN_PAGES.map(
          (page) => `
            <article class="page-card">
              <div class="page-card-head">
                <h2>${escapeHtml(page.title)}</h2>
                <span class="pill">${page.listed ? "Listed" : "Not listed"}</span>
              </div>
              <p>${escapeHtml(page.blurb)}</p>
              ${previewRows()}
              <button type="button" data-open="${page.id}">Open</button>
            </article>`,
        ).join("")}
      </div>
    `;
    panel.querySelectorAll("[data-open]").forEach((button) => {
      button.addEventListener("click", () => openPage(button.dataset.open));
    });
  }

  function draw() {
    paintRibbon();
    if (!pageId) {
      drawList();
      return;
    }
    const page = ADMIN_PAGES.find((item) => item.id === pageId);
    heading.textContent = page ? page.title : "Pages";
    if (pageId === "statements") {
      window.renderStatements(panel, { name: session.name, logout: session.logout, embedded: true });
      return;
    }
    drawDataAdmin();
  }

  function openPage(id) {
    pageId = id;
    setStatus("");
    draw();
  }

  function drawDataAdmin() {
    panel.innerHTML = `${banksSection()}${typesSection()}${templatesSection()}`;
    bindPicker("edit-bank", catalog.banks, (row) => [String(row.bank_id), row.bank_name]);
    bindPicker("edit-type", catalog.accountTypes, (row) => [String(row.a_type_id), row.type_name]);
    bindPicker("edit-template", catalog.templates, (row) => [
      `${row.bank_id}-${row.a_type_id}`,
      row.headers,
    ]);
    document.getElementById("edit-bank").addEventListener("submit", saveBank);
    document.getElementById("edit-bank").querySelector("[data-delete]").addEventListener("click", deleteBank);
    document.getElementById("edit-type").addEventListener("submit", saveType);
    document.getElementById("edit-type").querySelector("[data-delete]").addEventListener("click", deleteType);
    document.getElementById("edit-template").addEventListener("submit", saveTemplate);
    document.getElementById("edit-template").querySelector("[data-delete]").addEventListener("click", deleteTemplate);
    document.getElementById("add-bank").addEventListener("submit", addBank);
    document.getElementById("add-type").addEventListener("submit", addType);
    const templateForm = document.getElementById("add-template");
    if (templateForm) {
      templateForm.addEventListener("submit", addTemplate);
    }
  }

  function bindPicker(formId, rows, identity) {
    const form = document.getElementById(formId);
    const select = form.querySelector("[name=record]");
    const input = form.querySelector("[name=value]");
    const buttons = form.querySelectorAll("button");
    select.addEventListener("change", () => {
      const match = rows.find((row) => identity(row)[0] === select.value);
      const chosen = Boolean(match);
      input.disabled = !chosen;
      input.value = chosen ? identity(match)[1] ?? "" : "";
      buttons.forEach((button) => {
        button.disabled = !chosen;
      });
    });
  }

  function picker(formId, chooseLabel, options, fieldLabel) {
    return `
      <form id="${formId}" class="edit-form">
        <label>Record
          <select name="record" ${options ? "" : "disabled"}>
            <option value="">${escapeHtml(chooseLabel)}</option>
            ${options}
          </select>
        </label>
        <label>${escapeHtml(fieldLabel)}
          <input name="value" type="text" disabled />
        </label>
        <div class="row-actions">
          <button type="submit" disabled>Save</button>
          <button type="button" data-delete disabled>Delete</button>
        </div>
      </form>
    `;
  }

  function banksSection() {
    const rows = catalog.banks
      .map((row) => `<tr><td>${escapeHtml(row.bank_id)}</td><td>${escapeHtml(row.bank_name)}</td></tr>`)
      .join("");
    const options = catalog.banks
      .map(
        (row) =>
          `<option value="${escapeHtml(row.bank_id)}">${escapeHtml(row.bank_id)} · ${escapeHtml(row.bank_name)}</option>`,
      )
      .join("");
    return `
      <section class="page-section">
        <h2>Banks</h2>
        <table class="compact">
          <thead><tr><th>Id</th><th>Bank name</th></tr></thead>
          <tbody>${rows || `<tr><td colspan="2">No records yet.</td></tr>`}</tbody>
        </table>
        ${picker("edit-bank", "Choose a bank", options, "Bank name")}
        <form id="add-bank" class="add-form">
          <label>Bank id <input name="bank_id" type="number" min="1" required /></label>
          <label>Bank name <input name="bank_name" type="text" /></label>
          <button type="submit">Add bank</button>
        </form>
      </section>
    `;
  }

  function typesSection() {
    const rows = catalog.accountTypes
      .map(
        (row) =>
          `<tr><td>${escapeHtml(row.a_type_id)}</td><td>${escapeHtml(row.type_name)}</td><td>${escapeHtml(row.ledger_kind || "")}</td><td>${row.allows_cutoff ? "Yes" : "No"}</td></tr>`,
      )
      .join("");
    const options = catalog.accountTypes
      .map(
        (row) =>
          `<option value="${escapeHtml(row.a_type_id)}">${escapeHtml(row.a_type_id)} · ${escapeHtml(row.type_name)}</option>`,
      )
      .join("");
    return `
      <section class="page-section">
        <h2>Account types</h2>
        <p class="muted">Credit card types use a cutoff day. Debit and savings types close on the last day of the month.</p>
        <table class="compact">
          <thead><tr><th>Id</th><th>Type name</th><th>Ledger</th><th>Cutoff</th></tr></thead>
          <tbody>${rows || `<tr><td colspan="4">No records yet.</td></tr>`}</tbody>
        </table>
        ${picker("edit-type", "Choose an account type", options, "Type name")}
        <form id="add-type" class="add-form">
          <label>Type id <input name="a_type_id" type="number" min="1" required /></label>
          <label>Type name <input name="type_name" type="text" required /></label>
          <button type="submit">Add account type</button>
        </form>
      </section>
    `;
  }

  function templatesSection() {
    const rows = catalog.templates
      .map(
        (row) =>
          `<tr><td>${escapeHtml(row.bank_name)}</td><td>${escapeHtml(row.type_name)}</td><td>${escapeHtml(row.headers)}</td></tr>`,
      )
      .join("");
    const options = catalog.templates
      .map(
        (row) =>
          `<option value="${escapeHtml(row.bank_id)}-${escapeHtml(row.a_type_id)}">${escapeHtml(row.bank_name)} · ${escapeHtml(row.type_name)}</option>`,
      )
      .join("");
    const bankOptions = catalog.banks
      .map((row) => `<option value="${escapeHtml(row.bank_id)}">${escapeHtml(row.bank_name || row.bank_id)}</option>`)
      .join("");
    const typeOptions = catalog.accountTypes
      .map((row) => `<option value="${escapeHtml(row.a_type_id)}">${escapeHtml(row.type_name)}</option>`)
      .join("");
    const addForm =
      bankOptions && typeOptions
        ? `<form id="add-template" class="add-form">
            <label>Bank <select name="bank_id">${bankOptions}</select></label>
            <label>Account type <select name="a_type_id">${typeOptions}</select></label>
            <label>Headers <input name="headers" type="text" /></label>
            <button type="submit">Add template</button>
          </form>`
        : `<p>Add a bank and an account type before adding a template.</p>`;
    return `
      <section class="page-section">
        <h2>Templates</h2>
        <table class="compact">
          <thead><tr><th>Bank</th><th>Account type</th><th>Headers</th></tr></thead>
          <tbody>${rows || `<tr><td colspan="3">No records yet.</td></tr>`}</tbody>
        </table>
        ${picker("edit-template", "Choose a template", options, "Headers")}
        ${addForm}
      </section>
    `;
  }

  async function reload() {
    catalog = await api("/admin");
    draw();
  }

  async function saveBank(event) {
    event.preventDefault();
    const data = new FormData(event.target);
    const bankId = data.get("record");
    if (!bankId) {
      return;
    }
    try {
      await api("/admin/banks", {
        method: "PUT",
        body: JSON.stringify({ bank_id: Number(bankId), bank_name: data.get("value") }),
      });
      setStatus("Bank saved.");
      await reload();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function deleteBank() {
    const bankId = new FormData(document.getElementById("edit-bank")).get("record");
    if (!bankId) {
      return;
    }
    try {
      await api(`/admin/banks/${bankId}`, { method: "DELETE" });
      setStatus("Bank deleted.");
      await reload();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function addBank(event) {
    event.preventDefault();
    const data = new FormData(event.target);
    try {
      await api("/admin/banks", {
        method: "PUT",
        body: JSON.stringify({
          bank_id: Number(data.get("bank_id")),
          bank_name: data.get("bank_name"),
        }),
      });
      setStatus("Bank added.");
      await reload();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function saveType(event) {
    event.preventDefault();
    const data = new FormData(event.target);
    const typeId = data.get("record");
    if (!typeId) {
      return;
    }
    try {
      await api("/admin/account-types", {
        method: "PUT",
        body: JSON.stringify({ a_type_id: Number(typeId), type_name: data.get("value") }),
      });
      setStatus("Account type saved.");
      await reload();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function deleteType() {
    const typeId = new FormData(document.getElementById("edit-type")).get("record");
    if (!typeId) {
      return;
    }
    try {
      await api(`/admin/account-types/${typeId}`, { method: "DELETE" });
      setStatus("Account type deleted.");
      await reload();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function addType(event) {
    event.preventDefault();
    const data = new FormData(event.target);
    try {
      await api("/admin/account-types", {
        method: "PUT",
        body: JSON.stringify({
          a_type_id: Number(data.get("a_type_id")),
          type_name: data.get("type_name"),
        }),
      });
      setStatus("Account type added.");
      await reload();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function saveTemplate(event) {
    event.preventDefault();
    const key = new FormData(event.target).get("record");
    if (!key) {
      return;
    }
    const [bankId, typeId] = String(key).split("-");
    const headers = new FormData(event.target).get("value");
    try {
      await api("/admin/templates", {
        method: "PUT",
        body: JSON.stringify({
          bank_id: Number(bankId),
          a_type_id: Number(typeId),
          headers,
        }),
      });
      setStatus("Template saved.");
      await reload();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function deleteTemplate() {
    const key = new FormData(document.getElementById("edit-template")).get("record");
    if (!key) {
      return;
    }
    const [bankId, typeId] = String(key).split("-");
    try {
      await api(`/admin/templates/${bankId}/${typeId}`, { method: "DELETE" });
      setStatus("Template deleted.");
      await reload();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function addTemplate(event) {
    event.preventDefault();
    const data = new FormData(event.target);
    try {
      await api("/admin/templates", {
        method: "PUT",
        body: JSON.stringify({
          bank_id: Number(data.get("bank_id")),
          a_type_id: Number(data.get("a_type_id")),
          headers: data.get("headers"),
        }),
      });
      setStatus("Template added.");
      await reload();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  draw();
  reload().catch((error) => setStatus(error.message, true));
}

window.isAdminClaim = isAdmin;
window.renderMasterBanking = renderMasterBanking;
