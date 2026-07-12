# Music Bulk Upload — Source Analysis and Improvement Plan

**Date:** 2026-07-12  
**Context:** Import music from `C:\Users\sigref\Dropbox\Music` on the PC into `/srv/music` on the LMS server. Each top-level folder is an **artist**; subfolders are **albums**. The user wants to select either an artist folder or an album folder and upload everything underneath (audio + images), without overwriting anything already on the server.

---

## 1. Source folder analysis

### 1.1 Access limitation

The Windows path `C:\Users\sigref\Dropbox\Music` is **not reachable** from the Linux server where this app runs. Analysis of the two specific Dropbox folders must be done either:

1. **On the PC** — copy the two artist folders to the server (e.g. `scp -r "Artist Name" pi:/tmp/music-import/`) and run the analysis script below, or  
2. **Locally on Windows** — run the same script if Perl is available, pointing `--library` at a snapshot or using only the source side of the report.

Please provide the **two artist folder names** (or copy them to `/tmp/music-import/` on the server) to complete a concrete merge report.

### 1.2 Analysis tool

Added: **`bin/analyze_music_import.pl`**

```bash
# On the server, after copying source folders:
./bin/analyze_music_import.pl /tmp/music-import/"Artist One" /tmp/music-import/"Artist Two"

# Custom library path:
./bin/analyze_music_import.pl --library /srv/music /path/to/source
```

The script reports:

| Check | Output |
|-------|--------|
| Artist already in `/srv/music`? | YES → merge mode / NO → new artist |
| Albums in source | Count, per-album track/image counts |
| New vs existing albums | Existing folders are never replaced |
| New vs existing files | Existing files are counted as **skip** |
| Import mode | Auto-detects **artist** vs **album** layout |

### 1.3 Current library baseline (`/srv/music`)

| Metric | Value |
|--------|-------|
| Top-level artists | 95 |
| Typical layout | `Artist / Album / tracks + folder.jpg` |
| Image files | ~470 (mostly `folder.jpg` and cover art) |
| Non-music extras | Some `desktop.ini`, `Thumbs.db`, `.m3u` (should not be uploaded) |

**Merge rule for both source folders:** nothing on the server is overwritten — only missing artists, albums, and files are added.

### 1.4 Expected outcomes (by scenario)

#### Scenario A — New artist (not in library)

Example: Dropbox folder `New Artist/` with albums underneath.

| Action | Result |
|--------|--------|
| Artist folder | **Create** `/srv/music/New Artist/` |
| Album subfolders | **Create** each album directory |
| Audio + images | **Upload** all files |
| Existing server data | Unaffected |

#### Scenario B — Existing artist (already in library)

Example: Dropbox folder `Bjelleklang/` (already present on server).

| Action | Result |
|--------|--------|
| Artist folder | **Keep** existing `/srv/music/Bjelleklang/` |
| New album in Dropbox | **Create** only that album folder |
| Album already on server | **Merge** — upload only files that do not exist yet |
| Same filename on server | **Skip** (must not overwrite) |
| Dropbox-only tracks | **Upload** as new files |

#### Scenario C — Album folder only

Example: User selects `Some Album/` (no parent artist in selection).

| Action | Result |
|--------|--------|
| UI | User must pick **target artist** (existing or new) |
| Album path | `/srv/music/<Artist>/Some Album/` |
| Conflict check | Same skip rules as above |

### 1.5 What to verify for your two folders

When the folder names are available, the analysis should answer:

1. **Folder 1 (new artist)** — artist name, album count, total files, estimated upload size, zero conflicts expected.
2. **Folder 2 (existing artist)** — which albums are new vs already on server, which track filenames collide (skip list), how many files will actually be uploaded.

---

## 2. Analysis of the current music upload solution

### 2.1 What exists today

| Feature | Status |
|---------|--------|
| Browse library level-by-level | Implemented (`/music`, `/music/browse`) |
| Single-file upload at album depth | Implemented (`POST /music/upload`) |
| Image upload (`folder.jpg`, etc.) | Implemented at album level |
| Create artist/album/CD folder | Implemented (`POST /music/create`) |
| UTF-8 paths and display | Implemented |
| LMS rescan after upload | Implemented (once per file) |
| Bulk / folder upload | **Not implemented** |
| Artist-level import | **Not implemented** |
| Album-level folder import | **Not implemented** |
| Conflict / skip-if-exists | **Not implemented** |
| Upload preview / dry-run | **Not implemented** |

