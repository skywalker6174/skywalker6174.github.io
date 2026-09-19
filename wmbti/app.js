/* 犀鸟财富伴侣 · W-MBTI 网页版
 * 流程:测评 → 财富身份 → 养老金问题 → (确定性计算 + Kimi 撰写) → 报告 → PDF
 * 数字(仓位、金额、税优)全部由本文件确定性计算;大模型只负责解读与在产品目录内选品。
 */
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const clamp = (x, lo, hi) => Math.max(lo, Math.min(hi, x));
const yuan = (n) => "¥" + Math.round(n).toLocaleString("zh-CN");
const STORE = "wmbti_state_v1", CFG = "wmbti_cfg_v1";

const SCALE = [["很像 A", 2], ["略像 A", 1], ["略像 B", -1], ["很像 B", -2]];
const DIMS = ["EI", "SN", "TF", "JP"];
const GROWTH = ["前锋", "自动挡中场"], DEFENSIVE = ["守门员", "后卫", "长期后勤官"];

/* ---------------- 养老金问题 ---------------- */
const PENSION_Q = [
  { k: "age", label: "你的年龄", type: "number", min: 18, max: 70, def: 35 },
  { k: "retireAge", label: "计划退休年龄", type: "number", min: 45, max: 75, def: 60, hint: "延迟退休改革后,法定年龄将逐步提高" },
  { k: "income", label: "年税前收入(估算)", type: "select",
    opts: ["10万以下", "10–20万", "20–40万", "40–70万", "70–100万", "100万以上"], def: "20–40万", hint: "用于估算个人养老金的税优价值" },
  { k: "account", label: "个人养老金账户", type: "select", opts: ["已开通并缴存过", "已开通未缴存", "尚未开通"], def: "尚未开通" },
  { k: "contribution", label: "今年计划缴存(元,上限12000)", type: "number", min: 0, max: 12000, step: 1000, def: 12000 },
  { k: "balance", label: "账户内已有余额(元)", type: "number", min: 0, max: 10000000, step: 1000, def: 0 },
  { k: "emergency", label: "应急金能覆盖几个月生活开支", type: "select", opts: ["不到3个月", "3–6个月", "6–12个月", "12个月以上"], def: "3–6个月" },
  { k: "experience", label: "投资经验", type: "select",
    opts: ["几乎没有", "买过银行理财/货币基金", "买过基金或股票(3年内)", "3年以上基金/股票经验"], def: "买过银行理财/货币基金" },
  { k: "drawdown", label: "一年内能接受的最大亏损", type: "select", opts: ["不能亏", "5%以内", "10%左右", "20%左右", "30%以上"], def: "10%左右" },
  { k: "family", label: "家庭责任", type: "select", opts: ["单身无负担", "已婚暂无子女", "有子女需抚养", "需赡养老人", "上有老下有小"], def: "有子女需抚养" },
  { k: "other", label: "已有的其他养老储备(可多选)", type: "multi", opts: ["企业/职业年金", "商业养老保险", "长期基金定投", "房产", "暂无"], def: ["暂无"] },
  { k: "expense", label: "期望退休后每月支出(按今天物价,元)", type: "number", min: 0, max: 200000, step: 500, def: 8000 },
  { k: "concern", label: "关于养老金,你现在最想解决的问题(选填)", type: "text", wide: true, def: "" },
];
const TAX_RATE = { "10万以下": 0.03, "10–20万": 0.10, "20–40万": 0.20, "40–70万": 0.25, "70–100万": 0.30, "100万以上": 0.45 };
const DRAWDOWN_CAP = { "不能亏": 15, "5%以内": 30, "10%左右": 50, "20%左右": 70, "30%以上": 85 };
const EXP_ADJ = { "几乎没有": -10, "买过银行理财/货币基金": -5, "买过基金或股票(3年内)": 0, "3年以上基金/股票经验": 5 };

/* ---------------- 状态 ---------------- */
let S = { answers: {}, qi: 0, pension: {}, result: null };
const save = () => { try { localStorage.setItem(STORE, JSON.stringify(S)); } catch (e) {} };
const load = () => { try { return JSON.parse(localStorage.getItem(STORE)); } catch (e) { return null; } };
const cfg = () => { try { return JSON.parse(localStorage.getItem(CFG)) || {}; } catch (e) { return {}; } };

/* ---------------- 计分(与 src/wmbti/scoring.py 一致) ---------------- */
function score(answers) {
  let code = ""; const clarity = {};
  for (const dim of DIMS) {
    const qs = QUESTIONS.filter((q) => q.dim === dim);
    const total = qs.reduce((s, q) => s + (answers[q.qid] || 0), 0);
    code += total >= 0 ? dim[0] : dim[1];
    clarity[dim] = Math.abs(total) / (2 * qs.length);
  }
  return { code, clarity, functions: functionStrengths(code, clarity), borderline: DIMS.filter((d) => clarity[d] < 0.2) };
}
function functionStrengths(code, clarity) {
  const stack = TYPES[code].stack, flip = { i: "e", e: "i" };
  const shadow = stack.map((f) => f[0] + flip[f[1]]);
  const base = {}; [100, 80, 50, 30].forEach((v, i) => (base[stack[i]] = v)); [45, 40, 25, 20].forEach((v, i) => (base[shadow[i]] = v));
  const dimOf = (l) => DIMS.find((d) => d.includes(l));
  const out = {};
  for (const fn of FUNCTION_ORDER) {
    const c = clarity[dimOf(fn[0])], lean = code.includes(fn[0]) ? c : 1 - c;
    out[fn] = Math.round(base[fn] * (0.6 + 0.4 * lean));
  }
  return out;
}

