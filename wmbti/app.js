/* 犀鸟财富伴侣 · 网页端
 * 浏览器只负责展示题面、收集作答和显示服务器渲染好的报告。
 * 计分、参数、量化策略与大模型都在服务器端。
 */
const payload = () => ({ responses: S.responses, timing: S.timing, best_fit: S.best_fit, cards: S.cards });

function show(name, label = "", pct = null) {
  document.querySelectorAll(".screen").forEach((s) => s.classList.remove("active"));
  $("s-" + name).classList.add("active");
  $("stepLabel").textContent = label;
  if (pct !== null) $("progress").style.width = pct + "%";
  window.scrollTo(0, 0);
}
function loading(msg) { $("loadMsg").textContent = msg; show("loading", "", 95); }

/* ---------------- 通用答题器 ---------------- */
const Quiz = {
  start(screens, likert, stage, onDone) {
    this.screens = screens; this.likert = likert; this.stage = stage; this.onDone = onDone;
    this.i = screens.findIndex((q) => S.responses[q.id] == null);
    if (this.i < 0) return onDone();
    this.render();
  },
  render() {
    const q = this.screens[this.i];
    $("qCounter").textContent = `第 ${this.i + 1} / ${this.screens.length} 题`;
    $("qStage").textContent = this.stage;
    const bg = q.id.startsWith("BG-");  // 背景题:标题才是问题,正文是说明
    $("qTitle").textContent = bg ? "" : q.title || (q.format === "likert6" ? "更接近通常的你吗?" : "");
    $("qText").textContent = bg ? q.title : q.text;
    $("qHint").textContent = bg ? q.text : q.id.startsWith("HA-") ? "如果最近没有遇到或记不清,直接选最后一项就好。" : "";
    const cur = S.responses[q.id];
    $("qOptions").innerHTML = q.format === "likert6"
      ? `<div class="likert">${this.likert.map((t, k) => `<button class="opt py-3 px-2 text-sm ${cur === k + 1 ? "on" : ""}" onclick="Quiz.answer(${k + 1})">${k + 1}<br><span class="text-xs">${t}</span></button>`).join("")}</div>`
      : `<div class="grid gap-3">${q.options.map((o) => `<button class="opt choice ${cur === o.code ? "on" : ""}" onclick="Quiz.answer('${o.code}')">${o.code}. ${esc(o.text)}</button>`).join("")}</div>`;
    show("quiz", this.stage, 5 + (90 * this.i) / this.screens.length);
    if (window.FX) ["qText", "qOptions"].forEach((id) => FX.replay($(id), "q-in"));
    this.t0 = Date.now();
  },
  answer(v) {
    const q = this.screens[this.i];
    S.responses[q.id] = v; S.timing[q.id] = Date.now() - this.t0; save();
    if (this.i < this.screens.length - 1) { this.i++; setTimeout(() => this.render(), 110); } else this.onDone();
  },
  prev() { if (this.i > 0) { this.i--; this.render(); } else App.home(); },
};

