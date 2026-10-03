/* 各页面共用:本机存储、后端地址发现、带口令与登录令牌的接口调用。*/
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const STORE = "hornbill_v32";

let S = { responses: {}, timing: {}, best_fit: null, cards: {}, identityDone: false };
try { S = { ...S, ...(JSON.parse(localStorage.getItem(STORE)) || {}) }; } catch (e) {}
const save = () => { try { localStorage.setItem(STORE, JSON.stringify(S)); } catch (e) {} };

// 页面放在静态站点(如 GitHub Pages)上时,接口指向本机运行的服务;由本机服务直接打开时用同源地址。
// 优先用 backend.json 里登记的公网隧道地址(任何浏览器和手机都能用);没有或连不上时退回本机地址。
const LOCAL = location.port === "8600" || ["127.0.0.1", "localhost"].includes(location.hostname);
let API_BASE = LOCAL ? "" : "http://127.0.0.1:8600", TUNNEL = false;
const backendReady = LOCAL ? Promise.resolve() : (async () => {
  try {
    const cfg = await (await fetch("backend.json?t=" + Date.now(), { cache: "no-store" })).json();
    if (cfg.url && (await fetch(cfg.url + "/api/health", { cache: "no-store" })).ok) { API_BASE = cfg.url; TUNNEL = true; }
  } catch (e) {}
})();
const codeFromHash = location.hash.match(/[#&]code=([^&]+)/);
if (codeFromHash) { S.code = decodeURIComponent(codeFromHash[1]); history.replaceState(null, "", location.pathname); }
if (!S.sid) { S.sid = Array.from(crypto.getRandomValues(new Uint8Array(18)), (b) => b.toString(16).padStart(2, "0")).join(""); save(); }

const LOCAL_URL = "http://127.0.0.1:8600/";

async function rawFetch(url, opts) {
  if (TUNNEL) return fetch(url, opts);
  // Chrome 的“本地网络访问”:声明目标是本机地址,浏览器才会弹出授权询问;不认识这个选项的浏览器退回普通请求。
  try { return await fetch(url, { ...opts, targetAddressSpace: "loopback" }); }
  catch (e) { if (e instanceof TypeError && /targetAddressSpace|enum/i.test(e.message)) return fetch(url, opts); throw e; }
}

async function whyBlocked() {
  const ua = navigator.userAgent, safari = /Safari/.test(ua) && !/Chrome|Chromium|Edg/.test(ua);
  if (!TUNNEL && /Mobile|Android|iPhone|iPad/.test(ua)) return "服务暂时没有开启(需要运行服务的那台电脑在线并打开隧道)。请稍后再试。";
  if (safari) return "Safari 不允许网页访问本机服务。请点右侧按钮直接打开本机版本,或改用 Chrome / Edge。";
  let state = "";
  try { state = (await navigator.permissions.query({ name: "local-network-access" })).state; } catch (e) {}
  if (state === "denied") return "浏览器已拒绝本网站访问本机服务。请点地址栏左侧的图标 → 网站设置 → 把“本地网络访问”改为“允许”,然后刷新;或点右侧按钮直接打开本机版本。";
  if (state === "prompt") return "浏览器需要你的许可才能连接本机服务。请点右侧“重试”,在弹出的询问中选择“允许”。";
  return "连不上本机服务。请确认这台电脑上已经运行 sh scripts/serve.sh;如果已经运行,请点右侧按钮直接打开本机版本。";
}

async function api(path, body, retried) {
  await backendReady;
  const headers = { "X-Session-Id": S.sid };
  if (S.code) headers["X-Access-Code"] = S.code;
  if (S.token) headers["X-Auth-Token"] = S.token;
  if (body) headers["Content-Type"] = "application/json";
  let r;
  try { r = await rawFetch(API_BASE + path, { method: body ? "POST" : "GET", headers, body: body ? JSON.stringify(body) : undefined }); }
  catch (e) { throw new Error(API_BASE ? await whyBlocked() : "连不上服务器。"); }
  if (r.status === 401 && !retried) {
    const code = prompt("请输入访问口令");
    if (!code) throw new Error("需要访问口令才能使用。");
    S.code = code.trim(); save();
    return api(path, body, true);
  }
  if (r.status === 401) { delete S.code; save(); throw new Error("访问口令不正确。"); }
  if (!r.ok) {
    let detail = ""; try { detail = (await r.json()).detail; } catch (e) {}
    const err = new Error(detail || "HTTP " + r.status); err.status = r.status; throw err;
  }
  return r.json();
}
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
