# oMsg step 7 report

## What was added

### 1. Optimistic sending + local outbox

The client chat thread now has a real local outbox layer:

- outgoing messages are inserted immediately into the timeline
- each outgoing message keeps `client_message_id`
- local temporary message IDs are used until the server confirms the message
- pending messages are persisted locally and restored after app restart
- failed sends stay in the chat with a retry path instead of disappearing
- server-confirmed messages replace optimistic local copies by `client_message_id`

This is the foundation for retry-safe sending without duplicate messages.

### 2. Better queued-message UX

- queued or failed messages now show local status markers
- long-press on a failed queued message gives `Retry send`
- long-press on a queued message gives `Remove queued message`
- deleting a local queued message does not call the server
- websocket `ready` now triggers an outbox flush after reconnect

### 3. Build and deployment infrastructure

Added:

- `.github/workflows/ci.yml`
- `.github/workflows/release-build.yml`
- `Dockerfile`
- `.dockerignore`
- `docker-compose.server.yml`
- `docs/server_setup.md`
- `docs/github_actions_build.md`

What this gives:

- backend test job in GitHub Actions
- Flutter smoke build in CI
- Windows desktop build artifact in CI
- tag-based release workflow for Android APK + Windows ZIP + GitHub Release
- documented server setup path for Ubuntu/systemd and Docker Compose

## Backend verification

Executed locally in the container:

```bash
pytest -q
```

Result:

- `23 passed`

## Important notes

- Flutter SDK is not available in this container, so the Flutter project was not fully built here.
- Client-side Dart changes were done against the actual project structure and API contracts.
- GitHub Actions workflows were added to move real Flutter compilation into CI where Windows and Flutter runners are available.

## Files most relevant in this step

- `omsg_app/lib/src/features/chats/application/chat_view_models.dart`
- `omsg_app/lib/src/features/chats/data/chats_local_cache.dart`
- `omsg_app/lib/src/features/chats/presentation/chats_tab.dart`
- `.github/workflows/ci.yml`
- `.github/workflows/release-build.yml`
- `docs/server_setup.md`
- `docs/github_actions_build.md`
- `docker-compose.server.yml`
