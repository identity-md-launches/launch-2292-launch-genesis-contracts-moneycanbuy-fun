// moneycanbuy.fun teaser: sound on by default, autoplay fallback, keeps playing while scrolling.
(function () {
  "use strict";
  var video = document.getElementById("promo");
  var sound = document.getElementById("sound");
  var label = sound.querySelector("span");

  function tryPlay() {
    var p = video.play();
    if (p && p.catch) p.catch(function () { /* autoplay blocked: poster stays, a tap starts it */ });
  }

  function setSound(on, restart) {
    video.muted = !on;
    if (on && restart) { video.currentTime = 0; } // with sound, start from the typed opening
    sound.setAttribute("aria-pressed", String(on));
    label.textContent = on ? "Sound on" : "Sound";
    sound.classList.toggle("nudge", !on);
  }

  // Sound is on by default. Browsers refuse unmuted autoplay until the visitor interacts with the page,
  // so we try with sound, fall back to muted, and switch sound on at the first tap, click or key press.
  var userChoseMute = false;
  var gestures = ["pointerdown", "touchend", "keydown"];
  function unmuteOnGesture(e) {
    gestures.forEach(function (t) { window.removeEventListener(t, unmuteOnGesture, true); });
    if (userChoseMute || sound.contains(e.target)) return; // the sound button handles itself
    setSound(true, true);
    tryPlay();
  }
  setSound(true, false);
  var first = video.play();
  if (first && first.catch) {
    first.catch(function () {
      setSound(false, false);
      tryPlay();
      gestures.forEach(function (t) { window.addEventListener(t, unmuteOnGesture, true); });
    });
  }

  sound.addEventListener("click", function () {
    var turnOn = video.muted;
    userChoseMute = !turnOn;
    setSound(turnOn, true);
    tryPlay();
  });

  video.addEventListener("click", function () {
    if (video.paused) tryPlay(); else video.pause();
  });

  // keeps playing (and sounding) while the visitor scrolls the page
  tryPlay();
})();

