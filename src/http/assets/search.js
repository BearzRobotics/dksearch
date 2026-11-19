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
