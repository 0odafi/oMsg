# oMsg Messenger Reboot

This repository was rebuilt into a messenger-first architecture (Telegram-style flow), focused on:

- phone number authentication with one-time code
- username system (set/update after sign-in)
- private chats and message timeline
- global realtime channel for message/status events
- in-app release checks (`/api/releases/latest/{platform}`)

Social-network modules are no longer part of the active runtime path.

## Stack

- Backend: FastAPI + SQLAlchemy
- Client: Flutter (Android / Windows / Web)
- Auth: JWT access + refresh rotation
- Realtime: WebSocket global user channel

## Quick Start (Backend)

```powershell
cd C:\Users\odafi\Desktop\oMsg
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -e .
Copy-Item .env.example .env
uvicorn app.main:app --reload
```

Open:

- [http://127.0.0.1:8000/docs](http://127.0.0.1:8000/docs)
- [http://127.0.0.1:8000/health](http://127.0.0.1:8000/health)

## SMS Provider Setup

### Send from your own phone number (Android gateway)

Use any Android SMS gateway app that exposes an HTTP endpoint and sends SMS via device SIM.
Configure backend:

```env
SMS_PROVIDER=android_gateway
SMS_GATEWAY_URL=https://your-gateway-endpoint/send
SMS_GATEWAY_API_KEY=your_secret_token
SMS_GATEWAY_AUTH_HEADER=Authorization
SMS_GATEWAY_AUTH_PREFIX=Bearer
SMS_GATEWAY_TO_FIELD=to
SMS_GATEWAY_MESSAGE_FIELD=message
```

Backend will POST JSON like:

```json
{
  "to": "+79001234567",
  "message": "oMsg API: 12345"
}
```

Requirements:
- your Android phone must stay online
- gateway app must have SMS permission
- endpoint must be reachable from backend server

### Twilio
Set in `.env`:

```env
SMS_PROVIDER=twilio
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_FROM=+1xxxxxxxxxx
# or TWILIO_MESSAGING_SERVICE_SID=MGxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

For automated tests / local fake mode:

```env
SMS_PROVIDER=test
AUTH_TEST_CODE=12345
```

## Quick Start (Flutter)

```powershell
cd C:\Users\odafi\Desktop\oMsg\omsg_app
flutter pub get
flutter run
```

To point app at server:

```powershell
flutter run --dart-define=OMSG_API_BASE_URL=https://volds.ru
```

## API (Core)

- `POST /api/auth/request-code`
- `POST /api/auth/verify-code`
- `POST /api/auth/refresh`
- `GET /api/auth/sessions`
- `DELETE /api/auth/sessions/{session_id}`
- `POST /api/auth/sessions/revoke-others`
- `GET /api/users/me`
- `PATCH /api/users/me`
- `GET /api/users/search?q=...`
- `GET /api/users/lookup?q=...`
- `GET /api/chats`
- `POST /api/chats/private?query=...`
- `PATCH /api/chats/{chat_id}/state` (archive / pin / folder)
- `GET /api/chats/{chat_id}/messages`
- `POST /api/chats/{chat_id}/messages`
- `GET /api/chats/messages/search?q=...`
- `WS /api/realtime/me/ws?token=<jwt>`
- `GET /api/releases/latest/{platform}?channel=stable`

## Tests

```powershell
pytest -q
```

## CI / Releases

- Manifest file: `releases/manifest.json`
- Release endpoint reads it: `/api/releases/latest/{platform}`
- Client checks updates from Settings tab.

Recommended release flow on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\odafi\Desktop\oMsg\scripts\create_release_tag.ps1 -Version 0.0.2+2
```

What it does:

- validates version format
- creates annotated git tag `v0.0.2+2`
- pushes the tag to `origin`
- GitHub Actions builds Android and Windows artifacts
- publishes the files into GitHub Release
- optionally uploads release files to your Ubuntu server and refreshes `releases/manifest.json`

Dry run:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\odafi\Desktop\oMsg\scripts\create_release_tag.ps1 -Version 0.0.2+2 -DryRun
```

Local manual builds also accept explicit version now:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\odafi\Desktop\oMsg\scripts\build_windows.ps1 -Version 0.0.2+2
powershell -ExecutionPolicy Bypass -File C:\Users\odafi\Desktop\oMsg\scripts\build_android.ps1 -Version 0.0.2+2 -BuildAab
```

## Server Update Mode

For Ubuntu deployment, the recommended mode is now git deploy:

- first-time conversion from copied folder:
  - `sudo bash /opt/omsg/deploy/ubuntu/enable_git_deploy.sh`
- regular updates:
  - `sudo bash /opt/omsg/deploy/ubuntu/update_git_deploy.sh`
- GitHub Actions backend deploy:
  - `.github/workflows/deploy-server.yml`
  - pushes on `main`/`master` can SSH into Ubuntu 24.04 and run `update_git_deploy.sh` automatically

Recommended production env:

- set `DATABASE_AUTO_MIGRATE=false` in `/etc/omsg/api.env`
- let deploy scripts run `alembic upgrade head` before service restart

Details: `deploy/ubuntu/README.md`


## Deployment Docs

- Server setup: `docs/server_setup.md`
- GitHub Actions build/release: `docs/github_actions_build.md`
- Docker Compose stack: `docker-compose.server.yml`
- CI workflows: `.github/workflows/ci.yml`, `.github/workflows/release-build.yml`, `.github/workflows/deploy-server.yml`