// Dare calculator: every number below follows src/{VaultParams.sol,desks/Desk.sol,
// desks/DisputeDesk.sol} in this repository (one disputer, the NFT vote decides and nobody appeals, doer without
// a $YOLO lock). Amounts are in the reward's own currency: the contracts read no price for any of them.
(function () {
  "use strict";
  var stage = document.getElementById("calc-stage");
  if (!stage) return;

  var BPS = 10000;
  // VaultParams.sol LaunchParams.initial(): the launch values.
  var P = {
    bondFixedImd: 0.5, doerBondBps: 300, disputeBondBps: 100, // Desk.sol _doerBond / _disputeBond
    feeBps: 1000, nftFeeBps: 500, winnerBondBps: 5000 // DisputeDesk.sol _payReward / _splitCurrency
  };
  // minimum reward per currency (VaultParams.sol minReward*); no maximum. Slider and quick picks are page choices.
  var CUR = {
    USDC: { min: 5, max: 1000, step: 1, dec: 4, start: 100, quick: [20, 100, 300, 1000] },
    ETH: { min: 0.002, max: 1, step: 0.001, dec: 6, start: 0.05, quick: [0.01, 0.05, 0.1, 0.5] },
    IMD: { min: 1, max: 500, step: 1, dec: 4, start: 20, quick: [5, 20, 100, 500] },
    YOLO: { min: 1000, max: 5000000, step: 1000, dec: 2, start: 100000, quick: [10000, 100000, 1000000, 5000000] }
  };
  var ORDER = ["author", "doer", "contract", "disputer", "nft", "swarm", "treasury"];

  function pctBond(amount, bps) { // Desk.sol _pctBond: amount * bps / BPS, never above amount
    return Math.min(amount, amount * bps / BPS);
  }
  function fmtNum(x, cur) {
    return x.toLocaleString("en-US", { maximumFractionDigits: CUR[cur].dec });
  }
  function fmtCur(x, cur) { return fmtNum(x, cur) + " " + cur; }
  function fmtImd(x) { return fmtNum(x, "IMD") + " IMD"; }
  // a bond is two parts: fixed IMD + percent part in the reward's currency (one sum when the reward is IMD)
  function fmtBond(b, cur) { return cur === "IMD" ? fmtImd(b.imd + b.rew) : fmtImd(b.imd) + " + " + fmtCur(b.rew, cur); }
  function halfBond(b) { // _splitCurrency per currency: voters get penalty − penalty·winnerBondBps/BPS, the winner the rest
    var w = { imd: b.imd * P.winnerBondBps / BPS, rew: b.rew * P.winnerBondBps / BPS };
    return { winner: w, voters: { imd: b.imd - w.imd, rew: b.rew - w.rew } };
  }

  function calc(amount, currency, scenario) {
    var R = amount;
    var doerBond = { imd: P.bondFixedImd, rew: pctBond(R, P.doerBondBps) };
    var disputeBond = { imd: P.bondFixedImd, rew: pctBond(R, P.disputeBondBps) };
    var fee = R * P.feeBps / BPS;
    var r = { amount: R, currency: currency, doerBond: doerBond, disputeBond: disputeBond, fee: fee,
      burnsFee: currency === "YOLO" }; // TaskVault.sol: $YOLO the treasury would get goes to the BuybackBurner
    if (scenario === "none") { // no dispute: nftRight = false, the whole 10% to the treasury
      r.doerGets = R - fee;
      r.treasury = fee;
    } else if (scenario === "doerwin") { // NFT decided right for the doer: 5% to the voters, 5% to the treasury
      var s1 = halfBond(disputeBond);
      r.doerGets = R - fee;
      r.toVoters = R * P.nftFeeBps / BPS;
      r.treasury = fee - r.toVoters;
      r.winnerShare = s1.winner;
      r.votersBondCut = s1.voters;
    } else { // fake caught: _payReward never runs, the reward stays in the dare
      var s2 = halfBond(doerBond);
      r.winnerShare = s2.winner;
      r.votersBondCut = s2.voters;
    }
    return r;
  }

  function buildSteps(scenario) {
    var s = [
      { text: "Author locks the reward", from: "author", to: "contract", chip: "reward" },
      { text: "Doer submits proof + bond", from: "doer", to: "contract", chip: "bond" }
    ];
    if (scenario === "none") {
      s.push({ text: "24h window, nobody disputes", from: null, to: "contract", chip: null });
      s.push({ text: "Doer paid 90% of the reward", from: "contract", to: "doer", chip: "doerGets" });
      s.push({ text: "10% fee to the treasury", from: "contract", to: "treasury", chip: "treasury" });
      s.push({ text: "Doer's bond comes back", from: "contract", to: "doer", chip: "doerBond" });
    } else if (scenario === "doerwin") {
      s.push({ text: "Disputer bonds, challenges proof", from: "disputer", to: "contract", chip: "disputeBond" });
      s.push({ text: "NFT holders vote: doer right", from: null, to: "nft", chip: null });
      s.push({ text: "Doer paid 90%, NFT voters 5%", from: "contract", to: "doer", chip: "doerGets" });
      s.push({ text: "Doer's bond back + half the disputer's", from: "contract", to: "doer", chip: "winnerShare" });
      s.push({ text: "NFT voters get the other half", from: "contract", to: "nft", chip: "votersBondCut" });
    } else {
      s.push({ text: "Disputer bonds, challenges proof", from: "disputer", to: "contract", chip: "disputeBond" });
      s.push({ text: "NFT holders vote: fake caught", from: null, to: "nft", chip: null });
      s.push({ text: "Reward stays, dare stays open", from: "contract", to: "contract", chip: "stay" });
      s.push({ text: "Disputer's bond back + half the doer's", from: "contract", to: "disputer", chip: "winnerShare" });
      s.push({ text: "NFT voters get the other half", from: "contract", to: "nft", chip: "votersBondCut" });
    }
    return s;
  }

  function chipText(key, r) {
    var c = r.currency;
    switch (key) {
      case "reward": return fmtCur(r.amount, c);
      case "bond": return fmtBond(r.doerBond, c);
      case "disputeBond": return fmtBond(r.disputeBond, c);
      case "doerGets": return fmtCur(r.doerGets, c);
      case "treasury": return fmtCur(r.treasury, c);
      case "doerBond": return fmtBond(r.doerBond, c);
      case "winnerShare": return "+" + fmtBond(r.winnerShare, c);
      case "votersBondCut": return fmtBond(r.votersBondCut, c);
      case "stay": return "open";
      default: return "";
    }
  }

  // Every receipt splits into up to three lines: Put in (own money, gray), Back (own money returned, gray),
  // Profit/Loss (net result from someone else's money, green/red).
  function plain(text) { return { text: text, cls: "" }; }
  function putIn(text) { return { text: "Put in: " + text, cls: "" }; }
  function backLine(text) { return { text: "Back: " + text, cls: "" }; }
  function profit(text) { return { text: "Profit: " + text, cls: "pos" }; }
  function loss(text) { return { text: "Loss: − " + text, cls: "neg" }; }
  function note(label, text) { return { text: label + ": " + text, cls: "" }; }

  function treasuryReceipt(r, amount) {
    return r.burnsFee
      ? { label: "Burn", lines: [plain(fmtCur(amount, r.currency) + " fee burned")] }
      : { label: "Treasury", lines: [profit(fmtCur(amount, r.currency) + " fee")] };
  }

  function buildReceipts(scenario, r) {
    var c = r.currency;
    var out = [{ label: "Author", lines: scenario === "fake"
      ? [putIn(fmtCur(r.amount, c)), note("Still locked", "the dare stays open")]
      : [putIn(fmtCur(r.amount, c)), note("Got", "the dare done")] }];
    if (scenario === "none") {
      out.push({ label: "Doer", lines: [putIn(fmtBond(r.doerBond, c) + " bond"), backLine(fmtBond(r.doerBond, c)), profit(fmtCur(r.doerGets, c) + " reward")] });
      out.push(treasuryReceipt(r, r.treasury));
    } else if (scenario === "doerwin") {
      out.push({ label: "Doer", lines: [putIn(fmtBond(r.doerBond, c) + " bond"), backLine(fmtBond(r.doerBond, c)), profit(fmtCur(r.doerGets, c) + " reward + " + fmtBond(r.winnerShare, c))] });
      out.push({ label: "Disputer", lines: [putIn(fmtBond(r.disputeBond, c)), loss(fmtBond(r.disputeBond, c))] });
      out.push({ label: "NFT voters", lines: [profit(fmtCur(r.toVoters, c) + " fee + " + fmtBond(r.votersBondCut, c))] });
      out.push(treasuryReceipt(r, r.treasury));
    } else {
      out.push({ label: "Doer", lines: [putIn(fmtBond(r.doerBond, c) + " bond"), loss(fmtBond(r.doerBond, c))] });
      out.push({ label: "Disputer", lines: [putIn(fmtBond(r.disputeBond, c)), backLine(fmtBond(r.disputeBond, c)), profit(fmtBond(r.winnerShare, c))] });
      out.push({ label: "NFT voters", lines: [profit(fmtBond(r.votersBondCut, c))] });
    }
    return out;
  }

  // ---- DOM ----
  var amountInput = document.getElementById("calc-amount");
  var slider = document.getElementById("calc-slider");
  var currencySelect = document.getElementById("calc-currency");
  var quickBox = document.getElementById("calc-quick");
  var flagsBox = document.getElementById("calc-flags");
  var tabs = Array.prototype.slice.call(document.querySelectorAll(".calc-tab"));
  var playBtn = document.getElementById("calc-play");
  var chip = document.getElementById("calc-chip");
  var chipLabel = document.getElementById("calc-chip-label");
  var stepsList = document.getElementById("calc-steps");
  var dotsBox = document.getElementById("calc-dots");
  var currentLine = document.getElementById("calc-current");
  var receiptsBox = document.getElementById("calc-receipts");
  var personaEls = {};
  ORDER.forEach(function (role) { personaEls[role] = stage.querySelector('.calc-persona[data-role="' + role + '"]'); });

  var state = { amount: CUR.USDC.start, currency: "USDC", scenario: "none", stepIndex: 0 };
  var playTimer = null;

  function pct(idx) { return ((idx + 0.5) / ORDER.length * 100) + "%"; }

  function flyChip(fromRole, toRole, label) {
    if (!fromRole || !toRole) { chip.classList.remove("show", "flying"); return; }
    var fromIdx = ORDER.indexOf(fromRole), toIdx = ORDER.indexOf(toRole);
    chipLabel.textContent = label;
    chip.style.transition = "none";
    chip.style.left = pct(fromIdx);
    chip.classList.add("show");
    chip.classList.remove("flying");
    void chip.offsetWidth; // restart the arc keyframe on every hop, not just the first
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        chip.style.transition = "";
        chip.style.left = pct(toIdx);
        chip.classList.add("flying");
      });
    });
  }

  function render() {
    var r = calc(state.amount, state.currency, state.scenario);
    var steps = buildSteps(state.scenario);
    if (state.stepIndex >= steps.length) state.stepIndex = steps.length - 1;
    var cur = steps[state.stepIndex];

    flagsBox.innerHTML = "";
    if (r.burnsFee && state.scenario !== "fake") flagsBox.appendChild(flagEl("treasury share burns"));

    var usedRoles = {};
    steps.forEach(function (st) { if (st.from) usedRoles[st.from] = true; if (st.to) usedRoles[st.to] = true; });
    var activeRoles = {};
    if (cur.from) activeRoles[cur.from] = true;
    if (cur.to) activeRoles[cur.to] = true;
    ORDER.forEach(function (role) {
      var el = personaEls[role];
      var used = !!usedRoles[role];
      var active = !!activeRoles[role];
      el.classList.toggle("excluded", !used);
      el.classList.toggle("dim", used && !active);
      el.classList.toggle("active", active);
    });
    if (cur.chip) flyChip(cur.from, cur.to, chipText(cur.chip, r)); else chip.classList.remove("show");

    stepsList.innerHTML = "";
    steps.forEach(function (st, i) {
      var li = document.createElement("li");
      li.textContent = st.text;
      if (i === state.stepIndex) li.className = "current";
      li.addEventListener("click", function () { stopPlaying(); state.stepIndex = i; render(); });
      stepsList.appendChild(li);
    });

    currentLine.textContent = cur.text;
    dotsBox.innerHTML = "";
    steps.forEach(function (st, i) {
      var dot = document.createElement("button");
      dot.type = "button";
      dot.className = "calc-dot" + (i === state.stepIndex ? " current" : i < state.stepIndex ? " done" : "");
      dot.textContent = String(i + 1);
      dot.setAttribute("aria-label", st.text);
      dot.addEventListener("click", function () { stopPlaying(); state.stepIndex = i; render(); });
      dotsBox.appendChild(dot);
    });

    receiptsBox.innerHTML = "";
    buildReceipts(state.scenario, r).forEach(function (rec) {
      var box = document.createElement("div");
      box.className = "calc-receipt";
      var span = document.createElement("span");
      span.textContent = rec.label;
      box.appendChild(span);
      rec.lines.forEach(function (line) {
        var b = document.createElement("b");
        b.className = line.cls;
        b.textContent = line.text;
        box.appendChild(b);
      });
      receiptsBox.appendChild(box);
    });

    Array.prototype.forEach.call(quickBox.children, function (b) {
      b.classList.toggle("active", +b.getAttribute("data-amt") === state.amount);
    });
  }

  function flagEl(text) {
    var span = document.createElement("span");
    span.className = "calc-flag";
    span.textContent = text;
    return span;
  }

  function stopPlaying() {
    if (playTimer) { clearInterval(playTimer); playTimer = null; }
    playBtn.setAttribute("aria-pressed", "false");
  }

  function startPlaying() {
    stopPlaying();
    state.stepIndex = 0;
    render();
    if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      state.stepIndex = buildSteps(state.scenario).length - 1;
      render();
      return;
    }
    playBtn.setAttribute("aria-pressed", "true");
    playTimer = setInterval(function () {
      if (state.stepIndex >= buildSteps(state.scenario).length - 1) { stopPlaying(); return; }
      state.stepIndex++;
      render();
    }, 1100);
  }

  function setAmount(v) { // the minimum of the currency, no maximum (the slider only covers a range)
    var c = CUR[state.currency];
    v = Math.round(v / c.step) * c.step;
    v = +v.toFixed(c.dec);
    if (v < c.min) v = c.min;
    state.amount = v;
    amountInput.value = v;
    slider.value = Math.min(v, c.max);
    render();
  }

  function setupCurrency() {
    var c = CUR[state.currency];
    amountInput.min = slider.min = c.min;
    slider.max = c.max;
    amountInput.step = slider.step = c.step;
    amountInput.removeAttribute("max");
    quickBox.innerHTML = "";
    c.quick.forEach(function (q) {
      var b = document.createElement("button");
      b.type = "button";
      b.setAttribute("data-amt", String(q));
      b.textContent = fmtNum(q, state.currency);
      b.addEventListener("click", function () { setAmount(q); });
      quickBox.appendChild(b);
    });
    setAmount(c.start);
  }

  amountInput.addEventListener("input", function () {
    var v = parseFloat(amountInput.value);
    if (isFinite(v) && v >= CUR[state.currency].min) setAmount(v);
  });
  amountInput.addEventListener("change", function () {
    var v = parseFloat(amountInput.value);
    setAmount(isFinite(v) ? v : CUR[state.currency].min);
  });
  slider.addEventListener("input", function () { setAmount(+slider.value); });
  currencySelect.addEventListener("change", function () {
    state.currency = currencySelect.value;
    setupCurrency();
  });
  tabs.forEach(function (btn) {
    btn.addEventListener("click", function () {
      stopPlaying();
      tabs.forEach(function (b) { b.setAttribute("aria-selected", String(b === btn)); });
      state.scenario = btn.getAttribute("data-scenario");
      state.stepIndex = 0;
      render();
    });
  });
  playBtn.addEventListener("click", function () { if (playTimer) stopPlaying(); else startPlaying(); });

  setupCurrency();

  if ("IntersectionObserver" in window) {
    var played = false;
    var obs = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting && !played) { played = true; startPlaying(); obs.disconnect(); }
      });
    }, { threshold: 0.5 });
    obs.observe(stage);
  }
})();
