// Live progress for the administration dashboard. No data from the server is
// ever put into the page as markup: only textContent and attributes are set.
"use strict";
(function () {
  var card = document.getElementById("import-live");
  if (!card) return;

  var bar = document.getElementById("import-bar");
  var prev = null;
  var smoothRate = 0;

  function field(name) { return card.querySelector('[data-f="' + name + '"]'); }
  function setText(name, text) { var el = field(name); if (el) el.textContent = text; }
  function num(n) { return Number(n).toLocaleString(); }
  function duration(seconds) {
    if (!isFinite(seconds) || seconds < 0) return "unknown";
    seconds = Math.round(seconds);
    var h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60), s = seconds % 60;
    if (h > 0) return h + " h " + m + " min";
    if (m > 0) return m + " min " + s + " s";
    return s + " s";
  }

  function update(run) {
    var now = performance.now() / 1000;
    var elapsed = Math.max(0, Date.now() / 1000 - run.started_at);
    setText("docs", num(run.submitted));
    setText("elapsed", duration(elapsed));

    var total = run.progress_total || 0;
    var done = run.progress_done || 0;
    if (prev && now > prev.t) {
      var dt = now - prev.t;
      var inst = (run.submitted - prev.docs) / dt;
      smoothRate = smoothRate === 0 ? inst : smoothRate * 0.7 + inst * 0.3;
      setText("rate", smoothRate > 0 ? num(Math.round(smoothRate)) + " documents/s" : "waiting");
      if (total > 0 && done > prev.done) {
        var progressRate = (done - prev.done) / dt;
        prev.pr = prev.pr ? prev.pr * 0.7 + progressRate * 0.3 : progressRate;
        setText("eta", prev.pr > 0 ? duration((total - done) / prev.pr) : "estimating");
      }
    }
    var pr = prev ? prev.pr : 0;
    prev = { t: now, docs: run.submitted, done: done, pr: pr };

    if (bar) {
      if (total > 0) {
        bar.max = total;
        bar.value = Math.min(done, total);
        setText("percent", (100 * Math.min(done, total) / total).toFixed(1) + " %");
      } else {
        bar.removeAttribute("value"); // indeterminate: the source cannot say how much there is
        setText("percent", "size unknown");
        setText("eta", "unknown");
      }
    }
  }

  function poll() {
    fetch("/api/v1/admin/imports", { credentials: "same-origin", headers: { accept: "application/json" } })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(new Error("status " + r.status)); })
      .then(function (d) {
        if (!d.running) { window.location.reload(); return; } // finished: show how it ended
        update(d.running);
        window.setTimeout(poll, 1000);
      })
      .catch(function () { window.setTimeout(poll, 3000); });
  }
  poll();
})();
