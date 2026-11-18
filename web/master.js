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
    id: "dimensions",
    title: "Dimensions",
    blurb: "Attributes on each movement, how many movements have them, and transfers between accounts.",
    listed: true,
  },
  {
    id: "lists",
    title: "Lists",
    blurb: "Lists of items for attributes (shared by debit and credit), and how each attribute works.",
    listed: true,
  },
  {
    id: "api-tokens",
    title: "API tokens",
    blurb: "Read-only tokens for the Google Sheets GraphQL API and this plan's API usage.",
    listed: true,
  },
];
// sql/018: the "Data admin" view is gone. Banks are added and renamed on the Statements
// page; statement layouts come from built-in profiles or a column map saved per account.

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
    if (pageId === "dimensions") {
      window.renderDimensions(panel, session);
      return;
    }
    if (pageId === "lists") {
      window.renderLists(panel, session);
      return;
    }
    if (pageId === "api-tokens") {
      window.renderApiTokens(panel, session);
      return;
    }
    pageId = "";
    drawList();
  }

  function openPage(id) {
    pageId = id;
    setStatus("");
    draw();
  }

  draw();
}

window.isAdminClaim = isAdmin;
window.renderMasterBanking = renderMasterBanking;
