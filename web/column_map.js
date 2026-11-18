// sql/018: column map wizard for a statement upload whose file matches no built-in bank
// profile and no saved map of the account. It asks for the date, the concept (one or more
// columns joined), the cargo and the abono columns; every other column is ignored. The
// same column for cargo and abono means one signed amount: positive = abono, negative =
// cargo. The map is saved on the account and found again by the file's header row.
// Uses the same mapping keys and database code as the Investments & Assets upload (sql/017).

function strmMapEsc(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

const STRM_MAP_DATE_FORMATS = [
  ["DMY", "Day/Month/Year"],
  ["MDY", "Month/Day/Year"],
  ["YMD", "Year-Month-Day"],
];

// container: element to draw into. api: (path, options) => Promise (statementApi).
// onSave(mapping, templateName) uploads the file with the map; onCancel closes the wizard.
function strmColumnMapWizard({ container, api, accountId, csv, fileName, onSave, onCancel }) {
  const state = { mapping: { header_row: 1, date_format: "DMY" }, concepts: [], preview: null, headers: [] };

  function select(name, value, noneLabel) {
    const options = state.headers
      .filter((header) => header !== "")
      .map((header) => `<option value="${strmMapEsc(header)}" ${header === value ? "selected" : ""}>${strmMapEsc(header)}</option>`)
      .join("");
    return `<select name="${name}"><option value="">${strmMapEsc(noneLabel)}</option>${options}</select>`;
  }

  function conceptExpression() {
    return state.concepts.length ? state.concepts.join(" || ' ' || ") : null;
  }

  function readForm(form) {
    const values = Object.fromEntries(new FormData(form).entries());
    const pick = (name) => (values[name] ? String(values[name]) : null);
    state.concepts = [...form.querySelectorAll("input[name=concept_col]:checked")].map((input) => input.value);
    state.mapping = {
      header_row: Number(values.header_row) || 1,
      date_format: pick("date_format") || "DMY",
      txn_date: pick("txn_date"),
      concept: conceptExpression(),
      cargo: pick("cargo"),
      abono: pick("abono"),
    };
    return state.mapping;
  }

  function draw() {
    const preview = state.preview;
    const totals = preview?.totals;
    const rows = (preview?.rows || [])
      .slice(0, 8)
      .map(
        (row) => `<tr><td>${strmMapEsc(row.txn_date || "")}</td><td>${strmMapEsc(row.concept || "")}</td>
          <td class="num">${row.status === "ok" ? strmMapEsc(row.abonos) : ""}</td>
          <td class="num">${row.status === "ok" ? strmMapEsc(row.cargos) : `<span class="muted">${strmMapEsc(row.reason || "")}</span>`}</td></tr>`,
      )
      .join("");
    const concepts = state.headers
      .filter((header) => header !== "")
      .map(
        (header) =>
          `<label class="inline"><input type="checkbox" name="concept_col" value="${strmMapEsc(header)}" ${state.concepts.includes(header) ? "checked" : ""}/> ${strmMapEsc(header)}</label>`,
      )
      .join(" ");
    container.innerHTML = `
      <form class="add-form column-map" data-column-map>
        <p><strong>Map the columns</strong> · ${strmMapEsc(fileName)} <span class="muted">This file matches no known bank layout. Pick the columns once; the map is saved for this account and used for the next files with the same header.</span></p>
        <label>Header line <input type="number" name="header_row" min="1" max="50" value="${strmMapEsc(state.mapping.header_row || 1)}" /></label>
        <label>Date ${select("txn_date", state.mapping.txn_date, "— pick —")}</label>
        <label>Date format <select name="date_format">${STRM_MAP_DATE_FORMATS.map(([value, label]) => `<option value="${value}" ${value === state.mapping.date_format ? "selected" : ""}>${label}</option>`).join("")}</select></label>
        <fieldset><legend>Concept (tick one or more; they are joined)</legend>${concepts}</fieldset>
        <label>Cargo (money out) ${select("cargo", state.mapping.cargo, "— none —")}</label>
        <label>Abono (money in) ${select("abono", state.mapping.abono, "— none —")}</label>
        <p class="muted">${preview?.kind === "asset" ? "On an asset account a negative amount is stored as a positive cargo." : "Same column for both = one signed amount: positive is an abono, negative a cargo. A debit account stores that cargo negative."}</p>
        <label>Save the map as <input name="template_name" maxlength="60" placeholder="e.g. Bank export" /></label>
        <button type="submit" name="action" value="preview">Preview</button>
        <button type="button" data-map-cancel>Cancel</button>
      </form>
      ${preview && !preview.ready ? `<p class="muted">Pick the date column, the concept and at least one amount column, then Preview.</p>` : ""}
      ${preview?.ready ? `<p>${strmMapEsc(totals.ok)} rows read, ${strmMapEsc(totals.skipped)} skipped · abonos ${strmMapEsc(totals.abonos)} · cargos ${strmMapEsc(totals.cargos)}</p>
        <table class="compact"><thead><tr><th>Date</th><th>Concept</th><th>Abono</th><th>Cargo</th></tr></thead><tbody>${rows}</tbody></table>` : ""}
      ${preview?.ready && totals?.ok ? `<p><button type="button" data-map-save>Save these ${strmMapEsc(totals.ok)} rows</button> <span class="muted">Nothing is stored until you click this.</span></p>` : ""}
    `;
    const form = container.querySelector("[data-column-map]");
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      await run(readForm(form));
    });
    form.addEventListener("change", async (event) => {
      if (event.target.name !== "template_name") {
        await run(readForm(form));
      }
    });
    form.querySelector("[data-map-cancel]").addEventListener("click", () => {
      container.innerHTML = "";
      onCancel?.();
    });
    container.querySelector("[data-map-save]")?.addEventListener("click", async (event) => {
      event.target.disabled = true;
      event.target.textContent = "Saving…";
      const mapping = readForm(form);
      const name = String(new FormData(form).get("template_name") || "").trim() || null;
      await onSave(mapping, name);
      container.innerHTML = "";
    });
  }

  async function run(mapping) {
    state.preview = await api("/statements/preview", {
      method: "POST",
      body: JSON.stringify({ account_id: accountId, csv, mapping }),
    });
    state.headers = state.preview.headers || [];
    if (!state.preview.ready && state.preview.suggested_mapping && !mapping.txn_date) {
      const guess = state.preview.suggested_mapping;
      state.mapping = { ...state.mapping, ...guess };
      if (typeof guess.concept === "string" && state.headers.includes(guess.concept)) {
        state.concepts = [guess.concept];
      } else {
        const named = state.headers.find((header) => /concep|descrip|detalle|movimiento/i.test(header));
        if (named) {
          state.concepts = [named];
        }
      }
      if (state.mapping.txn_date && state.concepts.length) {
        state.mapping.concept = conceptExpression();
        return run(state.mapping);
      }
    }
    draw();
  }

  return run(state.mapping);
}

window.strmColumnMapWizard = strmColumnMapWizard;
