const el = (id) => document.getElementById(id);
const statusEl = el("status");

async function api(url, opts = {}) {
  const res = await fetch(url, opts);
  if (res.status === 401) {
    window.location.href = "/";
    throw new Error("unauthorized");
  }
  return res;
}

function esc(v) {
  return String(v === null || v === undefined ? "" : v)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

async function loadDbs(selectId) {
  const res = await api("/api/dbs");
  const { databases } = await res.json();
  const sel = el("db-select");
  sel.innerHTML = "";
  if (!databases.length) {
    const o = document.createElement("option");
    o.textContent = "Upload a .db to begin";
    o.value = "";
    sel.appendChild(o);
    return;
  }
  for (const d of databases) {
    const o = document.createElement("option");
    o.value = d.db_id;
    o.textContent = `${d.filename} (${d.tables.length} tables)`;
    sel.appendChild(o);
  }
  if (selectId) sel.value = selectId;
}

el("file").addEventListener("change", async (e) => {
  const file = e.target.files[0];
  if (!file) return;
  statusEl.textContent = `Uploading ${file.name}...`;
  const fd = new FormData();
  fd.append("file", file);
  const res = await api("/api/upload", { method: "POST", body: fd });
  if (res.ok) {
    const d = await res.json();
    statusEl.textContent = `Loaded ${d.filename}: ${d.tables.join(", ")}`;
    await loadDbs(d.db_id);
  } else {
    const err = await res.json().catch(() => ({}));
    statusEl.textContent = `Upload rejected: ${err.detail || "invalid file"}`;
  }
  e.target.value = "";
});

el("ask-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const db_id = el("db-select").value;
  const question = el("question").value.trim();
  if (!db_id) { statusEl.textContent = "Upload and select a database first."; return; }
  if (!question) return;

  statusEl.textContent = "Thinking...";
  el("sql-panel").classList.add("hidden");
  el("result-panel").classList.add("hidden");

  const res = await api("/api/ask", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ db_id, question }),
  });
  const data = await res.json();
  if (!res.ok) { statusEl.textContent = data.detail || "Request failed."; return; }
  statusEl.textContent = "";
  renderResult(data);
  loadHistory();
});

function renderResult(data) {
  // Conversational reply (no SQL run).
  if (data.kind === "reply") {
    el("result-title").textContent = "Answer";
    el("result").innerHTML = `<p style="padding:12px">${esc(data.reply)}</p>`;
    el("latency").textContent = `${data.latency_s}s · no query run`;
    el("result-panel").classList.remove("hidden");
    return;
  }

  if (data.sql) {
    el("sql").textContent = data.sql;
    const badges = [];
    if (data.repaired) badges.push("self-corrected");
    if (data.failed_over) badges.push("failover");
    badges.push(data.model.split("/").pop());
    el("sql-badges").innerHTML = badges.map((b) => `<span class="badge">${esc(b)}</span>`).join("");
    el("sql-panel").classList.remove("hidden");
  }

  if (!data.success) {
    el("result-title").textContent = "No results";
    el("result").innerHTML = `<p style="padding:12px;color:var(--error)">${esc(data.error)}</p>`;
  } else if (!data.rows.length) {
    el("result-title").textContent = "Results";
    el("result").innerHTML = `<p style="padding:12px" class="muted">Query ran successfully but returned 0 rows.</p>`;
  } else {
    el("result-title").textContent = `Results (${data.row_count})`;
    el("result").innerHTML = buildTable(data.columns, data.rows);
  }
  el("latency").textContent =
    `${data.latency_s}s · ${data.attempts} attempt(s) · ${data.prompt_tokens}+${data.completion_tokens} tokens`;
  el("result-panel").classList.remove("hidden");
}

function buildTable(columns, rows) {
  const head = columns.map((c) => `<th>${esc(c)}</th>`).join("");
  const body = rows.slice(0, 200).map(
    (r) => `<tr>${columns.map((c) => `<td>${esc(r[c])}</td>`).join("")}</tr>`
  ).join("");
  return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

async function loadHistory() {
  const res = await api("/api/history");
  const { history } = await res.json();
  el("history-list").innerHTML = history.map(
    (h) => `<li data-q="${esc(h.question)}">${h.success ? "" : "⚠ "}${esc(h.question)}</li>`
  ).join("");
  document.querySelectorAll("#history-list li").forEach((li) => {
    li.onclick = () => { el("question").value = li.getAttribute("data-q"); el("question").focus(); };
  });
}

el("logout").onclick = async () => {
  await fetch("/logout", { method: "POST" });
  window.location.href = "/";
};

loadDbs();
loadHistory();
