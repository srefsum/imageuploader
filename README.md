# Image Server

Perl CGI service for uploading and browsing images, integrated with a Lyrion Music Server (LMS) home network. All HTML pages share a dark, server-rendered theme defined in `templates/`.

## Application entrypoint

- **`bin/app`** — active CGI script routed through Apache (`apache/imageserver.conf` rewrites all requests to this script).

## Routes

| Route | Method | Description |
|-------|--------|-------------|
| `/index` | GET | Dashboard with quick links to upload and browse configured directories |
| `/getupload` | GET | Upload form with directory and optional subdirectory selector |
| `/upload` | POST | Upload a file to a configured directory |
| `/show?directory=<key>[&sub=<name>]` | GET | Gallery view of images in a configured directory |
| `/create` | POST | Create a subdirectory (only for directories with `showsubdirs = Yes`) |
| `/serve?directory=<key>&file=<name>[&sub=<name>]` | GET | Stream a file with MIME detection and cache headers |
| `/music` | GET | Browse music library root (artists/folders) |
| `/music/browse?path=<relative>` | GET | Browse one level of the music library |
| `/music/upload?path=<relative>` | GET | Upload form for a library folder |
| `/music/upload` | POST | Upload an audio file to a library folder |
| `/music/serve?path=<relative>` | GET | Stream a file from the music library |
| `/material` | GET | Redirect to LMS material page (`http://<host-ip>:9000/material`) |
| `/<PlayerName>` | GET | Dynamic redirect per LMS player (e.g. `/Arne` → material page for that player) |
| `/` | GET | Redirect to LMS web UI (`http://<host-ip>:9000`) |

Player routes are registered at startup by querying the LMS JSON-RPC API (`/jsonrpc.js`, method `slim.request`, command `players 0`). Player names have a leading `Radio ` prefix stripped for the URL path.

## Configuration

Directories and server settings are loaded from **`config/config.txt`** at startup via `Config::General`:

```ini
<allowed_dirs images>
    directory   = /var/www/images/gallery1
    description = Images Directory
    showsubdirs = Yes
</allowed_dirs>

music_server_port = 9000
```

| Setting | Purpose |
|---------|---------|
| `allowed_dirs` blocks | Allowed upload/browse targets (`directory`, `description`, `showsubdirs`) |
| `music_server_port` | LMS port for redirects, player discovery, and library rescan (default `9000`) |
| `music_library_path` | Root path of the Lyrion Music Server library (default `/srv/music`) |
| `music_upload_max_mb` | Maximum music upload size in MB (default `100`) |
| `music_extensions` | Allowed audio file extensions for upload |
| `music_rescan_after_upload` | Trigger LMS rescan after upload (`Yes` / `No`) |

The app exits on startup if the config file is missing.

## Current capabilities

- Unified dark UI theme across all pages (`templates/layout.html`, `templates/style.html`)
- Shared navigation built from config directory descriptions
- Image upload with filename sanitization and 20 MB POST limit
- Upload into subdirectories when they exist (gallery directories only)
- Image gallery with thumbnail grid, filename filter, and subdirectory browsing
- Subdirectory creation from the gallery page
- Application version shown in footer (currently **1.0.0**, defined as `$VERSION` in `bin/app`)
- LMS player shortcuts registered dynamically at startup
- Music library browse (level-by-level) and upload to `/srv/music`
- Optional LMS library rescan after music upload

## Limits

- No authentication or authorization
- No delete, rename, or move operations
- No metadata database
- Music library browsing is level-by-level (not a full recursive tree)
- Player routes are only registered at process start; new LMS players require an app restart (or future reload mechanism)

## Architecture

```
bin/app                 CGI entrypoint, routing, config load, template rendering
lib/upload.pm           POST /upload handler
lib/serve.pm            GET /serve and /show handlers
lib/music.pm            Music library browse, upload, serve, LMS rescan
lib/CGI/Dispatch.pm     URL router
templates/              HTML fragments, CSS, and JavaScript
config/config.txt       Runtime configuration
apache/imageserver.conf Apache vhost example
deploy                  Copy script to /var/www/image-server/
```

### Template system

`ProcessFileandPrint()` in `bin/app` supports:

- `#include "path"` — inline another template file
- `#replace "variable"` — substitute from `$resp->{variables}{variable}`

All pages render through `render_page()` → `templates/layout.html`.

### UI theme

Dark somber palette, system sans-serif fonts, no external CSS/JS frameworks. Components include cards, buttons, forms, gallery grid, folder list, alerts, and breadcrumbs. Client-side JavaScript (`templates/app.js`) handles upload validation, directory hints, subdirectory selection, and gallery filtering.

## Deployment

Run the syntax check, then deploy:

```bash
./check
./deploy
```

`./check` runs `perl -c bin/app` (which also loads all required modules). `./deploy` runs `./check` automatically before copying files.

Copies `bin/app`, libraries, templates, and `config/config.txt` to `/var/www/image-server/`.

Host IP is detected from `eth0` at runtime for LMS redirects.

## Legacy / unrelated files

These are not used by the active image server routes in `bin/app`:

- `lib/app`, `lib/CommonApiHandler.pm` — separate microservice framework
- `lib/showimages.pm` — superseded by `lib/serve.pm`
- `bin/index.html`, `bin/test*.html`, `bin/test*.pl` — experiments and prototypes
- `bin/test7.pl`, `bin/dir.html` — music directory tree prototype (see `MusicPlan.md`)

## Related documentation

- **`CAnalysis.md`** — original UI consistency analysis and theme implementation notes
- **`MusicPlan.md`** — analysis of the music directory prototype and plan for LMS music library pages
