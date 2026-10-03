/* 养老工具箱:完全在浏览器里计算,不连接任何服务器,也不保存你的输入。
 * 所有金额按“今天的购买力”口径;公式与假设在页面上逐项说明。结果是粗略估算,不是你的实际待遇。
 */
const $ = (id) => document.getElementById(id);
const yuan = (x) => "¥" + Math.round(x).toLocaleString("zh-CN");
const clamp = (x, lo, hi) => Math.max(lo, Math.min(hi, x));
const num = (id) => { const v = parseFloat($(id).value); return Number.isFinite(v) ? v : null; };

/* ---------- 政策参数 ---------- */
const PENSION_CAP = 12000, WITHDRAW_TAX = 0.03;
const BRACKETS = [[36000, 0.03], [144000, 0.10], [300000, 0.20], [420000, 0.25], [660000, 0.30], [960000, 0.35], [Infinity, 0.45]];
// 个人账户养老金计发月数(国发〔2005〕38号)
const MONTHS = { 40: 233, 41: 230, 42: 226, 43: 223, 44: 220, 45: 216, 46: 212, 47: 208, 48: 204, 49: 199, 50: 195, 51: 190, 52: 185, 53: 180, 54: 175,
  55: 170, 56: 164, 57: 158, 58: 152, 59: 145, 60: 139, 61: 132, 62: 125, 63: 117, 64: 109, 65: 101, 66: 93, 67: 84, 68: 75, 69: 65, 70: 56 };
// 渐进式延迟法定退休年龄(2025-01-01 起施行):原年龄、起始出生年、每几个月延 1 个月、最多延几个月
const DELAY = { male: [60, 1965, 4, 36], female55: [55, 1970, 4, 36], female50: [50, 1975, 2, 60] };
// 缺口测算的三种情景(实际回报率:扣除通胀之后)
const SCEN = [["压力情景", 0.010, 0.000, 5], ["基准情景", 0.025, 0.010, 0], ["较顺利情景", 0.040, 0.020, 0]];

function statutoryAge(year, month, kind) {
  const [base, y0, step, cap] = DELAY[kind];
  const idx = (year - y0) * 12 + (month - 1);
  const delay = idx < 0 ? 0 : Math.min(cap, Math.floor(idx / step) + 1);
  const total = base * 12 + delay;
  const retire = new Date(year, month - 1 + total, 1);
  return { years: Math.floor(total / 12), months: total % 12, delay, date: retire, age: total / 12 };
}

function taxRate(income) {  // 由全年税前收入粗估最高边际税率:扣基本减除费用 6 万与社保公积金个人部分(约 10.5%)
  const taxable = income - 60000 - 0.105 * Math.min(income, 420000);
  if (taxable <= 0) return 0;
  return BRACKETS.find(([cap]) => taxable <= cap)[1];
}

function basicPension({ base, salary, yearsPast, yearsFuture, balance, retireAge }) {
  const idx = clamp(salary / base, 0.6, 3);                    // 平均缴费指数,按当前工资与当地平均工资之比估计
  const years = yearsPast + yearsFuture;
  const basic = base * (1 + idx) / 2 * years * 0.01;           // 基础养老金
  const contribBase = clamp(salary, 0.6 * base, 3 * base);
  const acct = (balance ?? 0.08 * contribBase * 12 * yearsPast) + 0.08 * contribBase * 12 * yearsFuture;
  const months = MONTHS[clamp(Math.round(retireAge), 40, 70)];
  return { idx, years, basic, acct, months, personal: acct / months, total: basic + acct / months };
}

const fv = (a, c, r, T) => a * (1 + r) ** T + (Math.abs(r) < 1e-9 ? c * T : c * ((1 + r) ** T - 1) / r);
const pvNeed = (need, r, N) => (Math.abs(r) < 1e-9 ? need * N : need * (1 - (1 + r) ** -N) / r);

/* ---------- 页面 ---------- */
function fillCity() {
  const sel = $("city");
  sel.innerHTML = Object.keys(CITY_BASE).map((c) => `<option>${c}</option>`).join("") + "<option>其他城市</option>";
  sel.value = "上海市";
  sel.onchange = () => {
    const b = CITY_BASE[sel.value];
    $("base").value = b ?? "";
    $("baseHint").textContent = b ? "由当地 2025 年度社保缴费基数上限折算,可按实际修改" : "暂无该地数据,请填写当地上年度月平均工资(养老金计发基数)";
  };
  sel.onchange();
}

