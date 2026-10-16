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

// Dare calculator: every number below follows contracts/src/{VaultParams.sol,desks/Desk.sol,
// desks/DisputeDesk.sol} in this repository (one disputer, no swarm appeal, no contributor bonus
// — the same simplified path the page always showed).
(function () {
  "use strict";
  var stage = document.getElementById("calc-stage");
  if (!stage) return;

  var PRICE = 7.65; // example IMD price, same constant used across the page
  var BPS = 10000;
  // VaultParams.sol LaunchParams.initial(): the live protocol numbers, compiled in at launch.
  var P = {
    doerBondBps: 300, bondBase: 0.5, minBond: 1, disputeBondBps: 100,
    feeBps: 1000, nftFeeBps: 600, winnerBondBps: 5000,
    minRewardUsd: 5, minRewardImd: 0.5, largeRewardUsd: 300, largeRewardImd: 40,
    authorFeeEth: 0.0005, // TaskVault.sol minAuthorFee: flat, non-refundable, to the treasury
    swarmCheckFeeImd: 0.5 // example live Intake.priceOf() price the doer prepays for a large task's mandatory check
  };
  var ORDER = ["author", "doer", "contract", "disputer", "nft", "swarm", "treasury"];

  function bondFor(rewardImd, bps) { // Desk.sol _bondFor: max(minBond, bondBase + bps * R / BPS)
    return Math.max(P.minBond, P.bondBase + rewardImd * bps / BPS);
  }
  function round2(x) { return Math.round(x * 100) / 100; }
  function fmt(x) { return String(round2(x)); }
  function fmtImd(x) { return fmt(x) + " IMD"; }
  function fmtImdUsd(x) { return fmtImd(x) + " (~$" + fmt(x * PRICE) + ")"; } // receipts only: every IMD sum gets its $ estimate
  function fmtEth(x) { return x.toFixed(4) + " ETH"; }
  function fmtCur(usd, currency) { return currency === "IMD" ? fmtImd(usd / PRICE) : "$" + fmt(usd); }
  function minUsdFor(currency) { return currency === "IMD" ? round2(P.minRewardImd * PRICE) : P.minRewardUsd; }

  function calc(usd, currency, scenario) {
    var rewardImd = usd / PRICE;
    var doerBond = bondFor(rewardImd, P.doerBondBps); // Desk.sol:118,130 doerBondBps, n=0 (no rejects/queue)
    var disputeBond = bondFor(rewardImd, P.disputeBondBps); // Desk.sol:118 disputeBondBps
    var fee = usd * P.feeBps / BPS; // DisputeDesk.sol:559 _payReward
    var largeThresholdUsd = currency === "IMD" ? P.largeRewardImd * PRICE : P.largeRewardUsd; // VaultParams.sol largeRewardUsd/largeRewardImd
    var large = usd >= largeThresholdUsd;
    var r = {
      usd: usd, currency: currency, rewardImd: rewardImd, doerBond: doerBond, disputeBond: disputeBond, fee: fee,
      large: large,
      checkFeeImd: large ? P.swarmCheckFeeImd : 0, // CaseDesk.sol submit(): doer prepays this, forfeited either way
      authorFeeEth: P.authorFeeEth, // TaskVault.sol create(): paid once at posting, regardless of scenario
      flooredDoer: P.bondBase + rewardImd * P.doerBondBps / BPS < P.minBond
    };
    if (scenario === "none") {
      r.doerUsd = usd - fee;
      r.treasuryUsd = fee;
      r.doerBondBack = doerBond;
    } else if (scenario === "doerwin") {
      var toVoters = usd * P.nftFeeBps / BPS; // DisputeDesk.sol:560
      var penalty = disputeBond; // DisputeDesk.sol:529-534 _settleDecided, doerWins branch
      var votersBondCut = penalty * (1 - P.winnerBondBps / BPS);
      var winnerShare = penalty - votersBondCut;
      r.doerUsd = usd - fee;
      r.doerBondTotal = doerBond + winnerShare;
      r.winnerShare = winnerShare; // Doer's cut of the disputer's forfeited bond (half, winnerBondBps=5000)
      r.toVotersUsd = toVoters;
      r.votersBondCut = votersBondCut;
      r.treasuryUsd = fee - toVoters;
      r.disputerLostBond = disputeBond;
    } else { // fake: _payReward never runs (doerWins = false, DisputeDesk.sol:345)
      var penalty2 = doerBond;
      var votersBondCut2 = penalty2 * (1 - P.winnerBondBps / BPS);
      var disputerReward = penalty2 - votersBondCut2;
      r.rewardStaysUsd = usd;
      r.doerLostBond = doerBond;
      r.disputerTotalBond = disputeBond + disputerReward;
      r.disputerReward = disputerReward; // Disputer's cut of the doer's forfeited bond (half, winnerBondBps=5000)
      r.votersBondCut = votersBondCut2;
    }
    return r;
  }

  function buildSteps(scenario, large) {
    var s = [
      { text: "Author locks the reward", from: "author", to: "contract", chip: "reward" },
      { text: "Doer takes it, posts bond", from: "doer", to: "contract", chip: "bond" },
      { text: "Doer submits proof", from: null, to: "doer", chip: null }
    ];
    if (large) s.push({ text: "Swarm checks the big dare", from: "doer", to: "swarm", chip: "check" });
    if (scenario === "none") {
      s.push({ text: "24h window — nobody disputes", from: null, to: "contract", chip: null });
      s.push({ text: "Doer paid 90% of the reward", from: "contract", to: "doer", chip: "doerUsd" });
      s.push({ text: "Treasury keeps the 10% fee", from: "contract", to: "treasury", chip: "treasuryUsd" });
      s.push({ text: "Doer's bond comes back", from: "contract", to: "doer", chip: "doerBondBack" });
    } else if (scenario === "doerwin") {
      s.push({ text: "Disputer bonds, challenges proof", from: "disputer", to: "contract", chip: "disputeBond" });
      s.push({ text: "NFT holders vote: doer right", from: null, to: "nft", chip: null });
      s.push({ text: "Doer paid 90%, NFT cut 6%", from: "contract", to: "doer", chip: "doerUsd" });
      s.push({ text: "Doer's bond back + wins half", from: "contract", to: "doer", chip: "doerWinTotal" });
      s.push({ text: "NFT voters split the other half", from: "contract", to: "nft", chip: "nftBondOnly" });
    } else {
      s.push({ text: "Disputer bonds, challenges proof", from: "disputer", to: "contract", chip: "disputeBond" });
      s.push({ text: "NFT holders vote: fake caught", from: null, to: "nft", chip: null });
      s.push({ text: "Reward stays in Contract, dare reopens", from: "contract", to: "contract", chip: "stay" });
      s.push({ text: "Disputer's bond back + wins half", from: "contract", to: "disputer", chip: "disputerWinTotal" });
      s.push({ text: "NFT voters split the other half", from: "contract", to: "nft", chip: "nftBondOnly" });
    }
    return s;
  }

  function chipText(key, r) {
    switch (key) {
      case "reward": return fmtCur(r.usd, r.currency);
      case "bond": return fmtImd(r.doerBond);
      case "check": return fmtImd(r.checkFeeImd);
      case "disputeBond": return fmtImd(r.disputeBond);
      case "doerUsd": return fmtCur(r.doerUsd, r.currency);
      case "treasuryUsd": return fmtCur(r.treasuryUsd, r.currency);
      case "doerBondBack": return fmtImd(r.doerBondBack);
      case "doerWinTotal": return fmtImd(r.doerBondTotal);
      case "nftBondOnly": return fmtImd(r.votersBondCut);
      case "stay": return "reopened";
      case "disputerWinTotal": return fmtImd(r.disputerTotalBond);
      default: return "";
    }
  }

  // Every receipt splits into up to three lines: Put in (own money contributed, gray), Back (own money
  // returned, gray — never green, it's not a gain), Profit/Loss (net result from someone else's money, green/red).
  function plain(text) { return { text: text, cls: "" }; }
  function putIn(text) { return { text: "Put in: " + text, cls: "" }; }
  function backLine(text) { return { text: "Back: " + text, cls: "" }; }
  function profit(text) { return { text: "Profit: " + text, cls: "pos" }; }
  function loss(text) { return { text: "Loss: − " + text, cls: "neg" }; }
  function note(label, text) { return { text: label + ": " + text, cls: "" }; }

  function doerPutInText(r) { // bond is always staked; the large-dare swarm check fee is a flat prepaid cost, never returned either way
    var t = fmtImdUsd(r.doerBond) + " bond";
    if (r.large) t += " + " + fmtImdUsd(r.checkFeeImd) + " swarm check";
    return t;
  }

  function authorLines(scenario, r, cur) {
    var putInText = fmtCur(r.usd, cur) + " reward + " + fmtEth(r.authorFeeEth) + " fee";
    if (scenario === "fake") return [putIn(putInText), note("Still locked", "dare reopens for the next doer")];
    return [putIn(putInText), note("Got", "the dare done")];
  }
  function swarmReceipt(r) { return r.large ? { label: "$IMD swarm", lines: [profit(fmtImdUsd(r.checkFeeImd) + " check fee")] } : null; }

  function buildReceipts(scenario, r) {
    var cur = r.currency;
    var out = [{ label: "Author", lines: authorLines(scenario, r, cur) }];
    if (scenario === "none") {
      out.push({ label: "Doer", lines: [putIn(doerPutInText(r)), backLine(fmtImdUsd(r.doerBondBack)), profit(fmtCur(r.doerUsd, cur) + " reward")] });
      var sw = swarmReceipt(r); if (sw) out.push(sw);
      out.push({ label: "Treasury", lines: [profit(fmtCur(r.treasuryUsd, cur) + " fee + " + fmtEth(r.authorFeeEth) + " author fee")] });
    } else if (scenario === "doerwin") {
      out.push({ label: "Doer", lines: [putIn(doerPutInText(r)), backLine(fmtImdUsd(r.doerBond)), profit(fmtCur(r.doerUsd, cur) + " reward + " + fmtImdUsd(r.winnerShare) + " (half the disputer's bond)")] });
      out.push({ label: "Disputer", lines: [putIn(fmtImdUsd(r.disputeBond)), loss(fmtImdUsd(r.disputerLostBond))] });
      out.push({ label: "NFT holders", lines: [profit(fmtCur(r.toVotersUsd, cur) + " fee cut + " + fmtImdUsd(r.votersBondCut) + " (half the disputer's bond)")] });
      var sw2 = swarmReceipt(r); if (sw2) out.push(sw2);
      out.push({ label: "Treasury", lines: [profit(fmtCur(r.treasuryUsd, cur) + " fee + " + fmtEth(r.authorFeeEth) + " author fee")] });
    } else { // fake
      out.push({ label: "Contract", lines: [plain(fmtCur(r.rewardStaysUsd, cur) + " back in the pot, dare reopens")] });
      out.push({ label: "Doer", lines: [putIn(doerPutInText(r)), loss(fmtImdUsd(r.doerLostBond))] });
      out.push({ label: "Disputer", lines: [putIn(fmtImdUsd(r.disputeBond)), backLine(fmtImdUsd(r.disputeBond)), profit(fmtImdUsd(r.disputerReward) + " (half the doer's bond)")] });
      out.push({ label: "NFT holders", lines: [profit(fmtImdUsd(r.votersBondCut) + " (half the doer's bond)")] });
      var sw3 = swarmReceipt(r); if (sw3) out.push(sw3);
      out.push({ label: "Treasury", lines: [profit(fmtEth(r.authorFeeEth) + " author fee")] });
    }
    return out;
  }

  // ---- DOM ----
  var amountInput = document.getElementById("calc-amount");
  var slider = document.getElementById("calc-slider");
  var currencySelect = document.getElementById("calc-currency");
  var quickBtns = Array.prototype.slice.call(document.querySelectorAll(".calc-quick button"));
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

  var state = { usd: 100, currency: "USDC", scenario: "none", stepIndex: 0 };
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
    var r = calc(state.usd, state.currency, state.scenario);
    var steps = buildSteps(state.scenario, r.large);
    if (state.stepIndex >= steps.length) state.stepIndex = steps.length - 1;
    var cur = steps[state.stepIndex];

    flagsBox.innerHTML = "";
    if (r.large) flagsBox.appendChild(flagEl("swarm check required"));
    if (r.flooredDoer) flagsBox.appendChild(flagEl("bond floor: 1 IMD"));

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

    quickBtns.forEach(function (b) { b.classList.toggle("active", +b.getAttribute("data-amt") === state.usd); });
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
      var r = calc(state.usd, state.currency, state.scenario);
      var steps = buildSteps(state.scenario, r.large);
      state.stepIndex = steps.length - 1;
      render();
      return;
    }
    playBtn.setAttribute("aria-pressed", "true");
    playTimer = setInterval(function () {
      var r2 = calc(state.usd, state.currency, state.scenario);
      var steps2 = buildSteps(state.scenario, r2.large);
      if (state.stepIndex >= steps2.length - 1) { stopPlaying(); return; }
      state.stepIndex++;
      render();
    }, 1100);
  }

  function setUsd(v) {
    var min = minUsdFor(state.currency);
    v = Math.round(v);
    if (v < min) v = Math.ceil(min);
    if (v > 1000) v = 1000;
    state.usd = v;
    amountInput.value = v;
    slider.value = Math.min(v, +slider.max);
    render();
  }

  amountInput.addEventListener("input", function () {
    var v = parseFloat(amountInput.value);
    if (isFinite(v)) setUsd(v);
  });
  slider.addEventListener("input", function () { setUsd(+slider.value); });
  quickBtns.forEach(function (b) {
    b.addEventListener("click", function () { setUsd(+b.getAttribute("data-amt")); });
  });
  currencySelect.addEventListener("change", function () {
    state.currency = currencySelect.value;
    var min = minUsdFor(state.currency);
    slider.min = min;
    amountInput.min = min;
    setUsd(Math.max(state.usd, min));
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

  render();

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
