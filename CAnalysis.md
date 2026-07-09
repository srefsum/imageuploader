# Code Analysis: Image Uploader CGI Project

**Date:** 2026-07-09  
**Scope:** UI consistency analysis across all served HTML pages  
**Test endpoints:** `/index`, `/show?directory=images`, `/getupload`

---

## 1. Executive Summary

The image uploader is a Perl CGI application (`bin/app`) routed through `CGI::Dispatch`. It provides upload, gallery browsing, directory creation, and image serving. **The primary problem is that each page is rendered through a different mechanism with its own CSS**, producing three visibly different experiences. There is no shared layout, navigation, or design system in active use.

The README already sketches a dark, somber theme direction. This document consolidates a full code analysis, formalizes that theme, and provides a step-by-step implementation plan.

---

## 2. Project Structure

| Path | Role | Active? |
|------|------|---------|
| `bin/app` | Main CGI entry point, routes, inline landing page | **Yes** |
| `lib/upload.pm` | POST `/upload` handler | **Yes** |
| `lib/serve.pm` | GET `/serve` (binary stream) and `/show` (gallery HTML) | **Yes** |
| `lib/CGI/Dispatch.pm` | URL router | **Yes** |
| `templates/upload.html` | Upload form page | **Yes** |
| `templates/style.html` | Shared CSS fragment (partially used) | **Partial** |
| `templates/index.html` | Landing page template | **No** (unused; `bin/app` uses inline heredoc) |
| `lib/showimages.pm` | Duplicate gallery implementation | **No** (superseded by `serve::showImages`) |
| `lib/CommonApiHandler.pm` | Microservice API framework | **No** (different project) |
| `lib/app` | Password self-service app | **No** (legacy, unrelated) |
| `bin/index.html`, `bin/test*.html` | Unrelated static/test files | **No** |
| `apache/imageserver.conf` | Apache vhost + rewrite to `bin/app` | Deploy config |
| `deploy` | Copy script to `/var/www/image-server/` | Deploy script |

### Routes (from `bin/app`)

| Route | Method | Handler | Output type |
|-------|--------|---------|-------------|
| `/index` | GET | `index` → `printLandingPage()` | Inline HTML |
| `/getupload` | GET | `getupload` → `templates/upload.html` | Template |
| `/upload` | POST | `upload` → `upload::upload()` | Raw HTML fragments |
| `/show` | GET | `show` → `serve::showImages()` | CGI.pm HTML |
| `/create` | POST | `createDir` → `serve::showImages()` | CGI.pm HTML |
| `/serve` | GET | `serve` → `serve::serve()` | Binary image stream |
| `/` | GET | Redirect to `http://<eth0-ip>:9000` | 302 redirect |

### Configured directories (`%allowed_dirs` in `bin/app`)

| Key | Filesystem path | Subdirs shown |
|-----|-----------------|---------------|
| `images` | `/var/www/images/gallery1` | Yes |
| `uploads` | `/var/www/images/uploads` | No |
| `logos` | `/var/www/images/logos` | No |

---

## 3. UI Inconsistency Analysis

### 3.1 Three separate rendering pipelines

```
/index          →  bin/app::printLandingPage()     →  inline heredoc + embedded <style>
/getupload      →  ProcessFileandPrint(upload.html) →  template + #include style.html
/show, /create  →  serve::showImages()             →  CGI->start_html(-style => {...})
/upload         →  upload::upload()                →  bare <h3> and <p> tags, no wrapper
```

No page shares a common shell (header, nav, footer). CSS is duplicated or absent depending on the route.

### 3.2 Page-by-page comparison

#### `/index` — Landing page

- **Source:** `printLandingPage()` heredoc in `bin/app` (lines 312–404)
- **Theme:** Light page, dark header (`#333`), green accent (`#4CAF50`), Segoe UI font
- **Layout:** Header + three feature cards (Fast / Secure / Simple)
- **Content mismatch:** Generic "Dynamic Perl CGI Engine" marketing copy — not an image uploader dashboard
- **Navigation:** No links to upload or gallery; only an anchor to `#features`
- **Relation to templates:** `templates/index.html` is a near-duplicate but is **never loaded**

#### `/getupload` — Upload form

- **Source:** `templates/upload.html` via `ProcessFileandPrint()`
- **Theme:** Same green/light palette via `#include "../templates/style.html"`
- **Layout:** Reuses landing-page header and feature-box grid; form is squeezed inside a single `.feature-box` card
- **HTML issues:**
  - Duplicate `<head>` elements (lines 3–4 and 5–12)
  - Header text still says "Dynamic Perl CGI Engine" instead of upload context
  - "Explore Features" button links to `#features` on a page with no meaningful features section