function row(k, v, note = "") { return `<tr><td>${k}</td><td class="num"><b>${v}</b></td><td class="muted">${note}</td></tr>`; }

function calc() {
  const err = $("err"); err.textContent = "";
  const by = num("by"), bm = num("bm"), kind = $("kind").value, salary = num("salary"), base = num("base");
  const yearsPast = num("yearsPast") ?? 0, target = num("target"), longevity = +$("longevity").value;
  const savings = (num("savings") ?? 0) * 10000, monthly = num("monthly") ?? 0, income = (num("income") ?? 0) * 10000;
  if (!by || !bm || !salary || !base || !target) { err.textContent = "请填写出生年月、当地月平均工资、当前月工资和目标每月花销。"; return; }

  const now = new Date(), age = (now.getFullYear() - by) + (now.getMonth() + 1 - bm) / 12;
  const st = statutoryAge(by, bm, kind);
  const retireAge = num("retireAge") ?? st.age;
  const T = Math.max(0, retireAge - age);
  if (retireAge <= age) { err.textContent = "计划退休年龄需要大于当前年龄。"; return; }
  if (longevity <= retireAge + 4) { err.textContent = "寿命情景需要比退休年龄至少晚 5 年。"; return; }

  // ① 退休年限
  $("o-retire").innerHTML = `<table>${row("法定退休年龄", `${st.years} 岁${st.months ? " " + st.months + " 个月" : ""}`, st.delay ? `比原规定延后 ${st.delay} 个月` : "不受延迟退休影响")}
    ${row("法定退休时间", `${st.date.getFullYear()} 年 ${st.date.getMonth() + 1} 月`)}
    ${row("你计划的退休年龄", `${(+retireAge.toFixed(1))} 岁`, Math.abs(retireAge - st.age) > 0.05 ? "与法定年龄不同:可弹性提前或延后,最长 3 年,且提前不得低于原法定年龄" : "按法定年龄")}
    ${row("距离退休", `约 ${T.toFixed(1)} 年`)}</table>
    <p class="muted">依据:自 2025 年 1 月 1 日起施行的渐进式延迟法定退休年龄办法。另外,从 2030 年起,领取基本养老金的最低缴费年限由 15 年逐步提高到 20 年(每年提高 6 个月)。</p>`;

  // ② 退休金
  const p = basicPension({ base, salary, yearsPast, yearsFuture: T, balance: num("balance"), retireAge });
  const replace = p.total / salary;
  $("o-pension").innerHTML = `<div class="kpis"><div class="kpi"><b>${yuan(p.total)}</b><span>预计每月基本养老金</span></div>
    <div class="kpi"><b>${(replace * 100).toFixed(0)}%</b><span>相当于当前月工资的比例</span></div>
    <div class="kpi"><b>${p.years.toFixed(0)} 年</b><span>退休时累计缴费年限</span></div></div>
    <table>${row("基础养老金", yuan(p.basic), `当地月平均工资 × (1 + 缴费指数 ${p.idx.toFixed(2)}) ÷ 2 × 缴费年限 × 1%`)}
    ${row("个人账户养老金", yuan(p.personal), `个人账户储存额约 ${yuan(p.acct)} ÷ 计发月数 ${p.months}`)}</table>
    ${p.years < 15 ? '<div class="warn">按这些数字,退休时累计缴费不足 15 年,可能达不到按月领取的条件。</div>' : ""}
    <p class="muted">这是城镇职工基本养老保险(含灵活就业参保)的粗估,按今天的工资水平和购买力计算:假设你今后一直按当前工资相对当地平均工资的比例缴费,个人账户记账利率与工资增长大致相当;没有计入过渡性养老金和企业年金。实际待遇以社保部门核定为准。</p>`;

  // ③ 税优
  const rate = taxRate(income), net = PENSION_CAP * (rate - WITHDRAW_TAX);
  $("o-tax").innerHTML = `<table><tr><th>应纳税所得额对应税率</th><th class="num">缴满 12000 元当年少缴税</th><th class="num">领取时按 3% 缴税</th><th class="num">净节税</th></tr>
    ${BRACKETS.map(([, r]) => `<tr${income && r === rate ? ' style="background:#f8f0dc;font-weight:600"' : ""}><td>${(r * 100).toFixed(0)}%${income && r === rate ? " ← 你的估算档位" : ""}</td>
      <td class="num">${yuan(PENSION_CAP * r)}</td><td class="num">${yuan(PENSION_CAP * WITHDRAW_TAX)}</td><td class="num">${yuan(PENSION_CAP * (r - WITHDRAW_TAX))}</td></tr>`).join("")}</table>
    ${!income ? '<p class="muted">填写全年税前收入后,会标出你大致所在的档位。</p>'
      : rate === 0 ? '<div class="warn">按你填写的收入粗估,你目前可能不需要缴纳个人所得税。这种情况下缴存没有节税效果,领取时还要按 3% 缴税;缴存的意义主要是强制储蓄,而资金要锁定到退休。</div>'
      : rate <= WITHDRAW_TAX ? '<div class="warn">按你填写的收入粗估,你的最高税率约为 3%,与领取时的税率相同,税优基本为零。</div>'
      : `<p>按你填写的收入粗估,最高税率约 <b>${(rate * 100).toFixed(0)}%</b>:每年缴满 12000 元,当年约少缴税 <b>${yuan(PENSION_CAP * rate)}</b>,扣除领取时的税后净节税约 <b>${yuan(net)}</b>。</p>`}
    <p class="muted">税率档位只扣除了基本减除费用(每年 6 万元)和社保公积金个人部分的估算值,没有计入专项附加扣除,实际档位可能更低;以个税 App 的年度汇算为准。</p>`;

  // ④ 养老缺口
  const needMonthly = Math.max(0, target - p.total);
  let rows = "", anyGap = false;
  for (const [label, rPre, rPost, extraYears] of SCEN) {
    const N = longevity + extraYears - retireAge;
    const need = pvNeed(needMonthly * 12, rPost, N);
    const have = fv(savings, monthly * 12, rPre, T);
    const gap = need - have;
    if (gap > 0) anyGap = true;
    const g = (1 + rPre) ** T;
    const extra = gap <= 0 || T <= 0 ? 0 : (Math.abs(rPre) < 1e-9 ? gap / T : gap * rPre / (g - 1)) / 12;
    rows += `<tr><td>${label}<br><span class="muted">退休前实际回报 ${(rPre * 100).toFixed(1)}%,活到 ${longevity + extraYears} 岁</span></td>
      <td class="num">${yuan(need)}</td><td class="num">${yuan(have)}</td>
      <td class="num">${gap <= 0 ? "已覆盖" : "<b>" + yuan(gap) + "</b>"}</td><td class="num">${gap <= 0 ? "—" : yuan(extra)}</td></tr>`;
  }
  $("o-gap").innerHTML = `<div class="kpis"><div class="kpi"><b>${yuan(target)}</b><span>目标每月花销</span></div>
    <div class="kpi"><b>${yuan(p.total)}</b><span>预计每月基本养老金</span></div>
    <div class="kpi"><b>${yuan(needMonthly)}</b><span>每月需要自己补上的部分</span></div></div>
    ${needMonthly === 0 ? '<div class="motto">按这些数字,预计的基本养老金已经可以覆盖你的目标花销。</div>' : `
    <table><tr><th>情景</th><th class="num">退休时需要准备</th><th class="num">按现在的节奏能攒到</th><th class="num">缺口</th><th class="num">每月还需多存</th></tr>${rows}</table>
    ${anyGap ? `<p>个人养老金每年最多缴存 ${yuan(PENSION_CAP)}(每月 ${yuan(PENSION_CAP / 12)}),可以作为补上这部分缺口的一个账户;它在达到领取条件前不能取出。</p>`
      : "<p>按你现在的储蓄节奏,三种情景下都能覆盖这部分。可以在“测评”页的深度版里,把家庭责任、应急金和风险一起再核对一遍。</p>"}`}
    <p class="muted">口径:所有金额都是今天的购买力,回报率是扣除通胀后的实际回报率;三种情景只是假设,不是预测。“按现在的节奏能攒到”= 已有养老储蓄和每月养老储蓄按情景回报率滚存到退休。没有计入医疗与照护的额外开支、房产和其他收入。</p>`;

  $("results").hidden = false;
  if (window.FX) FX.countUp($("report"));
  $("results").scrollIntoView({ behavior: "smooth", block: "start" });
}

fillCity();
$("kind").onchange = $("by").onchange = $("bm").onchange = () => {
  const by = num("by"), bm = num("bm");
  if (by && bm) { const st = statutoryAge(by, bm, $("kind").value); $("retireAge").placeholder = `法定:${st.years} 岁${st.months ? st.months + " 个月" : ""}`; }
};
$("kind").onchange();
