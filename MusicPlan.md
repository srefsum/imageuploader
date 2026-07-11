# Music Library Pages — Analysis and Implementation Plan

**Date:** 2026-07-11  
**Goal:** Add web pages to browse the current music library and upload new music to the LMS music directory, using the same look and feel as the image uploader.

---

## 1. Analysis of `bin/test7.pl`

### What it does

`test7.pl` is a standalone CGI prototype (not wired into `bin/app`) that:

1. Sets `$target_dir = '/srv/music'`
2. Recursively walks the directory tree with `build_tree()`
3. Builds a nested Perl hash:
   - **Directory** → nested hash of children
   - **File** → string `"file"`
4. Encodes the entire structure as JSON via `JSON::encode_json`
5. Embeds the JSON inline in a self-contained HTML page
6. Renders a collapsible folder tree in the browser with vanilla JavaScript

### Key code paths

```perl
my $target_dir = '/srv/music';

sub build_tree {
    my ($dir) = @_;
    # readdir → recurse into subdirs or mark files as "file"
}

my $dir_structure = build_tree($target_dir);
my $json_structure = encode_json($dir_structure);
# ... embed $json_structure in <script>const data = ...</script>
```

### Strengths

- Simple proof-of-concept for visualizing the LMS music folder
- Correctly reflects the on-disk hierarchy (Artist → Album → tracks)
- Collapsible tree UX is usable for exploration

### Weaknesses (must not copy into production)

| Issue | Detail |
|-------|--------|
| **Monolithic payload** | Embeds the *entire* library JSON in one HTML response (~472 KB for current library; will grow) |
| **Full recursive scan** | Reads every directory on every request — expensive for 10k+ files / 37 GB library |
| **No shared theme** | Uses its own Arial/blue inline CSS, not `templates/layout.html` |
| **No upload** | Browse-only |
| **No path security** | Hardcoded path; no allowlist or traversal protection |
| **No LMS integration** | Uploading files does not trigger LMS library rescan |
| **Not integrated** | Separate script; not deployed via `bin/app` routes |

---

## 2. Analysis of `bin/dir.html` (test7.pl output)

### Generated output characteristics

`dir.html` is a captured run of `test7.pl` against the live `/srv/music` tree.

| Metric | Value |
|--------|-------|
| File size | ~472 KB (single HTML document) |
| Top-level artists | ~93 folders |
| Total files | ~10,606 |
| Total directories | ~511 |
| MP3 files | ~8,931 |
| Library size on disk | ~37 GB |

### Observed directory structure

Typical Lyrion Music Server layout:

```
/srv/music/
  Artist Name/
    Album Name/
      01 Track Title.mp3
      02 Another Track.mp3
      folder.jpg          ← album art (LMS convention)
```

Example from embedded JSON:

```
Louis Armstrong/
  What a Wonderful World!/
    01 Mack The Knife.mp3
    folder.jpg
    ...
The Three Tenors/
  The Three Tenors/
    1-01 José Carreras - ....mp3
    ...
```

### Encoding notes

Some filenames in the JSON show mojibake (e.g. `PlÃ¡cido Domingo` instead of `Plácido Domingo`). The production implementation must read directories with UTF-8 encoding and escape HTML correctly (`escapeHTML`).

### Path clarification

- **`test7.pl` uses:** `/srv/music`
- **User reference `/src/music`:** does not exist on this host; the live LMS music folder is **`/srv/music`**, owned by `squeezeboxserver`.

Configure the path in `config/config.txt` rather than hardcoding.

---

## 3. Design goals for production music pages

1. **Same look and feel** as the image uploader — reuse `layout.html`, `style.html`, `app.js` patterns, and `render_page()`.
2. **Browse current content** — show library hierarchy without loading the entire tree at once.
3. **Upload music** — add files into `/srv/music` (or a chosen subfolder), with sanitization and size limits appropriate for audio.
4. **LMS awareness** — optional rescan trigger after upload so new files appear in Lyrion Music Server.
5. **Safe by default** — path allowlisting, no `..` traversal, restricted file extensions.

---

## 4. Proposed routes