/* ---------------- 校准与配置(确定性) ---------------- */
function split(total, roles, preferred) {
  const w = {}; roles.forEach((r) => (w[r] = preferred.includes(r) ? 2 : 1));
  const s = roles.reduce((a, r) => a + w[r], 0), out = {};
  roles.forEach((r) => (out[r] = Math.floor((total * w[r]) / s)));
  const first = roles.reduce((a, r) => (w[r] > w[a] ? r : a), roles[0]);
  out[first] += total - roles.reduce((a, r) => a + out[r], 0);
  return out;
}
const rolesFor = (eq, pref) => ({ ...split(100 - eq, DEFENSIVE, pref), ...split(eq, GROWTH, pref) });

function compute(code, p) {
  const t = TYPES[code], b = t.behavior;
  const years = Math.max(p.retireAge - p.age, 0);
  const glide = clamp(20 + 2 * years, 20, 80);
  const cap = DRAWDOWN_CAP[p.drawdown];
  let before = clamp(Math.min(glide + EXP_ADJ[p.experience], cap), 5, 85);
  if (p.emergency === "不到3个月") before = Math.max(before - 5, 5);
  let after = clamp(before + b.equity_offset, 5, 85);
  if (b.equity_offset > 0) after = Math.min(after, Math.max(cap, before));

  const rate = TAX_RATE[p.income], contrib = clamp(+p.contribution || 0, 0, 12000);
  const tax = { rate, saveNow: contrib * rate, payLater: contrib * 0.03, net: contrib * (rate - 0.03),
                maxSave: 12000 * rate, worth: rate > 0.03 };
  const retireYear = new Date().getFullYear() + years;
  return {
    years, retireYear, glide, cap, before, after, tax, contrib,
    rolesBefore: rolesFor(before, []), rolesAfter: rolesFor(after, t.assets),
    targetVintage: Math.round(retireYear / 5) * 5,
  };
}

/* ---------------- 规则选品(无大模型时的兜底,也用于校验) ---------------- */
function rulePicks(code, p, c) {
  const t = TYPES[code], items = CATALOG.items, picks = [];
  const byRole = (r) => items.filter((x) => x.role === r);
  const conservative = c.after <= 35 || ["SJ"].includes(t.matrix) || ["INFP", "ISFP"].includes(code);
  const add = (list, n) => list.slice(0, n).forEach((x) => picks.push({ id: x.id, weight: 1, reason: "" }));

  // 自动挡中场:目标日期选最接近退休年份的;保守者再配一只稳健目标风险
  const fof = byRole("自动挡中场");
  const td = fof.filter((x) => x.targetYear).sort((a, b) => Math.abs(a.targetYear - c.targetVintage) - Math.abs(b.targetYear - c.targetVintage));
  const tr = fof.filter((x) => !x.targetYear);
  add(td, 1); add(conservative ? tr.filter((x) => /稳健/.test(x.name + x.subtype)) : tr.filter((x) => /平衡|积极/.test(x.name + x.subtype)), 1);
  // 前锋:保守/价值型偏红利,其余偏宽基
  const idx = byRole("前锋");
  const div = idx.filter((x) => (x.tags || []).includes("红利")), broad = idx.filter((x) => (x.tags || []).includes("宽基"));
  conservative ? (add(div, 1), add(broad, 1)) : (add(broad, 2));
  add(byRole("后卫").sort((a, b) => riskRank(a) - riskRank(b)), 2);
  add(byRole("守门员"), 2);
  add(byRole("长期后勤官"), 1);
  return picks;
}
const riskRank = (x) => ["低", "中低", "中", "中高", "高"].indexOf(x.risk);

/** 把选品(带权重)换算成占比与金额;剔除目录外的 id;某岗位没选品则用规则兜底。 */
function materialize(picks, code, p, c) {
  const byId = Object.fromEntries(CATALOG.items.map((x) => [x.id, x]));
  const fallback = rulePicks(code, p, c);
  const out = [];
  for (const role of Object.keys(ROLES)) {
    let sel = (picks || []).filter((k) => byId[k.id] && byId[k.id].role === role);
    if (!sel.length) sel = fallback.filter((k) => byId[k.id].role === role);
    sel = sel.slice(0, 2);
    const wsum = sel.reduce((a, k) => a + (+k.weight > 0 ? +k.weight : 1), 0) || 1;
    let left = c.rolesAfter[role];
    sel.forEach((k, i) => {
      const pct = i === sel.length - 1 ? left : Math.round((c.rolesAfter[role] * (+k.weight > 0 ? +k.weight : 1)) / wsum);
      left -= pct;
      out.push({ ...byId[k.id], pct, amount: (c.contrib * pct) / 100, stock: (p.balance * pct) / 100, reason: k.reason || "" });
    });
  }
  return out;
}

