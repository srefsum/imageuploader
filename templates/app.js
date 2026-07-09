document.addEventListener('DOMContentLoaded', function () {
    var categorySelect = document.getElementById('category');
    var categoryHint = document.getElementById('category-hint');
    if (categorySelect && categoryHint) {
        var hints = {
            images: 'Gallery images with subdirectory support.',
            uploads: 'General upload storage, no subdirectories.',
            logos: 'Logo files, no subdirectories.'
        };
        function updateHint() {
            categoryHint.textContent = hints[categorySelect.value] || '';
        }
        categorySelect.addEventListener('change', updateHint);
        updateHint();
    }

    var subdirsEl = document.getElementById('subdirs-data');
    var subSelect = document.getElementById('sub');
    var subGroup = document.getElementById('subdir-group');
    var selectedSubEl = document.getElementById('selected-sub');

    if (categorySelect && subdirsEl && subSelect && subGroup) {
        var subdirs = {};
        try {
            subdirs = JSON.parse(subdirsEl.textContent || '{}');
        } catch (e) {
            subdirs = {};
        }
        var selectedSub = selectedSubEl ? selectedSubEl.value : '';

        function updateSubdirs() {
            var cat = categorySelect.value;
            var subs = subdirs[cat] || [];
            subSelect.innerHTML = '<option value="">Root directory</option>';
            subs.forEach(function (name) {
                var opt = document.createElement('option');
                opt.value = name;
                opt.textContent = name;
                if (name === selectedSub) {
                    opt.selected = true;
                }
                subSelect.appendChild(opt);
            });
            subGroup.hidden = subs.length === 0;
        }

        categorySelect.addEventListener('change', function () {
            selectedSub = '';
            updateSubdirs();
        });
        updateSubdirs();
    }

    var uploadForm = document.getElementById('upload-form');
    if (uploadForm) {
        uploadForm.addEventListener('submit', function (e) {
            var fileInput = document.getElementById('filename');
            if (fileInput && !fileInput.files.length) {
                e.preventDefault();
                alert('Please select a file to upload.');
            }
        });
    }

    var filterInput = document.getElementById('gallery-filter');
    if (filterInput) {
        filterInput.addEventListener('input', function () {
            var query = filterInput.value.toLowerCase();
            var items = document.querySelectorAll('.gallery-item');
            items.forEach(function (item) {
                var name = item.getAttribute('data-name') || '';
                item.style.display = name.indexOf(query) !== -1 ? '' : 'none';
            });
        });
    }
});
