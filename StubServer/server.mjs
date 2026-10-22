// A stand-in for a Jarvis server (DE0CH/claudecodeui in staff mode) for the iOS app's UI tests: the same REST shapes
// and WebSocket frames (server/shared/types.ts NormalizedMessage), with canned conversations and a canned reply
// (preparing → ready → tool steps → Markdown with a table and code → a SendUserFile card → complete).
// Usage: node server.mjs [port]   (token: Cookie CF_Authorization=stub-token)
import http from "node:http";
import { randomUUID } from "node:crypto";
import { WebSocketServer } from "ws";

const PORT = Number(process.argv[2] || 8787);
const TOKEN = "stub-token";
const now = () => new Date().toISOString();
const ago = (min) => new Date(Date.now() - min * 60000).toISOString();

// A one-page PDF ("Report") for the file card and Quick Look.
const PDF = Buffer.from(
  "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n" +
  "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj\n" +
  "4 0 obj<</Length 44>>stream\nBT /F1 24 Tf 40 100 Td (Report) Tj ET\nendstream endobj\n" +
  "5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n");

const REPLY_MD = [
  "## 第三季摘要",
  "",
  "收入按年上升 **12%**，主要來自：",
  "",
  "- 新客戶合約",
  "- 續約率提升",
  "",
  "| 季度 | 收入（百萬港元） | 按年變化 |",
  "| --- | ---: | ---: |",
  "| Q2 | 41.2 | +8% |",
  "| Q3 | 46.1 | +12% |",
  "",
  "```python",
  "growth = (46.1 - 41.2) / 41.2",
  "print(f\"{growth:.1%}\")",
  "```",
].join("\n");

const sessions = new Map(); // id → {id, title, lastActivity, deleted, messages[], files[]}
function seed(title, minutesAgo, messages = [], files = []) {
  const id = randomUUID();
  sessions.set(id, { id, title, lastActivity: ago(minutesAgo), deleted: false, messages, files });
  return id;
}
const msg = (o) => ({ id: randomUUID(), timestamp: now(), provider: "claude", ...o });
seed("Meeting notes", 60 * 26, [msg({ kind: "text", role: "user", content: "Summarise the meeting" }),
  msg({ kind: "text", role: "assistant", content: "**Decisions**\n\n1. Launch in March\n2. Hire two analysts" })]);
seed("新聞稿草稿", 180);
const del = seed("舊對話", 60 * 50);
sessions.get(del).deleted = true;

const sockets = new Set();
const broadcast = (o) => { for (const s of sockets) s.send(JSON.stringify(o)); };
const upserted = (s) => broadcast({ kind: "session_upserted", sessionId: s.id, provider: "claude",
  session: { id: s.id, summary: s.title, messageCount: s.messages.length, lastActivity: s.lastActivity }, timestamp: now() });

const uploads = new Map(); // path → {name, mimeType, data}

function send(res, status, body, headers = {}) {
  const isBuf = Buffer.isBuffer(body);
  res.writeHead(status, { "content-type": isBuf ? "application/octet-stream" : "application/json", ...headers });
  res.end(isBuf ? body : JSON.stringify(body));
}
const ok = (data) => ({ success: true, data });
const authed = (req) => (req.headers.cookie || "").includes(`CF_Authorization=${TOKEN}`);
const readBody = (req) => new Promise((r) => { const c = []; req.on("data", (d) => c.push(d)); req.on("end", () => r(Buffer.concat(c))); });