/* ---------------- Kimi ---------------- */
const Kimi = {
  base() { const c = cfg(); return (c.proxy || "https://api.moonshot.cn/v1").replace(/\/+$/, ""); },
  headers() { const c = cfg(), h = { "Content-Type": "application/json" }; if (!c.proxy && c.key) h.Authorization = "Bearer " + c.key; return h; },
  ready() { const c = cfg(); return !!(c.key || c.proxy); },
  async models() {
    const r = await fetch(this.base() + "/models", { headers: this.headers() });
    if (!r.ok) throw new Error("HTTP " + r.status + " " + (await r.text()).slice(0, 200));
    return (await r.json()).data.map((m) => m.id).sort();
  },
  /** 选定模型:优先用户设置;否则从账号可用模型里挑(通用模型优先,排除 code 专用)。 */
  async resolveModel(force) {
    const c = cfg();
    if (c.model && !force) return c.model;
    const list = await this.models(), pref = ["kimi-k3", "kimi-k2.6", "kimi-latest", "moonshot-v1-32k"];
    const model = pref.find((m) => list.includes(m)) || list.find((m) => !/code|vision/.test(m)) || list[0];
    localStorage.setItem(CFG, JSON.stringify({ ...cfg(), model, models: list }));
    return model;
  },
  async json(messages, retry = true) {
    const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), 300000);
    try {
      const model = await this.resolveModel();
      // 不传 temperature:Kimi 新一代推理模型只接受默认值;推理过程也计入 max_tokens,所以给足额度
      const r = await fetch(this.base() + "/chat/completions", {
        method: "POST", headers: this.headers(), signal: ctl.signal,
        body: JSON.stringify({ model, messages, max_tokens: 16000, response_format: { type: "json_object" } }),
      });
      if (!r.ok) {
        const msg = (await r.text()).slice(0, 300);
        if (retry && (r.status === 404 || /model/i.test(msg))) { await this.resolveModel(true); return this.json(messages, false); }
        throw new Error("HTTP " + r.status + " " + msg);
      }
      const txt = (await r.json()).choices[0].message.content || "";
      return JSON.parse(txt.replace(/^\s*```(?:json)?/i, "").replace(/```\s*$/, "").trim());
    } finally { clearTimeout(timer); }
  },
};

