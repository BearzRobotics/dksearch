// Good and bad marks on the results, for the owner signed in (the server puts data-feedback on the list only then): they are
// sent to /feedback and kept in the data directory for `dksearch eval`. Nothing here works without the server's say-so.
"use strict";
(function () {
  var list = document.querySelector("ol.results[data-feedback]");
  if (!list || !window.fetch) return;
  var query = list.getAttribute("data-q") || "";
  function send(url, grade, done) {
    var body = "q=" + encodeURIComponent(query) + "&url=" + encodeURIComponent(url) + "&grade=" + grade;
    fetch("/feedback", { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: body })
      .then(function (r) { done(r.ok); })
      .catch(function () { done(false); });
  }
  Array.prototype.forEach.call(list.querySelectorAll("li"), function (li) {
    var shown = li.querySelector(".url");
    if (!shown) return;
    var url = shown.textContent.trim();
    var bar = document.createElement("span");
    bar.className = "fb";
    var state = 0;
    [["good", 1, "A good answer to this search"], ["bad", -1, "This should not have been shown for this search"]].forEach(function (d) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = d[0];
      b.title = d[2];
      b.className = "fb-" + d[0];
      b.addEventListener("click", function () {
        var next = state === d[1] ? 0 : d[1]; // the same button again takes the mark back
        send(url, next, function (ok) {
          if (!ok) { bar.setAttribute("data-failed", "1"); return; }
          bar.removeAttribute("data-failed");
          state = next;
          Array.prototype.forEach.call(bar.children, function (c) { c.classList.remove("on"); });
          if (next !== 0) b.classList.add("on");
        });
      });
      bar.appendChild(b);
    });
    shown.appendChild(bar);
  });
})();

// The owner's "a site is missing" form under the results: the address is sent to /suggest, which adds it to the sites to
// crawl and keeps it as a good answer for this search.
"use strict";
(function () {
  var form = document.querySelector("form.suggest[data-q]");
  if (!form || !window.fetch) return;
  var msg = form.querySelector(".msg");
  form.addEventListener("submit", function (e) {
    e.preventDefault();
    var url = form.elements["url"].value.trim();
    if (!url) return;
    msg.textContent = "…";
    fetch("/suggest", { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: "q=" + encodeURIComponent(form.getAttribute("data-q")) + "&url=" + encodeURIComponent(url) })
      .then(function (r) { return r.text().then(function (t) { msg.textContent = t.trim(); if (r.ok) form.elements["url"].value = ""; }); })
      .catch(function () { msg.textContent = "could not reach the server"; });
  });
  // A text area: Enter is a new line, Ctrl+Enter (or Cmd+Enter) sends, and the box grows with what is pasted.
  var area = form.elements["url"];
  function fit() { area.style.height = "auto"; area.style.height = Math.min(area.scrollHeight + 2, 240) + "px"; }
  area.addEventListener("input", fit);
  area.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey) && !e.isComposing && form.requestSubmit) { e.preventDefault(); form.requestSubmit(); }
  });
})();

// The search box as a multi-line field: Enter searches, Shift+Enter starts a new line, and the box grows with its text.
// The page works without this file (a one-line box that searches on Enter); this only upgrades it.
"use strict";
(function () {
  var box = document.querySelector('form.search input[name="q"]');
  if (!box || !window.HTMLFormElement || !HTMLFormElement.prototype.requestSubmit) return;

  var area = document.createElement("textarea");
  area.name = "q";
  area.rows = 1;
  if (box.maxLength > 0) area.maxLength = box.maxLength;
  area.value = box.value;
  area.className = box.className;
  area.setAttribute("aria-label", box.getAttribute("aria-label") || "Search");
  area.setAttribute("spellcheck", "true");
  area.setAttribute("enterkeyhint", "search");
  var focused = document.activeElement === box || box.hasAttribute("autofocus");

  function fit() {
    area.style.height = "auto";
    area.style.height = area.scrollHeight + 2 + "px";
  }
  area.addEventListener("keydown", function (e) {
    // Enter searches; Shift+Enter (or an input method still composing) is left alone: it is a line break.
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing && area.form) {
      e.preventDefault();
      area.form.requestSubmit();
    }
  });
  area.addEventListener("input", fit);
  box.replaceWith(area);
  fit();
  if (focused) {
    area.focus();
    area.setSelectionRange(area.value.length, area.value.length);
  }
})();

// A picture that cannot be loaded (a dead link on a page of the web) is left out of the gallery instead of showing a
// broken-image icon.
(function () {
  var imgs = document.querySelectorAll(".gallery img");
  Array.prototype.forEach.call(imgs, function (img) {
    function drop() {
      var li = img.closest ? img.closest("li") : null;
      if (li) li.hidden = true;
    }
    img.addEventListener("error", drop);
    // It may already have failed before this script ran.
    if (img.complete && img.currentSrc && img.naturalWidth === 0) drop();
  });
})();
