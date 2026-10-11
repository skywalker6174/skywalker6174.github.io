/* 风格切换:老钱(默认,暗)与 清风(小清新文艺,亮)。只换外观,内容与功能不变。
 * 在 <head> 里尽早执行,避免页面先以一种风格闪一下。偏好保存在本机浏览器。 */
(() => {
  const KEY = "hb_theme";
  let theme = "classic";
  try { theme = localStorage.getItem(KEY) || "classic"; } catch (e) {}
  document.documentElement.setAttribute("data-theme", theme);
  window.Theme = {
    get: () => document.documentElement.getAttribute("data-theme"),
    set(t) {
      document.documentElement.setAttribute("data-theme", t);
      try { localStorage.setItem(KEY, t); } catch (e) {}
      document.querySelectorAll("[data-theme-pick]").forEach((b) => b.classList.toggle("on", b.dataset.themePick === t));
      document.dispatchEvent(new CustomEvent("themechange", { detail: t }));
    },
    toggle() { this.set(this.get() === "light" ? "classic" : "light"); },
  };
  document.addEventListener("DOMContentLoaded", () => Theme.set(Theme.get()));
})();