function buildPrompt(code, a, p, c) {
  const t = TYPES[code], m = MATRICES[t.matrix];
  const cat = CATALOG.items.map((x) => `${x.id}|${x.role}|${x.name}|${x.code || "-"}|${x.issuer}|风险${x.risk}|${x.hold || "-"}|${x.note || ""}`).join("\n");
  const sys = `你是"犀鸟财富伴侣",一位面向中国居民的养老金规划顾问,正在为一位用户撰写《W-MBTI养老财富身份与个人养老金配置报告》。
写作要求:
- 简体中文,第二人称"你",专业但口语化;按下面"对TA说话的方式"调整语气。类型是帮助理解用户的语言而不是标签,不要说"你们XX型都……",让用户觉得准确且有尊严。
- 所有数字(仓位、占比、金额、税优)已由系统算好,原样引用,不得改动或自创数字;不得承诺或预测收益率。
- 选品只能从"产品目录"中选择,只在 picks[].id 字段里用 id 引用,正文和理由里一律写产品名称、不要出现 id;不得编造目录外的产品、代码或利率。每个资产岗位选1–2只,weight 表示同一岗位内的相对权重。
- 选品理由必须同时联系:①这只产品在组合中的岗位,②用户的客观情况,③用户的财富身份与行为特点。目标日期基金优先选择最接近用户退休年份(${c.retireYear},建议档 ${c.targetVintage})的。
- 区分事实、假设与情景;不确定就明说。不制造焦虑,不使用 R3/R4 这类黑箱术语而不解释。
- 只输出一个 JSON 对象,不要输出其它文字。`;

  const user = `【财富身份】${t.code} ${t.name}(${m.name}矩阵;主导 ${t.stack[0]},辅助 ${t.stack[1]},劣势 ${t.stack[3]})
宣言:${t.motto}
决策逻辑:${t.logic}
偏好的资产岗位:${t.assets.join("、")}(${t.asset_note})
压力下的阴影状态:${t.shadow}
行为护栏:${t.behavior.guardrail}
对TA说话的方式:${t.behavior.tone};矩阵交互策略:${m.interaction}
偏好清晰度:${DIMS.map((d) => d + " " + Math.round(a.clarity[d] * 100) + "%").join(",")}${a.borderline.length ? ";边界维度:" + a.borderline.join("、") : ""}
八维功能强度:${FUNCTION_ORDER.map((f) => f + " " + a.functions[f]).join(",")}

【用户的养老底盘】
年龄 ${p.age},计划 ${p.retireAge} 岁退休(约 ${c.retireYear} 年,还有 ${c.years} 年)
年税前收入:${p.income}(估算最高边际税率 ${Math.round(c.tax.rate * 100)}%)
个人养老金账户:${p.account};今年计划缴存 ${c.contrib} 元;账户已有余额 ${p.balance} 元
应急金:${p.emergency};投资经验:${p.experience};一年内可接受最大亏损:${p.drawdown}
家庭责任:${p.family};其他养老储备:${(p.other || []).join("、")}
期望退休后月支出(今天物价):${p.expense} 元
最想解决的问题:${p.concern || "(未填写)"}

【系统已算好的结果】
税优:今年缴存 ${c.contrib} 元,当期约省税 ${Math.round(c.tax.saveNow)} 元,领取时按3%缴税约 ${Math.round(c.tax.payLater)} 元,净税优约 ${Math.round(c.tax.net)} 元${c.tax.worth ? "" : "(税率不高于3%,税优基本为零,需提醒用户:缴存的主要意义是强制储蓄而非节税,并注意资金要锁定到退休)"}
校准前(只看客观条件)权益占比 ${c.before}% → 校准后(叠加财富身份)${c.after}%(类型校准 ${t.behavior.equity_offset >= 0 ? "+" : ""}${t.behavior.equity_offset} 个百分点)
校准后各岗位占比:${Object.entries(c.rolesAfter).map(([r, v]) => `${r}(${ROLES[r]}) ${v}%`).join(",")}
建议缴费节奏:${t.behavior.rhythm};触达频率:${t.behavior.touch}

【产品目录】(数据截至 ${CATALOG.asOf};格式:id|岗位|名称|代码|机构|风险|持有期|备注)
${cat}

【政策要点】
${CATALOG.policy.map((x) => "- " + x).join("\n")}

请输出 JSON:
{
 "identity_reading": "对用户财富身份的解读,250–350字:TA如何决定、学习和坚持,优势与盲区,为什么传统风险问卷看不到这些",
 "foundation_reading": "对养老底盘的解读,200–300字:时间、税优是否值得、应急金与流动性、家庭责任、已有储备;直接回应用户最想解决的问题",
 "calibration_reading": "解释校准前→校准后发生了什么变化或确认了什么,150–250字",
 "picks": [{"id": "目录id", "weight": 1, "reason": "60–120字的选品理由"}],
 "outside_account": "账户外的配套安排建议(应急金、保险保障、其余长期资金),120–200字,不点名目录外产品",
 "action_steps": ["3–5条按顺序的、今天就能开始的具体动作"],
 "stress_plan": "市场大跌或生活变故时,针对TA的阴影状态的预案,150–250字",
 "one_liner": "一句话总结这套方案为什么属于TA,40字以内"
}`;
  return [{ role: "system", content: sys }, { role: "user", content: user }];
}

function ruleNarrative(code, p, c) {
  const t = TYPES[code], b = t.behavior, dir = c.after < c.before ? "下调" : c.after > c.before ? "上调" : "确认";
  return {
    identity_reading: `${t.logic}这意味着你在养老金这件事上的优势是「${MATRICES[t.matrix].strength}」。需要留意的是压力下的另一面:${t.shadow}`,
    foundation_reading: `你距离计划退休还有约 ${c.years} 年。按估算税率 ${Math.round(c.tax.rate * 100)}%,今年缴存 ${yuan(c.contrib)} 的净税优约 ${yuan(c.tax.net)}。${c.tax.worth ? "" : "你的税率不高于3%,缴存的意义主要是强制储蓄而不是节税,请先确认这笔钱可以锁定到退休。"}${p.emergency === "不到3个月" ? "你的应急金偏薄,建议先补足3–6个月生活开支,再考虑缴满。" : ""}`,
    calibration_reading: `只看客观条件,你可以承担约 ${c.before}% 的权益仓位;叠加你的财富身份后${dir}为 ${c.after}%。缴费节奏建议「${b.rhythm}」。`,
    picks: rulePicks(code, p, c),
    outside_account: "个人养老金账户内的钱要锁定到退休,所以账户外请先留足3–6个月应急金,并确认重疾、医疗、意外等基础保障已到位,其余长期资金再按同样的岗位思路安排。",
    action_steps: [p.account === "尚未开通" ? "在常用银行App开通个人养老金资金账户" : "登录个人养老金资金账户,核对余额与持仓", `按「${b.rhythm}」设置缴存`, "按下表的岗位与占比逐项买入,买入前阅读产品说明书", "在个税App上传缴费凭证,办理税前扣除", "每年做一次复盘与再平衡"],
    stress_plan: `${t.shadow} 护栏:${b.guardrail}。`,
    one_liner: `为「${t.name}」准备的、拿得住的养老金方案。`,
  };
}

