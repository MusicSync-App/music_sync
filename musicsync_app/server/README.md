# MusicSync server (updates + community themes)

FastAPI service for:

- **App updates**: `GET /api/manifest` returns the latest release's `version.json` and the current content revision.
- **Community themes**: users submit countries or photos, admins approve or reject them, and approved content is published to a public GitHub repo that the app downloads from directly (sha-pinned `raw.githubusercontent.com` URLs).

All persistent state lives in GitHub, because Render's free-tier disk is wiped on every restart:

| Env var | Repo | Visibility | Contents |
|---|---|---|---|
| `CONTENT_REPO` | e.g. `<org>/musicsync-content` | public | `index.json` + `photos/<sha256>.jpg` (approved) |
| `PENDING_REPO` | e.g. `<org>/musicsync-pending` | **private** | `submissions.json` (aggregate) + `submissions/<id>/meta.json` + `submissions/<id>/<n>.jpg` |
| `APP_REPO` | e.g. `<org>/music_sync` | public | GitHub Releases with `app-release.apk` + `version.json` |

Repo names are never hardcoded, so the repos can move to another owner or organization. When they do, update the three env vars on Render.

The old `musicsync_app/backend/` (yt-dlp) is unrelated dead code.

## Files

- `app.py`: FastAPI app and all endpoints (`create_app(settings, storage, userinfo)` is injectable for tests).
- `storage.py`: the `Storage` protocol, `MemoryStorage` (test fake), and `atomic_update` (optimistic read-modify-write with ≤3 retries).
- `github_storage.py`: GitHub implementation. Uses the Git Data API (blobs → tree → commit → fast-forward ref update), so each multi-file change is one commit. A rejected ref update (409/422) triggers a rebuild and retry.
- `auth.py`: Google access token → verified email (`/oauth2/v3/userinfo`), cached by sha256(token) for 10 minutes. Tokens are never logged.
- `images.py`: Pillow validation. Accepts JPEG, PNG and WEBP up to 64 MP; decompression bombs are rejected. EXIF orientation is applied and then all metadata is stripped. Images are resized so the long side is ≤1600 px and saved as JPEG q82.
- `validation.py`: meta/edit validation and the list of the app's built-in theme ids.
- `content.py`: pure functions that change `index.json` (approve/merge, delete theme or photo).

## Render setup

1. **Create the repos** (or transfer them):
   - `musicsync-content`, **public**. Create it with "Add a README". Commit an initial `index.json`:
     ```json
     {"version": 1, "updatedAt": "2026-01-01T00:00:00Z", "themes": []}
     ```
     The server creates `index.json` on the first approval if it is missing. Until then, `indexUrl` in the manifest returns 404, so seeding the file is cleaner.
   - `musicsync-pending`, **private**. Create it with "Add a README". If you leave it empty, the server initializes it on the first write.
2. **Create the fine-grained GitHub token**: GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token.
   - **Resource owner**: the account or organization that owns the repos. If the owner is an organization, the org must allow fine-grained tokens, and an org owner may need to approve the token.
   - **Repository access**: *Only select repositories*: `musicsync-content`, `musicsync-pending`, `music_sync`.
   - **Repository permissions**:
     - **Contents: Read and write**. Required for the content and pending repos. On `music_sync` the server only reads releases, but fine-grained tokens apply one permission set to all selected repos, so Contents is read and write everywhere. Release assets are covered by Contents.
     - **Metadata: Read-only**. This is mandatory and selected automatically.
     - Nothing else is needed.
   - **Expiration**: pick the longest allowed period and set a reminder. When the token expires, every write returns `502 storage_unavailable` and the manifest returns stale data or errors.
   - If you want `music_sync` read-only, create two tokens. The server takes only one token, so that setup is not supported. Since `music_sync` is public, an alternative is to leave it out of the token entirely; releases of public repos are readable without auth.
3. **Render**: Dashboard → New → **Blueprint** → select this GitHub repo. Render reads `render.yaml` at the repo root and creates the `musicsync-server` web service (free plan, `rootDir: musicsync_app/server`, health check `/health`).
4. **Fill these env vars** in the dashboard. They are marked `sync: false`, so Render asks for them:

   | Variable | Example value |
   |---|---|
   | `GITHUB_TOKEN` | the fine-grained token from step 2 |
   | `CONTENT_REPO` | `<org>/musicsync-content` |
   | `PENDING_REPO` | `<org>/musicsync-pending` |
   | `APP_REPO` | `<org>/music_sync` |
   | `ADMIN_EMAILS` | `eric.ratiu@gmail.com` (comma separated, case insensitive) |
   | `MAX_SUBMISSIONS_PER_DAY` | `5` (optional; pre-set in `render.yaml`) |
   | `GIT_BRANCH` | `main` (optional; the branch used in the content and pending repos) |
   | `PYTHON_VERSION` | `3.12.8` (pre-set) |

