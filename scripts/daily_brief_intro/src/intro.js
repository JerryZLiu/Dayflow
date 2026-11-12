/* Daily Briefs intro, in-app copy. Four steps; "Next" (or →/←) moves between them, and the
   envelope's seal finishes the flow. Each step's right-hand art replays its entrance whenever
   it opens.

   Talks to the app through window.webkit.messageHandlers.dailyBriefIntro:
     {command: "ready"}                  the page is up
     {command: "step", index: 0...3}     a step opened
     {command: "finish"}                 the seal was clicked and the envelope has opened
     {command: "skip", step: 0...3}      Escape was pressed */
(function () {
  "use strict";

  var frame = document.getElementById("frame");
  var modal = document.getElementById("modal");
  var steps = Array.prototype.slice.call(document.querySelectorAll(".step"));
  var nextBtn = document.getElementById("next");
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var current = -1;

  // build.py inlines every asset; ones whose names are put together at runtime come from this table
  function assetURL(path) { return (window.INTRO_ASSETS && window.INTRO_ASSETS[path]) || path; }

  function post(message) {
    var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dailyBriefIntro;
    if (bridge) bridge.postMessage(message);
  }

  document.addEventListener("contextmenu", function (e) { e.preventDefault(); });

  /* ---------- step 1: connector lines ----------
     Smooth curves, all drawn in one SVG: the timeline cards and Claude/ChatGPT feed the ring,
     and every app icon feeds both Claude and ChatGPT. Each line runs in the direction data
     flows, so the light packets travel start → end. */
  (function () {
    var svg = document.getElementById("s1-net");
    var pk = document.getElementById("s1-net-pk");
    var RING_TOP = 199, RING_BOTTOM = 232, RING_X = 183;
    var lines = [
      // [path, draw delay s, packet delay s, class]
      ["M80 141C80 180 183 164 183 " + RING_TOP, 0.45, 1.9, "main"],
      ["M160 141C160 176 183 166 183 " + RING_TOP, 0.5, 2.2, "main"],
      ["M287 141C287 180 183 164 183 " + RING_TOP, 0.55, 2.6, "main"],
      ["M132 270C132 248 " + RING_X + " 256 " + RING_X + " " + RING_BOTTOM, 1.0, 2.4, "main"],
      ["M228 266.3C228 248 " + RING_X + " 256 " + RING_X + " " + RING_BOTTOM, 1.05, 2.9, "main"]
    ];
    var llms = [[132, 298.1], [228, 294.3]];               // Claude, ChatGPT centres
    var apps = [[45.5, 338.5], [123.3, 373], [196.5, 382.5], [271, 370], [335, 326]]; // GitHub, Gmail, Slack, Notion, Figma
    var n = 0;
    apps.forEach(function (a, i) {
      llms.forEach(function (l) {
        // a gentle bow: one control point pushed sideways from the midpoint, as a cubic
        var dx = l[0] - a[0], dy = l[1] - a[1], len = Math.hypot(dx, dy) || 1;
        var bow = Math.min(14, len * 0.15);
        var nx = -dy / len * bow, ny = dx / len * bow;
        var c1 = [a[0] + dx / 3 + nx, a[1] + dy / 3 + ny], c2 = [a[0] + 2 * dx / 3 + nx, a[1] + 2 * dy / 3 + ny];
        var f = function (p) { return p[0].toFixed(1) + " " + p[1].toFixed(1); };
        lines.push(["M" + f(a) + "C" + f(c1) + " " + f(c2) + " " + f(l), 0.75 + i * 0.06, 1.7 + n * 0.37, "app"]);
        n++;
      });
    });
    svg.innerHTML = lines.map(function (l) {
      return '<path class="' + l[3] + '" pathLength="1" d="' + l[0] + '" style="--d:' + l[1] + 's"/>';
    }).join("");
    pk.innerHTML = lines.map(function (l) {
      return '<span class="pk"><b style="offset-path:path(\'' + l[0] + '\');animation-delay:' + l[2].toFixed(2) + 's"></b></span>';
    }).join("");
  })();

  /* ---------- steps ---------- */
  function setStep(i, replay) {
    i = Math.max(0, Math.min(steps.length - 1, i));
    if (i === current && !replay) return;
    steps.forEach(function (s, n) { if (n !== i) s.classList.remove("is-active"); });
    var el = steps[i];
    el.classList.remove("is-active");
    void el.offsetWidth; // restart the entrance animations
    el.classList.add("is-active");
    current = i;

    modal.setAttribute("aria-labelledby", "step-title-" + i);
    nextBtn.classList.toggle("is-hidden", i === steps.length - 1);

    if (i === 1) tasks.start(); else tasks.stop();
    if (i === 2) caughtUp.start(); else caughtUp.stop();
    if (i === steps.length - 1) envelope.reset();
    post({ command: "step", index: i });
  }

  nextBtn.addEventListener("click", function () { setStep(current + 1); });

  document.addEventListener("keydown", function (e) {
    if (frame.classList.contains("is-done")) return;
    if (e.key === "ArrowRight") setStep(current + 1);
    if (e.key === "ArrowLeft") setStep(current - 1);
    if (e.key === "Escape") post({ command: "skip", step: current });
  });

  /* ---------- step 2 pets: Clawd (orange) and the Codex pet (blue) ----------
     Drawn the way ../mac-handoff.js draws them: Clawd from the frames traced in ../clawd-vectors
     (walk, sway) and ../pet-poses (hands up), the Codex pet from its sprite sheet (../codex-pet:
     8 × 11 cells of 192 × 208, kept here as the four rows this uses: idle, walk right, walk
     left, and the original row 8's hop) with app frame times. Each is pinned by its feet to the bottom
     centre of its Figma box. Poses: idle, walk (right), walkLeft, hold (card overhead). */
  var cycle = function (list, fps, ms) { return list[Math.floor((ms * fps) / 1000) % list.length]; };
  var timed = function (list, ms) {
    var total = list.reduce(function (n, f) { return n + f[1]; }, 0), at = ms % total;
    for (var i = 0; i < list.length; i++) if ((at -= list[i][1]) < 0) return list[i][0];
    return list[0][0];
  };

  var PETS = {
    clawd: (function () {
      var PX = 3.5; // px to a pixel of Clawd's art (its body is 24 across, 16 tall: 84 × 56)
      var WALK = ["walk-05", "walk-06", "walk-07", "walk-08", "walk-09"];
      var SWAY = [[4, 167], [6, 167], [8, 167], [10, 250], [13, 167], [15, 167], [17, 167], [19, 250], [22, 167], [24, 167],
        [26, 167], [28, 250], [31, 167], [33, 167], [35, 167], [37, 250], [40, 167], [42, 167], [44, 417]]
        .map(function (f) { return ["sway-" + String(f[0]).padStart(2, "0"), f[1]]; });
      var HOLD = [["hold-happy", 700], ["jumping-07", 350]];
      // [canvas w, h, middle of its body, feet] in art pixels
      var CANVAS = { walk: [24, 18, 12, 18], sway: [28, 17, 14, 17], jumping: [24, 30, 12, 30] };
      var FEET = { "jumping-07": 20, "hold-happy": 20 }; // (arms-up frames are drawn up their canvas)
      var ids = WALK.concat(SWAY.map(function (f) { return f[0]; }), ["jumping-00", "jumping-07", "hold-happy"]);
      return {
        hands: 20 * PX,
        build: function (el) {
          var imgs = {};
          ids.forEach(function (id) {
            var c = CANVAS[id === "hold-happy" ? "jumping" : id.split("-")[0]];
            var img = document.createElement("img");
            img.src = assetURL(id === "hold-happy" ? "assets/pets/clawd/clawd-hands-up-happy.svg" : "assets/pets/clawd/" + id + ".svg");
            img.alt = "";
            img.style.cssText = "left:" + (-c[2] * PX) + "px;top:" + (-(FEET[id] || c[3]) * PX) + "px;width:" + c[0] * PX + "px;height:" + c[1] * PX + "px";
            el.appendChild(img);
            imgs[id] = img;
          });
          var on = null;
          return function (id) { if (on === id) return; if (on) imgs[on].classList.remove("is-on"); imgs[id].classList.add("is-on"); on = id; };
        },
        frame: function (pose, ms) {
          if (pose === "walk") return [cycle(WALK, 14, ms), false];      // (its walk faces right)
          if (pose === "walkLeft") return [cycle(WALK, 14, ms), true];
          if (pose === "hold") return [timed(HOLD, ms), false];
          return [timed(SWAY, ms), false];
        }
      };
    })(),
    codex: (function () {
      var CX = 0.47; // px to a pixel of its sheet (standing it's 144 across, 170 tall, feet at 200: 68 × 80,
                      // about Clawd's visual size: it's narrower but taller)
      var cells = function (row, durs) { return durs.map(function (d, c) { return [row + "-" + c, d]; }); };
      var IDLE = cells(0, [280, 110, 110, 140, 140, 320]);
      var WALK_R = cells(1, [150, 150, 150, 150, 150, 150, 150, 150]);
      var WALK_L = cells(2, [150, 150, 150, 150, 150, 150, 150, 150]);
      var HOLD = [["3-2", 700], ["hold-plain", 350]]; // happy hop peak, hands up; and the same with its default face
      var FEET = { "3-2": 178, "hold-plain": 178 };
      return {
        hands: 170 * CX,
        build: function (el) {
          var d = document.createElement("div");
          d.className = "is-on";
          d.style.cssText = "left:" + (-96 * CX) + "px;width:" + 192 * CX + "px;height:" + 208 * CX + "px";
          el.appendChild(d);
          var on = null;
          return function (id) {
            if (on === id) return;
            on = id;
            d.style.top = -(FEET[id] || 200) * CX + "px";
            if (id === "hold-plain") {
              d.style.backgroundImage = 'url("assets/pets/codex/codex-hands-up-default.webp")';
              d.style.backgroundSize = "100% 100%";
              d.style.backgroundPosition = "0 0";
              return;
            }
            var rc = id.split("-").map(Number);
            d.style.backgroundImage = 'url("assets/pets/codex/codex-spritesheet.webp")';
            d.style.backgroundSize = 8 * 192 * CX + "px auto";
            d.style.backgroundPosition = -rc[1] * 192 * CX + "px " + -rc[0] * 208 * CX + "px";
          };
        },
        frame: function (pose, ms) {
          if (pose === "walk") return [timed(WALK_R, ms), false];
          if (pose === "walkLeft") return [timed(WALK_L, ms), false];  // (it has its own walk to the left)
          if (pose === "hold") return [timed(HOLD, ms), false];
          return [timed(IDLE, ms), false];
        }
      };
    })()
  };

  var CARRY = 0.4; // how small a task card gets on a pet's hands (intro.css .s2-carry matches)
  var SWIPE = 500; // ms for a card to fly from the stack to a pet

  // One per agent: knows its pose (from walking / carrying) and draws it every frame
  function Pet(agent) {
    var el = agent.querySelector(".pet");
    var kind = PETS[el.dataset.pet];
    var show = kind.build(el);
    var self = { walking: false, dir: "right", carrying: false, pose: null, since: 0, kind: kind };
    agent.querySelector(".s2-carry").style.setProperty("--ride", -(kind.hands + (149 * CARRY) / 2 - 3) + "px");
    self.draw = function (now) {
      var pose = self.carrying ? "hold" : self.walking ? (self.dir === "left" ? "walkLeft" : "walk") : "idle";
      if (pose !== self.pose) { self.pose = pose; self.since = now; }
      var f = kind.frame(pose, now - self.since);
      show(f[0]);
      el.classList.toggle("is-left", !!f[1]);
      agent.classList.toggle("is-holding", self.carrying);
    };
    self.reset = function () { self.walking = false; self.carrying = false; self.pose = null; };
    return self;
  }

  /* ---------- step 2: Clawd carries a task off, the Codex pet catches the next ----------
     Loop: Clawd walks under the stack → card swipes onto its raised hands → it carries it off to
     the left. The Codex pet walks in from the right → the next card swipes onto it → it carries
     it off to the right. Both walk back in from their own sides, repeat. */
  var tasks = (function () {
    var titles = ["Review PR #482 for bugs", "Draft v2.4 launch notes", "Reply to Sam about pricing",
      "Fix the flaky signup test", "Prep notes for the 3pm sync"];
    var tpl = document.getElementById("task-body");
    var cards = Array.prototype.slice.call(document.querySelectorAll(".s2-card"));
    var orange = document.getElementById("agent-left");
    var blue = document.getElementById("agent-right");
    var pets = [Pet(orange), Pet(blue)];
    orange._pet = pets[0]; blue._pet = pets[1];
    var CARD_CX = 66 + 252 / 2, CARD_CY = 115 + 149 / 2;  // front card centre in the art panel
    var run = 0, nextTitle = 0, raf = 0;

    function title(card, t) { card.querySelector(".s2-title").textContent = t; }
    function byPos(p) { return cards.filter(function (c) { return c.dataset.pos === String(p); })[0]; }
    function box(a) { return { l: parseFloat(a.style.left), t: parseFloat(a.style.top), w: parseFloat(a.style.width), h: parseFloat(a.style.height) }; }
    function ride(a) { return parseFloat(a.querySelector(".s2-carry").style.getPropertyValue("--ride")) || 0; }

    function wait(ms, id) {
      return new Promise(function (res, rej) { setTimeout(function () { id === run ? res() : rej("stopped"); }, ms); });
    }
    function tick(now) { pets.forEach(function (p) { p.draw(now); }); raf = requestAnimationFrame(tick); }

    // walk an agent from one x offset to another (px from its Figma position)
    function walk(agent, from, to, ms, id) {
      if (id !== run) return Promise.reject("stopped");
      var pet = agent._pet;
      pet.walking = true;
      pet.dir = to < from ? "left" : "right";
      agent.classList.add("is-walking");
      agent.getAnimations().forEach(function (an) { if (an instanceof CSSAnimation === false) an.cancel(); });
      var an = agent.animate([{ transform: "translateX(" + from + "px)" }, { transform: "translateX(" + to + "px)" }],
        { duration: ms, easing: "ease-in-out", fill: "forwards" });
      return an.finished.then(function () { pet.walking = false; agent.classList.remove("is-walking"); });
    }

    // the front card swipes right and lands on the agent's raised hands
    function swipe(agent, agentX, id) {
      if (id !== run) return Promise.reject("stopped");
      var front = byPos(0);
      var b = box(agent);
      var tx = b.l + b.w / 2 + agentX - CARD_CX;
      var ty = b.t + b.h + ride(agent) - CARD_CY;
      front.style.zIndex = "7";
      byPos(1).dataset.pos = "0";
      byPos(2).dataset.pos = "1";
      var an = front.animate([
        { transform: "none" },
        { transform: "translate(52px, -14px) rotate(10deg)", offset: 0.32 },
        { transform: "translate(" + tx + "px, " + ty + "px) rotate(6deg) scale(" + CARRY + ")" }
      ], { duration: SWIPE, easing: "cubic-bezier(0.45, 0, 0.3, 1)", fill: "forwards" });
      setTimeout(function () { if (id === run) agent._pet.carrying = true; }, SWIPE * 0.66); // arms go up to catch
      return an.finished.then(function () {
        // hand the card to the agent, then recycle the stack card to the back
        var clone = front.cloneNode(true);
        clone.removeAttribute("style");
        agent.querySelector(".s2-carry").appendChild(clone);
        agent.classList.add("is-catching");
        setTimeout(function () { agent.classList.remove("is-catching"); }, 460);

        an.cancel();
        front.style.zIndex = "";
        front.classList.add("no-anim", "is-entering");
        front.dataset.pos = "2";
        title(front, titles[nextTitle++ % titles.length]);
        void front.offsetWidth;
        front.classList.remove("no-anim");
        requestAnimationFrame(function () { front.classList.remove("is-entering"); });
      });
    }

    function drop(agent) { agent.querySelector(".s2-carry").innerHTML = ""; agent._pet.carrying = false; }

    function reset() {
      cards.forEach(function (c) {
        if (!c.firstElementChild) c.appendChild(tpl.content.cloneNode(true));
        c.getAnimations().forEach(function (an) { an.cancel(); });
        c.className = "s2-card";
        c.style.zIndex = "";
      });
      [0, 1, 2].forEach(function (p, n) {
        cards[2 - n].dataset.pos = String(p);
        title(cards[2 - n], titles[n]);
      });
      nextTitle = 3;
      [orange, blue].forEach(function (a) {
        a.getAnimations().forEach(function (an) { if (an instanceof CSSAnimation === false) an.cancel(); });
        a.classList.remove("is-walking", "is-catching", "is-holding");
        drop(a);
        a._pet.reset();
      });
    }

    // x offsets (px) from each pet's Figma spot: where it catches, and just out of sight
    var ORANGE_CATCH = 118, ORANGE_OFF = -130;   // Clawd comes and goes on the left
    var BLUE_CATCH = -105, BLUE_OFF = 115;        // the Codex pet on the right

    // Each pet is out of sight for AWAY ms. Its walks ease in and out, so it's already hidden for
    // the last part of walking off and still hidden for the first part of walking back: the
    // waits below are AWAY minus those (measured in the browser: Clawd 575 ms, the Codex pet 621 ms).
    var AWAY = 2000;
    var ORANGE_HIDDEN_WALKING = 575, BLUE_HIDDEN_WALKING = 621;

    async function loop(id) {
      await wait(1500, id);
      for (;;) {
        // Clawd: walks under the stack, catches, carries it off to the left, comes back after AWAY
        await walk(orange, 0, ORANGE_CATCH, 1300, id);    await wait(120, id);
        await swipe(orange, ORANGE_CATCH, id);            await wait(380, id);
        var orangeTrip = walk(orange, ORANGE_CATCH, ORANGE_OFF, 1900, id)
          .then(function () { drop(orange); return wait(AWAY - ORANGE_HIDDEN_WALKING, id); })
          .then(function () { return walk(orange, ORANGE_OFF, 0, 750, id); });
        await wait(700, id);

        // the Codex pet: walks in from the right as the next card swipes over to it, carries it
        // off to the right, comes back after AWAY
        walk(blue, 0, BLUE_CATCH, 1300, id).catch(function () {});
        await wait(1300 - SWIPE, id);                     // (the card lands as it arrives)
        await swipe(blue, BLUE_CATCH, id);                await wait(420, id);
        await walk(blue, BLUE_CATCH, BLUE_OFF, 1700, id);
        drop(blue);
        await wait(AWAY - BLUE_HIDDEN_WALKING, id);
        await walk(blue, BLUE_OFF, 0, 650, id);
        await orangeTrip;
        await wait(900, id);
      }
    }

    return {
      start: function () {
        this.stop();
        reset();
        raf = requestAnimationFrame(tick);
        if (!reduceMotion) loop(run).catch(function () {});
      },
      stop: function () { run++; cancelAnimationFrame(raf); reset(); }
    };
  })();

  /* ---------- step 3: updates come in, then hand over to sources, on a loop ---------- */
  var caughtUp = (function () {
    var art = document.getElementById("caught-up");
    var timer = null;
    var HOLD = 2000; // ms each set stays fully on screen (all its parts settled) before it leaves
    // ms from a phase starting until everything in it has settled (from intro.css: the --in wait
    // for the outgoing set, then the last part's delay + duration)
    var SETTLE = { a0: 1650, a: 2200, b: 1730 };
    function next() {
      var to = art.dataset.phase.charAt(0) === "a" ? "b" : "a";
      art.dataset.phase = to;
      timer = setTimeout(next, SETTLE[to] + HOLD);
    }
    return {
      start: function () {
        this.stop();
        art.dataset.phase = "a0";
        if (reduceMotion) return;
        timer = setTimeout(next, SETTLE.a0 + HOLD);
      },
      stop: function () { clearTimeout(timer); timer = null; delete art.dataset.phase; }
    };
  })();

  /* ---------- step 4: open the envelope, then hand over to the app ---------- */
  var envelope = (function () {
    var env = document.getElementById("envelope");
    var seal = document.getElementById("seal");
    var timers = [];

    seal.addEventListener("click", function () {
      if (env.classList.contains("is-open")) return;
      env.classList.add("is-open");
      timers.push(setTimeout(function () { env.classList.add("is-flap-back"); }, 420));
      // the letter has slid up: the modal fades and the app opens the brief behind it
      timers.push(setTimeout(function () {
        frame.classList.add("is-done");
        post({ command: "finish" });
      }, 1500));
    });

    return {
      reset: function () {
        timers.forEach(clearTimeout); timers = [];
        env.classList.remove("is-open", "is-flap-back");
      }
    };
  })();

  /* ---------- open ---------- */
  post({ command: "ready" });
  requestAnimationFrame(function () {
    requestAnimationFrame(function () {
      frame.classList.remove("is-intro");
      setStep(0, true);
    });
  });
})();
