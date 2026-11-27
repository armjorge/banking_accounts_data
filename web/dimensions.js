// sql/015: Dimensions page (attribute_1..3 per movement) and API tokens page (Google
// Sheets GraphQL access with the plan's quota). sql/016: list-bound attributes, the
// Lists page and transfer links. sql/017: investments and assets group and the
// Investments & Assets page (assets.js). Uses statementApi() from statements.js.

function dimEsc(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

const DIMENSION_GROUPS = [
  { kind: "debit", title: "Debit", layers: ["open", "closed"] },
  { kind: "credit", title: "Credit", layers: ["open", "closed", "future"] },
  // sql/017: master_closed_aaccandass_f (one layer; rows are stored closed).
  { kind: "asset", title: "Investments & assets", layers: ["closed"] },
];
const LAYER_TITLES = { open: "Open", closed: "Closed", future: "Future" };
const LAYER_TITLES_BY_KIND = { asset: { closed: "Movements" } };

function layerTitle(kind, layer) {
  return LAYER_TITLES_BY_KIND[kind]?.[layer] || LAYER_TITLES[layer];
}

function pctLabel(level) {
  const total = level?.total ?? 0;
  const filled = level?.filled ?? 0;
  const pct = level?.pct ?? 0;
  return `${pct}% with attributes <span class="muted">(${filled} of ${total})</span>`;
}

function money(value) {
  if (value === null || value === undefined || value === "") {
    return "";
  }
  return Number(value).toLocaleString("es-MX", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

const DEFAULT_ATTRIBUTES = [
  ["List 1", "list"],
  ["Sublist 1", "list"],
  ["List 2", "list"],
  ["Sublist 2", "list"],
  ["Note", "text"],
].map(([label, mode], index) => ({
  slot: index + 1,
  field: `attribute_${index + 1}`,
  label,
  mode,
  list_id: null,
}));

function transferBadge(row) {
  if (!row.is_internal_transfer) return "";
  const arrow = row.transfer_role === "sending" ? "→" : "←";
  const review = row.transfer_source === "auto" && !row.transfer_reviewed ? ' <span class="tag warn">auto · review</span>' : "";
  return `<span class="tag transfer" title="${dimEsc(row.transfer_type === "same_bank" ? "Same bank" : "Between banks")}">↔ ${arrow} ${dimEsc(row.transfer_counterpart_account || "")}</span>${review}`;
}

function linkSide(side) {
  if (!side || side.missing) return '<span class="muted">movement no longer stored</span>';
  return `${dimEsc(side.account_number)} <span class="muted">${dimEsc(side.bank_name)}</span><br><span class="muted">${dimEsc(side.txn_date)} · ${dimEsc(side.concept)}</span>`;
}

function renderDimensions(root, session) {
  const status = document.getElementById("status");
  let summary = {};
  let catalog = { attributes: DEFAULT_ATTRIBUTES, lists: [] };
  let transfers = { auto_link_transfers: true, links: [], suggestions: [] };
  const state = {};

  function setStatus(message, isError = false) {
    if (status) {
      status.textContent = message;
      status.className = isError ? "error" : "";
    }
  }

  function layerKey(kind, layer) {
    return `${kind}:${layer}`;
  }

  function attributes() {
    return catalog.attributes && catalog.attributes.length ? catalog.attributes : DEFAULT_ATTRIBUTES;
  }

  function listById(listId) {
    return (catalog.lists || []).find((list) => list.list_id === listId) || null;
  }

  function listItems(listId) {
    return listById(listId)?.items || [];
  }

  function sameId(left, right) {
    if (left === null || left === undefined || left === "" || right === null || right === undefined || right === "") {
      return false;
    }
    return Number(left) === Number(right);
  }

  function nestedChoices(listId, parentItemId) {
    const list = listById(listId);
    const items = listItems(listId).filter((item) => !list?.parent_list_id || item.parent_item_id);
    if (!list?.parent_list_id) return items.filter((item) => !item.parent_item_id);
    if (!parentItemId) return [];
    return items.filter((item) => sameId(item.parent_item_id, parentItemId));
  }

  function shownAttribute(row, attribute) {
    const storedId = row[`${attribute.field}_item_id`];
    for (const list of catalog.lists || []) {
      const item = (list.items || []).find((entry) => sameId(entry.item_id, storedId));
      if (!item) continue;
      if (!item.parent_item_id) return item.item_name;
      const parentList = (catalog.lists || []).find((entry) => sameId(entry.list_id, list.parent_list_id));
      const parent = (parentList?.items || []).find((entry) => sameId(entry.item_id, item.parent_item_id));
      return parent ? `${parent.item_name} · ${item.item_name}` : item.item_name;
    }
    return row[attribute.field];
  }

  function transfersSummary() {
    const toReview = transfers.links.filter((link) => link.source === "auto" && !link.reviewed).length;
    const pending = (transfers.suggestions || []).length;
    return `<strong>Transfers between your accounts</strong> · ${transfers.links.length} linked${toReview ? ` · <span class="tag warn">${toReview} to review</span>` : ""}${pending ? ` · ${pending} suggested` : ""}`;
  }

  function transfersBody() {
    const links = transfers.links
      .map((link) => `
        <tr class="${link.source === "auto" && !link.reviewed ? "review" : ""}">
          <td>${dimEsc(link.txn_date)}</td>
          <td class="num">${money(link.amount)}</td>
          <td>${linkSide(link.sending)}</td>
          <td>${linkSide(link.receiving)}</td>
          <td>${link.transfer_type === "same_bank" ? "Same bank" : "Between banks"}${link.receiving?.kind === "credit" ? " · card payment" : ""}</td>
          <td>${link.source === "auto" ? (link.reviewed ? "Auto · kept" : `Auto${link.match_candidates > 1 ? ` · ${dimEsc(link.match_candidates)} matches` : ""}`) : "Manual"}</td>
          <td>
            ${link.source === "auto" && !link.reviewed ? `<button type="button" data-confirm-link="${dimEsc(link.link_hash)}">Keep</button>` : ""}
            <button type="button" data-unlink="${dimEsc(link.link_hash)}">Unlink</button>
          </td>
        </tr>`)
      .join("");
    const suggestions = (transfers.suggestions || [])
      .map((pair) => `
        <tr>
          <td>${dimEsc(pair.txn_date)}</td>
          <td class="num">${money(pair.amount)}</td>
          <td>${dimEsc(pair.sending.account_number)} <span class="muted">${dimEsc(pair.sending.concept)}</span></td>
          <td>${dimEsc(pair.receiving.account_number)} <span class="muted">${dimEsc(pair.receiving.concept)}</span></td>
          <td>${pair.transfer_type === "same_bank" ? "Same bank" : "Between banks"}</td>
          <td><button type="button" data-link-pair="${dimEsc(pair.sending_hash)}|${dimEsc(pair.receiving_hash)}">Link</button></td>
        </tr>`)
      .join("");
    return `
      <p class="muted">A transfer is money out of one of your debit accounts and into another account (or a card payment) on the same day for the same amount. Linked rows carry <code>is_internal_transfer</code> in Google Sheets.</p>
      <p>
        <label><input type="checkbox" id="auto-links" ${transfers.auto_link_transfers ? "checked" : ""} /> Link matches automatically (flagged "auto" until you keep or unlink them)</label>
        <button type="button" id="detect-links">Find transfers now</button>
      </p>
      <table class="compact">
        <thead><tr><th>Date</th><th>Amount</th><th>From</th><th>To</th><th>Type</th><th>Source</th><th></th></tr></thead>
        <tbody>${links || '<tr><td colspan="7">No linked transfers.</td></tr>'}</tbody>
      </table>
      ${suggestions ? `<h3>Suggested</h3><table class="compact"><thead><tr><th>Date</th><th>Amount</th><th>From</th><th>To</th><th>Type</th><th></th></tr></thead><tbody>${suggestions}</tbody></table>` : ""}
    `;
  }

  function draw() {
    root.innerHTML = `
      <p class="lede">Label your movements with up to three attributes. Labels stay with a movement when its period closes. Bind an attribute to a list on the <strong>Lists</strong> page to pick from items.</p>
      <details class="dim-group dim-transfers" id="dim-transfers">
        <summary>${transfersSummary()}</summary>
        <div class="dim-body" id="dim-transfers-body">${transfersBody()}</div>
      </details>
      ${DIMENSION_GROUPS.map((group) => `
        <details class="dim-group" data-kind="${group.kind}">
          <summary><strong>${group.title}</strong> · ${pctLabel(summary[group.kind])}</summary>
          ${group.layers.map((layer) => `
            <details class="dim-layer" data-kind="${group.kind}" data-layer="${layer}">
              <summary>${layerTitle(group.kind, layer)} · ${pctLabel(summary[group.kind]?.layers?.[layer])}</summary>
              <div class="dim-body" id="dim-${group.kind}-${layer}"></div>
            </details>`).join("")}
        </details>`).join("")}
    `;
    root.querySelectorAll("details.dim-layer").forEach((element) => {
      element.addEventListener("toggle", () => {
        if (element.open) {
          loadRows(element.dataset.kind, element.dataset.layer);
        }
      });
    });
    bindTransfers();
  }

  function redrawTransfers() {
    const panel = document.getElementById("dim-transfers");
    if (!panel) return;
    panel.querySelector(":scope > summary").innerHTML = transfersSummary();
    document.getElementById("dim-transfers-body").innerHTML = transfersBody();
    bindTransfers();
  }

  async function reloadAfterTransferChange(message) {
    setStatus(message);
    await Promise.all([loadTransfers(), loadSummary()]);
    redrawTransfers();
    refreshSummaryLabels();
    await reloadOpenLayers();
  }

  function bindTransfers() {
    const auto = document.getElementById("auto-links");
    if (auto) {
      auto.addEventListener("change", async () => {
        try {
          await statementApi("/transfers/settings", { method: "POST", body: JSON.stringify({ auto_link_transfers: auto.checked }) });
          await reloadAfterTransferChange(auto.checked ? "Automatic links on." : "Automatic links off: matches are only suggested.");
        } catch (error) {
          setStatus(error.message, true);
        }
      });
    }
    const detect = document.getElementById("detect-links");
    if (detect) {
      detect.addEventListener("click", async () => {
        try {
          const result = await statementApi("/transfers/detect", { method: "POST", body: "{}" });
          await reloadAfterTransferChange(`${result.created || 0} new link(s), ${(result.pairs || []).length} match(es).`);
        } catch (error) {
          setStatus(error.message, true);
        }
      });
    }
    root.querySelectorAll("[data-unlink]").forEach((button) => {
      button.addEventListener("click", () => unlink(button.dataset.unlink));
    });
    root.querySelectorAll("[data-confirm-link]").forEach((button) => {
      button.addEventListener("click", async () => {
        try {
          await statementApi(`/transfers/${encodeURIComponent(button.dataset.confirmLink)}/confirm`, { method: "POST", body: "{}" });
          await reloadAfterTransferChange("Link kept.");
        } catch (error) {
          setStatus(error.message, true);
        }
      });
    });
    root.querySelectorAll("[data-link-pair]").forEach((button) => {
      button.addEventListener("click", () => {
        const [rowA, rowB] = button.dataset.linkPair.split("|");
        link(rowA, rowB);
      });
    });
  }

  async function unlink(linkHash) {
    try {
      await statementApi(`/transfers/${encodeURIComponent(linkHash)}`, { method: "DELETE" });
      await reloadAfterTransferChange("Unlinked. This pair will not be suggested again.");
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function link(rowA, rowB) {
    try {
      await statementApi("/transfers", { method: "POST", body: JSON.stringify({ row_a: rowA, row_b: rowB }) });
      await reloadAfterTransferChange("Linked as a transfer.");
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function loadSummary() {
    summary = (await statementApi("/dimensions")) || {};
  }

  async function loadCatalog() {
    try {
      catalog = (await statementApi("/lists")) || catalog;
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function loadTransfers() {
    try {
      transfers = (await statementApi("/transfers")) || transfers;
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  function filters(kind, layer) {
    const key = layerKey(kind, layer);
    state[key] = state[key] || { from: "", to: "", q: "", selected: null, rows: [], total: 0, partners: null, partnerQ: "" };
    return state[key];
  }

  async function reloadOpenLayers() {
    const open = [...root.querySelectorAll("details.dim-layer[open]")];
    for (const element of open) {
      await loadRows(element.dataset.kind, element.dataset.layer);
    }
  }

  async function loadRows(kind, layer) {
    const current = filters(kind, layer);
    const params = new URLSearchParams({ kind, layer, limit: "200" });
    if (current.from) params.set("from", current.from);
    if (current.to) params.set("to", current.to);
    if (current.q) params.set("q", current.q);
    try {
      const page = await statementApi(`/dimensions/rows?${params.toString()}`);
      current.rows = page.rows || [];
      current.total = page.total || 0;
      drawRows(kind, layer);
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  function attributeField(attribute, row, parentItemId) {
    const value = row[attribute.field];
    if (attribute.mode !== "list") {
      return `<label>${dimEsc(attribute.label)} <input name="${attribute.field}" maxlength="500" value="${dimEsc(value)}" /></label>`;
    }
    if (!attribute.list_id) {
      const waiting = attribute.slot === 2 || attribute.slot === 4 ? "No sublist yet." : "No list yet.";
      return `<label>${dimEsc(attribute.label)} <span class="muted">${waiting}</span></label>`;
    }
    const selectedId = row[`${attribute.field}_item_id`];
    const choices = nestedChoices(attribute.list_id, parentItemId);
    const visible = choices.some((item) => sameId(item.item_id, selectedId)) ? selectedId : null;
    const options = choices
      .map((item) => `<option value="${dimEsc(item.item_id)}" ${sameId(item.item_id, visible) ? "selected" : ""}>${dimEsc(item.item_name)}</option>`)
      .join("");
    const orphan = !selectedId && value ? `<option value="" selected>${dimEsc(value)} (text, not in the list)</option>` : "";
    const list = listById(attribute.list_id);
    const parent = list?.parent_list_id ? listById(list.parent_list_id) : null;
    const listLabel = parent ? `sublist of ${parent.list_name}` : (attribute.list_name || "list");
    return `<label>${dimEsc(attribute.label)} <span class="muted">(${dimEsc(listLabel)})</span>
      <select name="${attribute.field}" data-list-field data-nested="${list?.parent_list_id ? "1" : ""}">
        ${orphan}
        <option value="" ${!visible && !value ? "selected" : ""}>— none —</option>
        ${options}
        <option value="__new__">+ New item…</option>
      </select>
      <input name="${attribute.field}__new" maxlength="500" placeholder="New item name" hidden />
    </label>`;
  }

  function refillNestedSelects(form) {
    const attrs = attributes();
    attrs.forEach((attribute, index) => {
      const list = listById(attribute.list_id);
      if (!list?.parent_list_id || attribute.mode !== "list") return;
      const select = form.querySelector(`[name="${attribute.field}"]`);
      if (!select) return;
      const previous = attrs[index - 1];
      const previousSelect = previous ? form.querySelector(`[name="${previous.field}"]`) : null;
      const previousRaw = previousSelect ? String(previousSelect.value || "") : "";
      const parentItemId = previousRaw && previousRaw !== "__new__" ? Number(previousRaw) : null;
      const current = String(select.value || "");
      const choices = nestedChoices(attribute.list_id, parentItemId);
      const still = choices.some((item) => sameId(item.item_id, current));
      const keepNew = current === "__new__";
      select.innerHTML = [
        `<option value="" ${!still && !keepNew ? "selected" : ""}>— none —</option>`,
        ...choices.map((item) => `<option value="${dimEsc(item.item_id)}" ${sameId(item.item_id, current) ? "selected" : ""}>${dimEsc(item.item_name)}</option>`),
        `<option value="__new__" ${keepNew ? "selected" : ""}>+ New item…</option>`,
      ].join("");
      if (keepNew) select.value = "__new__";
      else if (!still) select.value = "";
      const extra = select.parentElement.querySelector(`[name="${select.name}__new"]`);
      if (extra) extra.hidden = select.value !== "__new__";
    });
  }

  function transferEditor(kind, layer, row) {
    if (layer === "future") {
      return '<p class="muted">Installment plans cannot be linked as transfers.</p>';
    }
    if (kind === "asset") {
      return '<p class="muted">Investment and asset movements are not linked as transfers. Manage them on the Investments &amp; Assets page.</p>';
    }
    const current = filters(kind, layer);
    if (row.is_internal_transfer) {
      const review = row.transfer_source === "auto" && !row.transfer_reviewed;
      return `<div class="dim-transfer">
        <p>Transfer ${row.transfer_role === "sending" ? "to" : "from"} <strong>${dimEsc(row.transfer_counterpart_account || "")}</strong>
          (${row.transfer_type === "same_bank" ? "same bank" : "between banks"}, ${row.transfer_source === "auto" ? (review ? "auto, to review" : "auto, kept") : "manual"}).</p>
        ${review ? `<button type="button" data-confirm-link="${dimEsc(row.transfer_link_hash)}">Keep link</button>` : ""}
        <button type="button" data-unlink="${dimEsc(row.transfer_link_hash)}">Unlink</button>
      </div>`;
    }
    if (!current.partners) {
      return `<div class="dim-transfer"><button type="button" data-find-partners>Link as transfer…</button></div>`;
    }
    const partners = current.partners
      .map((partner) => `
        <tr>
          <td><input type="radio" name="partner-${kind}-${layer}" value="${dimEsc(partner.row_hash)}" aria-label="Pick movement" /></td>
          <td>${dimEsc(partner.account_number)}</td><td>${dimEsc(partner.bank_name)}</td><td>${dimEsc(partner.txn_date)}</td>
          <td>${dimEsc(partner.concept)}</td><td class="num">${money(partner.abs_amount)}</td>
          <td>${partner.transfer_role === "sending" ? "money out" : partner.kind === "credit" ? "card payment" : "money in"}</td>
        </tr>`)
      .join("");
    return `<div class="dim-transfer">
      <form data-partner-search>
        <label>Other side <input type="search" name="q" value="${dimEsc(current.partnerQ)}" placeholder="Concept, account or bank (blank = ±45 days)" /></label>
        <button type="submit">Search</button>
      </form>
      <table class="compact">
        <thead><tr><th></th><th>Account</th><th>Bank</th><th>Date</th><th>Concept</th><th>Amount</th><th>Side</th></tr></thead>
        <tbody>${partners || '<tr><td colspan="7">No movement can be the other side.</td></tr>'}</tbody>
      </table>
      <button type="button" data-link-partner>Link</button> <button type="button" data-cancel-partners>Cancel</button>
    </div>`;
  }

  async function findPartners(kind, layer) {
    const current = filters(kind, layer);
    const params = new URLSearchParams({ row_hash: current.selected });
    if (current.partnerQ) params.set("q", current.partnerQ);
    try {
      const found = await statementApi(`/transfers/partners?${params.toString()}`);
      current.partners = found.partners || [];
      drawRows(kind, layer);
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  function drawRows(kind, layer) {
    const current = filters(kind, layer);
    const mount = document.getElementById(`dim-${kind}-${layer}`);
    if (!mount) return;
    const attrs = attributes();
    const selected = current.rows.find((row) => row.row_hash === current.selected);
    const body = current.rows
      .map((row) => `
        <tr class="${row.row_hash === current.selected ? "selected" : ""}">
          <td><input type="radio" name="pick-${kind}-${layer}" value="${dimEsc(row.row_hash)}" ${row.row_hash === current.selected ? "checked" : ""} aria-label="Select movement" /></td>
          <td>${dimEsc(row.account_number)}</td>
          <td>${dimEsc(row.bank_name)}</td>
          <td>${dimEsc(row.txn_date)}</td>
          <td>${dimEsc(row.concept)}${row.entry_source && row.entry_source !== "upload" ? ` <span class="tag">${dimEsc(row.entry_source)}</span>` : ""}</td>
          <td class="num">${money(row.abonos)}</td>
          <td class="num">${money(row.cargos)}</td>
          ${attrs.map((attribute) => `<td>${dimEsc(shownAttribute(row, attribute))}</td>`).join("")}
          <td>${kind === "asset" ? `<span class="muted">${dimEsc(row.source_profile || "")}</span>` : transferBadge(row)}</td>
        </tr>`)
      .join("");
    mount.innerHTML = `
      <form class="dim-filter" data-filter>
        <label>From <input type="date" name="from" value="${dimEsc(current.from)}" /></label>
        <label>To <input type="date" name="to" value="${dimEsc(current.to)}" /></label>
        <label>Name <input type="search" name="q" value="${dimEsc(current.q)}" placeholder="Concept, bank, account or attribute" /></label>
        <button type="submit">Filter</button>
        <span class="muted">${current.rows.length} of ${current.total} shown</span>
      </form>
      <table class="compact">
        <thead><tr><th></th><th>Account</th><th>Bank</th><th>Date</th><th>Concept</th><th>Abonos</th><th>Cargos</th>${attrs.map((attribute) => `<th>${dimEsc(attribute.label)}</th>`).join("")}<th>${kind === "asset" ? "Source" : "Transfer"}</th></tr></thead>
        <tbody>${body || `<tr><td colspan="${7 + attrs.length}">No movements match.</td></tr>`}</tbody>
      </table>
      ${selected ? `
        <form class="dim-edit" data-edit>
          <p><strong>${dimEsc(selected.txn_date)}</strong> · ${dimEsc(selected.concept)}</p>
          ${(() => {
            let parentItemId = null;
            return attrs.map((attribute, index) => {
              const field = attributeField(attribute, selected, parentItemId);
              parentItemId = attribute.mode === "list" ? selected[`${attribute.field}_item_id`] || null : null;
              return field;
            }).join("");
          })()}
          <button type="submit">Save</button>
        </form>
        ${transferEditor(kind, layer, selected)}` : '<p class="muted">Select one row to edit its attributes or link it as a transfer.</p>'}
    `;
    mount.querySelector("[data-filter]").addEventListener("submit", (event) => {
      event.preventDefault();
      const form = new FormData(event.target);
      current.from = String(form.get("from") || "");
      current.to = String(form.get("to") || "");
      current.q = String(form.get("q") || "").trim();
      current.selected = null;
      current.partners = null;
      loadRows(kind, layer);
    });
    mount.querySelectorAll('input[name^="pick-"]').forEach((input) => {
      input.addEventListener("change", () => {
        current.selected = input.value;
        current.partners = null;
        current.partnerQ = "";
        drawRows(kind, layer);
      });
    });
    mount.querySelectorAll("[data-list-field]").forEach((select) => {
      const extra = select.parentElement.querySelector(`[name="${select.name}__new"]`);
      select.addEventListener("change", () => {
        refillNestedSelects(select.closest("form"));
        extra.hidden = select.value !== "__new__";
        if (!extra.hidden) extra.focus();
      });
    });
    const edit = mount.querySelector("[data-edit]");
    if (edit) {
      edit.addEventListener("submit", async (event) => {
        event.preventDefault();
        const form = new FormData(event.target);
        const values = {};
        for (const attribute of attrs) {
          if (!event.target.querySelector(`[name="${attribute.field}"]`)) continue;
          const raw = String(form.get(attribute.field) || "");
          if (attribute.mode === "list" && attribute.list_id) {
            if (raw === "__new__") {
              const name = String(form.get(`${attribute.field}__new`) || "").trim();
              values[attribute.field] = name ? { new_item: name } : null;
            } else if (raw === "") {
              const keepsText = !selected[`${attribute.field}_item_id`] && selected[attribute.field];
              if (!keepsText || edit.querySelector(`[name="${attribute.field}"]`).selectedIndex !== 0) {
                values[attribute.field] = null;
              }
            } else {
              values[attribute.field] = { item_id: Number(raw) };
            }
          } else {
            values[attribute.field] = raw;
          }
        }
        try {
          await statementApi("/dimensions", {
            method: "POST",
            body: JSON.stringify({ row_hash: current.selected, values }),
          });
          setStatus("Saved.");
          await Promise.all([loadSummary(), loadCatalog()]);
          refreshSummaryLabels();
          await loadRows(kind, layer);
        } catch (error) {
          setStatus(error.message, true);
        }
      });
    }
    const find = mount.querySelector("[data-find-partners]");
    if (find) find.addEventListener("click", () => findPartners(kind, layer));
    const search = mount.querySelector("[data-partner-search]");
    if (search) {
      search.addEventListener("submit", (event) => {
        event.preventDefault();
        current.partnerQ = String(new FormData(event.target).get("q") || "").trim();
        findPartners(kind, layer);
      });
    }
    const cancel = mount.querySelector("[data-cancel-partners]");
    if (cancel) {
      cancel.addEventListener("click", () => {
        current.partners = null;
        drawRows(kind, layer);
      });
    }
    const linkButton = mount.querySelector("[data-link-partner]");
    if (linkButton) {
      linkButton.addEventListener("click", () => {
        const picked = mount.querySelector(`input[name="partner-${kind}-${layer}"]:checked`);
        if (!picked) {
          setStatus("Pick the other movement first.", true);
          return;
        }
        current.partners = null;
        link(current.selected, picked.value);
      });
    }
    mount.querySelectorAll("[data-unlink]").forEach((button) => {
      button.addEventListener("click", () => unlink(button.dataset.unlink));
    });
    mount.querySelectorAll("[data-confirm-link]").forEach((button) => {
      button.addEventListener("click", async () => {
        try {
          await statementApi(`/transfers/${encodeURIComponent(button.dataset.confirmLink)}/confirm`, { method: "POST", body: "{}" });
          await reloadAfterTransferChange("Link kept.");
        } catch (error) {
          setStatus(error.message, true);
        }
      });
    });
  }

  function refreshSummaryLabels() {
    root.querySelectorAll("details.dim-group[data-kind]").forEach((element) => {
      const group = DIMENSION_GROUPS.find((item) => item.kind === element.dataset.kind);
      element.querySelector(":scope > summary").innerHTML = `<strong>${group.title}</strong> · ${pctLabel(summary[group.kind])}`;
    });
    root.querySelectorAll("details.dim-layer").forEach((element) => {
      const { kind, layer } = element.dataset;
      element.querySelector(":scope > summary").innerHTML =
        `${layerTitle(kind, layer)} · ${pctLabel(summary[kind]?.layers?.[layer])}`;
    });
  }

  root.innerHTML = "<p>Loading dimensions…</p>";
  Promise.all([loadSummary(), loadCatalog(), loadTransfers()])
    .then(draw)
    .catch((error) => {
      root.innerHTML = "";
      setStatus(error.message, true);
    });
  return session;
}

// sql/016: Lists page. Lists are shared by debit and credit; each attribute slot is free
// text or bound to one list (its current values become items of that list).
function renderLists(root, session) {
  const status = document.getElementById("status");
  let catalog = { attributes: DEFAULT_ATTRIBUTES, lists: [] };

  function setStatus(message, isError = false) {
    if (status) {
      status.textContent = message;
      status.className = isError ? "error" : "";
    }
  }

  async function load() {
    catalog = (await statementApi("/lists")) || catalog;
    draw();
  }

  async function act(path, body, message) {
    try {
      await statementApi(path, { method: "POST", body: JSON.stringify(body) });
      setStatus(message);
      await load();
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  function draw() {
    const openLists = new Set([...root.querySelectorAll("details.list-card[open]")].map((element) => element.dataset.listId));
    const slots = (catalog.attributes || DEFAULT_ATTRIBUTES)
      .map((attribute) => `
        <form class="slot-form" data-slot="${attribute.slot}">
          <strong>${dimEsc(attribute.label)}</strong>
          <span class="muted">${attribute.mode === "text" ? "Free text" : (attribute.list_name || "Assigned from your lists")}</span>
          <label>Label <input name="label" maxlength="60" value="${dimEsc(attribute.custom_label || "")}" placeholder="${dimEsc(attribute.label)}" /></label>
          <button type="submit">Rename</button>
        </form>`)
      .join("");
    const subItems = (nested, parentItem) => (nested?.items || []).filter((item) => item.parent_item_id === parentItem.item_id);
    const lists = (catalog.lists || []).filter((list) => !list.parent_list_id)
      .map((list) => {
        const nested = (catalog.lists || []).find((item) => item.parent_list_id === list.list_id);
        const roots = list.items.filter((item) => !item.parent_item_id);
        return `
        <details class="list-card" data-list-id="${dimEsc(list.list_id)}" ${openLists.has(String(list.list_id)) ? "open" : ""}>
          <summary><strong>${dimEsc(list.list_name)}</strong> · ${roots.length} item(s)${nested ? ` · nested list ${dimEsc(nested.list_name)}` : ""}${list.slots.length ? ` · used by ${list.slots.map((slot) => `attribute_${slot}`).join(", ")}` : ""}</summary>
          <form class="inline" data-rename-list="${dimEsc(list.list_id)}">
            <label>Name <input name="list_name" maxlength="100" value="${dimEsc(list.list_name)}" required /></label>
            <button type="submit">Rename list</button>
          </form>
          ${nested ? `
            <form class="inline" data-rename-list="${dimEsc(nested.list_id)}">
              <label>Nested list <input name="list_name" maxlength="100" value="${dimEsc(nested.list_name)}" required /></label>
              <button type="submit">Rename nested list</button>
            </form>` : `
            <form class="inline" data-add-nested="${dimEsc(list.list_id)}">
              <label>Nested list <input name="list_name" maxlength="100" required placeholder="Place" /></label>
              <button type="submit">Add nested list</button>
            </form>`}
          <table class="compact">
            <thead><tr><th>Item</th><th>Movements</th><th></th></tr></thead>
            <tbody>${roots.map((item) => `
              <tr>
                <td><form class="inline" data-rename-item="${dimEsc(item.item_id)}" id="item-${dimEsc(item.item_id)}"><input name="item_name" maxlength="500" value="${dimEsc(item.item_name)}" required aria-label="Item name" /></form></td>
                <td>${dimEsc(item.used)}</td>
                <td><button type="submit" form="item-${dimEsc(item.item_id)}">Rename</button></td>
              </tr>
              ${nested ? `<tr><td colspan="3">
                <p class="muted">Sub-items of ${dimEsc(item.item_name)}</p>
                ${subItems(nested, item).map((sub) => `
                  <form class="inline" data-rename-item="${dimEsc(sub.item_id)}" id="item-${dimEsc(sub.item_id)}">
                    <input name="item_name" maxlength="500" value="${dimEsc(sub.item_name)}" required aria-label="Sub-item name" />
                    <button type="submit">Rename</button>
                    <span class="muted">${dimEsc(sub.used)} movement(s)</span>
                  </form>`).join("") || '<p class="muted">No sub-items yet.</p>'}
                <form class="inline" data-add-sub="${dimEsc(nested.list_id)}" data-parent-item="${dimEsc(item.item_id)}">
                  <label>New sub-item <input name="item_name" maxlength="500" required /></label>
                  <button type="submit">Add</button>
                </form>
              </td></tr>` : ""}`).join("") || '<tr><td colspan="3">No items yet.</td></tr>'}</tbody>
          </table>
          <form class="inline" data-add-item="${dimEsc(list.list_id)}">
            <label>New item <input name="item_name" maxlength="500" required /></label>
            <button type="submit">Add</button>
          </form>
        </details>`;
      })
      .join("");
    root.innerHTML = `
      <p class="lede">Lists give your attributes fixed choices. Renaming an item renames it on every movement and in Google Sheets.</p>
      <section class="card">
        <h2>Attributes</h2>
        <p class="muted">Binding an attribute to a list turns the values already typed into items of that list. Switching back to free text keeps the names as text.</p>
        ${slots}
      </section>
      <section class="card">
        <h2>Lists</h2>
        <form class="inline" id="create-list">
          <label>New list <input name="list_name" maxlength="100" required placeholder="Categories" /></label>
          <button type="submit">Create list</button>
        </form>
        ${lists || '<p class="muted">No lists yet.</p>'}
      </section>
    `;
    root.querySelector("#create-list").addEventListener("submit", (event) => {
      event.preventDefault();
      const name = String(new FormData(event.target).get("list_name") || "").trim();
      act("/lists", { list_name: name }, "List created.");
    });
    root.querySelectorAll("[data-slot]").forEach((form) => {
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        const data = new FormData(form);
        act(
          "/attribute-settings",
          { slot: Number(form.dataset.slot), label: String(data.get("label") || ""), list_id: null },
          "Label saved.",
        );
      });
    });
    root.querySelectorAll("[data-add-nested]").forEach((form) => {
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        act(`/lists/${form.dataset.addNested}/nested`, { list_name: String(new FormData(form).get("list_name") || "") }, "Nested list added.");
      });
    });
    root.querySelectorAll("[data-add-sub]").forEach((form) => {
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        act(
          `/lists/${form.dataset.addSub}/items`,
          { item_name: String(new FormData(form).get("item_name") || ""), parent_item_id: Number(form.dataset.parentItem) },
          "Sub-item added.",
        );
      });
    });
    root.querySelectorAll("[data-rename-list]").forEach((form) => {
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        act(`/lists/${form.dataset.renameList}`, { list_name: String(new FormData(form).get("list_name") || "") }, "List renamed.");
      });
    });
    root.querySelectorAll("[data-add-item]").forEach((form) => {
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        act(`/lists/${form.dataset.addItem}/items`, { item_name: String(new FormData(form).get("item_name") || "") }, "Item added.");
      });
    });
    root.querySelectorAll("[data-rename-item]").forEach((form) => {
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        act(`/list-items/${form.dataset.renameItem}`, { item_name: String(new FormData(form).get("item_name") || "") }, "Item renamed.");
      });
    });
  }

  root.innerHTML = "<p>Loading lists…</p>";
  load().catch((error) => {
    root.innerHTML = "";
    setStatus(error.message, true);
  });
  return session;
}

function apiResetText(usage) {
  if (!usage?.resets_at) return "";
  const when = new Date(usage.resets_at);
  if (Number.isNaN(when.getTime())) return String(usage.resets_at);
  return when.toLocaleString("es-MX", {
    timeZone: "America/Mexico_City",
    dateStyle: "medium",
    timeStyle: "short",
  }) + " (Mexico City)";
}

function renderApiTokens(root, session) {
  const status = document.getElementById("status");
  const cfg = window.STRM_CONFIG || {};
  const graphqlUrl = cfg.graphqlUrl || (cfg.apiUrl ? `${cfg.apiUrl}/graphql` : "");
  let created = null;

  function setStatus(message, isError = false) {
    if (status) {
      status.textContent = message;
      status.className = isError ? "error" : "";
    }
  }

  async function load() {
    const listed = await statementApi("/api-tokens");
    draw(listed.tokens || [], listed.usage || {});
  }

  function draw(tokens, usage) {
    const per = usage.window === "day" ? "day" : "week";
    const recent = (usage.recent || [])
      .map((call) => `<tr><td>${dimEsc(new Date(call.called_at).toLocaleString("es-MX", { timeZone: "America/Mexico_City" }))}</td><td>${dimEsc(call.status)}</td><td>${dimEsc(call.rows_returned ?? "")}</td></tr>`)
      .join("");
    const rows = tokens
      .map((token) => `
        <tr>
          <td>${dimEsc(token.token_name)}</td>
          <td><code>${dimEsc(token.token_prefix)}…</code></td>
          <td>${dimEsc(token.created_at ? new Date(token.created_at).toLocaleDateString("es-MX") : "")}</td>
          <td>${dimEsc(token.last_used_at ? new Date(token.last_used_at).toLocaleString("es-MX", { timeZone: "America/Mexico_City" }) : "Never")}</td>
          <td>${token.revoked_at ? "Revoked" : `<button type="button" data-revoke="${dimEsc(token.token_id)}">Revoke</button>`}</td>
        </tr>`)
      .join("");
    root.innerHTML = `
      <section class="card">
        <h2>API usage</h2>
        <p><strong>${dimEsc(usage.used ?? 0)}</strong> of <strong>${dimEsc(usage.limit ?? 0)}</strong> calls used ${per === "day" ? "today" : "this week"}
          on the ${dimEsc(usage.plan_name || usage.plan_code || "")} plan. Resets at ${dimEsc(apiResetText(usage))}.</p>
        <p class="muted">One "Refresh all" in Google Sheets is one call, whatever the number of tabs. Up to ${dimEsc(usage.max_rows ?? "")} rows per call.</p>
        ${recent ? `<table class="compact"><thead><tr><th>Called at</th><th>Result</th><th>Rows</th></tr></thead><tbody>${recent}</tbody></table>` : ""}
      </section>
      <section class="card">
        <h2>Google Sheets</h2>
        <p>GraphQL URL: <code>${dimEsc(graphqlUrl || "not published yet")}</code></p>
        <p class="muted">Paste <code>integrations/google_sheets/Code.gs</code> into Extensions › Apps Script, then use the Bank data menu to set this URL and a token.</p>
      </section>
      <section class="card">
        <h2>Tokens</h2>
        ${created ? `<div class="notice"><p>Copy this token now. It is shown only once.</p><p><code id="new-token">${dimEsc(created.token)}</code> <button type="button" id="copy-token">Copy</button></p></div>` : ""}
        <form id="create-token">
          <label>Name <input name="token_name" maxlength="60" value="Google Sheets" /></label>
          <button type="submit">Create read-only token</button>
        </form>
        <table class="compact">
          <thead><tr><th>Name</th><th>Starts with</th><th>Created</th><th>Last used</th><th></th></tr></thead>
          <tbody>${rows || '<tr><td colspan="5">No tokens yet.</td></tr>'}</tbody>
        </table>
      </section>
    `;
    root.querySelector("#create-token").addEventListener("submit", async (event) => {
      event.preventDefault();
      const name = String(new FormData(event.target).get("token_name") || "").trim();
      try {
        created = await statementApi("/api-tokens", { method: "POST", body: JSON.stringify({ token_name: name }) });
        setStatus("Token created.");
        await load();
      } catch (error) {
        setStatus(error.message, true);
      }
    });
    const copy = root.querySelector("#copy-token");
    if (copy) {
      copy.addEventListener("click", () => navigator.clipboard?.writeText(created.token));
    }
    root.querySelectorAll("[data-revoke]").forEach((button) => {
      button.addEventListener("click", async () => {
        if (!window.confirm("Revoke this token? Sheets using it stop refreshing.")) return;
        try {
          await statementApi(`/api-tokens/${encodeURIComponent(button.dataset.revoke)}`, { method: "DELETE" });
          created = null;
          setStatus("Token revoked.");
          await load();
        } catch (error) {
          setStatus(error.message, true);
        }
      });
    });
  }

  root.innerHTML = "<p>Loading tokens…</p>";
  load().catch((error) => {
    root.innerHTML = "";
    setStatus(error.message, true);
  });
  return session;
}

// Signed-in (non-admin) shell: Statements, Investments & Assets, Dimensions, Lists, API tokens.
const USER_PAGES = [
  { id: "statements", title: "Statements" },
  { id: "assets", title: "Investments & Assets" },
  { id: "dimensions", title: "Dimensions" },
  { id: "lists", title: "Lists" },
  { id: "api-tokens", title: "API tokens" },
];

function renderUserPages(root, session) {
  root.classList.add("wide");
  root.innerHTML = `
    <nav class="ribbon" aria-label="Pages">
      <span id="user-pages"></span>
      <button type="button" id="logout">Sign out</button>
    </nav>
    <h1 id="heading">Statements</h1>
    <p id="status" role="status"></p>
    <div id="panel"></div>
  `;
  document.getElementById("logout").addEventListener("click", session.logout);
  const panel = document.getElementById("panel");
  const heading = document.getElementById("heading");

  function open(id) {
    const page = USER_PAGES.find((item) => item.id === id) || USER_PAGES[0];
    heading.textContent = page.title;
    document.getElementById("status").textContent = "";
    document.getElementById("user-pages").innerHTML = USER_PAGES.map(
      (item) => `<button type="button" data-page="${item.id}" ${item.id === page.id ? 'aria-current="page"' : ""}>${dimEsc(item.title)}</button>`,
    ).join("");
    document.querySelectorAll("[data-page]").forEach((button) => {
      button.addEventListener("click", () => open(button.dataset.page));
    });
    if (page.id === "dimensions") {
      renderDimensions(panel, session);
    } else if (page.id === "lists") {
      renderLists(panel, session);
    } else if (page.id === "api-tokens") {
      renderApiTokens(panel, session);
    } else if (page.id === "assets") {
      window.renderAssets(panel, session);
    } else {
      window.renderStatements(panel, { ...session, embedded: true });
    }
  }

  open("statements");
}

window.renderDimensions = renderDimensions;
window.renderApiTokens = renderApiTokens;
window.renderLists = renderLists;
window.renderUserPages = renderUserPages;
