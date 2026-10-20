/* MergePro website. Vanilla JS, no tracking, no network requests. */

/* ===================================================================
 * APP STORE URL: the ONE place to change it.
 * Set this to the Mac App Store listing once it is live, e.g.
 *   const APP_STORE_URL = "https://apps.apple.com/app/mergepro/id0000000000";
 * While it is null, every [data-app-store] button keeps its fallback
 * link to GitHub Releases and the "Coming soon to the" label.
 * =================================================================== */
const APP_STORE_URL = null;

(() => {
  "use strict";
  const doc = document.documentElement;
  doc.classList.add("js");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

  /* App Store links */
  if (APP_STORE_URL) {
    $$("[data-app-store]").forEach((a) => { a.href = APP_STORE_URL; });
    $$("[data-app-store-kicker]").forEach((s) => { s.textContent = "Download on the"; });
  }

  /* Sticky nav */
  const nav = $("#nav");
  const onScroll = () => nav && nav.classList.toggle("scrolled", scrollY > 8);
  addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* Mobile menu */
  const toggle = $(".nav-toggle");
  if (toggle) {
    const setOpen = (open) => {
      nav.classList.toggle("open", open);
      toggle.setAttribute("aria-expanded", String(open));
      toggle.setAttribute("aria-label", open ? "Close menu" : "Open menu");
    };
    toggle.addEventListener("click", () => setOpen(!nav.classList.contains("open")));
    $$(".nav-links a").forEach((a) => a.addEventListener("click", () => setOpen(false)));
    addEventListener("keydown", (e) => { if (e.key === "Escape" && nav.classList.contains("open")) { setOpen(false); toggle.focus(); } });
  }

  /* Scroll reveals */
  const reveals = $$(".reveal");
  if ("IntersectionObserver" in window && !reduce.matches) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    reveals.forEach((el) => io.observe(el));
  } else {
    reveals.forEach((el) => el.classList.add("in"));
  }

  /* Feature card glow + tilt */
  const finePointer = matchMedia("(hover: hover) and (pointer: fine)").matches;
  $$(".feature").forEach((card) => {
    card.addEventListener("pointermove", (e) => {
      const r = card.getBoundingClientRect();
      const x = (e.clientX - r.left) / r.width;
      const y = (e.clientY - r.top) / r.height;
      card.style.setProperty("--mx", `${x * 100}%`);
      card.style.setProperty("--my", `${y * 100}%`);
      if (finePointer && !reduce.matches) {
        card.classList.add("tilting");
        card.style.setProperty("--ry", `${(x - 0.5) * 7}deg`);
        card.style.setProperty("--rx", `${(0.5 - y) * 7}deg`);
      }
    });
    card.addEventListener("pointerleave", () => {
      card.classList.remove("tilting");
      card.style.setProperty("--rx", "0deg");
      card.style.setProperty("--ry", "0deg");
    });
  });

  /* Counters */
  const counters = $$("[data-count]");
  if (counters.length && "IntersectionObserver" in window && !reduce.matches) {
    const run = (el) => {
      const end = +el.dataset.count;
      const suffix = el.dataset.suffix || "";
      if (!end) return;
      const t0 = performance.now();
      const dur = 1400;
      const step = (t) => {
        const p = Math.min(1, (t - t0) / dur);
        el.textContent = Math.round(end * (1 - Math.pow(1 - p, 3))) + suffix;
        if (p < 1) requestAnimationFrame(step);
      };
      el.textContent = "0" + suffix;
      requestAnimationFrame(step);
    };
    const co = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) { run(e.target); co.unobserve(e.target); } });
    }, { threshold: 0.6 });
    counters.forEach((c) => co.observe(c));
  }

  /* Keyboard caps light up when you press the matching key */
  const caps = $$("[data-key]");
  if (caps.length) {
    const flash = (key) => {
      const hits = caps.filter((c) => c.dataset.key === key);
      hits.forEach((c) => { c.classList.add("hit"); setTimeout(() => c.classList.remove("hit"), 220); });
    };
    addEventListener("keydown", (e) => {
      const t = e.target;
      if (e.altKey || e.ctrlKey || (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName)))) return;
      const key = e.key === "Enter" ? "enter" : e.key.toLowerCase();
      if (!e.metaKey || key === "k" || key === "1" || key === "2" || key === "p") flash(key);
    });
    // Gentle idle demo on the big caps while the section is visible
    const hero = $(".kb-hero");
    if (hero && !reduce.matches && "IntersectionObserver" in window) {
      const seq = ["j", "j", "k", "a", "j", "m"];
      let i = 0, timer = null;
      new IntersectionObserver(([e]) => {
        if (e.isIntersecting && !timer) timer = setInterval(() => flash(seq[i++ % seq.length]), 900);
        else if (!e.isIntersecting && timer) { clearInterval(timer); timer = null; }
      }, { threshold: 0.5 }).observe(hero);
    }
  }

  /* Terminal typing effect */
  const term = $("#term");
  if (term && !reduce.matches && "IntersectionObserver" in window) {
    const lines = [
      ["git clone https://github.com/jonathansudhakar1/mergepro", "Cloning into 'mergepro'... done."],
      ["cd mergepro", null],
      ["xcodegen generate", "Created project at MergePro.xcodeproj"],
      ["scripts/verify.sh", null],
    ];
    const finalHTML = term.innerHTML;
    const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
    let started = false;
    const type = async () => {
      let html = "";
      const caret = '<span class="caret"></span>';
      const wait = (ms) => new Promise((r) => setTimeout(r, ms));
      for (const [cmd, out] of lines) {
        html += '<span class="pr">$</span> ';
        for (let c = 1; c <= cmd.length; c++) {
          term.innerHTML = html + esc(cmd.slice(0, c)) + caret;
          await wait(cmd.length > 30 ? 18 : 45);
        }
        html += esc(cmd) + "\n";
        await wait(260);
        if (out) { html += '<span class="dim">' + esc(out) + "</span>\n"; term.innerHTML = html + caret; await wait(420); }
      }
      html += '<span class="dim"># Package tests, app build and unit tests.\n# Requires Xcode 27 with the macOS 26 SDK.</span>\n<span class="pr">$</span> ';
      term.innerHTML = html + caret;
    };
    new IntersectionObserver(([e], o) => {
      if (e.isIntersecting && !started) { started = true; o.disconnect(); type().catch(() => { term.innerHTML = finalHTML; }); }
    }, { threshold: 0.5 }).observe(term);
  }

  /* ---------- Hero app mock ---------- */
  const stage = $("#mock-stage");
  if (!stage) return;

  const fit = () => {
    const w = stage.clientWidth;
    stage.classList.toggle("compact", w < 760);
    const base = stage.classList.contains("compact") ? 720 : 1120;
    stage.style.setProperty("--s", String(Math.min(1, w / base)));
  };
  fit();
  if ("ResizeObserver" in window) new ResizeObserver(fit).observe(stage);
  else addEventListener("resize", fit);

  const board = $("#board", stage);
  const card = $("#hero-card", stage);
  const cols = {};
  $$(".col", board).forEach((c) => { cols[c.dataset.col] = { list: $(".col-list", c), count: $(".c", c) }; });
  const state = $("[data-state]", card);
  const bar = $(".progress i", card);
  const checks = $$("[data-check]", stage);
  const checksSum = $("#checks-sum", stage);
  const icon = (id, cls = "") => `<svg class="${cls}"><use href="#${id}"/></svg>`;

  const counts = () => Object.values(cols).forEach((c) => { c.count.textContent = c.list.children.length; });

  // FLIP-animate every card while moving `el` to the top of `to`.
  const move = (el, to) => {
    const cards = $$(".card", board);
    const first = new Map(cards.map((c) => [c, c.getBoundingClientRect()]));
    to.list.prepend(el);
    counts();
    if (reduce.matches || !el.animate) return;
    const s = parseFloat(getComputedStyle(stage).getPropertyValue("--s")) || 1;
    cards.forEach((c) => {
      const a = first.get(c), b = c.getBoundingClientRect();
      const dx = (a.left - b.left) / s, dy = (a.top - b.top) / s;
      if (!dx && !dy) return;
      const lift = c === el;
      c.animate([
        { transform: `translate(${dx}px, ${dy}px)${lift ? " scale(1.04)" : ""}`, zIndex: lift ? 5 : 1 },
        { transform: "none", zIndex: lift ? 5 : 1 },
      ], { duration: lift ? 820 : 600, easing: "cubic-bezier(.22,1,.36,1)" });
    });
  };

  const setChecks = (done) => {
    checks.forEach((row) => {
      const svg = row.querySelector("svg"), d = row.querySelector(".d");
      if (done) { svg.outerHTML = icon("i-checkc", "ok"); d.textContent = row.textContent.includes("integration") ? "4:58" : "2:07"; }
      else { svg.outerHTML = icon("i-spin", "run spin"); d.textContent = "running"; }
    });
    checksSum.textContent = done ? "4 of 4" : "2 of 4";
  };

  const reset = () => {
    state.className = "st run";
    state.innerHTML = icon("i-spin", "spin") + "Checks running";
    bar.parentElement.style.display = "";
    bar.style.transition = "none"; bar.style.width = "8%";
    void bar.offsetWidth; bar.style.transition = "";
    card.classList.add("focus");
    setChecks(false);
  };

  if (reduce.matches) return; // static illustration

  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  let visible = true;
  if ("IntersectionObserver" in window) new IntersectionObserver(([e]) => { visible = e.isIntersecting; }).observe(stage);
  const whenVisible = async () => { while (!visible || document.hidden) await wait(400); };

  const loop = async () => {
    for (;;) {
      reset();
      await wait(500);
      bar.style.width = "100%";
      await wait(1900);
      await whenVisible();
      // checks finish
      state.className = "st pass";
      state.innerHTML = icon("i-checkc") + "Passing";
      bar.parentElement.style.display = "none";
      setChecks(true);
      card.classList.add("flash");
      setTimeout(() => card.classList.remove("flash"), 1000);
      await wait(1600);
      await whenVisible();
      // approved
      state.insertAdjacentHTML("afterend", `<span class="st appr" data-appr>${icon("i-check")}Approved</span>`);
      move(card, cols.approved);
      await wait(2600);
      await whenVisible();
      // merged
      card.classList.remove("focus");
      const appr = $("[data-appr]", card); if (appr) appr.remove();
      state.className = "st merged";
      state.innerHTML = icon("i-merge") + "Merged";
      move(card, cols.merged);
      await wait(3000);
      await whenVisible();
      // back to open for the next round
      if (card.animate) await card.animate([{ opacity: 1 }, { opacity: 0, transform: "scale(.96)" }], { duration: 300, fill: "forwards" }).finished;
      reset();
      move(card, cols.open);
      if (card.animate) {
        card.getAnimations().forEach((a) => a.cancel());
        card.animate([{ opacity: 0, transform: "translateY(-8px)" }, { opacity: 1, transform: "none" }], { duration: 450, easing: "ease-out" });
      }
    }
  };
  loop();
})();