/* ---------------- 规划卡 ---------------- */
const Cards = {
  start(meta, onDone) { this.meta = meta; this.cards = meta.cards; this.onDone = onDone; this.i = 0; this.render(); },
  field(f) {
    const v = S.cards[f.key];
    const label = `<label class="block text-sm mb-1.5" style="color:#d8c9a6">${esc(f.label)}${f.unit ? `(${f.unit})` : ""}${f.required === false || (f.type === "amount" && !f.required) ? "" : " *"}</label>`;
    let input;
    if (f.type === "select") input = `<select class="field" name="${f.key}"><option value="">请选择</option>${f.options.map((o) => `<option ${o === v ? "selected" : ""}>${o}</option>`).join("")}</select>`;
    else if (f.type === "multi") input = `<div class="flex flex-wrap gap-2">${f.options.map((o) => `<button type="button" data-multi="${f.key}" data-v="${o}" class="opt px-4 py-1.5 text-sm ${(v || []).includes(o) ? "on" : ""}">${o}</button>`).join("")}</div>`;
    else if (f.type === "region") input = `<select class="field" name="${f.key}"><option value="">请选择</option>${this.meta.regions.map((o) => `<option ${o === v ? "selected" : ""}>${o}</option>`).join("")}<option ${v === "其他城市" ? "selected" : ""}>其他城市</option></select>`;
    else if (f.type === "industry") {
      const l1 = this.meta.industries.find((g) => g.children.some((c) => c.code == v));
      input = `<div class="grid grid-cols-2 gap-2"><select class="field" id="indL1" onchange="Cards.fillL3()"><option value="">一级行业</option>${this.meta.industries.map((g) => `<option value="${g.code}" ${l1 && l1.code === g.code ? "selected" : ""}>${g.name}</option>`).join("")}</select>
        <select class="field" name="${f.key}" id="indL3"><option value="">细分行业</option>${l1 ? l1.children.map((c) => `<option value="${c.code}" ${c.code == v ? "selected" : ""}>${c.name}</option>`).join("") : ""}</select></div>`;
    } else if (f.type === "number") input = `<input class="field" type="number" name="${f.key}" min="${f.min}" max="${f.max}" value="${v ?? ""}">`;
    else input = `<input class="field" type="text" name="${f.key}" value="${esc(v ?? "")}" ${f.type === "amount" ? 'inputmode="decimal"' : ""} placeholder="${f.hint || ""}">`;
    const wide = f.type === "multi" || f.type === "industry" || f.label.length > 22;
    return `<div class="${wide ? "md:col-span-2" : ""}">${label}${input}</div>`;
  },
  fillL3() {
    const g = this.meta.industries.find((x) => x.code == $("indL1").value);
    $("indL3").innerHTML = `<option value="">细分行业</option>` + (g ? g.children.map((c) => `<option value="${c.code}">${c.name}</option>`).join("") : "");
  },
  render() {
    const c = this.cards[this.i];
    $("cCounter").textContent = `第 ${this.i + 1} / ${this.cards.length} 张`;
    $("cTitle").textContent = c.title; $("cLead").textContent = c.lead; $("cWhy").textContent = "为什么问:" + c.why; $("cErr").textContent = "";
    $("cForm").innerHTML = c.fields.map((f) => this.field(f)).join("");
    $("cForm").onclick = (e) => { const b = e.target.closest("[data-multi]"); if (b) b.classList.toggle("on"); };
    show("card", "养老规划建档", 5 + (90 * this.i) / this.cards.length);
    if (window.FX) { FX.replay($("cForm"), "q-in"); FX.replay($("cTitle"), "q-in"); }
  },
  collect() {
    const c = this.cards[this.i], form = $("cForm"), missing = [];
    for (const f of c.fields) {
      let v;
      if (f.type === "multi") v = [...form.querySelectorAll(`[data-multi="${f.key}"].on`)].map((x) => x.dataset.v);
      else v = form.elements[f.key].value.trim();
      if (f.type === "industry" && v) v = +v;
      S.cards[f.key] = v;
      const empty = v === "" || (Array.isArray(v) && !v.length);
      if (empty && f.required !== false && !(f.type === "amount" && !f.required)) missing.push(f.label.split(/[::]/)[0]);
      if (f.type === "amount" && v && !/^\d+(\.\d+)?(\s*[-—~至到]\s*\d+(\.\d+)?)?$/.test(v.replace(/,/g, ""))) missing.push(f.label.split(/[::]/)[0] + "(格式:数字或区间)");
    }
    save();
    return missing;
  },
  next() {
    const missing = this.collect();
    if (missing.length) { $("cErr").textContent = "还需要填写:" + missing.join("、"); return; }
    if (this.i < this.cards.length - 1) { this.i++; this.render(); } else this.onDone();
  },
  prev() { this.collect(); if (this.i > 0) { this.i--; this.render(); } else App.home(); },
};