### 2.2 Current upload flow

```
User browses to album → "Upload music or images" → selects ONE file → POST → file written
```

Relevant code:

- `lib/music.pm` — `can_upload()` requires depth ≥ 2 (album or below)
- `templates/music_upload.html` — single `<input type="file">` (no `multiple`, no directory picker)
- `music::upload()` — writes with `open('>', $path)` → **overwrites** if filename already exists

### 2.3 Gaps for Dropbox import

| Requirement | Current behaviour | Gap |
|-------------|-------------------|-----|
| Select artist folder | Not possible | Need directory picker + batch upload |
| Select album folder | Not possible | Same |
| Upload all files below | One file per request | Need multi-file / tree upload |
| Include all images | Partial (configured extensions only) | OK for jpg/png; need explicit policy for “all sensible files” |
| Do not overwrite folders | `create_subdir` skips if exists | OK |
| Do not overwrite files | File upload **overwrites** | **Must fix** before bulk import |
| Upload from PC Dropbox | Manual, one file at a time | Impractical for full albums |
| Rescan after import | Rescan per file | Should be once per batch |

### 2.4 Risk: silent overwrite (existing bug)

Today, uploading `01 Track.mp3` to an album that already contains that file **replaces** the server copy. Bulk import must change this to **skip + report**:

```perl
# Required policy
if (-e $final_path) {
    push @skipped, $rel_path;
    next;
}
```

---

## 3. Proposed improvement plan

### 3.1 Goals

1. Select a local **artist folder** or **album folder** in the browser.
2. Upload **all audio and image files** under that folder, preserving relative paths.
3. **Never overwrite** existing folders or files on the server.
4. Show a clear **preview / result**: created, skipped, rejected.
5. Trigger **one LMS rescan** after the whole batch completes.
6. Keep the existing dark theme and browse UI.

### 3.2 Recommended UX

New page: **`/music/import`**

```
┌─────────────────────────────────────────────────────────┐
│  Import Music                                           │
│                                                         │
│  Import type:  ( ) Artist folder   ( ) Album folder     │
│                                                         │
│  [ Choose folder... ]   ← webkitdirectory + multiple    │
│                                                         │
│  Target artist: [ dropdown / text ]  (album mode only)  │
│                                                         │
│  Preview (after selection):                             │
│    Artist: Bjelleklang (exists)                         │
│    Albums:  1 new, 2 existing                           │
│    Files:   24 to upload, 8 skipped (exist)             │
│                                                         │
│  [ Upload ]   [ Cancel ]                                │
└─────────────────────────────────────────────────────────┘
```

**Artist folder mode**

- User picks `Bjelleklang/` from Dropbox.
- Client sends files with paths like `Bjelleklang/Album/track.mp3`.
- Server maps to `/srv/music/Bjelleklang/Album/track.mp3`.

**Album folder mode**

- User picks `Back in Black/`.
- User selects target artist (dropdown from library + “New artist…”).
- Client sends paths like `Back in Black/01.mp3`.
- Server maps to `/srv/music/AC-DC/Back in Black/01.mp3`.

### 3.3 Technical approach

#### Phase 1 — Safety foundation (required first)

| Step | Task |
|------|------|
| 1.1 | Change `music::upload` to **skip existing files** (config: `music_overwrite = No`) |
| 1.2 | Add `music::safe_write_file($abs, $fh)` helper — returns `created`, `skipped`, or `error` |
| 1.3 | Extend result template to list skipped filenames |

**Effort:** ~1 hour

#### Phase 2 — Multi-file upload (same album)

| Step | Task |
|------|------|
| 2.1 | Add `multiple` to file input on upload form |
| 2.2 | Loop files in `music::upload` or new `music::upload_batch` |
| 2.3 | Single rescan at end of batch |
| 2.4 | Progress / summary on result page |

**Effort:** ~2 hours

#### Phase 3 — Folder import (artist / album)

| Step | Task |
|------|------|
| 3.1 | New route `GET/POST /music/import` |
| 3.2 | Template `music_import.html` + JS folder reader |
| 3.3 | Client builds manifest: `[{ relativePath, file }]` from `webkitRelativePath` |
| 3.4 | POST as `multipart/form-data` with repeated file parts + path metadata |
| 3.5 | Server function `music::import_tree($mode, $target_artist, $files)` |
| 3.6 | Create missing directories (`mkdir` cascade, never overwrite) |
| 3.7 | Filter: upload audio + images; ignore `desktop.ini`, `Thumbs.db`, `.DS_Store` |
| 3.8 | Optional dry-run via `POST /music/import/preview` (JSON counts only) |