/** 模型偶尔会在正文里写目录 id(如 GK04),统一换成产品名;picks[].id 保持不变。 */
function deId(n) {
  const names = Object.fromEntries(CATALOG.items.map((x) => [x.id, "「" + x.name + "」"]));
  const fix = (v) => (typeof v === "string" ? v.replace(/\b(?:FOF|IDX|WM|GK|INS)\d{2}\b/g, (m) => names[m] || m) : v);
  const out = {};
  for (const [k, v] of Object.entries(n)) {
    if (k === "picks") out[k] = (v || []).map((x) => ({ ...x, reason: fix(x.reason) }));
    else out[k] = Array.isArray(v) ? v.map(fix) : fix(v);
  }
  return out;
}

/* ---------------- 报告渲染 ---------------- */
function renderReport(R) {
  const { code, a, p, c, n, picks, mode } = R, t = TYPES[code], m = MATRICES[t.matrix];
  const today = new Date().toISOString().slice(0, 10);
  const para = (s) => String(s || "").split(/\n+/).map((x) => `<p>${esc(x)}</p>`).join("");
  const roleRows = Object.keys(ROLES).map((r) => `<tr><td>${r}</td><td>${ROLES[r]}</td><td class="num">${c.rolesBefore[r]}%</td><td class="num"><b>${c.rolesAfter[r]}%</b></td><td><div class="bar"><i style="width:${c.rolesAfter[r]}%"></i></div></td><td class="num">${yuan((c.contrib * c.rolesAfter[r]) / 100)}</td></tr>`).join("");
  const H5 = "<h2>五、具体产品建议(个人养老金账户内)</h2>";
  const prodHtml = Object.keys(ROLES).map((r, ri) => {
    const ps = picks.filter((x) => x.role === r); if (!ps.length) return "";
    return `<div class="avoid">${ri === 0 ? H5 : ""}<h3>${r} · ${ROLES[r]}(合计 ${c.rolesAfter[r]}%)</h3>` + ps.map((x) => `<div class="prod">
      <span class="amt">${x.pct}% · ${yuan(x.amount)}/年</span>
      <div class="name">${esc(x.name)}${x.code ? `(${esc(x.code)})` : ""}</div>
      <div class="meta"><span class="chip">${esc(x.cat)}</span><span class="chip">风险 ${esc(x.risk)}</span>${x.hold ? `<span class="chip">${esc(x.hold)}</span>` : ""} ${esc(x.issuer)}${x.note ? " · " + esc(x.note) : ""}</div>
      <div>${esc(x.reason || "按岗位规则选入:与你的退休时间、风险边界和财富身份匹配。")}</div>
      ${p.balance > 0 ? `<div class="muted">存量参考:账户现有余额按此占比约对应 ${yuan(x.stock)}</div>` : ""}</div>`).join("") + "</div>";
  }).join("");

  $("report").innerHTML = `
  <div class="cover">
    <div class="kicker">犀鸟财富伴侣 · W-MBTI</div>
    <h1>养老财富身份与个人养老金配置报告</h1>
    <div class="type">${t.code} · ${esc(t.name)} <span class="muted">/ ${m.name}矩阵</span></div>
    <div class="muted">生成日期 ${today} · 产品数据截至 ${esc(CATALOG.asOf)} · ${mode}</div>
    ${n.one_liner ? `<div class="motto">${esc(n.one_liner)}</div>` : ""}
  </div>

  <h2>一、你的财富身份</h2>
  <div class="two"><div>
    <div class="motto">“${esc(t.motto)}”</div>
    <p><b>船长(主导功能)</b> ${t.stack[0]} · <b>副手(辅助功能)</b> ${t.stack[1]}</p>
    <p><b>偏好的资产岗位</b> ${t.assets.map((r) => r + "(" + ROLES[r] + ")").join("、")}</p>
    <p><b>核心认知优势</b> ${esc(m.strength)}</p>
  </div><div><img id="reportRadar" alt="八爪图" style="width:100%"></div></div>
  ${para(n.identity_reading)}
  <div class="warn"><b>阴影状态 · 压力下要留意:</b>${esc(t.shadow)}</div>
  <p class="muted">偏好清晰度:${DIMS.map((d) => d + " " + Math.round(a.clarity[d] * 100) + "%").join(" · ")}${a.borderline.length ? "。边界维度:" + a.borderline.join("、") + "——这些维度上你的偏好不明显,相关描述可能只部分适用。" : ""}</p>

  <h2>二、你的养老底盘</h2>
  <div class="kpis">
    <div class="kpi"><b>${c.years} 年</b><span>距计划退休(约 ${c.retireYear} 年)</span></div>
    <div class="kpi"><b>${yuan(c.contrib)}</b><span>今年计划缴存 / 上限 ¥12,000</span></div>
    <div class="kpi"><b>${yuan(c.tax.net)}</b><span>估算净税优(税率约 ${Math.round(c.tax.rate * 100)}%,领取时3%)</span></div>
    <div class="kpi"><b>${c.after}%</b><span>校准后权益占比</span></div>
  </div>
  ${para(n.foundation_reading)}

  <h2>三、校准前 → 新信息 → 校准后</h2>
  <table><tr><th></th><th>校准前 · 只看客观条件</th><th>校准后 · 叠加 ${t.code}</th></tr>
    <tr><td>权益类占比</td><td>${c.before}%</td><td><b>${c.after}%</b></td></tr>
    <tr><td>缴费节奏</td><td>月度缴费(默认)</td><td>${esc(t.behavior.rhythm)}</td></tr>
    <tr><td>陪伴与提醒频率</td><td>中频(默认)</td><td>${esc(t.behavior.touch)}</td></tr>
    <tr><td>行为护栏</td><td>—</td><td>${esc(t.behavior.guardrail)}</td></tr></table>
  ${para(n.calibration_reading)}

  <h2>四、资产岗位配置</h2>
  <table><tr><th>岗位</th><th>对应资产</th><th class="num">校准前</th><th class="num">校准后</th><th></th><th class="num">今年缴存分配</th></tr>${roleRows}</table>
  <p class="muted">球队隐喻:守门员守住本金,后卫提供稳健收益,自动挡中场随年龄自动换挡,前锋负责长期增长,长期后勤官提供终身现金流。</p>

  ${prodHtml}
  <p class="muted">以上产品均选自个人养老金产品目录中的公开产品。可购买范围取决于你的开户银行与销售机构,买入前请在银行App或国家社会保险公共服务平台核对产品是否在售、最新费率与利率。</p>

  <h2>六、账户外的配套安排</h2>
  ${para(n.outside_account)}

  <h2>七、下一步行动</h2>
  <div class="steps">${(n.action_steps || []).map((s, i) => `<div class="step avoid"><b>${i + 1}</b><span>${esc(String(s).replace(/^\s*\d+[.、)]\s*/, ""))}</span></div>`).join("")}</div>

  <h2>八、压力情景预案</h2>
  ${para(n.stress_plan)}

  <div class="disclaimer avoid"><b>重要声明</b><br>
  本报告由研究演示系统自动生成,${mode.includes("Kimi") ? "解读文字与选品理由由 Kimi 大模型撰写," : ""}仓位、金额与税优为基于你所填信息的简化估算。报告不构成任何投资建议、要约或收益承诺;撰写方不是持牌基金投资顾问或保险销售机构,不代客交易,也不因任何产品获得佣金。
  基金、理财产品有风险,过往业绩不代表未来表现;保险结算利率与储蓄利率会调整。个人养老金资金账户封闭运行,除达到领取条件外不得提前支取。请在充分阅读产品法律文件、结合自身情况独立判断后再做决定。</div>`;

  $("reportRadar").src = radarImage(a.functions);
  $("reportMode").textContent = mode;
}

