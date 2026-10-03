/* 动效层(见 fx.css)。纯装饰:任何一步失败都不影响页面功能。 */
(() => {
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const fine = matchMedia("(hover: hover) and (pointer: fine)").matches;
  window.FX = { reveal() {}, countUp() {}, replay() {}, stagger() {} };
  if (reduce) return;

  /* ---- 金色微粒与连线 ---- */
  const cv = Object.assign(document.createElement("canvas"), { id: "fx-canvas" });
  document.body.prepend(cv);
  const ctx = cv.getContext("2d");
  let W, H, pts = [];
  const N = innerWidth < 700 ? 26 : 64, LINK = 130;
  function resize() {
    const d = Math.min(devicePixelRatio || 1, 2);
    W = innerWidth; H = innerHeight; cv.width = W * d; cv.height = H * d; cv.style.width = W + "px"; cv.style.height = H + "px";
    ctx.setTransform(d, 0, 0, d, 0, 0);
  }
  resize(); addEventListener("resize", resize);
  for (let i = 0; i < N; i++) pts.push({ x: Math.random() * W, y: Math.random() * H, vx: (Math.random() - .5) * .16, vy: (Math.random() - .5) * .12 - .03,
    r: Math.random() * 1.3 + .4, a: Math.random() * .35 + .12, t: Math.random() * 6.28 });
  let mx = -999, my = -999, running = true;
  function frame() {
    if (!running) return;
    ctx.clearRect(0, 0, W, H);
    for (const p of pts) {
      p.x += p.vx; p.y += p.vy; p.t += .012;
      if (p.x < -10) p.x = W + 10; if (p.x > W + 10) p.x = -10; if (p.y < -10) p.y = H + 10; if (p.y > H + 10) p.y = -10;
      const near = Math.max(0, 1 - Math.hypot(p.x - mx, p.y - my) / 220);
      ctx.beginPath(); ctx.arc(p.x, p.y, p.r + near * 1.2, 0, 6.283);
      ctx.fillStyle = `rgba(236,208,137,${(p.a * (.7 + .3 * Math.sin(p.t)) + near * .4).toFixed(3)})`; ctx.fill();
    }
    ctx.lineWidth = .6;
    for (let i = 0; i < N; i++) for (let j = i + 1; j < N; j++) {
      const a = pts[i], b = pts[j], d = Math.hypot(a.x - b.x, a.y - b.y);
      if (d < LINK) { ctx.strokeStyle = `rgba(201,162,75,${(.13 * (1 - d / LINK)).toFixed(3)})`; ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke(); }
    }
    requestAnimationFrame(frame);
  }
  frame();
  document.addEventListener("visibilitychange", () => { running = !document.hidden; if (running) frame(); });

  /* ---- 烛光般的光标光晕 + 画框视差 ---- */
  if (fine) {
    const glow = Object.assign(document.createElement("div"), { id: "fx-glow" });
    document.body.prepend(glow);
    let gx = 0, gy = 0, tx = 0, ty = 0;
    addEventListener("pointermove", (e) => { mx = tx = e.clientX; my = ty = e.clientY; glow.style.opacity = 1; });
    (function follow() { gx += (tx - gx) * .08; gy += (ty - gy) * .08; glow.style.transform = `translate(${gx}px,${gy}px)`; requestAnimationFrame(follow); })();
  }
  const ORBIT = `<svg class="fx-orbit" viewBox="0 0 200 200" fill="none" aria-hidden="true">
    <g><circle cx="100" cy="100" r="98" stroke="rgba(201,162,75,.20)" stroke-width=".3"/><rect x="98.6" y=".6" width="2.8" height="2.8" transform="rotate(45 100 2)" fill="#ecd089"/></g>
    <g class="r2"><circle cx="100" cy="100" r="78" stroke="rgba(201,162,75,.16)" stroke-width=".3" stroke-dasharray="1 3"/><circle cx="178" cy="100" r="1.1" fill="#c9a24b"/></g>
    <g class="r3"><circle cx="100" cy="100" r="60" stroke="rgba(201,162,75,.12)" stroke-width=".3"/><rect x="99" y="39" width="2" height="2" transform="rotate(45 100 40)" fill="#ecd089" opacity=".8"/></g></svg>`;
  document.querySelectorAll("figure").forEach((fig) => {
    const frame = fig.querySelector(".frame"); if (!frame) return;
    fig.classList.add("fx-fig"); fig.insertAdjacentHTML("afterbegin", ORBIT);
    if (!fine) return;
    fig.addEventListener("pointermove", (e) => {
      const r = frame.getBoundingClientRect(), x = (e.clientX - r.left) / r.width - .5, y = (e.clientY - r.top) / r.height - .5;
      frame.style.transform = `rotateY(${x * 7}deg) rotateX(${-y * 7}deg) scale(1.015)`;
    });
    fig.addEventListener("pointerleave", () => { frame.style.transform = ""; });
  });

  /* ---- 入场动画 ---- */
  const io = new IntersectionObserver((es) => es.forEach((en) => { if (en.isIntersecting) { en.target.classList.add("in"); io.unobserve(en.target); } }), { threshold: .12 });
  FX.reveal = (root = document) => {
    root.querySelectorAll("main .card, main figure, main h1, main h2:not(#qText):not(#cTitle), main .tag, main form > div, main hr.dim").forEach((el) => {
      if (el.closest("#report") || el.classList.contains("rv")) return;
      const sibs = [...el.parentElement.children];
      el.style.setProperty("--d", Math.min(sibs.indexOf(el), 6) * 70 + "ms");
      el.classList.add("rv"); io.observe(el);
    });
  };
  FX.reveal();

  /* ---- 数字滚动与重播 ---- */
  FX.countUp = (root) => {
    root.querySelectorAll(".kpi b").forEach((el) => {
      const m = el.textContent.match(/^(¥?)([\d,]+(?:\.\d+)?)(.*)$/); if (!m || /—|-/.test(m[3].slice(0, 1))) return;
      const end = parseFloat(m[2].replace(/,/g, "")), dec = (m[2].split(".")[1] || "").length, t0 = performance.now(), final = el.textContent;
      (function tick(t) {
        const k = Math.min(1, (t - t0) / 900), v = end * (1 - Math.pow(1 - k, 3));
        el.textContent = k === 1 ? final : m[1] + v.toLocaleString("zh-CN", { minimumFractionDigits: dec, maximumFractionDigits: dec }) + m[3];
        if (k < 1) requestAnimationFrame(tick);
      })(t0);
    });
  };
  // 逐字浮现
  document.querySelectorAll(".fx-letters").forEach((el) => {
    el.innerHTML = [...el.textContent.trim()].map((ch, i) => `<span style="--i:${i}">${ch}</span>`).join("");
  });
  // 结果逐段浮现(工具页)
  FX.stagger = (root) => [...root.children].forEach((el, i) => { el.style.setProperty("--i", i); FX.replay(el, "res-in"); });
  FX.replay = (el, cls) => { if (!el) return; el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls); };
})();