function parseMultipart(buf, boundary) {
  const out = [];
  const sep = Buffer.from("--" + boundary);
  let i = buf.indexOf(sep);
  while (i !== -1) {
    const next = buf.indexOf(sep, i + sep.length);
    if (next === -1) break;
    const part = buf.subarray(i + sep.length + 2, next - 2);
    const h = part.indexOf("\r\n\r\n");
    const head = part.subarray(0, h).toString();
    const name = /filename="([^"]*)"/.exec(head)?.[1] || "file";
    const type = /Content-Type: ([^\r\n]+)/i.exec(head)?.[1] || "application/octet-stream";
    out.push({ name, mimeType: type, data: part.subarray(h + 4) });
    i = next;
  }
  return out;
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, "http://x");
  const p = u.pathname;
  console.log(req.method, p);
  if (p === "/healthz") return send(res, 200, { ok: true });
  if (!authed(req)) return send(res, 401, "<html>未登入</html>", { "content-type": "text/html" });
  let m;
  if (p === "/api/jarvis/me") return send(res, 200, { firstName: "Chris" });
  if (p === "/api/jarvis/warm") return send(res, 202, { ok: true });
  if (p === "/api/providers/sessions/recent") {
    const list = [...sessions.values()].filter((s) => !s.deleted).sort((a, b) => b.lastActivity.localeCompare(a.lastActivity));
    return send(res, 200, ok({ conversations: list.map((s) => ({ sessionId: s.id, provider: "claude", projectId: "p1",
      projectDisplayName: "Stub", sessionTitle: s.title, lastActivity: s.lastActivity })), total: list.length, hasMore: false }));
  }
  if (p === "/api/providers/sessions/deleted") {
    return send(res, 200, ok({ retentionDays: 30, sessions: [...sessions.values()].filter((s) => s.deleted).map((s) => {
      const deletedAt = s.deletedAt || s.lastActivity;
      return { sessionId: s.id, provider: "claude", sessionTitle: s.title, deletedAt,
        purgeAt: new Date(Date.parse(deletedAt) + 30 * 86400000).toISOString(), lastActivity: s.lastActivity };
    }) }));
  }
  if (p === "/api/providers/sessions/running") return send(res, 200, ok({ sessions: [] }));
  if (p === "/api/providers/sessions" && req.method === "POST") {
    const body = JSON.parse((await readBody(req)).toString() || "{}");
    const title = (body.initialMessage || "").slice(0, 24) || "新對話";
    const id = seed(title, 0);
    upserted(sessions.get(id));
    return send(res, 201, ok({ sessionId: id, provider: "claude", projectPath: "/workspace", sessionName: title }));
  }
  if ((m = /^\/api\/providers\/sessions\/([^/]+)\/messages$/.exec(p))) {
    const s = sessions.get(m[1]);
    if (!s) return send(res, 404, { success: false, error: { code: "SESSION_NOT_FOUND", message: "not found" } });
    return send(res, 200, ok({ messages: s.messages, total: s.messages.length, hasMore: false, offset: 0, limit: 200 }));
  }
  if ((m = /^\/api\/providers\/sessions\/([^/]+)\/restore$/.exec(p))) {
    const s = sessions.get(m[1]); s.deleted = false; s.deletedAt = null; upserted(s);
    return send(res, 200, ok({ sessionId: s.id, isArchived: false }));
  }
  if ((m = /^\/api\/providers\/sessions\/([^/]+)$/.exec(p))) {
    const s = sessions.get(m[1]);
    if (!s) return send(res, 404, { success: false, error: { code: "SESSION_NOT_FOUND", message: "not found" } });
    if (req.method === "PUT") { s.title = JSON.parse((await readBody(req)).toString()).summary; upserted(s); return send(res, 200, ok({ sessionId: s.id, summary: s.title })); }
    if (req.method === "DELETE") {
      if (u.searchParams.get("force") === "true") sessions.delete(s.id); else { s.deleted = true; s.deletedAt = now(); }
      broadcast({ kind: "session_removed", sessionId: s.id, action: u.searchParams.get("force") ? "purged" : "deleted" });
      return send(res, 200, ok({ sessionId: s.id, action: "archived" }));
    }
  }
  if (p === "/api/assets/files" && req.method === "POST") {
    const boundary = /boundary=(.+)$/.exec(req.headers["content-type"] || "")?.[1];
    const parts = parseMultipart(await readBody(req), boundary);
    const attachments = parts.map((f) => {
      const path = `/home/stub/.cloudcli/assets/${Date.now()}-${f.name}`;
      uploads.set(path, f);
      return { name: f.name, path, size: f.data.length, mimeType: f.mimeType };
    });
    console.log("uploaded", attachments.map((a) => `${a.name} ${a.size}`).join(", "));
    return send(res, 200, { attachments });
  }
  if ((m = /^\/api\/jarvis\/sessions\/([^/]+)\/files$/.exec(p))) {
    const s = sessions.get(m[1]);
    if (!s || !s.files.length) return send(res, 404, { success: false, error: { code: "SESSION_NOT_FOUND" } });
    return send(res, 200, { files: s.files });
  }
  if ((m = /^\/api\/jarvis\/sessions\/([^/]+)\/files\/raw$/.exec(p))) {
    return send(res, 200, PDF, { "content-type": "application/pdf", "content-disposition": "attachment; filename=summary.pdf" });
  }
  if ((m = /^\/api\/jarvis\/sessions\/([^/]+)\/shares$/.exec(p))) {
    if (req.method === "POST") return send(res, 201, { id: "stubshare0000000000001", url: "/s/stubshare0000000000001", createdAt: now() });
    return send(res, 200, { shares: [] });
  }
  return send(res, 404, { success: false, error: { code: "NOT_FOUND", message: p } });
});