5. Check the deployment: `curl https://<service>.onrender.com/health` should return `{"ok":true}`, and `/api/manifest` should return `{"app": ..., "content": {...}}`.

The free plan spins down when idle, and the first request after that takes a cold start of roughly 30–60 s. The app is built to wait for it. Heavy imports (Pillow) are loaded lazily.

## Behaviour notes

- **Rate limit**: each user can make `MAX_SUBMISSIONS_PER_DAY` submissions per rolling 24 h. The count comes from `createdAt` and `submitterEmail` of submissions stored in the pending repo. This survives restarts because it is loaded from `submissions.json` on first use.
- **Locks**: one asyncio lock covers read-modify-write of `index.json`, and another covers the pending repo. This assumes a single instance, which is what the free plan runs.
- **Approve**: photos are copied to `photos/<sha256>.jpg` and `index.json` is updated in one commit to `CONTENT_REPO`. The submission is then marked approved in `PENDING_REPO` with a second commit.
  - `kind=country` merges into a non-builtin theme with the same `countryCode`, or creates `c_<cc>`.
  - `kind=photos` appends photos to `themeId`. If `themeId` is a built-in app theme that is not in the index yet, a `builtin: true` entry is created.
- **Built-in theme ids** are the keys of `appThemes` in `lib/themes/app_themes.dart`: `armenia`, `grecia`, `iran`, `turcia`, `azerbaidjan`, `kurdistan`, `bosnia`, `central asia`. The key `central asia` contains a space, so it is accepted as an explicit exception to `^[a-z0-9_]{1,40}$`. If you add a built-in theme to the app, also add it to `BUILTIN_THEMES` in `validation.py`.
- **Errors**: always JSON `{"error": "<code>", "message": "<Romanian text>"}`.

## Tests

```powershell
python -m venv .venv; .venv\Scripts\pip install -r requirements-dev.txt
.venv\Scripts\python -m pytest -q
```

The tests use `MemoryStorage` and a fake userinfo function, so they need no network. `tests/test_github_storage.py` checks the GitHub REST call sequence against `httpx.MockTransport`.

## Releasing the app (`musicsync_app/tools/release/release.ps1`)

```powershell
cd musicsync_app\tools\release
.\release.ps1 -Notes "Remedieri si teme noi"                          # bump +N only
.\release.ps1 -Notes "Versiune noua" -VersionName 1.2.0 -MinSupported 3
.\release.ps1 -Notes "test" -DryRun                                   # preview, changes nothing
```

The script runs on Windows PowerShell 5.1 and needs `flutter`, `gh` (authenticated with `gh auth login`) and `git`. It does the following:

1. **Resolves the target repo.** It uses `-Repo owner/repo` if given. Otherwise it parses `git remote get-url origin`, so it follows a repo transfer automatically.
2. **Bumps the version.** It increases `+N` in `pubspec.yaml`. `-VersionName X.Y.Z` also changes the name; without it the name stays the same.
3. **Sets `minSupported`.** It uses `-MinSupported`, or else the previous release's value, or else 1. This is the lowest `versionCode` that may keep running. The app forces older versions to update.
4. **Builds the APK** with `flutter build apk --release`. If the build fails, `pubspec.yaml` is restored.
5. **Writes `build/release/version.json`.** It contains `versionCode`, `versionName`, `apkUrl`, `sha256`, `size`, `notes`, `minSupported` and `publishedAt`. `apkUrl` is `https://github.com/<repo>/releases/download/v<name>+<code>/app-release.apk`, and `sha256` comes from `Get-FileHash`.
6. **Publishes the release.** It runs `gh release create v<name>+<code> app-release.apk version.json --repo <repo> --notes-file ...`.
7. **Reminds you to commit** the `pubspec.yaml` bump.

The server serves the new `version.json` within 5 minutes, which is the manifest cache lifetime.

`-DryRun` prints every planned action and writes a preview `build/release/version.json`. If no APK exists yet, the preview uses a placeholder hash and size. It does not change `pubspec.yaml`, build, or call `gh`.