| Route | Method | Purpose |
|-------|--------|---------|
| `/music` | GET | Music library landing — top-level artists/folders |
| `/music/browse?path=<relative>` | GET | Browse one level deeper (artist → albums → tracks) |
| `/music/upload` | GET | Upload form with target folder selector |
| `/music/upload` | POST | Upload audio file(s) to selected path under music root |
| `/music/serve?path=<relative>` | GET | Stream/download a music file (optional; LMS may already serve media) |

Query param `path` is relative to the configured music root, e.g. `AC-DC/Back%20in%20Black`.

---

## 5. Proposed configuration (`config/config.txt`)

```ini
music_library_path   = /srv/music
music_upload_max_mb  = 100
music_extensions     = mp3 flac ogg m4a aac wma wav

# Optional: trigger LMS rescan after upload
music_rescan_after_upload = Yes
```

Keep separate from `allowed_dirs` — music uses its own path and rules, not the image gallery keys.

---

## 6. Architecture

### New module: `lib/music.pm`

| Function | Responsibility |
|----------|----------------|
| `browse($resp, $q)` | List one directory level; build HTML fragments |
| `upload($resp, $q)` | Validate path, save file, optional rescan |
| `serve($resp, $q)` | Stream audio file with correct MIME type |
| `validate_music_path($rel)` | Ensure path stays under `music_library_path` |
| `list_level($abs_path)` | Return sorted dirs and audio files at one level |
| `trigger_lms_rescan($host, $port)` | JSON-RPC call to LMS (e.g. `rescan` or `rescan mtimes`) |

### New templates

| Template | Purpose |
|----------|---------|
| `templates/music_browse.html` | Breadcrumb, folder list, track list, upload link |
| `templates/music_upload.html` | Directory picker + file input (reuse form components) |
| `templates/music_upload_result.html` | Success/error (reuse `upload_result.html` pattern) |

### Changes to existing files

| File | Change |
|------|--------|
| `bin/app` | Register `/music*` routes; add nav link "Music Library" |
| `templates/layout.html` | Optionally generalize header subtitle for both images and music |
| `templates/index_content.html` | Add action card linking to `/music` |
| `templates/style.html` | Add `.track-list` / `.track-item` if needed (minimal) |
| `templates/app.js` | Music upload validation, optional path hint updates |
| `deploy` | No change beyond existing copy |

---

## 7. Browse UX — do NOT replicate test7.pl

The full-tree JSON approach does not scale. Use **level-by-level browsing** (same pattern as image gallery + subdirs):

```
/music                          → list artists (top-level folders)
/music/browse?path=AC-DC        → list albums
/music/browse?path=AC-DC/Album  → list tracks + folder.jpg
```

Each page request reads **only one directory** via `readdir`, not the full tree.

### Page content per level

1. **Breadcrumb** — `Home › Music › AC-DC › Back in Black`
2. **Folders** — grid/list with links to `/music/browse?path=...`
3. **Files** — track list with filename, optional file size, play/download link
4. **Actions** — "Upload to this folder" button
5. **Filter** — client-side filename filter (reuse gallery filter JS)

### Optional enhancements (later phases)

- Show `folder.jpg` as album art thumbnail in album/track views
- Sort by name / date / size
- Show track count and total size per folder

---

## 8. Upload UX

Reuse the existing upload form patterns from `templates/upload.html`:

1. **Destination** — browse path selector or hidden field set from current browse context
2. **File input** — `accept="audio/*"` plus explicit extensions from config
3. **Validation** — client-side (file selected) and server-side (extension, size, path)
4. **Result page** — themed success/error with links to "Upload another" and "Browse folder"

### Server-side upload rules

- Resolve target path: `music_library_path` + sanitized relative path
- Reject `..`, absolute paths, and unknown extensions
- Sanitize filename (same rules as images: `[A-Za-z0-9._-]`)
- Create parent directories if missing (optional; configurable)
- Set ownership/permissions compatible with LMS (`squeezeboxserver` group) — may require deploy note or post-upload `chown`

### POST size limit

Music files exceed the current 20 MB CGI limit. Increase for music routes only:

```perl
# Before music upload handler
local $CGI::POST_MAX = 1024 * 1024 * $config->{music_upload_max_mb};
```

Or set a higher global limit in config.

---

## 9. LMS integration after upload