**Effort:** ~4–6 hours

#### Phase 4 — Polish and operations

| Step | Task |
|------|------|
| 4.1 | Raise `music_upload_max_mb` or add `music_import_max_mb` for batch total size |
| 4.2 | Apache `LimitRequestBody` / timeout tuning for large imports |
| 4.3 | Link “Import music” from `/music` and dashboard |
| 4.4 | Run `analyze_music_import.pl` before first real import; document in README |
| 4.5 | Optional: CLI import on server (`rsync --ignore-existing`) as fallback for very large libraries |

**Effort:** ~2 hours

### 3.4 Server-side import algorithm

```
INPUT: mode (artist|album), target_artist, files[{ rel_path, handle }]

1. Normalize and validate all path segments (UTF-8, no ..)
2. Compute destination root:
     artist mode → /srv/music/<artist-from-folder>/
     album mode  → /srv/music/<target_artist>/<album-from-folder>/
3. For each file (sorted deepest-first):
     a. Map rel_path → abs destination
     b. If path escapes music root → reject
     c. If destination is directory → skip
     d. If file exists → skip (record in report)
     e. Else ensure parent dirs exist (mkdir_p, no overwrite)
     f. Write file
4. Trigger one LMS rescan if any file created
5. Return summary JSON / render result page
```

### 3.5 Config additions

```ini
music_import_max_mb       = 500
music_overwrite           = No
music_import_skip_files   = desktop.ini Thumbs.db .DS_Store *.m3u
music_import_all_images   = Yes
```

### 3.6 Browser constraints

| Limitation | Mitigation |
|------------|------------|
| `webkitdirectory` is non-standard but works in Chrome/Edge | Document supported browsers |
| Very large folders (100+ files) | Batch POST in chunks of N files |
| Total size may exceed CGI limit | Chunked uploads or raise limits |
| No direct filesystem access to Dropbox | User selects folder via browser picker (Dropbox synced locally) |

### 3.7 Alternative: server-side sync (large libraries)

For very large imports, a complementary **non-web** path avoids browser limits:

```bash
rsync -av --ignore-existing "/mnt/dropbox/Music/Artist/" /srv/music/Artist/
```

The web import UI remains the primary user-friendly path; rsync is the escape hatch.

---

## 4. Implementation priority

| Priority | Item | Why |
|----------|------|-----|
| P0 | Skip-if-exists on file upload | Prevents data loss today |
| P1 | `/music/import` with folder picker | Core user request |
| P1 | Artist + album modes | Matches Dropbox layout |
| P2 | Preview before upload | User confidence |
| P2 | Batch rescan | Avoids LMS spam |
| P3 | Chunked upload for large folders | Reliability |

**Total estimate:** 9–13 hours after the two source folders have been analyzed.

---

## 5. Verification checklist

| Check | Expected |
|-------|----------|
| Import new artist | Artist + albums + files created |
| Import existing artist | Only new albums/files added |
| Duplicate filename | Skipped, shown in report |
| Duplicate album folder | Not recreated; files inside merged |
| `folder.jpg` | Uploaded with album |
| `desktop.ini` | Ignored |
| UTF-8 names (ø, å, &) | Correct paths and display |
| LMS | One rescan; new tracks appear |
| No overwrite | Server files unchanged when skipped |

---

## 6. Next steps

1. **Name the two Dropbox artist folders** (or copy them to the server) so `analyze_music_import.pl` can produce a concrete merge report.
2. **Implement P0** (skip-if-exists) — small change, high safety value.
3. **Implement Phase 3** (`/music/import`) for folder-based upload from the PC.
4. Run analysis script → dry-run import → live import → LMS rescan → verify in browse UI.

---

## 7. Summary

The current upload solution works for **single files at album level** but cannot import a whole artist or album from Dropbox. It also **overwrites** same-named files, which must be fixed before any bulk import.

The proposed **`/music/import`** page with artist/album folder selection, tree-preserving multi-file upload, skip-if-exists policy, and batch rescan matches the Dropbox layout and the requirement that **no existing folder or file on the server is overwritten**.
