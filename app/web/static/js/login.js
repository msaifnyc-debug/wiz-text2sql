const el = (id) => document.getElementById(id);
const err = el("error");

function show(which) {
  const login = which === "login";
  el("tab-login").classList.toggle("active", login);
  el("tab-signup").classList.toggle("active", !login);
  el("login-form").classList.toggle("hidden", !login);
  el("signup-form").classList.toggle("hidden", login);
  err.textContent = "";
}
el("tab-login").onclick = () => show("login");
el("tab-signup").onclick = () => show("signup");

async function post(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (res.ok) {
    window.location.href = "/console";
    return;
  }
  const data = await res.json().catch(() => ({}));
  err.textContent = data.detail || "Something went wrong.";
}

el("login-form").addEventListener("submit", (e) => {
  e.preventDefault();
  post("/login", { email: el("login-email").value, password: el("login-password").value });
});

el("signup-form").addEventListener("submit", (e) => {
  e.preventDefault();
  post("/signup", {
    username: el("signup-username").value,
    email: el("signup-email").value,
    password: el("signup-password").value,
  });
});