After a successful upload, optionally notify LMS to rescan:

```json
POST http://<host-ip>:9000/jsonrpc.js
{
  "id": 1,
  "method": "slim.request",
  "params": ["", ["rescan"]]
}
```

Alternative: `["rescan", "mtimes"]` for incremental scan (faster).

Expose as config flag `music_rescan_after_upload = Yes|No`. Failure to rescan should not fail the upload — show a warning on the result page instead.

---

## 10. Security considerations

| Risk | Mitigation |
|------|------------|
| Path traversal | Strip `..`; validate resolved path is under `music_library_path` |
| Arbitrary file upload | Extension allowlist from config |
| Large uploads | Configurable `music_upload_max_mb`; Apache `LimitRequestBody` if needed |
| No authentication | Same as image server — document in security notice; restrict network access |
| Filesystem permissions | Run upload as `www-data`; may need group write to `/srv/music` or a setgid directory |
| LMS rescan abuse | Only trigger on successful upload; no public rescan endpoint |

---

## 11. Implementation phases

### Phase 1 — Foundation (~3–4 hours)

| Step | Task |
|------|------|
| 1.1 | Add `music_library_path` and related settings to `config/config.txt` |
| 1.2 | Create `lib/music.pm` with `validate_music_path`, `list_level` |
| 1.3 | Register `/music` and `/music/browse` routes in `bin/app` |
| 1.4 | Create `templates/music_browse.html` using shared layout |
| 1.5 | Add "Music Library" to nav and dashboard action card |

**Deliverable:** Browse top-level artists and drill down one level at a time with themed UI.

### Phase 2 — Upload (~2–3 hours)

| Step | Task |
|------|------|
| 2.1 | Add `/music/upload` GET/POST routes |
| 2.2 | Implement `music::upload` with path validation and filename sanitization |
| 2.3 | Create `templates/music_upload.html` and result template |
| 2.4 | Raise POST max for music uploads |
| 2.5 | "Upload to this folder" links from browse pages |

**Deliverable:** Upload audio files into selected music subfolders.

### Phase 3 — LMS integration (~1–2 hours)

| Step | Task |
|------|------|
| 3.1 | Implement `trigger_lms_rescan()` via JSON-RPC |
| 3.2 | Call after successful upload when config enabled |
| 3.3 | Show rescan status on result page |

**Deliverable:** New uploads appear in LMS after scan.

### Phase 4 — Polish (~2–3 hours)

| Step | Task |
|------|------|
| 4.1 | Album art thumbnails from `folder.jpg` where present |
| 4.2 | `/music/serve` for direct file streaming (if needed outside LMS) |
| 4.3 | File size and extension display in track list |
| 4.4 | UTF-8 filename handling audit |
| 4.5 | Update README and remove/archive `test7.pl` once integrated |

**Deliverable:** Production-ready music library management UI.

---

## 12. Estimated effort

| Phase | Effort |
|-------|--------|
| Phase 1 — Browse | 3–4 hours |
| Phase 2 — Upload | 2–3 hours |
| Phase 3 — LMS rescan | 1–2 hours |
| Phase 4 — Polish | 2–3 hours |
| **Total** | **8–12 hours** |

---

## 13. Verification checklist

| Check | Expected |
|-------|----------|
| `/music` | Themed page listing top-level artist folders |
| `/music/browse?path=Artist/Album` | Track list for that album |
| Theme consistency | Same header, nav, footer, version as `/index` |
| `/music/upload?path=Artist/Album` | Form pre-selects target folder |
| POST upload | File appears on disk under `/srv/music/...` |
| LMS rescan | New track visible in LMS after scan |
| Path traversal `../etc/passwd` | Rejected with error page |
| Large file | Rejected above configured limit |
| Non-audio extension `.exe` | Rejected |

---

## 14. Summary

`test7.pl` proves the music folder can be visualized as a tree, but its approach — full recursive scan, inline JSON, standalone styling — is unsuitable for a 37 GB / 10k-file library.

The production implementation should **reuse the existing image server template stack** and **browse one directory level per request**, matching the gallery/subdirectory pattern already in `lib/serve.pm`. Uploads target `/srv/music` (configurable), with optional LMS rescan to keep Lyrion Music Server in sync.
