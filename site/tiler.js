// weft — the page's small tiler. One engine drives the hero loop, the
// scroll story and the try-it demo, so all three behave alike: a new window
// halves the focused one along its longer side, and `move` restructures the
// layout tree instead of swapping with a neighbour.

(() => {
  "use strict";

  const APPS = {
    terminal: { name: "Terminal" },
    safari: { name: "Safari" },
    notes: { name: "Notes" },
    xcode: { name: "Xcode" },
    mail: { name: "Mail" },
    music: { name: "Music" },
    messages: { name: "Messages" },
    calendar: { name: "Calendar" },
    finder: { name: "Finder" },
  };
  const ORDER = Object.keys(APPS);

  const l = (w) => `<i class="ln" style="width:${w}%"></i>`;
  const CONTENT = {
    terminal: () => `<pre class="c-term"><b>~ %</b> weftctl doctor
<em>✓</em> weftd 0.9.22 is running
<em>✓</em> Accessibility
<em>✓</em> Input Monitoring
<b>~ %</b> weftctl service status
weftctl: service is ACTIVE
  <span class="dim">state = running</span>
<b>~ %</b> <span class="cursor"></span></pre>`,
    safari: () => `<div class="c-safari"><div class="c-url"><span class="c-lock"></span>weft.app</div><div class="c-page"><div class="c-banner"><i></i><i></i></div><div class="c-cards"><i></i><i></i><i></i></div>${l(86)}${l(72)}${l(90)}${l(64)}${l(80)}</div></div>`,
    notes: () => `<div class="c-notes"><div class="c-side"><span class="c-note is-on"></span><span class="c-note"></span><span class="c-note"></span><span class="c-note"></span></div><div class="c-doc"><strong>Keybinds</strong>${l(70)}<span class="c-check is-done"></span><span class="c-check is-done"></span><span class="c-check"></span>${l(84)}${l(92)}${l(58)}</div></div>`,
    xcode: () => `<div class="c-xcode"><div class="c-nav">${l(70)}${l(54)}${l(62)}${l(48)}${l(66)}</div><pre class="c-code"><span class="c-gut">1
2
3
4
5
6
7</span><span><s>struct</s> <u>Layout</u> {
  <s>var</s> gap = <q>8</q>

  <s>func</s> <i>split</i>(<s>_</s> w: <u>Window</u>) {
    tree.<i>insert</i>(w, along: .longer)
  }
}</span></pre></div>`,
    mail: () => `<div class="c-list">${["Release 0.9.22", "Design review", "Weekly notes", "Invoice", "Lunch?", "Trip photos"].map((s, i) => `<div class="c-row${i === 0 ? " is-on" : ""}"><strong>${s}</strong>${l(88 - i * 6)}</div>`).join("")}</div>`,
    music: () => `<div class="c-music"><strong>Recently Played</strong><div class="c-albums">${"<i></i>".repeat(8)}</div></div>`,
    messages: () => `<div class="c-msgs"><i class="in" style="width:58%"></i><i class="out" style="width:46%"></i><i class="in" style="width:38%"></i><i class="out" style="width:62%"></i><i class="in" style="width:50%"></i></div>`,
    calendar: () => `<div class="c-cal">${Array.from({ length: 28 }, (_, i) => `<i${[3, 8, 12, 17, 23].includes(i) ? ` class="ev ev${i % 3}"` : ""}></i>`).join("")}</div>`,
    finder: () => `<div class="c-finder">${"<i></i>".repeat(8)}</div>`,
  };

  // ── Tree ──────────────────────────────────────────────────────────
  let sids = 0;
  const leaf = (id) => ({ id });
  const split = (axis, a, b, ratio = 0.5) => ({ sid: sids++, axis, ratio, a, b });
  const isLeaf = (n) => n && n.id !== undefined;

  function pathTo(node, id, path = []) {
    if (!node) return null;
    if (isLeaf(node)) return node.id === id ? path : null;
    return pathTo(node.a, id, [...path, { node, side: "a" }]) || pathTo(node.b, id, [...path, { node, side: "b" }]);
  }
  function leaves(node, out = []) {
    if (!node) return out;
    if (isLeaf(node)) out.push(node.id);
    else { leaves(node.a, out); leaves(node.b, out); }
    return out;
  }
  function without(node, id) {
    if (!node) return null;
    if (isLeaf(node)) return node.id === id ? null : node;
    const a = without(node.a, id), b = without(node.b, id);
    if (!a) return b;
    if (!b) return a;
    node.a = a; node.b = b;
    return node;
  }
  function replaceLeaf(node, id, next) {
    if (isLeaf(node)) return node.id === id ? next : node;
    node.a = replaceLeaf(node.a, id, next);
    node.b = replaceLeaf(node.b, id, next);
    return node;
  }
  function balanceTree(node) {
    if (!node || isLeaf(node)) return;
    node.ratio = 0.5;
    balanceTree(node.a); balanceTree(node.b);
  }
  function layout(node, r, gap, rects, gaps) {
    if (!node) return;
    if (isLeaf(node)) { rects.set(node.id, r); return; }
    const along = node.axis === "x" ? r.w : r.h;
    const first = Math.round((along - gap) * node.ratio);
    const second = along - gap - first;
    if (node.axis === "x") {
      layout(node.a, { x: r.x, y: r.y, w: first, h: r.h }, gap, rects, gaps);
      layout(node.b, { x: r.x + first + gap, y: r.y, w: second, h: r.h }, gap, rects, gaps);
      gaps.push({ node, box: r, at: { x: r.x + first, y: r.y, w: gap, h: r.h } });
    } else {
      layout(node.a, { x: r.x, y: r.y, w: r.w, h: first }, gap, rects, gaps);
      layout(node.b, { x: r.x, y: r.y + first + gap, w: r.w, h: second }, gap, rects, gaps);
      gaps.push({ node, box: r, at: { x: r.x, y: r.y + first, w: r.w, h: gap } });
    }
  }

  const DIRS = {
    west: { axis: "x", toward: "a" },
    east: { axis: "x", toward: "b" },
    north: { axis: "y", toward: "a" },
    south: { axis: "y", toward: "b" },
  };

  const px = (r) => ({ left: `${r.x}px`, top: `${r.y}px`, width: `${r.w}px`, height: `${r.h}px` });

  class Tiler {
    constructor(screen, { desks = 1, gap = null, interactive = false, onFocus = null } = {}) {
      this.screen = screen;
      // Null: scale the gap with the screen, the way a real one scales with
      // its resolution.
      this.fixedGap = gap;
      this.gap = gap ?? 8;
      this.interactive = interactive;
      this.onFocus = onFocus;
      this.desks = Array.from({ length: desks }, () => ({ tree: null, focus: null, zoom: null }));
      this.current = 0;
      this.mc = false;
      this.els = new Map();
      this.gapEls = new Map();
      this.track = document.createElement("div");
      this.track.className = "track";
      this.deskEls = this.desks.map((_, i) => {
        const el = document.createElement("div");
        el.className = "desk";
        el.dataset.label = `Desktop ${i + 1}`;
        if (interactive) {
          el.setAttribute("role", "group");
          el.setAttribute("aria-label", `Desktop ${i + 1}`);
        }
        this.track.append(el);
        return el;
      });
      screen.append(this.track);
      new ResizeObserver(() => this.render()).observe(screen);
    }

    get desk() { return this.desks[this.current]; }
    where(key) { return this.desks.findIndex((d) => leaves(d.tree).includes(key)); }
    isOpen(key) { return this.where(key) !== -1; }
    count(i = this.current) { return leaves(this.desks[i].tree).length; }
    focused() { return this.desk.focus; }
    appName(key) { return APPS[key] ? APPS[key].name : "Finder"; }
    nextApp() { return ORDER.find((k) => !this.isOpen(k)) || null; }

    area() {
      if (this.fixedGap == null) this.gap = Math.min(10, Math.max(4, Math.round(this.screen.clientWidth * 0.008)));
      const g = this.gap;
      return { x: g, y: g, w: this.screen.clientWidth - g * 2, h: this.screen.clientHeight - g * 2 };
    }
    rects(desk) {
      const rects = new Map(), gaps = [];
      layout(desk.tree, this.area(), this.gap, rects, gaps);
      return { rects, gaps };
    }

    reset() {
      for (const d of this.desks) { d.tree = null; d.focus = null; d.zoom = null; }
      this.current = 0;
      this.mc = false;
    }

    open(key, i = this.current) {
      if (this.isOpen(key)) return false;
      const d = this.desks[i];
      if (!d.tree) { d.tree = leaf(key); d.focus = key; return true; }
      const { rects } = this.rects(d);
      const target = rects.has(d.focus) ? d.focus : leaves(d.tree)[0];
      const r = rects.get(target);
      d.tree = replaceLeaf(d.tree, target, split(r.w >= r.h ? "x" : "y", leaf(target), leaf(key)));
      d.focus = key;
      d.zoom = null;
      return true;
    }

    close(key) {
      const i = this.where(key);
      if (i < 0) return false;
      const d = this.desks[i];
      const path = pathTo(d.tree, key);
      let heir = null;
      if (path && path.length) {
        const { node, side } = path[path.length - 1];
        heir = leaves(node[side === "a" ? "b" : "a"])[0];
      }
      d.tree = without(d.tree, key);
      if (d.zoom === key) d.zoom = null;
      if (d.focus === key) d.focus = heir;
      return true;
    }

    focus(key) {
      const i = this.where(key);
      if (i < 0) return;
      this.desks[i].focus = key;
      this.current = i;
    }

    // The nearest window that way, preferring ones that overlap on the other axis.
    focusDir(dir) {
      const d = this.desk;
      const { rects } = this.rects(d);
      const f = rects.get(d.focus);
      if (!f) return false;
      let best = null, score = Infinity;
      for (const [id, r] of rects) {
        if (id === d.focus) continue;
        const horiz = dir === "east" || dir === "west";
        const gap = { east: r.x - (f.x + f.w), west: f.x - (r.x + r.w), south: r.y - (f.y + f.h), north: f.y - (r.y + r.h) }[dir];
        const overlap = horiz
          ? Math.min(f.y + f.h, r.y + r.h) - Math.max(f.y, r.y)
          : Math.min(f.x + f.w, r.x + r.w) - Math.max(f.x, r.x);
        if (gap < -1) continue;
        const s = gap + (overlap > 0 ? 0 : 10000) - Math.max(overlap, 0) / 1000;
        if (s < score) { score = s; best = id; }
      }
      if (best == null) return false;
      d.focus = best;
      d.zoom = null;
      return true;
    }

    // One step that way in the tree: the nearest ancestor split on that axis
    // with room on that side decides. A direct child changes sides; a window
    // nested deeper leaves its group and becomes a sibling of it.
    move(dir) {
      const d = this.desk;
      const { axis, toward } = DIRS[dir];
      const id = d.focus;
      const path = pathTo(d.tree, id);
      if (!path || !path.length) return false;
      for (let i = path.length - 1; i >= 0; i--) {
        const { node, side } = path[i];
        if (node.axis !== axis || side === toward) continue;
        if (i === path.length - 1) {
          [node.a, node.b] = [node.b, node.a];
          node.ratio = 1 - node.ratio;
        } else {
          const rest = without(node[side], id);
          node[side] = toward === "b" ? split(axis, rest, leaf(id)) : split(axis, leaf(id), rest);
        }
        d.zoom = null;
        return true;
      }
      return false;
    }

    send(n) {
      const id = this.desk.focus;
      if (id == null) return "empty";
      if (n === this.current) return "same";
      this.close(id);
      this.open(id, n);
      return "sent";
    }

    switchTo(n) { this.current = n; this.mc = false; }
    balance() { balanceTree(this.desk.tree); }
    toggleZoom() {
      const d = this.desk;
      if (d.focus == null) return null;
      d.zoom = d.zoom === d.focus ? null : d.focus;
      return d.zoom ? "zoom" : "unzoom";
    }
    setMissionControl(on) { this.mc = on; }

    // ── Rendering ───────────────────────────────────────────────────

    windowEl(key) {
      if (this.els.has(key)) return this.els.get(key);
      const name = this.appName(key);
      const el = document.createElement("div");
      el.className = "win is-entering";
      el.dataset.app = key;
      el.innerHTML = `
        <div class="win-bar">
          <span class="lights">${this.interactive
            ? `<button class="light light-close" type="button" aria-label="Close ${name}"></button>`
            : `<span class="light light-close"></span>`}<span class="light light-min"></span><span class="light light-max"></span></span>
          <span class="win-title">${name}</span>
        </div>
        <div class="win-body" aria-hidden="true">${CONTENT[key] ? CONTENT[key]() : ""}</div>`;
      if (this.interactive) {
        el.addEventListener("pointerdown", () => {
          if (this.desk.focus === key || this.where(key) !== this.current) return;
          this.desk.focus = key;
          this.render();
          this.onFocus && this.onFocus(key);
        });
        el.querySelector(".light-close").addEventListener("click", (e) => {
          e.stopPropagation();
          this.close(key);
          this.render();
          this.onFocus && this.onFocus(null, "close");
        });
      }
      this.els.set(key, el);
      return el;
    }

    gapEl(node) {
      if (this.gapEls.has(node.sid)) return this.gapEls.get(node.sid);
      const el = document.createElement("button");
      el.type = "button";
      el.className = `divider divider-${node.axis}`;
      el.setAttribute("role", "separator");
      el.setAttribute("aria-orientation", node.axis === "x" ? "vertical" : "horizontal");
      el.setAttribute("aria-valuemin", "15");
      el.setAttribute("aria-valuemax", "85");
      el.setAttribute("aria-label", "Resize the windows on either side");
      const setRatio = (r) => { el._gap.node.ratio = Math.min(0.85, Math.max(0.15, r)); this.render(); };
      el.addEventListener("pointerdown", (e) => {
        e.preventDefault();
        el.setPointerCapture(e.pointerId);
        el.classList.add("is-active");
        this.screen.classList.add("is-dragging");
      });
      el.addEventListener("pointermove", (e) => {
        if (!el.hasPointerCapture(e.pointerId)) return;
        const g = el._gap, box = this.screen.getBoundingClientRect();
        const pos = g.node.axis === "x" ? e.clientX - box.left - g.box.x : e.clientY - box.top - g.box.y;
        setRatio(pos / (g.node.axis === "x" ? g.box.w : g.box.h));
      });
      const end = (e) => {
        if (!el.hasPointerCapture(e.pointerId)) return;
        el.releasePointerCapture(e.pointerId);
        el.classList.remove("is-active");
        this.screen.classList.remove("is-dragging");
        this.onFocus && this.onFocus(null, "resize");
      };
      el.addEventListener("pointerup", end);
      el.addEventListener("pointercancel", end);
      el.addEventListener("keydown", (e) => {
        const step = { ArrowLeft: -0.05, ArrowUp: -0.05, ArrowRight: 0.05, ArrowDown: 0.05 }[e.key];
        if (step === undefined) return;
        e.preventDefault();
        setRatio(el._gap.node.ratio + step);
        this.onFocus && this.onFocus(null, "resize");
      });
      this.gapEls.set(node.sid, el);
      return el;
    }

    render() {
      const W = this.screen.clientWidth, H = this.screen.clientHeight;
      if (!W || !H) return;
      this.screen.classList.toggle("is-mc", this.mc);

      // Mission Control lays every desktop out as a thumbnail in a row;
      // otherwise the track slides to the current one, as a swipe does.
      if (this.mc) {
        const n = this.desks.length, s = n > 2 ? 0.29 : 0.4, gap = W * 0.03;
        const total = n * s * W + (n - 1) * gap;
        const x0 = (W - total) / 2, y = (H - s * H) / 2 - H * 0.05;
        this.track.style.transform = "translate(0px, 0px)";
        this.deskEls.forEach((el, i) => {
          el.style.transform = `translate(${x0 + i * (s * W + gap) - i * W}px, ${y}px) scale(${s})`;
        });
      } else {
        this.track.style.transform = `translate(${-this.current * W}px, 0px)`;
        this.deskEls.forEach((el) => { el.style.transform = "translate(0px, 0px) scale(1)"; });
      }

      const live = new Set(), liveGaps = new Set();
      this.desks.forEach((d, i) => {
        const host = this.deskEls[i];
        host.classList.toggle("is-current", i === this.current);
        if (this.interactive) host.toggleAttribute("inert", i !== this.current || this.mc);
        const { rects, gaps } = this.rects(d);
        const full = this.area();
        for (const [key, r] of rects) {
          live.add(key);
          const el = this.windowEl(key);
          if (el.parentElement !== host) {
            const moving = el.parentElement != null;
            host.append(el);
            if (moving) { el.classList.add("is-entering"); }
          }
          el.classList.remove("is-leaving");
          const zoomed = d.zoom === key;
          Object.assign(el.style, px(zoomed ? full : r));
          el.classList.toggle("is-zoomed", zoomed);
          el.classList.toggle("is-focused", d.focus === key);
          if (el.classList.contains("is-entering")) {
            requestAnimationFrame(() => requestAnimationFrame(() => el.classList.remove("is-entering")));
          }
        }
        if (this.interactive) {
          for (const g of gaps) {
            liveGaps.add(g.node.sid);
            const el = this.gapEl(g.node);
            if (el.parentElement !== host) host.append(el);
            Object.assign(el.style, px(g.at));
            el.hidden = d.zoom != null;
            el.setAttribute("aria-valuenow", String(Math.round(g.node.ratio * 100)));
            el._gap = g;
          }
        }
      });
      for (const [key, el] of this.els) {
        if (live.has(key) || el.classList.contains("is-leaving")) continue;
        el.classList.add("is-leaving");
        setTimeout(() => {
          if (el.classList.contains("is-leaving")) { el.remove(); this.els.delete(key); }
        }, 260);
      }
      for (const [sid, el] of this.gapEls) if (!liveGaps.has(sid)) { el.remove(); this.gapEls.delete(sid); }
    }
  }

  window.WeftTiler = Tiler;
})();