/* ---------------- 八爪图 ---------------- */
let radarChart;
function radarConfig(fn, light) {
  const ink = light ? "#374151" : "#CBD5E1", grid = light ? "#d1d5db" : "rgba(255,255,255,.12)";
  return { type: "radar",
    data: { labels: FUNCTION_ORDER.map((f) => FUNCTION_LABELS[f].split(" ")), datasets: [{ data: FUNCTION_ORDER.map((f) => fn[f]),
      borderColor: light ? "#059669" : "#34D399", backgroundColor: light ? "rgba(16,185,129,.18)" : "rgba(52,211,153,.18)", borderWidth: 2, pointRadius: 4,
      pointBackgroundColor: light ? "#059669" : "#34D399" }] },
    options: { animation: !light, responsive: !light, plugins: { legend: { display: false }, tooltip: { callbacks: { title: (i) => i[0].label.replace(",", " "), label: (i) => "强度 " + i.raw } } },
      scales: { r: { min: 0, max: 100, ticks: { stepSize: 25, display: false }, grid: { color: grid }, angleLines: { color: grid }, pointLabels: { color: ink, font: { size: light ? 15 : 11 } } } } } };
}
function drawRadar(fn) { if (radarChart) radarChart.destroy(); radarChart = new Chart($("radar"), radarConfig(fn, false)); }
function radarImage(fn) {
  const cv = document.createElement("canvas"); cv.width = 640; cv.height = 520;
  const ch = new Chart(cv, radarConfig(fn, true)); const url = cv.toDataURL("image/png"); ch.destroy(); return url;
}

