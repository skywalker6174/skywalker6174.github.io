/* 对话页:登录(手机号或邮箱)后与犀鸟对话。回复在服务器端生成并经过治理检查;这里只负责显示。 */
const box = $("messages");
let busy = false;

function bubble(role, text, tools = []) {
  const mine = role === "user";
  const el = document.createElement("div");
  el.className = "flex " + (mine ? "justify-end" : "justify-start") + " q-in";
  el.innerHTML = `<div class="max-w-[85%] px-4 py-3 leading-relaxed whitespace-pre-wrap ${mine ? "msg-me" : "msg-ai"}">${esc(text)}${
    tools.length ? `<div class="mt-2 flex flex-wrap gap-1.5">${tools.map((t) => `<span class="chip-ai">${esc(t)}</span>`).join("")}</div>` : ""}</div>`;
  box.appendChild(el); box.scrollTop = box.scrollHeight;
  return el;
}

function showAuth(msg = "") { $("auth").hidden = false; $("chat").hidden = true; $("authErr").textContent = msg; }

async function enter() {
  if (!S.token) return showAuth();
  let me;
  try { me = await api("/api/auth/me"); }
  catch (e) {
    if (e.status === 403) { delete S.token; save(); return showAuth("登录已过期,请重新登录。"); }
    return showAuth(e.message);
  }
  $("auth").hidden = true; $("chat").hidden = false;
  $("who").textContent = S.display || "";
  const has = me.has, parts = [];
  if (has.identity) parts.push("身份结果"); else if (has.explorer) parts.push("探索版结果");
  if (has.planning) parts.push("规划结果");
  if (has.recommendation) parts.push("投资建议");
  $("status").innerHTML = parts.length ? "犀鸟可以读取你的:" + parts.join("、") + "。"
    : '你还没有做过测评。可以先到 <a href="./" class="underline" style="color:#ecd089">测评</a> 页完成,犀鸟才能结合你的情况回答。';
  box.innerHTML = "";
  if (!me.history.length) bubble("assistant", has.identity || has.planning
    ? "你好,我是犀鸟。我已经看过你的测评结果,可以陪你把其中任何一点聊清楚。想先从哪里开始?"
    : "你好,我是犀鸟。个人养老金的规则、税优、法定退休年龄这些问题,现在就可以问我;做完测评之后,我还能结合你自己的情况来回答。");
  me.history.forEach((m) => bubble(m.role, m.content, []));
  const tips = has.planning ? ["我的养老缺口主要来自哪里?", "为什么给我这样的配置?", "市场大跌时我该怎么办?", "我今年该缴多少个人养老金?"]
    : has.identity ? ["我的身份结果说明了什么?", "个人养老金对我划算吗?", "我该从哪一步开始?"]
    : ["个人养老金是什么?", "每年交 12000 元能省多少税?", "我的法定退休年龄是多少?"];
  $("tips").innerHTML = tips.map((t) => `<button class="opt px-3 py-1.5 text-sm" onclick="send('${t}')">${t}</button>`).join("");
  $("input").focus();
}

async function signIn() {
  $("authErr").textContent = "";
  const contact = $("contact").value.trim(), code = $("vcode").value.trim();
  if (!contact || !code) { $("authErr").textContent = "请填写手机号或邮箱,以及验证码。"; return; }
  $("btnSignIn").disabled = true;
  try {
    const r = await api("/api/auth/signin", { contact, code });
    S.token = r.token; S.display = r.display; save();
    await enter();
  } catch (e) { $("authErr").textContent = e.message; }
  finally { $("btnSignIn").disabled = false; }
}

async function signOut() {
  try { await api("/api/auth/signout", {}); } catch (e) {}
  delete S.token; delete S.display; save(); showAuth();
}

async function send(preset) {
  if (busy) return;
  const text = (preset || $("input").value).trim();
  if (!text) return;
  busy = true; $("input").value = ""; $("btnSend").disabled = true; $("tips").innerHTML = "";
  bubble("user", text);
  const wait = bubble("assistant", "犀鸟正在思考…");
  const t0 = Date.now(), tick = setInterval(() => { wait.firstChild.textContent = `犀鸟正在思考… ${Math.round((Date.now() - t0) / 1000)} 秒`; }, 1000);
  try {
    let r = await api("/api/chat", { message: text });
    const job = r.job;
    for (r = { done: false }; !r.done;) { await sleep(2000); r = await api("/api/jobs/" + job); }
    if (r.error && typeof r.error === "string") throw new Error(r.error);
    wait.remove(); bubble("assistant", r.reply, r.tools || []);
  } catch (e) {
    wait.remove();
    if (e.status === 403) { delete S.token; save(); showAuth("登录已过期,请重新登录。"); }
    else bubble("assistant", "出了点问题:" + e.message);
  } finally { clearInterval(tick); busy = false; $("btnSend").disabled = false; $("input").focus(); }
}

$("input").addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); } });
enter();