- **Form styling:** Native browser defaults for `<select>`, `<input type="file">`, and submit button — no `.form-group` styles despite class names used elsewhere

#### `/show?directory=images` — Gallery

- **Source:** `serve::showImages()` in `lib/serve.pm`
- **Theme:** Completely different — CGI.pm default document styling (browser defaults + minimal inline CSS)
- **Gallery CSS (inline in Perl):**
  - Flexbox grid, 15px gap
  - 1px `#ccc` border on items
  - Thumbnails capped at **100×100px** (vs 200px in unused `showimages.pm`)
  - Filename text at 12px, `#555` color
- **Missing elements:**
  - No site header or navigation
  - No link back to `/index` or `/getupload`
  - No page title reflecting which directory is being viewed
- **Subdirectory listing:** Mixed markup — `<ul>` wrapping `<div class="gallery-item">` containing `<li>` (invalid HTML nesting)
- **Hardcoded links:** Subdirectory hrefs always use `directory=images`, ignoring current folder key
- **Create-directory form:** Appended as raw HTML heredoc with `.form-container` / `.form-group` classes that have **no CSS defined anywhere**
- **Subdirectory support:** Only shown when not already inside a subdir; `showsubdirs` flag respected for URL building

#### `/upload` — Upload result (POST response)

- **Source:** `upload::upload()` in `lib/upload.pm`
- **Output:** Unstyled fragments only:
  ```html
  <h3>/var/www/images/...</h3>
  <h3>Success!</h3>
  <p>File has been safely uploaded to: <b>images</b> folder.</p>
  ```
- No `<!DOCTYPE>`, no charset, no navigation, no success/error card styling
- Exposes full server filesystem path to the user

#### `/create` — Directory creation (POST response)

- **Source:** `createDir()` in `bin/app` → `serve::showImages()`
- **Bug:** `print Dumper \%resp` left in production code (line 246) — dumps debug structure into HTML before gallery
- After `mkdir`, re-renders gallery page (same inconsistent styling as `/show`)

### 3.3 CSS inventory

| CSS source | Used by | Palette | Components defined |
|------------|---------|---------|-------------------|
| Inline in `printLandingPage()` | `/index` | Green `#4CAF50`, dark `#333`, light `#f4f4f4` | header, container, btn, features, feature-box |
| `templates/style.html` | `/getupload` (via include) | Same as above | Same as above |
| `templates/index.html` | *(unused)* | Same as above | Same as above |
| CGI `-style => { -code => ... }` in `serve.pm` | `/show`, `/create` | Minimal: `#ccc`, `#555` | gallery, gallery-item, filename |
| *(none)* | `/upload` response | Browser default | — |
| Form classes in `serve.pm` heredoc | `/show`, `/create` | *(unstyled)* | form-container, form-group referenced but not defined |

### 3.4 Template preprocessor (`ProcessFileandPrint`)

`bin/app` implements a minimal template engine:

- `#include "path"` — inline file contents
- `#replace "variable"` — substitute from `$resp->{variables}{variable}`

**Gaps for UI work:**

- No layout inheritance (no base template / content slot)
- No conditional blocks or loops in templates
- Include paths are relative to the template file, not the CGI bin directory

### 3.5 JavaScript

- **None** in any active page
- README proposes vanilla JS for directory selector hints, form validation, gallery filter — not implemented

---

## 4. Non-UI Code Issues (relevant to theming work)

| Issue | Location | Impact on UI work |
|-------|----------|-------------------|
| `print Dumper` in `createDir` | `bin/app:246` | Breaks gallery page with debug output |
| `if (-e !$found_path)` | `serve.pm:29` | Likely broken file-exists check (should be `!-e`) |
| Duplicate `showimages.pm` | `lib/showimages.pm` | Confusion; different thumbnail size (200px) |
| `templates/index.html` unused | templates/ | Dead duplicate of landing page |
| Upload exposes filesystem path | `upload.pm:43` | Should show user-friendly message in themed result page |
| No error page template | all handlers | Errors render as plain text or `die` |

---

## 5. Proposed Common UI Theme

### 5.1 Design direction

**Somber, simple, modern** — a cohesive dark theme suitable for an internal image management tool. No external dependencies (no CDN fonts, no CSS frameworks, no npm).

### 5.2 Color palette