/* ---------------- 界面流程 ---------------- */
const STEPS = { home: [0, ""], quiz: [10, "① 身份测评"], identity: [55, "② 财富身份"], pension: [70, "③ 养老金账户"], loading: [90, "④ 生成报告"], report: [100, "⑤ 我的报告"] };
const App = {
  go(name) {
    document.querySelectorAll(".screen").forEach((s) => s.classList.remove("active"));
    $("s-" + name).classList.add("active");
    $("stepLabel").textContent = STEPS[name][1];
    if (name !== "quiz") $("progress").style.width = STEPS[name][0] + "%";
    if (name === "quiz") this.showQ();
    if (name === "identity") this.showIdentity();
    if (name === "pension") this.showPension();
    window.scrollTo(0, 0);
  },
  start() { S = { answers: {}, qi: 0, pension: {}, result: null }; save(); this.go("quiz"); },
  restart() { this.start(); },
  resume() { const o = load(); if (o) S = o; this.go(Object.keys(S.answers).length >= QUESTIONS.length ? "identity" : "quiz"); },

  showQ() {
    const q = QUESTIONS[S.qi];
    $("qCounter").textContent = `第 ${S.qi + 1} / ${QUESTIONS.length} 题`;
    $("qAspect").textContent = q.aspect; $("qPrompt").textContent = q.prompt; $("qA").textContent = q.a; $("qB").textContent = q.b;
    $("progress").style.width = 10 + (45 * S.qi) / QUESTIONS.length + "%";
    $("qScale").innerHTML = SCALE.map(([lab, v]) => `<button class="opt rounded-xl py-3 ${S.answers[q.qid] === v ? "on" : ""}" onclick="App.answer(${v})">${lab}</button>`).join("");
  },
  answer(v) {
    S.answers[QUESTIONS[S.qi].qid] = v; save();
    if (S.qi < QUESTIONS.length - 1) { S.qi++; save(); setTimeout(() => this.showQ(), 120); } else this.go("identity");
  },
  prevQ() { if (S.qi > 0) { S.qi--; this.showQ(); } else this.go("home"); },

  showIdentity() {
    const a = score(S.answers), t = TYPES[a.code], m = MATRICES[t.matrix];
    $("idCode").textContent = t.code; $("idName").textContent = t.name;
    $("idSub").textContent = `${m.name}矩阵(${t.matrix}) · 船长 ${t.stack[0]} / 副手 ${t.stack[1]}`;
    $("idMotto").textContent = `“${t.motto}”`;
    const row = (k, v) => `<div><div class="text-white font-semibold">${k}</div><div>${esc(v)}</div></div>`;
    $("idBody").innerHTML = row("你的决策机制", t.logic) + row("偏好的资产岗位", t.assets.map((r) => `${r}(${ROLES[r]})`).join("、") + " —— " + t.asset_note) +
      row("核心认知优势", m.strength) +
      `<div class="rounded-xl p-4 bg-amber-400/10 border border-amber-400/25 text-amber-100"><b>阴影状态 · 压力下要留意</b><br>${esc(t.shadow)}</div>` + row("行为护栏", t.behavior.guardrail);
    $("idClarity").textContent = "偏好清晰度:" + DIMS.map((d) => `${d} ${Math.round(a.clarity[d] * 100)}%`).join(" · ") + (a.borderline.length ? ` · 边界维度:${a.borderline.join("、")}` : "");
    drawRadar(a.functions);
  },

  showPension() {
    const f = $("pensionForm"); if (f.dataset.built) return; f.dataset.built = 1;
    f.innerHTML = PENSION_Q.map((q) => {
      const v = S.pension[q.k] ?? q.def, hint = q.hint ? `<div class="text-xs text-slate-500 mt-1">${q.hint}</div>` : "";
      let input;
      if (q.type === "select") input = `<select class="field" name="${q.k}">${q.opts.map((o) => `<option ${o === v ? "selected" : ""}>${o}</option>`).join("")}</select>`;
      else if (q.type === "multi") input = `<div class="flex flex-wrap gap-2">${q.opts.map((o) => `<button type="button" data-multi="${q.k}" data-v="${o}" class="opt rounded-full px-4 py-1.5 text-sm ${v.includes(o) ? "on" : ""}">${o}</button>`).join("")}</div>`;
      else if (q.type === "text") input = `<textarea class="field" name="${q.k}" rows="2" maxlength="300" placeholder="例如:每年12000到底要不要交满?交了买什么?">${esc(v)}</textarea>`;
      else input = `<input class="field" type="number" name="${q.k}" min="${q.min}" max="${q.max}" step="${q.step || 1}" value="${v}">`;
      return `<div class="${q.wide ? "md:col-span-2" : ""}"><label class="block text-sm text-slate-300 mb-1.5">${q.label}</label>${input}${hint}</div>`;
    }).join("");
    f.addEventListener("click", (e) => {
      const b = e.target.closest("[data-multi]"); if (!b) return;
      const none = b.dataset.v === "暂无";
      f.querySelectorAll(`[data-multi="${b.dataset.multi}"]`).forEach((x) => { if (none || x.dataset.v === "暂无") x.classList.remove("on"); });
      b.classList.toggle("on", none ? true : !b.classList.contains("on"));
    });
  },
  readPension() {
    const f = $("pensionForm"), p = {};
    for (const q of PENSION_Q) {
      if (q.type === "multi") p[q.k] = [...f.querySelectorAll(`[data-multi="${q.k}"].on`)].map((x) => x.dataset.v);
      else { const el = f.elements[q.k]; p[q.k] = q.type === "number" ? clamp(+el.value || 0, q.min, q.max) : el.value.trim(); }
    }
    if (!p.other.length) p.other = ["暂无"];
    if (p.retireAge <= p.age) throw new Error("计划退休年龄需要大于当前年龄。");
    return p;
  },

  async generate() {
    let p; try { p = this.readPension(); } catch (e) { $("pensionErr").textContent = e.message; return; }
    $("pensionErr").textContent = ""; S.pension = p; save();
    const a = score(S.answers), code = a.code, c = compute(code, p);
    this.go("loading");
    let n, mode;
    if (Kimi.ready()) {
      const t0 = Date.now(), tick = setInterval(() => ($("loadMsg").textContent = `Kimi 正在为你撰写报告… 已用时 ${Math.round((Date.now() - t0) / 1000)} 秒`), 1000);
      this._tick = tick;
      try { n = await Kimi.json(buildPrompt(code, a, p, c)); mode = `由 Kimi(${cfg().model})撰写`; }
      catch (e) { console.error(e); n = null; mode = "规则引擎简版(Kimi 调用失败:" + String(e.message).slice(0, 80) + ")"; }
      finally { clearInterval(this._tick); }
    } else mode = "规则引擎简版(未配置 Kimi,点击右上角「AI 设置」后可生成完整版)";
    const base = ruleNarrative(code, p, c);
    n = deId({ ...base, ...(n || {}) });
    if (!Array.isArray(n.action_steps) || !n.action_steps.length) n.action_steps = base.action_steps;
    const picks = materialize(n.picks, code, p, c);
    S.result = { code, a, p, c, n, picks, mode }; save();
    renderReport(S.result); this.go("report");
  },

  async downloadPDF() {
    const t = TYPES[S.result.code];
    await html2pdf().set({
      margin: [10, 0, 12, 0], filename: `W-MBTI养老财富报告_${t.code}_${new Date().toISOString().slice(0, 10)}.pdf`,
      image: { type: "jpeg", quality: 0.96 }, html2canvas: { scale: 2, backgroundColor: "#ffffff", useCORS: true },
      jsPDF: { unit: "mm", format: "a4", orientation: "portrait" }, pagebreak: { mode: ["css", "legacy"], avoid: [".avoid", ".prod", "table", ".kpis", ".motto", ".warn", "h2", "h3", "img"] },
    }).from($("report")).save();
  },
};

