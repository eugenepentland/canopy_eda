// Design-note add/delete handlers for the schematic page's embedded
// review sections. Reads the global `DESIGN_NAME` declared earlier on the
// page and POSTs to /api/section-note/:name/(add|remove).
(function () {
  function post(path, body) {
    return fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r;
    });
  }
  function noteBase() {
    return '/api/section-note/' + encodeURIComponent(DESIGN_NAME);
  }
  // Populate the PDF dropdown on every design-note "Add" form from the
  // list of uploaded datasheets, so reviewers can pin a source link
  // without editing the .sexp by hand.
  fetch('/api/datasheets')
    .then(function (r) {
      return r.ok ? r.json() : { files: [] };
    })
    .then(function (j) {
      var files = (j.files || [])
        .map(function (f) {
          return '<option value="' + f.name + '">' + f.name + '</option>';
        })
        .join('');
      document.querySelectorAll('.note-new-pdf').forEach(function (sel) {
        sel.innerHTML = '<option value="">(no datasheet)</option>' + files;
      });
    });
  document.addEventListener('click', function (e) {
    var t = e.target;
    if (t.classList.contains('note-add-btn')) {
      // Design note add: uses section NAME (not slug) because the editor
      // splices into the .sexp by "(section \"NAME\"" needle match.
      var addRow = t.closest('.note-add');
      var section = addRow.getAttribute('data-section');
      var text = addRow.querySelector('.note-new-text').value.trim();
      if (!text) return;
      var pdf = addRow.querySelector('.note-new-pdf').value || '';
      var page = parseInt(addRow.querySelector('.note-new-page').value, 10) || 0;
      post(noteBase() + '/add', { section: section, text: text, pdf: pdf, page: page })
        .then(function () {
          location.reload();
        })
        .catch(function (err) {
          alert('Add note failed: ' + err.message);
        });
    } else if (t.classList.contains('note-del')) {
      var li = t.closest('li');
      var idx = parseInt(li.getAttribute('data-index'), 10);
      var det = t.closest('details');
      var addRow = det && det.querySelector('.note-add');
      var section = addRow && addRow.getAttribute('data-section');
      if (isNaN(idx) || !section) return;
      post(noteBase() + '/remove', { section: section, index: idx })
        .then(function () {
          location.reload();
        })
        .catch(function (err) {
          alert('Delete note failed: ' + err.message);
        });
    }
  });
})();