| Token | Value | Usage |
|-------|-------|-------|
| `--color-bg` | `#121417` | Page background |
| `--color-surface` | `#1A1D21` | Cards, panels, form fields |
| `--color-surface-raised` | `#22262C` | Hover states, elevated cards |
| `--color-border` | `#2A2F36` | Dividers, input borders, gallery frames |
| `--color-primary` | `#8AA3B8` | Links, primary buttons, active nav |
| `--color-primary-hover` | `#9DB5C7` | Button/link hover |
| `--color-text` | `#E8EDF2` | Body text, headings |
| `--color-text-muted` | `#A1ACB8` | Secondary text, labels, filenames |
| `--color-success` | `#6B9E78` | Upload success banner |
| `--color-error` | `#C07070` | Error messages |
| `--color-warning` | `#B8A06B` | Security/constraint notices |

### 5.3 Typography

```css
font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
```

| Element | Size | Weight |
|---------|------|--------|
| `h1` (page title) | 1.75rem | 600 |
| `h2` (section) | 1.25rem | 600 |
| `h3` (card title) | 1.1rem | 600 |
| Body | 1rem | 400 |
| Small / filename | 0.8125rem | 400 |
| Line height | 1.6 | — |

### 5.4 Spacing scale

`4px · 8px · 12px · 16px · 24px · 32px · 48px`

Use consistently for padding, margins, and grid gaps.

### 5.5 Border radius and shadows

- Border radius: `8px` (cards, buttons, inputs); `4px` (thumbnails, badges)
- Box shadow: `0 1px 3px rgba(0,0,0,0.3)` on cards only — subtle, no heavy elevation

### 5.6 Component library

#### Layout shell (`templates/layout.html`)

```
┌─────────────────────────────────────────────┐
│  HEADER: app name + tagline                 │
│  NAV: Home | Upload | Images | Uploads | Logos │
├─────────────────────────────────────────────┤
│  MAIN (max-width 1100px, centered)          │
│    ┌─ page title + breadcrumb ─────────┐  │
│    └─ content slot (#replace "content") ┘  │
├─────────────────────────────────────────────┤
│  FOOTER: constraints notice (max 20MB etc)  │
└─────────────────────────────────────────────┘
```

#### Buttons (`.btn`, `.btn-primary`, `.btn-secondary`)

- Primary: `--color-primary` background, dark text or white text (test for contrast)
- Secondary: transparent with `--color-border` border
- Padding: `8px 16px`, radius `8px`
- Hover: `--color-primary-hover`; focus: `2px outline`

#### Cards (`.card`)

- Background: `--color-surface`
- Border: `1px solid --color-border`
- Padding: `24px`
- Used for: dashboard action tiles, form wrapper, upload result

#### Forms (`.form-group`, `.form-label`, `.form-input`, `.form-select`)

- Full-width inputs on mobile; max `400px` on desktop for single-field forms
- Labels above inputs, `--color-text-muted`
- File input styled with consistent padding and border
- Focus ring: `outline: 2px solid --color-primary`

#### Gallery (`.gallery`, `.gallery-item`, `.gallery-thumb`, `.gallery-filename`)

- CSS Grid: `repeat(auto-fill, minmax(160px, 1fr))`, gap `16px`
- Thumbnail: `max-width/height 160px`, `object-fit: contain`
- Item card: surface background, border, centered image + filename below
- Hover: slight `surface-raised` background

#### Alerts (`.alert-success`, `.alert-error`, `.alert-info`)

- Left border accent (4px) + tinted background
- Used for upload results, errors, security notice

#### Navigation (`.nav`, `.nav-link`, `.nav-link--active`)

- Horizontal nav below header
- Active page highlighted with `--color-primary` bottom border

#### Breadcrumb (`.breadcrumb`)

- For gallery subdirectories: `Home › Images › subfolder-name`
- Muted text with `/` separators; current page non-linked

### 5.7 Page-specific content designs

#### Dashboard (`/index`)

Replace generic CGI marketing copy with an image-uploader dashboard:

1. **Header** — "Image Server" + short description
2. **Quick action cards** (3-column grid, collapses to 1 on mobile):
   - Upload file → `/getupload`
   - Browse gallery → `/show?directory=images`
   - Browse uploads → `/show?directory=uploads`
   - Browse logos → `/show?directory=logos`
3. **How it works** — one paragraph per action
4. **Constraints panel** — allowed directories, 20 MB limit, image extensions
5. **Security notice** — no auth enabled, path allowlisting

#### Upload (`/getupload`)

- Page title: "Upload Image"
- Card-wrapped form with styled directory selector and file picker
- Optional JS: update helper text when directory selection changes
- Breadcrumb: `Home › Upload`

#### Gallery (`/show`)

