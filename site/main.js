// weft — landing page: the release link, the scroll scenes, and the demo.
// Every animated Mac is a WeftTiler (tiler.js), so what the hero and the
// story show is what the try-it demo actually does.

(() => {
  "use strict";

  const REPO = "amiralibg/weft";
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const clamp = (v, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));

  // ── Latest release ────────────────────────────────────────────────
  // Links already point at /releases/latest; this sharpens them to the zip.
  fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((release) => {
      if (release.tag_name) {
        document.querySelectorAll("[data-version]").forEach((el) => { el.textContent = release.tag_name.replace(/^v/, ""); });
      }
      const zip = (release.assets || []).find((a) => /^WeftBar-.*\.zip$/.test(a.name));
      if (!zip) return;
      document.querySelectorAll("[data-download]").forEach((a) => { a.href = zip.browser_download_url; });
      document.querySelectorAll("[data-asset-name]").forEach((el) => { el.textContent = zip.name.replace(/\.zip$/, ""); });
    })
    .catch(() => {});

  // ── Copy ──────────────────────────────────────────────────────────
  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const el = document.getElementById(button.dataset.copy);
      const text = (el.dataset.full || el.textContent).trim();
      try {
        await navigator.clipboard.writeText(text);
        button.textContent = "Copied";
      } catch {
        button.textContent = "Select to copy";
      }
      setTimeout(() => { button.textContent = "Copy"; }, 1600);
    });
  });

  // ── Reveal on scroll ──────────────────────────────────────────────
  const revealer = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      e.target.classList.add("is-in");
      revealer.unobserve(e.target);
    }
  }, { threshold: 0.15, rootMargin: "0px 0px -8% 0px" });
  document.querySelectorAll(".reveal").forEach((el) => revealer.observe(el));

  // Feature tiles animate only while on screen.
  const player = new IntersectionObserver((entries) => {
    for (const e of entries) e.target.classList.toggle("is-playing", e.isIntersecting);
  }, { threshold: 0.2 });
  document.querySelectorAll(".tile").forEach((el) => player.observe(el));

  // ── A drawn display ───────────────────────────────────────────────
  function display(root, opts) {
    const t = new window.WeftTiler(root.querySelector("[data-screen]"), opts);
    const appName = root.querySelector("[data-app-name]");
    const deskLabel = root.querySelector("[data-desk-label]");
    const hud = root.querySelector("[data-hud]");
    const hudKeys = root.querySelector("[data-hud-keys]");
    const hudLabel = root.querySelector("[data-hud-label]");
    let hudTimer = 0;
    return {
      t,
      render() {
        t.render();
        appName.textContent = t.appName(t.mc ? null : t.focused());
        deskLabel.textContent = String(t.current + 1);
      },
      hud(keys, label, hold = 1100) {
        clearTimeout(hudTimer);
        if (!keys) { hud.classList.remove("is-on"); return; }
        hudKeys.innerHTML = keys.map((k) => `<kbd>${k}</kbd>`).join("");
        hudLabel.textContent = label;
        hud.classList.add("is-on");
        if (hold) hudTimer = setTimeout(() => hud.classList.remove("is-on"), hold);
      },
    };
  }

  // ── Hero: a Mac tiling itself on a loop ───────────────────────────
  const heroRoot = document.querySelector('[data-display="hero"]');
  const hero = display(heroRoot, { desks: 2 });
  hero.t.open("mail", 1);
  hero.t.open("music", 1);

  const SCRIPT = [
    [900, (d) => d.t.open("terminal")],
    [1300, (d) => d.t.open("safari")],
    [1300, (d) => d.t.open("notes")],
    [1600, (d) => { d.t.focusDir("west"); d.hud(["⌥", "H"], "focus west"); }],
    [1600, (d) => { d.t.move("east"); d.hud(["⌥", "⇧", "L"], "move east"); }],
    [1600, (d) => d.t.open("xcode")],
    [1700, (d) => { d.t.switchTo(1); d.hud(["⌥", "2"], "space focus 2"); }],
    [1700, (d) => { d.t.switchTo(0); d.hud(["⌥", "1"], "space focus 1"); }],
    [1500, (d) => { d.t.toggleZoom(); d.hud(["⌥", "F"], "zoom"); }],
    [1500, (d) => { d.t.toggleZoom(); d.hud(["⌥", "F"], "zoom"); }],
    [1400, (d) => { d.t.focusDir("west"); d.t.move("south"); d.hud(["⌥", "⇧", "J"], "move south"); }],
    [1800, (d) => d.t.close("xcode")],
    [450, (d) => d.t.close("notes")],
    [450, (d) => d.t.close("safari")],
    [450, (d) => d.t.close("terminal")],
  ];
  let step = 0, timer = 0, userPaused = reduced, heroVisible = true;
  const button = document.querySelector("[data-playpause]");

  function tick() {
    const [, run] = SCRIPT[step];
    run(hero);
    hero.render();
    step = (step + 1) % SCRIPT.length;
    schedule();
  }
  function schedule() {
    clearTimeout(timer);
    if (userPaused || !heroVisible) return;
    timer = setTimeout(tick, SCRIPT[step][0]);
  }
  function setPaused(paused) {
    userPaused = paused;
    button.setAttribute("aria-pressed", String(paused));
    button.setAttribute("aria-label", paused ? "Play the animation" : "Pause the animation");
    schedule();
  }
  button.addEventListener("click", () => setPaused(!userPaused));
  new IntersectionObserver((entries) => {
    heroVisible = entries[0].isIntersecting;
    schedule();
  }).observe(heroRoot);

  if (reduced) {
    // A still frame, and the button to play it.
    ["terminal", "safari", "notes"].forEach((k) => hero.t.open(k));
    step = 3;
    setPaused(true);
  }
  hero.render();
  if (!reduced) setTimeout(schedule, 900);

  // ── Story: the pinned scene ───────────────────────────────────────
  const story = document.querySelector("[data-story]");
  const studio = story.querySelector(".studio");
  const sd = display(story.querySelector('[data-display="story"]'), { desks: 3 });
  const captions = [...story.querySelectorAll(".story-step")];
  const dotsHost = story.querySelector("[data-story-dots]");
  const dots = captions.map(() => dotsHost.appendChild(document.createElement("i")));

  const three = (t) => { t.open("terminal"); t.open("safari"); t.open("notes"); };
  const others = (t) => { t.open("mail", 1); t.open("music", 1); t.open("calendar", 2); };
  const SCENES = [
    { build: (t) => t.open("terminal") },
    { build: (t) => { t.open("terminal"); t.open("safari"); } },
    { build: three },
    { build: (t) => { three(t); t.move("west"); }, hud: [["⌥", "⇧", "H"], "move west"] },
    { build: (t) => { three(t); t.move("west"); others(t); t.switchTo(1); }, hud: [["⌥", "2"], "space focus 2"] },
    { build: (t) => { three(t); t.move("west"); others(t); t.switchTo(1); t.setMissionControl(true); }, hud: [["⌃", "↑"], "Mission Control"] },
  ];
  let scene = -1;

  function showScene(i) {
    if (i === scene) return;
    const forward = i > scene;
    scene = i;
    sd.t.reset();
    SCENES[i].build(sd.t);
    sd.render();
    captions.forEach((c, j) => c.classList.toggle("is-on", j === i));
    dots.forEach((d, j) => d.classList.toggle("is-on", j === i));
    if (SCENES[i].hud && forward) sd.hud(...SCENES[i].hud);
    else sd.hud(null);
  }

  // ── Statement: words light up as you scroll ───────────────────────
  const statement = document.querySelector("[data-statement]");
  const wordsHost = statement.querySelector("[data-words]");
  const words = wordsHost.textContent.trim().split(/\s+/);
  wordsHost.innerHTML = words.map((w) => `<span class="w">${w}</span>`).join(" ");
  const wordEls = [...wordsHost.querySelectorAll(".w")];
  wordsHost.setAttribute("aria-label", words.join(" "));

  // ── Scroll ────────────────────────────────────────────────────────
  const nav = document.querySelector("[data-nav]");
  const themed = [...document.querySelectorAll("[data-theme]")];
  const heroCopy = document.querySelector("[data-hero-copy]");
  const macbook = document.querySelector(".macbook");
  let ticking = false;

  function onScroll() {
    ticking = false;
    const vh = innerHeight;

    // The bar takes the colour of whatever it sits over, as Apple's does.
    const under = themed.find((el) => { const b = el.getBoundingClientRect(); return b.top <= 24 && b.bottom > 24; });
    nav.classList.toggle("is-light", !!under && under.dataset.theme === "light");

    if (!reduced) {
      const p = clamp(scrollY / (vh * 0.7));
      heroCopy.style.opacity = String(1 - p * 1.1);
      heroCopy.style.transform = `translateY(${-p * 60}px) scale(${1 - p * 0.05})`;
      const q = clamp(scrollY / (vh * 0.6));
      macbook.style.transform = `scale(${0.9 + 0.1 * q})`;
    }

    const r = story.getBoundingClientRect();
    if (!reduced) studio.style.setProperty("--enter", String(0.86 + 0.14 * clamp((vh - r.top) / vh)));
    const progress = clamp(-r.top / (r.height - vh));
    showScene(Math.min(SCENES.length - 1, Math.floor(progress * SCENES.length)));

    const s = statement.getBoundingClientRect();
    const sp = clamp((vh * 0.35 - s.top) / (s.height - vh * 0.9));
    const lit = Math.round(sp * wordEls.length);
    wordEls.forEach((w, i) => w.classList.toggle("is-lit", reduced || i < lit));
  }
  addEventListener("scroll", () => {
    if (!ticking) { ticking = true; requestAnimationFrame(onScroll); }
  }, { passive: true });
  addEventListener("resize", onScroll);
  onScroll();

  // ── Try it ────────────────────────────────────────────────────────
  const tryRoot = document.querySelector('[data-display="try"]');
  const logCode = document.querySelector("[data-log]");
  const logNote = document.querySelector("[data-log-note]");
  const log = (cmd, note) => { logCode.textContent = cmd; logNote.textContent = note; };
  const demo = display(tryRoot, {
    desks: 3,
    interactive: true,
    onFocus: (_key, why) => {
      demo.render();
      if (why === "close") log("(you closed a window)", NOTES.close);
      else if (why === "resize") log("(you dragged a gap)", NOTES.resize);
      else log("(you clicked a window)", "Focus follows the click, as it does in macOS.");
    },
  });
  ["terminal", "safari", "notes"].forEach((k) => demo.t.open(k));
  demo.t.focusDir("west");
  demo.t.open("mail", 1);
  demo.t.open("xcode", 1);
  demo.t.open("music", 2);
  demo.render();

  const NOTES = {
    focus: "Focus moved to the nearest window that way.",
    nothing: "There is no window that way.",
    move: "The window took one step in the layout tree. Nothing was swapped.",
    edge: "Already at the edge. There is nowhere further to go.",
    desk: "Switched desktops. Each one keeps its own layout.",
    send: "Sent. It split the focused window on that desktop.",
    same: "That window is already on this desktop.",
    empty: "This desktop is empty. Open a window.",
    zoom: "The focused window fills the desktop. Press it again to put it back.",
    unzoom: "Back in its slot.",
    balance: "Every split back to half and half.",
    open: "The new window took half of the focused one, cut along its longer side.",
    full: "Every app in the demo is open. Close one first.",
    close: "The window closed and its neighbour grew into the space.",
    resize: "Dragging the gap resizes both sides. No modifier needed.",
  };
  const HUD = {
    "focus west": ["⌥", "H"], "focus south": ["⌥", "J"], "focus north": ["⌥", "K"], "focus east": ["⌥", "L"],
    "move west": ["⌥", "⇧", "H"], "move south": ["⌥", "⇧", "J"], "move north": ["⌥", "⇧", "K"], "move east": ["⌥", "⇧", "L"],
    "window toggle zoom-fullscreen": ["⌥", "F"], balance: ["⌥", "B"],
  };

  function run(cmd) {
    const t = demo.t;
    const [verb, a1, a2] = cmd.split(" ");
    let shown = cmd, note = "";
    if (verb === "focus") note = t.focusDir(a1) ? NOTES.focus : NOTES.nothing;
    else if (verb === "move") note = t.focused() == null ? NOTES.empty : t.move(a1) ? NOTES.move : NOTES.edge;
    else if (verb === "space" && a1 === "focus") { t.switchTo(Number(a2) - 1); note = NOTES.desk; }
    else if (verb === "space" && a1 === "move-window") note = NOTES[t.send(Number(a2) - 1)] || NOTES.send;
    else if (verb === "window") note = NOTES[t.toggleZoom()] || NOTES.empty;
    else if (verb === "balance") { t.balance(); note = NOTES.balance; }
    else if (verb === "open") {
      const key = t.nextApp();
      if (key) { t.open(key); note = NOTES.open; shown = `(${t.appName(key)} opened a window)`; }
      else { note = NOTES.full; shown = "nothing"; }
    } else if (verb === "close") {
      const key = t.focused();
      if (key) { t.close(key); note = NOTES.close; shown = "(you closed a window)"; }
      else note = NOTES.empty;
    }
    demo.render();
    const keys = HUD[cmd] || (verb === "space" ? (a1 === "focus" ? ["⌥", a2] : ["⌥", "⇧", a2]) : null);
    if (keys) demo.hud(keys, cmd, 900);
    log(shown, note);
  }

  const keyButtons = new Map();
  document.querySelectorAll("[data-cmd]").forEach((b) => {
    keyButtons.set(b.dataset.cmd, b);
    b.addEventListener("click", () => run(b.dataset.cmd));
  });

  let tryVisible = false;
  new IntersectionObserver((entries) => { tryVisible = entries[0].isIntersecting; }, { threshold: 0.3 }).observe(tryRoot);

  const LETTERS = { KeyH: "west", KeyJ: "south", KeyK: "north", KeyL: "east" };
  addEventListener("keydown", (e) => {
    if (!tryVisible || !e.altKey || e.metaKey || e.ctrlKey) return;
    if (e.target instanceof Element && e.target.closest("input, textarea, [contenteditable]")) return;
    let cmd = null;
    if (LETTERS[e.code]) cmd = `${e.shiftKey ? "move" : "focus"} ${LETTERS[e.code]}`;
    const digit = /^Digit([1-3])$/.exec(e.code);
    if (digit) cmd = e.shiftKey ? `space move-window ${digit[1]}` : `space focus ${digit[1]}`;
    if (e.code === "KeyF" && !e.shiftKey) cmd = "window toggle zoom-fullscreen";
    if (e.code === "KeyB" && !e.shiftKey) cmd = "balance";
    if (!cmd) return;
    e.preventDefault();
    const b = keyButtons.get(cmd);
    if (b) { b.classList.add("is-pressed"); setTimeout(() => b.classList.remove("is-pressed"), 150); }
    run(cmd);
  });

  // ── Terminal types its command ────────────────────────────────────
  const typed = document.querySelector("[data-type]");
  typed.dataset.full = typed.textContent;
  if (!reduced) {
    typed.textContent = "";
    const typer = new IntersectionObserver((entries) => {
      if (!entries[0].isIntersecting) return;
      typer.disconnect();
      const full = typed.dataset.full;
      let i = 0;
      const next = () => {
        i = Math.min(full.length, i + (i < 30 ? 1 : 3));
        typed.textContent = full.slice(0, i);
        if (i < full.length) setTimeout(next, i < 30 ? 38 : 14);
      };
      setTimeout(next, 400);
    }, { threshold: 0.6 });
    typer.observe(typed.closest("[data-terminal]"));
  }
})();
