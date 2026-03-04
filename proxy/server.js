"use strict";

const http = require("http");
const httpProxy = require("http-proxy");
const jwt = require("jsonwebtoken");

const PROXY_PORT = Number.parseInt(process.env.PROXY_PORT || "8443", 10);
const CODE_SERVER_PORT = Number.parseInt(process.env.CODE_SERVER_PORT || "8080", 10);
const TARGET_URL = process.env.TARGET_URL || `http://127.0.0.1:${CODE_SERVER_PORT}`;
const JWT_SECRET = process.env.JWT_SECRET || "HieuDz@999";
const CODE_SERVER_PASSWORD = process.env.CODE_SERVER_PASSWORD || "HieuDz@999";
const TOKEN_TTL = process.env.TOKEN_TTL || "12h";
const COOKIE_NAME = process.env.JWT_COOKIE_NAME || "token";
const TRUST_X_FORWARDED_PROTO = (process.env.TRUST_X_FORWARDED_PROTO || "true").toLowerCase() !== "false";

const proxy = httpProxy.createProxyServer({
  target: TARGET_URL,
  // Keep the original Host header so code-server origin checks pass behind tunnels/proxies.
  changeOrigin: false,
  ws: true,
  xfwd: true
});

function parseCookies(cookieHeader) {
  if (!cookieHeader) {
    return {};
  }

  return cookieHeader
    .split(";")
    .map((part) => part.trim())
    .filter(Boolean)
    .reduce((acc, part) => {
      const idx = part.indexOf("=");
      if (idx <= 0) {
        return acc;
      }

      const key = part.slice(0, idx).trim();
      const rawValue = part.slice(idx + 1).trim();
      try {
        acc[key] = decodeURIComponent(rawValue);
      } catch (_) {
        acc[key] = rawValue;
      }
      return acc;
    }, {});
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > 1024 * 1024) {
        reject(new Error("Payload too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function parseLoginBody(req, body) {
  const contentType = (req.headers["content-type"] || "").toLowerCase();
  if (contentType.includes("application/json")) {
    const parsed = JSON.parse(body || "{}");
    return String(parsed.password || "");
  }

  if (contentType.includes("application/x-www-form-urlencoded")) {
    const params = new URLSearchParams(body || "");
    return String(params.get("password") || "");
  }

  return "";
}

function getRequestToken(req) {
  const cookies = parseCookies(req.headers.cookie || "");
  if (cookies[COOKIE_NAME]) {
    return cookies[COOKIE_NAME];
  }

  const authHeader = req.headers.authorization || "";
  if (authHeader.startsWith("Bearer ")) {
    return authHeader.slice("Bearer ".length).trim();
  }

  return "";
}

function verifyJwtFromRequest(req) {
  const token = getRequestToken(req);
  if (!token) {
    return null;
  }

  try {
    return jwt.verify(token, JWT_SECRET);
  } catch (_) {
    return null;
  }
}

function shouldTreatAsBrowser(req) {
  const accept = (req.headers.accept || "").toLowerCase();
  return accept.includes("text/html");
}

function sendUnauthorized(req, res) {
  if (shouldTreatAsBrowser(req)) {
    res.writeHead(302, { Location: "/login" });
    res.end();
    return;
  }

  res.writeHead(401, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify({ error: "unauthorized" }));
}

function buildCookieHeader(req, token) {
  const forwardedProto = String(req.headers["x-forwarded-proto"] || "").toLowerCase();
  const secure = TRUST_X_FORWARDED_PROTO ? forwardedProto.includes("https") : false;
  const parts = [
    `${COOKIE_NAME}=${encodeURIComponent(token)}`,
    "Path=/",
    "HttpOnly",
    "SameSite=Strict",
    "Max-Age=43200"
  ];
  if (secure) {
    parts.push("Secure");
  }
  return parts.join("; ");
}

function clearCookieHeader() {
  return `${COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0`;
}

function sendLoginPage(res, message) {
  const escapedMessage = message ? String(message).replace(/[<>&]/g, "") : "";
  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Code Server Login</title>
  <style>
    body{margin:0;font-family:Segoe UI,Arial,sans-serif;background:#f5f7fb;color:#1f2937;}
    .wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;}
    .card{background:#fff;width:100%;max-width:360px;border-radius:14px;box-shadow:0 12px 30px rgba(2,6,23,.12);padding:24px;}
    h1{margin:0 0 8px;font-size:24px;}
    p{margin:0 0 16px;color:#64748b;}
    .msg{margin:8px 0 14px;color:#b91c1c;min-height:20px;}
    input{width:100%;padding:12px;border:1px solid #cbd5e1;border-radius:10px;font-size:16px;box-sizing:border-box;}
    button{margin-top:12px;width:100%;padding:12px;border:0;border-radius:10px;background:#0f172a;color:#fff;font-weight:600;cursor:pointer;}
    button:hover{background:#1e293b;}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Code Server</h1>
      <p>Enter your password to continue.</p>
      <div class="msg" id="msg">${escapedMessage}</div>
      <form id="loginForm">
        <input type="password" id="password" name="password" placeholder="Password" required />
        <button type="submit">Sign In</button>
      </form>
    </div>
  </div>
  <script>
    const form = document.getElementById("loginForm");
    const msg = document.getElementById("msg");
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      msg.textContent = "";
      const password = document.getElementById("password").value;
      try {
        const resp = await fetch("/login", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ password })
        });
        if (!resp.ok) {
          const payload = await resp.json().catch(() => ({}));
          msg.textContent = payload.error || "Invalid password";
          return;
        }
        window.location.href = "/";
      } catch (err) {
        msg.textContent = "Login failed. Please retry.";
      }
    });
  </script>
</body>
</html>`;
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(html);
}

async function handleLogin(req, res) {
  try {
    const body = await readBody(req);
    const password = parseLoginBody(req, body);
    if (password !== CODE_SERVER_PASSWORD) {
      res.writeHead(401, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ error: "invalid password" }));
      return;
    }

    const token = jwt.sign(
      { sub: "code-server", scope: "editor" },
      JWT_SECRET,
      {
        expiresIn: TOKEN_TTL,
        issuer: "windows-code-server-jwt-proxy"
      }
    );

    res.writeHead(200, {
      "Content-Type": "application/json; charset=utf-8",
      "Set-Cookie": buildCookieHeader(req, token)
    });
    res.end(JSON.stringify({ ok: true, token }));
  } catch (error) {
    const badRequest = error instanceof SyntaxError || /Payload too large/.test(String(error.message));
    res.writeHead(badRequest ? 400 : 500, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ error: badRequest ? "invalid request body" : "internal error" }));
  }
}

function authenticateHttp(req, res) {
  const payload = verifyJwtFromRequest(req);
  if (payload) {
    req.user = payload;
    return true;
  }
  sendUnauthorized(req, res);
  return false;
}

const server = http.createServer(async (req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ status: "ok" }));
    return;
  }

  if (req.url === "/login" && req.method === "GET") {
    sendLoginPage(res, "");
    return;
  }

  if (req.url === "/login" && req.method === "POST") {
    await handleLogin(req, res);
    return;
  }

  if (req.url === "/logout" && req.method === "POST") {
    res.writeHead(200, {
      "Content-Type": "application/json; charset=utf-8",
      "Set-Cookie": clearCookieHeader()
    });
    res.end(JSON.stringify({ ok: true }));
    return;
  }

  if (!authenticateHttp(req, res)) {
    return;
  }

  proxy.web(req, res, {}, () => {
    if (!res.headersSent) {
      res.writeHead(502, { "Content-Type": "application/json; charset=utf-8" });
    }
    res.end(JSON.stringify({ error: "bad gateway" }));
  });
});

server.on("upgrade", (req, socket, head) => {
  const payload = verifyJwtFromRequest(req);
  if (!payload) {
    socket.destroy();
    return;
  }
  req.user = payload;
  proxy.ws(req, socket, head);
});

proxy.on("error", (_error, req, res) => {
  if (res && !res.headersSent) {
    res.writeHead(502, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ error: "proxy unavailable" }));
  }
});

proxy.on("proxyReq", (proxyReq, req) => {
  // Ensure downstream host/origin validation sees the public host from the incoming request.
  if (req.headers.host && !req.headers["x-forwarded-host"]) {
    proxyReq.setHeader("x-forwarded-host", req.headers.host);
  }
});

proxy.on("proxyReqWs", (proxyReq, req) => {
  if (req.headers.host && !req.headers["x-forwarded-host"]) {
    proxyReq.setHeader("x-forwarded-host", req.headers.host);
  }
});

server.listen(PROXY_PORT, "127.0.0.1", () => {
  console.log(`JWT proxy listening on http://127.0.0.1:${PROXY_PORT}`);
  console.log(`Forwarding authenticated traffic to ${TARGET_URL}`);
});
