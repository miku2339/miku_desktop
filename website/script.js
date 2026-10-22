(function () {
  const root = document.documentElement;
  root.classList.add("js");
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  const language = root.lang === "en" ? "en" : root.lang === "ja" ? "ja" : "zh-Hant";
  const languagePaths = { "zh-Hant": "/", en: "/en/", ja: "/ja/" };
  const languageSelect = document.getElementById("site-language");
  if (languageSelect) {
    languageSelect.value = languagePaths[language];
    languageSelect.addEventListener("change", () => window.location.assign(languageSelect.value));
  }

  // ---------- Time of day: match the hero to the visitor's clock, like the app does ----------
  const copy = {
    "zh-Hant": {
      periods: { day: "白天", dusk: "黃昏", night: "夜晚" },
      clock: (period) => `現在是你所在地的${period}`,
      room: (period) => `${period}的房間`,
      play: "播放一天",
      pause: "暫停",
    },
    en: {
      periods: { day: "daytime", dusk: "dusk", night: "night" },
      clock: (period) => `It’s ${period} where you are`,
      room: (period) => `${period[0].toUpperCase()}${period.slice(1)} in her room`,
      play: "Play a day",
      pause: "Pause",
    },
    ja: {
      periods: { day: "日中", dusk: "夕暮れ", night: "夜" },
      clock: (period) => `あなたのいる場所はいま${period}です`,
      room: (period) => `${period}の部屋`,
      play: "1日を再生",
      pause: "一時停止",
    },
  }[language];
  const clock = document.getElementById("clock");
  const buttons = document.querySelectorAll(".dial button");
  const periodFor = (h) => (h >= 6 && h < 17 ? "day" : h >= 17 && h < 19 ? "dusk" : "night");

  function show(period, fromClock) {
    document.body.dataset.time = period;
    buttons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.set === period)));
    clock.textContent = fromClock ? copy.clock(copy.periods[period]) : copy.room(copy.periods[period]);
    heroFx && heroFx.setMode(period);
  }

  // ---------- Particle field ----------
  const TEAL = [57, 197, 187];
  const palettes = {
    day: { note: [[255, 255, 255], TEAL, [191, 240, 235]], mote: [255, 250, 230] },
    dusk: { note: [[255, 214, 160], [255, 170, 190], TEAL], mote: [255, 200, 140] },
    night: { note: [TEAL, [180, 210, 255]], mote: [140, 255, 235] },
  };
  const NOTES = ["♪", "♫", "♪"];
  const rand = (a, b) => a + Math.random() * (b - a);
  const pick = (arr) => arr[(Math.random() * arr.length) | 0];

  function Field(canvas, opts) {
    const ctx = canvas.getContext("2d");
    const host = canvas.parentElement;
    let w = 0, h = 0, dpr = 1, mode = opts.mode || "day";
    let parts = [], stars = [], running = false, visible = true, last = 0;
    const mouse = { x: -9999, y: -9999 };

    function resize() {
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      w = host.clientWidth; h = host.clientHeight;
      canvas.width = w * dpr; canvas.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      stars = [];
      const n = Math.round((w * h) / 9000);
      for (let i = 0; i < n; i++) stars.push({ x: rand(0, w), y: rand(0, h * 0.75), r: rand(0.4, 1.6), p: rand(0, 6.28), s: rand(0.6, 2) });
    }

    const target = () => Math.round(Math.min(opts.max, (w * h) / opts.density));

    function spawn(kind, x, y, burst) {
      const pal = palettes[mode];
      const isNote = kind === "note";
      parts.push({
        kind, x, y,
        vx: burst ? rand(-2.4, 2.4) : rand(-0.15, 0.15),
        vy: burst ? rand(-3.4, -1) : isNote ? rand(-0.55, -0.25) : rand(-0.25, 0.1),
        size: isNote ? rand(14, 26) : rand(1.2, 3.2),
        rot: rand(-0.4, 0.4), vr: rand(-0.01, 0.01),
        phase: rand(0, 6.28), sway: rand(0.3, 1.1),
        color: isNote ? pick(pal.note) : pal.mote,
        glyph: burst && Math.random() < 0.3 ? "♡" : pick(NOTES),
        life: 0, max: burst ? rand(60, 100) : rand(420, 900),
        burst: !!burst, fade: 0,
      });
    }

    function ambient(initial) {
      const want = target();
      let count = 0;
      for (const p of parts) if (!p.burst && !p.fade) count++;
      for (let i = count; i < want; i++) {
        const note = opts.notes && Math.random() < (mode === "night" ? 0.18 : 0.42);
        const y = initial ? rand(0, h) : h + 20;
        spawn(note ? "note" : "mote", rand(0, w), note ? y : initial ? rand(0, h) : rand(0, h), false);
      }
    }

    function draw(p, alpha) {
      const [r, g, b] = p.color;
      if (p.kind === "note") {
        ctx.save();
        ctx.translate(p.x, p.y);
        ctx.rotate(p.rot);
        ctx.font = `700 ${p.size}px "Hiragino Sans", "PingFang TC", "Noto Sans TC", sans-serif`;
        ctx.shadowColor = `rgba(${r},${g},${b},${alpha * 0.9})`;
        ctx.shadowBlur = 12;
        ctx.fillStyle = `rgba(${r},${g},${b},${alpha})`;
        ctx.fillText(p.glyph, -p.size / 3, p.size / 3);
        ctx.restore();
      } else {
        const glow = mode === "night" ? 0.5 + 0.5 * Math.sin(p.phase * 3) : 1;
        const rad = p.size * (mode === "night" ? 3.2 : 2.4);
        const grd = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, rad);
        grd.addColorStop(0, `rgba(${r},${g},${b},${alpha * glow})`);
        grd.addColorStop(1, `rgba(${r},${g},${b},0)`);
        ctx.fillStyle = grd;
        ctx.beginPath(); ctx.arc(p.x, p.y, rad, 0, 6.283); ctx.fill();
      }
    }

    function frame(t) {
      if (!running) return;
      const dt = Math.min(2, last ? (t - last) / 16.7 : 1);
      last = t;
      ctx.clearRect(0, 0, w, h);

      if (mode === "night" && opts.stars) {
        for (const s of stars) {
          const a = 0.35 + 0.45 * Math.sin(t / 1000 * s.s + s.p);
          ctx.fillStyle = `rgba(230,240,255,${a})`;
          ctx.beginPath(); ctx.arc(s.x, s.y, s.r, 0, 6.283); ctx.fill();
        }
      }

      ambient(false);
      for (let i = parts.length - 1; i >= 0; i--) {
        const p = parts[i];
        p.life += dt; p.phase += 0.02 * dt;
        if (p.burst) { p.vy += 0.06 * dt; p.vx *= 0.985; }
        else {
          p.x += Math.sin(p.phase) * p.sway * 0.4 * dt;
          if (p.kind === "mote" && mode === "night") { p.vx += rand(-0.02, 0.02); p.vy += rand(-0.02, 0.02); p.vx *= 0.98; p.vy *= 0.98; }
        }
        // Drift away from the cursor
        const dx = p.x - mouse.x, dy = p.y - mouse.y, d2 = dx * dx + dy * dy;
        if (d2 < 14400 && d2 > 1) { const f = (1 - d2 / 14400) * 0.6; const d = Math.sqrt(d2); p.x += (dx / d) * f * dt * 3; p.y += (dy / d) * f * dt * 3; }
        p.x += p.vx * dt; p.y += p.vy * dt; p.rot += p.vr * dt;

        let a = Math.min(1, p.life / 40) * Math.min(1, (p.max - p.life) / 60);
        if (p.fade) { p.fade += dt; a *= Math.max(0, 1 - p.fade / 50); }
        const base = p.kind === "note" ? 0.85 : 0.75;
        if (p.life > p.max || p.y < -40 || p.y > h + 60 || p.x < -60 || p.x > w + 60 || (p.fade && p.fade > 50)) { parts.splice(i, 1); continue; }
        draw(p, Math.max(0, a) * base);
      }
      requestAnimationFrame(frame);
    }

    function start() { if (!running && visible && !document.hidden) { running = true; last = 0; requestAnimationFrame(frame); } }
    function stop() { running = false; }

    resize(); ambient(true);
    window.addEventListener("resize", resize);
    document.addEventListener("visibilitychange", () => (document.hidden ? stop() : start()));
    new IntersectionObserver(([e]) => { visible = e.isIntersecting; visible ? start() : stop(); }).observe(host);
    host.addEventListener("pointermove", (e) => { const r = canvas.getBoundingClientRect(); mouse.x = e.clientX - r.left; mouse.y = e.clientY - r.top; });
    host.addEventListener("pointerleave", () => { mouse.x = mouse.y = -9999; });

    return {
      setMode(m) {
        if (m === mode) return;
        mode = m;
        parts.forEach((p) => { if (!p.burst) p.fade = 1; });
        ambient(true);
      },
      burst(x, y, n) { for (let i = 0; i < n; i++) spawn("note", x, y, true); },
    };
  }

  let heroFx = null;
  if (!reduceMotion) {
    heroFx = Field(document.getElementById("hero-particles"), { notes: true, stars: true, density: 14000, max: 110 });
    const streets = document.getElementById("street-particles");
    if (streets) Field(streets, { notes: false, stars: false, density: 9000, max: 90, mode: "night" });
  }
  show(periodFor(new Date().getHours()), true);
  buttons.forEach((b) => b.addEventListener("click", () => show(b.dataset.set, false)));

  // ---------- Hero: load sequence, cursor parallax, poke Miku ----------
  requestAnimationFrame(() => requestAnimationFrame(() => root.classList.add("ready")));

  const hero = document.querySelector(".hero");
  const wrap = document.getElementById("miku-wrap");
  const miku = wrap.querySelector(".hero-miku");
  if (!reduceMotion && window.matchMedia("(pointer: fine)").matches) {
    hero.addEventListener("pointermove", (e) => {
      const r = hero.getBoundingClientRect();
      const nx = (e.clientX - r.left) / r.width - 0.5, ny = (e.clientY - r.top) / r.height - 0.5;
      wrap.style.setProperty("--px", `${(-nx * 18).toFixed(1)}px`);
      wrap.style.setProperty("--py", `${(-ny * 10).toFixed(1)}px`);
      document.querySelector(".scene").style.transform = `scale(1.04) translate(${(nx * 10).toFixed(1)}px, ${(ny * 6).toFixed(1)}px)`;
    });
    hero.addEventListener("pointerleave", () => {
      wrap.style.setProperty("--px", "0px"); wrap.style.setProperty("--py", "0px");
      document.querySelector(".scene").style.transform = "";
    });
  }
  miku.addEventListener("click", (e) => {
    miku.classList.remove("poked"); void miku.offsetWidth; miku.classList.add("poked");
    if (heroFx) { const r = hero.getBoundingClientRect(); heroFx.burst(e.clientX - r.left, e.clientY - r.top, 14); }
  });
  miku.addEventListener("animationend", (e) => { if (e.animationName === "poke") miku.classList.remove("poked"); });

  // ---------- Scroll reveals and the chat exchange ----------
  const bubbles = document.querySelector(".bubbles");
  const steps = document.querySelector(".steps");
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      e.target.classList.add("in");
      io.unobserve(e.target);
      if (e.target.contains(bubbles) && !bubbles.classList.contains("step1")) {
        bubbles.classList.add("step1");
        setTimeout(() => bubbles.classList.add("step2"), 600);
        setTimeout(() => bubbles.classList.add("step3"), 2000);
      }
      if (e.target.contains(steps)) steps.classList.add("in");
    }
  }, { threshold: 0.2 });
  document.querySelectorAll(".reveal").forEach((el) => (reduceMotion ? el.classList.add("in") : io.observe(el)));
  if (reduceMotion) { bubbles.classList.add("step1", "step2", "step3"); steps.classList.add("in"); }
  // ---------- Live background demo (the app's ambience engine in an iframe) ----------
  const frame = document.getElementById("live-demo");
  if (frame) {
    const slider = document.getElementById("live-hour");
    const out = document.getElementById("live-clock");
    const play = document.getElementById("live-play");
    const send = (m) => frame.contentWindow && frame.contentWindow.postMessage({ type: "miku-demo-set", ...m }, "*");
    const fmt = (h) => `${String(Math.floor(h)).padStart(2, "0")}:${String(Math.floor((h % 1) * 60)).padStart(2, "0")}`;
    const setHourUI = (h) => { slider.value = h.toFixed(2); out.textContent = fmt(h); };
    const now = new Date();
    let hour = now.getHours() + now.getMinutes() / 60;
    let demoPaused = true;
    setHourUI(hour);

    const setPlaying = (on) => { play.setAttribute("aria-pressed", String(on)); play.textContent = on ? copy.pause : copy.play; send({ playing: on }); };

    document.querySelectorAll(".live .chips").forEach((group) => {
      group.addEventListener("click", (e) => {
        const b = e.target.closest("button");
        if (!b) return;
        group.querySelectorAll("button").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
        send({ [group.dataset.key]: b.dataset.value });
      });
    });
    slider.addEventListener("input", () => { hour = Number(slider.value); out.textContent = fmt(hour); setPlaying(false); send({ hour }); });
    play.addEventListener("click", () => setPlaying(play.getAttribute("aria-pressed") !== "true"));

    window.addEventListener("message", (e) => {
      if (e.source !== frame.contentWindow || !e.data) return;
      if (e.data.type === "miku-demo-ready") {
        const pressed = (key) => document.querySelector(`.live .chips[data-key="${key}"] [aria-pressed="true"]`).dataset.value;
        send({ scene: pressed("scene"), weather: pressed("weather"), hour, playing: play.getAttribute("aria-pressed") === "true", paused: demoPaused });
      } else if (e.data.type === "miku-demo") { hour = e.data.hour; setHourUI(hour); }
    });
    // Only animate while the demo is on screen.
    new IntersectionObserver(([en]) => {
      demoPaused = !en.isIntersecting;
      send({ paused: demoPaused });
    }).observe(frame);
  }
})();