- Page title: directory description from `%allowed_dirs` (e.g. "Images Directory")
- Breadcrumb reflecting `directory` and optional `sub` param
- Filter input (optional JS): client-side filename filter
- Subdirectory links as styled folder cards (not broken `<ul>`/`<div>` mix)
- Create-directory form in a separate card (only when `showsubdirs eq "Yes"` and not inside a subdir)
- Nav link back to dashboard and upload

#### Upload result (`/upload`)

- Full themed page (not bare `<h3>` tags)
- Success card with directory name (not raw filesystem path)
- Links: "Upload another" → `/getupload`, "View gallery" → `/show?directory=<key>`

#### Error states

- Themed 400/404 pages for invalid directory, missing file, upload failure
- Consistent alert component

### 5.8 Responsive behavior

- Container: `max-width: 1100px`, horizontal padding `16px`
- Gallery grid and action cards: single column below `600px`
- Navigation: wrap on narrow screens

### 5.9 Accessibility

- Sufficient contrast ratios on dark background (WCAG AA target)
- Visible focus states on all interactive elements
- `alt` text on gallery images (already partially done via `escapeHTML`)
- Form labels associated with inputs via `for`/`id`
- `lang="en"` on `<html>`

---

## 6. Implementation Plan

### Phase 0 — Prerequisites (before any visual work)

| Step | Task | Files |
|------|------|-------|
| 0.1 | Remove `print Dumper \%resp` from `createDir` | `bin/app` |
| 0.2 | Fix `-e` check in `serve::serve` | `lib/serve.pm` |
| 0.3 | Delete or archive `lib/showimages.pm` to avoid confusion | `lib/showimages.pm` |
| 0.4 | Verify `deploy` script copies all template changes | `deploy` |

### Phase 1 — Shared CSS and layout foundation

| Step | Task | Files | Details |
|------|------|-------|---------|
| 1.1 | Rewrite `templates/style.html` with full design system | `templates/style.html` | All CSS variables, components from §5 |
| 1.2 | Create `templates/layout.html` | `templates/layout.html` | HTML shell with `#include style`, header, nav, `#replace "content"`, footer |
| 1.3 | Create `templates/nav.html` fragment | `templates/nav.html` | Nav links; optional `#replace "active_page"` for highlighting |
| 1.4 | Extend `ProcessFileandPrint` if needed | `bin/app` | Support multiple `#replace` keys (content, title, active_page) — already supports arbitrary keys via `$resp->{variables}` |

**Nav links (static in template):**

```html
<a href="/index" class="nav-link">Home</a>
<a href="/getupload" class="nav-link">Upload</a>
<a href="/show?directory=images" class="nav-link">Gallery</a>
<a href="/show?directory=uploads" class="nav-link">Uploads</a>
<a href="/show?directory=logos" class="nav-link">Logos</a>
```

### Phase 2 — Migrate each page to templates

| Step | Task | Files | Details |
|------|------|-------|---------|
| 2.1 | Create `templates/index_content.html` | new | Dashboard cards, how-it-works, constraints |
| 2.2 | Refactor `index` handler | `bin/app` | Remove `printLandingPage` heredoc; use `ProcessFileandPrint` with layout |
| 2.3 | Refactor `templates/upload.html` | `templates/upload.html` | Fix duplicate `<head>`; use layout wrapper; proper form classes |
| 2.4 | Create `templates/gallery.html` | new | Gallery grid, subdirectory list, create-dir form |
| 2.5 | Refactor `serve::showImages` | `lib/serve.pm` | Build HTML fragments into `$resp->{variables}`, render via template instead of `CGI::start_html` |
| 2.6 | Create `templates/upload_result.html` | new | Success/error card |
| 2.7 | Refactor `upload::upload` | `lib/upload.pm` | Set success/error variables; render through layout template |
| 2.8 | Create `templates/error.html` | new | Generic error page for invalid directory, etc. |

**Variable contract for templates:**

```perl
$resp->{variables}{title}        = 'Upload Image';
$resp->{variables}{active_page}  = 'upload';
$resp->{variables}{content}      = $gallery_html;  # pre-built fragment
```

### Phase 3 — Gallery and form logic improvements

| Step | Task | Files | Details |
|------|------|-------|---------|
| 3.1 | Fix subdirectory link generation | `lib/serve.pm` | Use `$folder` variable, not hardcoded `images` |
| 3.2 | Fix subdirectory HTML structure | `lib/serve.pm` | Use `.folder-list` / `.folder-item` instead of `<ul>` inside `.gallery` |
| 3.3 | Pass directory metadata to template | `lib/serve.pm` | Description, `showsubdirs` flag, current `sub` for breadcrumb |
| 3.4 | Conditionally show create-dir form | template + Perl | Only when `showsubdirs eq "Yes"` and not in subdir |
| 3.5 | Pre-select `current_dir` in create form | `lib/serve.pm` | Use actual `$folder`, not hardcoded `"images"` |

