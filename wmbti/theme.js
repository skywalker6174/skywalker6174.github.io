/* 风格切换:Dark(默认,老钱风:暗底金色)与 Light(小清新文艺风:亮色)。只换外观与配图,内容与功能不变。
 * 在 <head> 里尽早执行,避免页面先以一种风格闪一下。偏好保存在本机浏览器。 */
(() => {
  const KEY = "hb_theme";
  let theme = "dark";
  try { theme = localStorage.getItem(KEY) || "dark"; } catch (e) {}
  if (theme === "classic") theme = "dark";           // 旧版本保存的值
  document.documentElement.setAttribute("data-theme", theme);
  const swapArt = (t) => document.querySelectorAll("img[data-light-src]").forEach((img) => {
    if (!img.dataset.darkSrc) img.dataset.darkSrc = img.getAttribute("src");
    const want = t === "light" ? img.dataset.lightSrc : img.dataset.darkSrc;
    if (img.getAttribute("src") !== want) img.setAttribute("src", want);
  });
  window.Theme = {
    get: () => document.documentElement.getAttribute("data-theme"),
    set(t) {
      if (t === "classic") t = "dark";
      document.documentElement.setAttribute("data-theme", t);
      try { localStorage.setItem(KEY, t); } catch (e) {}
      document.querySelectorAll("[data-theme-pick]").forEach((b) => b.classList.toggle("on", b.dataset.themePick === t));
      swapArt(t);
      const icon = document.querySelector('link[rel="icon"]');
      if (icon) icon.setAttribute("href", t === "light" ? "hornbill-light.svg" : "hornbill.svg");
      document.dispatchEvent(new CustomEvent("themechange", { detail: t }));
    },
    toggle() { this.set(this.get() === "light" ? "dark" : "light"); },
  };
  document.addEventListener("DOMContentLoaded", () => Theme.set(Theme.get()));
})();