/* ---------------- 设置 ---------------- */
const DEFAULT_MODELS = ["kimi-k3", "kimi-k2.6"];
const Settings = {
  open() { const c = cfg(); $("setKey").value = c.key || ""; $("setProxy").value = c.proxy || ""; this.fill(c.models || DEFAULT_MODELS, c.model); $("setMsg").textContent = ""; $("settings").classList.replace("hidden", "flex"); },
  close() { $("settings").classList.replace("flex", "hidden"); },
  fill(list, cur) { $("setModel").innerHTML = list.map((m) => `<option ${m === (cur || DEFAULT_MODELS[0]) ? "selected" : ""}>${esc(m)}</option>`).join(""); },
  persist() { const c = { ...cfg(), key: $("setKey").value.trim(), proxy: $("setProxy").value.trim(), model: $("setModel").value }; localStorage.setItem(CFG, JSON.stringify(c)); return c; },
  save() { this.persist(); this.close(); },
  async loadModels() {
    this.persist(); $("setMsg").textContent = "正在获取模型列表…";
    try { const list = await Kimi.models(); const c = { ...cfg(), models: list }; localStorage.setItem(CFG, JSON.stringify(c)); this.fill(list, c.model); $("setMsg").textContent = `✅ 已获取 ${list.length} 个模型`; }
    catch (e) { $("setMsg").textContent = "❌ " + e.message; }
  },
  async test() {
    this.persist(); $("setMsg").textContent = "测试中…";
    try { const r = await Kimi.json([{ role: "user", content: '请只输出 JSON:{"ok":true}' }]); $("setMsg").textContent = r.ok ? "✅ 连接正常" : "⚠️ 已连通,但返回格式异常"; }
    catch (e) { $("setMsg").textContent = "❌ " + e.message; }
  },
};

$("btnSettings").onclick = () => Settings.open();
// 一次性导入:打开 …/wmbti/#key=sk-xxx 会把 Key 存入本机浏览器并立刻从地址栏抹掉(# 后的内容不会发送到服务器)
(() => {
  const m = location.hash.match(/[#&]key=([^&]+)/), px = location.hash.match(/[#&]proxy=([^&]+)/);
  if (!m && !px) return;
  const c = cfg(); if (m) c.key = decodeURIComponent(m[1]); if (px) c.proxy = decodeURIComponent(px[1]);
  delete c.model; localStorage.setItem(CFG, JSON.stringify(c));
  history.replaceState(null, "", location.pathname);
})();
if (load() && Object.keys(load().answers || {}).length) $("btnResume").classList.remove("hidden");