const wss = new WebSocketServer({ noServer: true });
server.on("upgrade", (req, socket, head) => {
  if (new URL(req.url, "http://x").pathname !== "/ws" || !authed(req)) { socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n"); return socket.destroy(); }
  wss.handleUpgrade(req, socket, head, (ws) => {
    sockets.add(ws);
    ws.on("close", () => sockets.delete(ws));
    ws.on("message", (raw) => onFrame(ws, JSON.parse(raw.toString())));
  });
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function onFrame(ws, f) {
  console.log("ws", f.type);
  if (f.type === "chat.subscribe") {
    for (const s of f.sessions || []) ws.send(JSON.stringify({ kind: "chat_subscribed", sessionId: s.sessionId, isProcessing: false, lastSeq: 0, pendingPermissions: [], timestamp: now() }));
    return;
  }
  if (f.type !== "chat.send") return;
  const s = sessions.get(f.sessionId);
  if (!s) return ws.send(JSON.stringify({ kind: "protocol_error", code: "SESSION_NOT_FOUND", error: "Session not found", sessionId: f.sessionId }));
  const atts = f.options?.attachments || [];
  const images = atts.filter((a) => (a.mimeType || "").startsWith("image/")).map((a) => {
    const u = uploads.get(a.path);
    return { data: `data:${a.mimeType};base64,` + (u ? u.data.toString("base64") : "") };
  });
  const files = atts.filter((a) => !(a.mimeType || "").startsWith("image/")).map((a) => ({ path: `/workspace/uploads/${a.name}`, name: a.name }));
  s.messages.push(msg({ kind: "text", role: "user", content: f.content, images, files, sessionId: s.id }));
  let seq = 0;
  const emit = (o, keep = true) => {
    const m = msg({ sessionId: s.id, seq: ++seq, ...o });
    if (keep) s.messages.push(m);
    ws.send(JSON.stringify(m));
  };
  await sleep(300);
  emit({ kind: "status", jarvisSandbox: "preparing", canInterrupt: false }, false);
  await sleep(2500);
  emit({ kind: "status", jarvisSandbox: "ready", canInterrupt: true }, false);
  for (const file of ["data/q2.xlsx", "data/q3.xlsx"]) {
    const toolId = randomUUID();
    emit({ kind: "tool_use", toolName: "Read", toolId, toolInput: { file_path: `/workspace/${file}` } });
    await sleep(300);
    emit({ kind: "tool_result", toolId, content: "rows: 120", isError: false });
  }
  await sleep(500);
  emit({ kind: "text", role: "assistant", content: REPLY_MD });
  const toolId = randomUUID();
  emit({ kind: "tool_use", toolName: "SendUserFile", toolId, toolInput: { files: ["/workspace/reports/summary.pdf"], caption: "今日嘅報告" } });
  await sleep(400);
  emit({ kind: "tool_result", toolId, content: "sent", isError: false, toolUseResult: { attachments: [{ path: "/workspace/reports/summary.pdf", size: PDF.length }] } });
  s.files = [{ path: "reports/summary.pdf", size: PDF.length, mtime: now(), sentAt: now(), caption: "今日嘅報告" }];
  s.lastActivity = now();
  upserted(s);
  emit({ kind: "complete", exitCode: 0, success: true, aborted: false, actualSessionId: s.id }, false);
}

server.listen(PORT, "127.0.0.1", () => console.log(`stub listening on ${PORT}`));
