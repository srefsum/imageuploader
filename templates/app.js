document.addEventListener('DOMContentLoaded', function () {
    var categorySelect = document.getElementById('category');
    var categoryHint = document.getElementById('category-hint');
    if (categorySelect && categoryHint) {
        var hints = {};
        var hintsEl = document.getElementById('category-hints-data');
        if (hintsEl) {
            try {
                hints = JSON.parse(hintsEl.textContent || '{}');
            } catch (e) {
                hints = {};
            }
        }
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

    var trackFilter = document.getElementById('track-filter');
    if (trackFilter) {
        trackFilter.addEventListener('input', function () {
            var query = trackFilter.value.toLowerCase();
            var items = document.querySelectorAll('.track-item');
            items.forEach(function (item) {
                var name = item.getAttribute('data-name') || '';
                item.style.display = name.indexOf(query) !== -1 ? '' : 'none';
            });
        });
    }

    var musicUploadForm = document.getElementById('music-upload-form');
    if (musicUploadForm) {
        musicUploadForm.addEventListener('submit', function (e) {
            var fileInput = document.getElementById('music-filename');
            if (fileInput && !fileInput.files.length) {
                e.preventDefault();
                alert('Please select at least one file to upload.');
            }
        });
    }

    var importForm = document.getElementById('music-import-form');
    if (importForm) {
        var folderInput = document.getElementById('import-folder');
        var submitBtn = document.getElementById('import-submit');
        var previewBox = document.getElementById('import-preview');
        var previewSummary = document.getElementById('import-preview-summary');
        var previewStats = document.getElementById('import-preview-stats');
        var progressBox = document.getElementById('import-progress');
        var progressBar = document.getElementById('import-progress-bar');
        var progressText = document.getElementById('import-progress-text');
        var resultBox = document.getElementById('import-result');
        var albumFields = document.getElementById('album-mode-fields');
        var sourceArtistGroup = document.getElementById('source-artist-group');
        var sourceArtistInput = document.getElementById('source-artist');
        var sourceAlbumInput = document.getElementById('source-album');
        var targetArtistSelect = document.getElementById('target-artist');
        var targetArtistNew = document.getElementById('target-artist-new');
        var batchSize = parseInt(importForm.getAttribute('data-batch-size') || '25', 10);
        var selectedFiles = [];

        function getImportMode() {
            var checked = importForm.querySelector('input[name="import_mode"]:checked');
            return checked ? checked.value : 'artist';
        }

        function isUploadableFile(name) {
            return /\.(mp3|flac|ogg|m4a|aac|wma|wav|jpg|jpeg|png|gif|webp)$/i.test(name);
        }

        function isSkippedFile(name) {
            var base = name.split(/[/\\]/).pop().toLowerCase();
            return base === 'desktop.ini' || base === 'thumbs.db' || base === '.ds_store' || /\.m3u$/i.test(base);
        }

        function collectFiles(fileList) {
            var files = [];
            for (var i = 0; i < fileList.length; i++) {
                var file = fileList[i];
                var rel = (file.webkitRelativePath || file.name).replace(/\\/g, '/');
                if (isSkippedFile(rel)) {
                    continue;
                }
                if (!isUploadableFile(rel)) {
                    continue;
                }
                files.push({ file: file, path: rel });
            }
            return files;
        }

        function updatePreview() {
            if (!selectedFiles.length) {
                previewBox.hidden = true;
                submitBtn.disabled = true;
                return;
            }

            var albums = {};
            selectedFiles.forEach(function (entry) {
                var parts = entry.path.split('/');
                if (getImportMode() === 'artist' && parts.length > 1) {
                    albums[parts[0]] = true;
                }
            });

            previewBox.hidden = false;
            submitBtn.disabled = false;
            previewSummary.textContent = selectedFiles.length + ' file(s) ready to upload.';
            previewStats.innerHTML = '';
            if (getImportMode() === 'artist') {
                previewStats.innerHTML += '<li>Album folders detected: ' + Object.keys(albums).length + '</li>';
            }
            previewStats.innerHTML += '<li>Existing server files will be skipped automatically.</li>';
        }

        function updateModeUi() {
            var mode = getImportMode();
            if (mode === 'artist') {
                albumFields.hidden = true;
                sourceArtistGroup.hidden = false;
                sourceArtistInput.required = true;
                sourceAlbumInput.required = false;
            } else {
                albumFields.hidden = false;
                sourceArtistGroup.hidden = true;
                sourceArtistInput.required = false;
                sourceAlbumInput.required = true;
            }
            updatePreview();
        }

        importForm.querySelectorAll('input[name="import_mode"]').forEach(function (radio) {
            radio.addEventListener('change', updateModeUi);
        });

        if (folderInput) {
            folderInput.addEventListener('change', function () {
                selectedFiles = collectFiles(folderInput.files);
                updatePreview();
            });
        }

        updateModeUi();

        importForm.addEventListener('submit', function (e) {
            e.preventDefault();
            if (!selectedFiles.length) {
                alert('Please choose a folder first.');
                return;
            }

            var mode = getImportMode();
            var sourceArtistVal = sourceArtistInput.value.trim();
            var sourceAlbumVal = sourceAlbumInput.value.trim();
            var targetArtistVal = targetArtistNew.value.trim() || targetArtistSelect.value.trim();

            if (mode === 'artist' && !sourceArtistVal) {
                alert('Please enter the artist name.');
                return;
            }
            if (mode === 'album' && (!sourceAlbumVal || !targetArtistVal)) {
                alert('Please enter the album name and target artist.');
                return;
            }

            submitBtn.disabled = true;
            progressBox.hidden = false;
            resultBox.hidden = true;

            var totals = { created: [], skipped: [], rejected: [], errors: [], rescan: '' };
            var batches = [];
            for (var i = 0; i < selectedFiles.length; i += batchSize) {
                batches.push(selectedFiles.slice(i, i + batchSize));
            }

            var batchIndex = 0;

            function escapeHtml(text) {
                var div = document.createElement('div');
                div.textContent = text;
                return div.innerHTML;
            }

            function showFinalResult() {
                progressBar.value = 100;
                progressText.textContent = 'Upload complete.';
                resultBox.hidden = false;
                resultBox.innerHTML =
                    '<div class="alert alert-success"><p><strong>' + totals.created.length +
                    '</strong> uploaded, <strong>' + totals.skipped.length +
                    '</strong> skipped, <strong>' + totals.rejected.length +
                    '</strong> rejected, <strong>' + totals.errors.length + '</strong> errors.</p></div>';

                if (totals.rescan) {
                    resultBox.innerHTML += '<div class="alert alert-info"><p>' + escapeHtml(totals.rescan) + '</p></div>';
                }

                var browsePath = mode === 'artist' ? sourceArtistVal : (targetArtistVal + '/' + sourceAlbumVal);
                var encodedPath = browsePath.split('/').map(encodeURIComponent).join('/');
                resultBox.innerHTML += '<div class="btn-group"><a href="/music/browse?path=' +
                    encodedPath +
                    '" class="btn btn-primary">Browse destination</a>' +
                    '<a href="/music" class="btn btn-secondary">Music library</a></div>';
            }

            function uploadNextBatch() {
                if (batchIndex >= batches.length) {
                    showFinalResult();
                    return;
                }

                var batch = batches[batchIndex];
                var fd = new FormData();
                fd.append('import_mode', mode);
                fd.append('source_artist', sourceArtistVal);
                fd.append('source_album', sourceAlbumVal);
                fd.append('target_artist', targetArtistVal);
                fd.append('import_count', String(batch.length));
                fd.append('trigger_rescan', batchIndex === batches.length - 1 ? '1' : '0');

                batch.forEach(function (entry, idx) {
                    fd.append('import_path_' + idx, entry.path);
                    fd.append('import_file_' + idx, entry.file, entry.file.name);
                });

                progressText.textContent = 'Uploading batch ' + (batchIndex + 1) + ' of ' + batches.length + '...';
                progressBar.value = Math.round((batchIndex / batches.length) * 100);

                fetch('/music/import', {
                    method: 'POST',
                    body: fd
                }).then(function (response) {
                    return response.json();
                }).then(function (data) {
                    if (!data.ok) {
                        throw new Error(data.error || 'Import failed');
                    }
                    totals.created = totals.created.concat(data.created || []);
                    totals.skipped = totals.skipped.concat(data.skipped || []);
                    totals.rejected = totals.rejected.concat(data.rejected || []);
                    totals.errors = totals.errors.concat(data.errors || []);
                    if (data.rescan) {
                        totals.rescan = data.rescan;
                    }
                    batchIndex += 1;
                    uploadNextBatch();
                }).catch(function (err) {
                    progressText.textContent = 'Error: ' + err.message;
                    submitBtn.disabled = false;
                });
            }

            uploadNextBatch();
        });
    }
});
