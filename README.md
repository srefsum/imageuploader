# imageuploader

Perl CGI image upload and image browsing service with server-rendered HTML pages.

## What the app currently does

The active application entrypoint is:

- `bin/app`

It uses `CGI::Dispatch` and serves these actions:

- `GET /index`  
  Shows a simple landing page (inline HTML/CSS in Perl).
- `GET /getupload`  
  Shows an upload form with destination selector.
- `POST /upload`  
  Uploads one file to a predefined target directory.
- `GET /show?directory=<key>[&sub=<name>]`  
  Shows a gallery view of images in a configured directory (and optional subdirectory).
- `POST /create`  
  Creates a subdirectory under a configured base directory.
- `GET /serve?directory=<key>&file=<name>[&sub=<name>]`  
  Streams an image file with MIME type detection and cache headers.
- `GET /`  
  Redirects to `http://<host-ip>:9000` (current hardcoded behavior defined in `bin/app` route mapping; should be made configurable per environment).

Configured target directories (hardcoded in `bin/app`):

- `images` => `/var/www/images/gallery1` (subdirectories shown)
- `uploads` => `/var/www/images/uploads`
- `logos` => `/var/www/images/logos`

## Current capabilities and limits

### Capabilities

- Upload image/file content into one of three allowed base folders.
- Serve files directly via `/serve`.
- Render a basic image gallery for allowed directories.
- List first-level subdirectories in gallery mode.
- Create a new folder (currently primarily wired to the `images` flow in UI).
- Basic filename sanitizing and path-key allowlisting for uploads/serving.

### Limits

- No authentication/authorization.
- No delete/rename/move operations.
- No metadata database.
- UI is inconsistent (mixed inline CSS/templates, duplicated styles).
- Some repository files are legacy or unrelated to the current image uploader flow, including `bin/index.html` and `lib/app`.
- These files are not required by the active image upload routes in `bin/app` and should be treated as separate/archived context unless intentionally re-used.

## Runtime architecture (current)

- **Backend language:** Perl
- **Frontend language:** HTML + CSS + small inline pure JavaScript for simple DOM behavior (for example form interaction and basic dynamic selection)
- **Router:** `CGI::Dispatch`
- **Core modules used by app:**
  - `lib/upload.pm`
  - `lib/serve.pm`
- **Templates:** `templates/*.html`
- **Apache example config:** `apache/imageserver.conf`

---

## Proposed common UI theme (somber, simple, modern)

No external packages required. Use only Perl templates and pure JavaScript.

### Visual direction

- Dark neutral palette:
  - Background: `#121417`
  - Surface/card: `#1A1D21`
  - Border: `#2A2F36`
  - Primary accent: `#8AA3B8`
  - Text main: `#E8EDF2`
  - Text muted: `#A1ACB8`
- Clean typography: system sans-serif stack only (no externally loaded web fonts).
- Rounded corners (`8px`), subtle shadows, high contrast.
- Consistent spacing scale (`4px, 8px, 12px, 16px, 24px, 32px`).
- Small, focused interactions (hover/focus states, no animation-heavy UI).

### Implementation approach

1. Move all shared CSS into one template include:
   - `templates/style.html`
2. Create a shared page shell template (header/nav/content/footer).
3. Reuse the same button, card, form, table, and gallery classes on every page.
4. Keep JavaScript minimal and framework-free:
   - DOMContentLoaded init
   - Form validation helpers
   - Optional gallery filtering/sorting controls
5. Keep rendering server-side in Perl; use JS only for progressive enhancement.

---

## Proposed common landing page

Create one dashboard page where all actions are explained and reachable.

### Purpose

- Explain what this service is.
- Give direct links to each operation.
- Show status/context (configured directories, allowed file types, upload limits).

### Suggested sections

1. **Header**
   - App name and short description.
2. **Quick actions (cards/buttons)**
   - Upload file (`/getupload`)
   - Browse images (`/show?directory=images`)
   - Browse uploads (`/show?directory=uploads`)
   - Browse logos (`/show?directory=logos`)
3. **How it works**
   - One short paragraph per action.
4. **Operational constraints**
   - Allowed directories, max upload size, supported image extensions.
5. **Security notice**
   - Explain path restrictions and that auth is currently not enabled.

### Suggested route usage

- Keep `/index` as the canonical landing page.
- Keep `/` as redirect if needed by deployment, but target `/index` for app entry consistency.

---

## Pure JavaScript usage proposal

Use vanilla JS only for UI behavior, for example:

- Directory selector that updates helper text.
- Inline form validation before submit.
- Copyable direct links for served images.
- Optional client-side filter field in gallery view.

All business logic and file operations remain in Perl.
