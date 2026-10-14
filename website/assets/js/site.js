// Wren website: header state, mobile menu, scroll reveals and the illustrative product demos.
// The HTML already contains every demo's final state, so the page is complete without this script
// and with reduced motion; the script only replays the demos, once each, when they come into view.
(() => {
  "use strict";
  window.wrenReady = true;
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => Array.from(el.querySelectorAll(s));

  // Header: a quiet background once the page scrolls.
  const header = $(".header");
  const onScroll = () => header && header.classList.toggle("is-scrolled", window.scrollY > 8);
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Mobile menu.
  const btn = $(".menu-btn"), nav = $("#site-nav");
  if (btn && nav) {
    const set = (open) => {
      nav.classList.toggle("is-open", open);
      btn.setAttribute("aria-expanded", String(open));
      btn.setAttribute("aria-label", open ? "Close menu" : "Open menu");
    };
    btn.addEventListener("click", () => set(btn.getAttribute("aria-expanded") !== "true"));
    nav.addEventListener("click", (e) => { if (e.target.closest("a")) set(false); });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && btn.getAttribute("aria-expanded") === "true") { set(false); btn.focus(); }
    });
    window.matchMedia("(min-width: 961px)").addEventListener("change", (m) => { if (m.matches) set(false); });
  }

  // Scroll reveals.
  const reveals = $$(".reveal");
  if (reduce || !("IntersectionObserver" in window)) {
    reveals.forEach((el) => el.classList.add("is-visible"));
  } else {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) if (e.isIntersecting) { e.target.classList.add("is-visible"); io.unobserve(e.target); }
    }, { rootMargin: "0px 0px -4% 0px", threshold: 0 });
    reveals.forEach((el) => io.observe(el));
  }

  if (reduce) return;

  // Demos run once, when at least a third is visible.
  const demos = {
    async capture(root) {
      const typed = $("[data-typed]", root), card = $(".result-card", root), send = $(".send", root);
      const text = typed.textContent;
      typed.textContent = ""; card.classList.remove("is-in"); send.classList.remove("is-ready", "is-sent");
      await wait(700);
      for (let i = 1; i <= text.length; i++) {
        typed.textContent = text.slice(0, i);
        await wait(text[i - 1] === " " ? 70 : 42 + Math.random() * 38);
      }
      send.classList.add("is-ready");
      await wait(800);
      send.classList.add("is-sent");
      await wait(500);
      card.classList.add("is-in");
    },
    async voice(root) {
      const text = $("[data-voice-text]", root), label = $("[data-voice-label]", root), sub = $("[data-voice-sub]", root);
      const result = $("[data-voice-result]", root), panel = $(".panel-dark", root);
      const steps = $$("[data-steps] li");
      const final = text.textContent;
      const words = final.split(" ");
      const mark = (n) => steps.forEach((li, i) => li.classList.toggle("is-active", i <= n));
      result.classList.remove("is-in"); text.textContent = ""; panel.classList.add("is-listening");
      label.textContent = "I'm listening…"; sub.textContent = "Release ⌥ Space to finish.";
      mark(0); await wait(900); mark(1);
      for (let i = 1; i <= words.length; i++) { text.textContent = words.slice(0, i).join(" "); await wait(230); }
      mark(2); await wait(1200);
      panel.classList.remove("is-listening");
      label.textContent = "Transcribing your voice…"; sub.textContent = "Microphone off. Recognising on this Mac.";
      mark(3); await wait(1600);
      mark(4); result.classList.add("is-in");
    },
    async gpt(root) {
      const state = $("[data-gpt-state]", root), view = $("[data-gpt-view]", root), toast = $("[data-gpt-toast]", root);
      const setState = (cls, label) => { state.className = "state " + cls; state.textContent = label; };
      view.classList.remove("is-in"); toast.classList.remove("is-in");
      setState("state--prepared", "Prepared");
      await wait(1100); setState("state--running", "Running");
      await wait(2600); setState("state--done", "Completed");
      await wait(500); view.classList.add("is-in");
      await wait(700); toast.classList.add("is-in");
    },
    async lifecycle(root) {
      const items = $$("li", root);
      const done = $("[data-done]");
      items.forEach((li) => li.classList.remove("is-done", "is-active"));
      for (const li of items) { li.classList.add("is-active"); await wait(750); li.classList.replace("is-active", "is-done"); }
      if (done) { done.classList.add("is-pressed"); }
    },
  };

  const io2 = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      io2.unobserve(e.target);
      const run = demos[e.target.dataset.demo];
      if (run) run(e.target).catch(() => {});
    }
  }, { threshold: 0.35 });
  $$("[data-demo]").forEach((el) => io2.observe(el));
})();
