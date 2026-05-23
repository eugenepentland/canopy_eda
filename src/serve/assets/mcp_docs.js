(function () {
  var box = document.getElementById("mcp-search");
  var info = document.getElementById("count-info");
  var tools = Array.prototype.slice.call(document.querySelectorAll(".tool"));

  function apply() {
    var q = box.value.trim().toLowerCase();
    var shown = 0;
    tools.forEach(function (t) {
      var hay = (t.dataset.search || "").toLowerCase();
      var match = q === "" || hay.indexOf(q) !== -1;
      t.style.display = match ? "" : "none";
      if (match) shown++;
    });
    info.textContent = shown + " / " + tools.length + " tools";
  }

  box.addEventListener("input", apply);
  apply();
})();