### Phase 4 — JavaScript enhancements (optional, progressive)

| Step | Task | Files | Details |
|------|------|-------|---------|
| 4.1 | Create `templates/app.js` | new | Vanilla JS, included in layout |
| 4.2 | Directory selector helper text | `app.js` + upload template | Update description on `<select>` change |
| 4.3 | Client-side form validation | `app.js` | Require file selected before submit |
| 4.4 | Gallery filename filter | `app.js` + gallery template | Input field filters visible `.gallery-item` elements |
| 4.5 | Copy image URL button | `app.js` + gallery template | Copy `/serve?...` URL to clipboard |

Serve `app.js` either inline in layout or via a new static route (would require a new `url` handler or Apache static file).

### Phase 5 — Cleanup and consistency

| Step | Task | Files | Details |
|------|------|-------|---------|
| 5.1 | Remove inline `printLandingPage` heredoc | `bin/app` | After template migration |
| 5.2 | Remove or sync `templates/index.html` | `templates/index.html` | Delete dead duplicate or make it the content fragment |
| 5.3 | Remove CGI `-style` inline CSS | `lib/serve.pm` | After gallery template migration |
| 5.4 | Unify `http_header_html` usage | all handlers | Ensure charset and CORS header on every HTML response |
| 5.5 | Update README | `README.md` | Document new template structure and theme |
| 5.6 | Update `deploy` script | `deploy` | Ensure all new templates are copied |

### Phase 6 — Verification

| Check | URL / action | Expected |
|-------|-------------|----------|
| Visual consistency | `/index`, `/getupload`, `/show?directory=images` | Same header, nav, footer, dark theme |
| Navigation | Click nav links on each page | Correct page, active state highlighted |
| Upload flow | POST file via `/getupload` | Themed success page, no filesystem path exposed |
| Gallery subdirs | `/show?directory=images` | Folder cards link correctly |
| Create dir | POST new folder name | Gallery reloads without Dumper output |
| Mobile | Resize to 400px width | Single-column layout, readable |
| Deploy | Run `deploy`, reload | Changes visible on `192.168.86.48` |

---

## 7. Recommended File Structure After Implementation

```
templates/
  layout.html          # Master shell (header, nav, footer, #include style)
  style.html           # Complete CSS design system
  nav.html             # Navigation fragment (optional)
  app.js               # Vanilla JS (optional, Phase 4)
  index_content.html   # Dashboard body
  upload.html          # Upload form body (or upload_content.html inside layout)
  gallery.html         # Gallery body
  upload_result.html   # Upload success/error body
  error.html           # Generic error body
```

```
bin/app                # Handlers set $resp->{variables}{...} and call ProcessFileandPrint
lib/serve.pm           # Builds gallery HTML fragments; no CGI::start_html
lib/upload.pm          # Sets result variables; renders through template
```

---

## 8. Effort Estimate

| Phase | Effort | Dependency |
|-------|--------|------------|
| Phase 0 — Bug fixes | ~30 min | None |
| Phase 1 — CSS + layout | ~2–3 hours | Phase 0 |
| Phase 2 — Page migration | ~3–4 hours | Phase 1 |
| Phase 3 — Gallery fixes | ~1–2 hours | Phase 2 |
| Phase 4 — JavaScript | ~1–2 hours | Phase 2 (optional) |
| Phase 5 — Cleanup | ~1 hour | Phase 2 |
| Phase 6 — Verification | ~30 min | All |

**Total:** approximately 1–2 days of focused work.

---

## 9. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| `ProcessFileandPrint` include paths break when deployed | Use paths relative to template file; test after `deploy` |
| Moving gallery from CGI.pm to templates loses escaping | Continue using `$q->escapeHTML()` when building fragments in Perl |
| Large CSS in every page response | Single included file is small (~5–8 KB); acceptable for this app |
| `serve::showImages` called from both `show` and `createDir` | Single template path covers both; pass flash message variable for "directory created" |
| Root `/` redirects away from app | Consider changing redirect target to `/index` per README recommendation |

---

## 10. Summary

The image uploader works functionally but presents **at least four distinct visual styles** across its pages because HTML is generated via inline heredocs, a partial template system, CGI.pm helpers, and raw print statements — with no shared layout.

The fix is straightforward: **one CSS file, one layout template, and migrating every HTML response to render through that shell.** The proposed dark somber theme provides a professional, consistent look without external dependencies. Phases 0–2 deliver the highest impact; Phases 3–4 polish gallery behavior and interactivity.