/* ---------------- 报告页 ---------------- */
function showReport(html, label, buttons, extra = "") {
  $("report").innerHTML = html;
  $("actions").innerHTML = buttons.map(([text, fn, ghost]) => `<button class="${ghost ? "btn-ghost" : "btn"}" onclick="${fn}">${text}</button>`).join("")
    + `<button class="btn-ghost" id="btnPdf" onclick="App.pdf('${label}')">⬇ 下载 PDF</button>`
    + (label === "探索结果" ? "" : `<a class="btn-ghost" href="chat.html">和犀鸟聊聊这份报告 →</a>`);
  $("extra").innerHTML = extra;
  show("report", label, 100);
  if (window.FX) FX.countUp($("report"));
}

const App = {
  home() {
    show("home", "", 0);
    if (!LOCAL) this.checkBackend();
  },
  checkBackend() {
    api("/api/health").then(() => $("backend").classList.add("hidden")).catch((e) => {
      $("backend").innerHTML = `<div class="flex flex-wrap items-center gap-3 justify-between"><span>${esc(e.message)}</span>
        <span class="flex gap-2"><button class="btn-ghost !py-1.5 !px-3 text-xs" onclick="App.checkBackend()">重试</button>
        <a class="btn !py-1.5 !px-3 text-xs" href="${LOCAL_URL}">直接打开本机版本 →</a></span></div>`;
      $("backend").classList.remove("hidden");
    });
  },
  reset() { if (confirm("清除本机保存的全部作答?")) { localStorage.removeItem(STORE); location.reload(); } },
  fail(e) { console.error(e); if (LOCAL || TUNNEL) alert("出错了:" + e.message); this.home(); },

  async startExplorer() {
    try {
      const f = await api("/api/forms/explorer");
      Quiz.start(f.screens, f.likert, "探索版", async () => {
        loading("正在整理你的初步线索…");
        const r = await api("/api/wmbti/explorer", payload());
        showReport(r.html, "探索结果", [["继续完整版 →", "App.startIdentity()"], ["先到这里", "App.home()", true]]);
      });
    } catch (e) { this.fail(e); }
  },

  async startIdentity() {
    try {
      const f = await api("/api/forms/identity");
      S.planningEntry = false; save();
      Quiz.start(f.screens, f.likert, "完整版 · 第一段", async () => {
        loading("主要轮廓已经出现,正在选择需要补充的几块拼图…");
        const route = await api("/api/wmbti/identity/route", payload());
        const extra = route.screens.concat(S.responses["CN-CTL-01"] == null ? [(await api("/api/forms/explorer")).screens.find((q) => q.id === "CN-CTL-01")] : []);
        Quiz.start(extra, f.likert, "完整版 · 第二段", () => this.identityReport());
      });
    } catch (e) { this.fail(e); }
  },
  async startPlanningFull() {
    // 规划完整版:第一段与身份完整版相同的固定 42 题 → 身份结果与确认 → 第二段(功能 6 + 财富心理 8 + 规划卡)
    try {
      const f = await api("/api/forms/identity");
      S.planningEntry = true; save();
      Quiz.start(f.screens, f.likert, "深度版 · 第一段", () => this.identityReport());
    } catch (e) { this.fail(e); }
  },
  async identityReport() {
    try {
      loading("正在生成身份报告…");
      const r = await api("/api/wmbti/identity", payload());
      S.identityDone = true; save();
      const fit = !r.classifiable ? "" : `<div class="card p-4 sans"><div class="text-sm mb-3" style="color:#d8c9a6">最佳适配确认:看完报告后,哪一种更像你?(系统的测量候选和你的认领会分开保存)</div>
        <div class="flex flex-wrap gap-2">${[["primary", `主要候选 ${r.primary} 更像我`], ["adjacent", `相邻候选 ${r.adjacent} 更像我`], ["mixed", "各有一部分"], ["neither", "都不像,需要复核"]]
          .map(([k, t]) => `<button class="opt px-4 py-2 text-sm ${S.best_fit === k ? "on" : ""}" onclick="App.bestFit('${k}')">${t}</button>`).join("")}</div></div>`;
      showReport(r.html, "身份报告", [["继续:养老规划建档 →", "App.startPlanning()"], ["回到首页", "App.home()", true]], fit);
    } catch (e) { this.fail(e); }
  },
  bestFit(k) { S.best_fit = k; save(); this.identityReport(); },

  async startPlanning() {
    try {
      loading("正在准备规划部分…");
      const meta = await api("/api/planning/route", payload());
      const likert = (await api("/api/forms/identity")).likert;
      Quiz.start(meta.screens, likert, "深度版 · 第二段", () => Cards.start(meta, () => this.planningReport()));
    } catch (e) { this.fail(e); }
  },
  async planningReport() {
    try {
      loading("正在测算现金流、缺口与风险五维…");
      const r = await api("/api/planning", payload());
      const btn = r.can_recommend ? [["生成投资建议报告 →", "App.recommend(false)"]] : [];
      showReport(r.html, "规划报告", btn.concat([["修改规划信息", "App.startPlanning()", true]]),
        r.can_recommend ? "" : `<div class="card p-4 text-sm sans" style="color:#e9a27a">规划数据尚未达到“缺口就绪”(当前 ${r.readiness.level}),补全后才能生成投资建议。</div>`);
    } catch (e) { this.fail(e); }
  },
  async recommend(withNarrative) {
    try {
      loading(withNarrative ? "正在请大模型撰写文字解读,通常需要 1—3 分钟,请不要关闭页面…" : "正在调用量化策略库并从产品池选品…");
      let r = await api("/api/recommendation?with_narrative=" + withNarrative, payload());
      if (r.job) {  // 文字解读是后台任务:轮询直到完成
        const job = r.job, t0 = Date.now();
        for (r = { done: false }; !r.done;) {
          await sleep(5000);
          $("loadMsg").textContent = `正在请大模型撰写文字解读… 已用时 ${Math.round((Date.now() - t0) / 1000)} 秒`;
          r = await api("/api/jobs/" + job);
        }
        if (r.error) throw new Error(r.error);
      }
      const btn = [];
      if (r.available && r.llm_ready && !withNarrative) btn.push(["加入 AI 文字解读(约 1—3 分钟)", "App.recommend(true)"]);
      btn.push(["返回规划报告", "App.planningReport()", true]);
      showReport(r.html, "投资建议报告", btn, r.narrative_status ? `<div class="text-xs muted sans">文字解读:${esc(r.narrative_status)}</div>` : "");
    } catch (e) { this.fail(e); }
  },

  async pdf(label) {
    if (/MicroMessenger/i.test(navigator.userAgent)) { alert("微信内置浏览器无法下载文件。请点右上角「···」选择「在浏览器打开」。"); return; }
    const el = $("report"), btn = $("btnPdf"), mobile = window.innerWidth < 700;
    btn.disabled = true; btn.textContent = "正在生成 PDF…"; el.classList.add("pdf");
    try {
      await html2pdf().set({
        margin: [10, 0, 12, 0], filename: `犀鸟_${label}_${new Date().toISOString().slice(0, 10)}.pdf`,
        image: { type: "jpeg", quality: 0.95 }, html2canvas: { scale: mobile ? 1.5 : 2, backgroundColor: "#fffdf7", windowWidth: 800, scrollX: 0, scrollY: 0 },
        jsPDF: { unit: "mm", format: "a4", orientation: "portrait" },
        pagebreak: { mode: ["css", "legacy"], avoid: [".avoid", ".prod", "table", ".kpis", ".motto", ".warn", ".axis", "h2", "h3"] },
      }).from(el).save();
    } finally { el.classList.remove("pdf"); btn.disabled = false; btn.textContent = "⬇ 下载 PDF"; }
  },
};
App.home();
