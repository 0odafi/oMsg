# Flutter Client Architecture (Phase 3)

The client is now split by features instead of a single monolithic UI file.

## Structure

```text
lib/src/
  api.dart
  models.dart
  realtime.dart
  session.dart
  app.dart
  core/ui/
    adaptive_size.dart
    app_theme.dart
  features/
    auth/presentation/auth_screen.dart
    home/presentation/home_shell.dart
    chats/presentation/chats_tab.dart
    contacts/presentation/contacts_tab.dart
    settings/presentation/settings_tab.dart
    profile/presentation/profile_tab.dart
```

## Notes

- `app.dart` now only bootstraps session/theme and routes to Auth/Home.
- `home_shell.dart` composes tabs and bottom navigation.
- Chat realtime/reconnect logic remains in `features/chats/presentation/chats_tab.dart`.
- Shared UI primitives are in `core/ui`.
- Offline cache is enabled for dialogs and message timelines via
  `features/chats/data/chats_local_cache.dart` (`SharedPreferences`).
- Chat drafts are cached locally via
  `features/chats/data/chat_drafts_local_cache.dart`.
- Chats/messages state is managed with `Riverpod` view-models in
  `features/chats/application/chat_view_models.dart`.
- Appearance state is managed with `Riverpod` in
  `features/settings/application/app_preferences.dart` and persisted via
  `features/settings/data/app_preferences_store.dart`.
- App-wide theme, chat background, bubble colors, message scale, and compact
  inbox density now read from a single appearance model in `core/ui/app_appearance.dart`.
- Realtime client now persists the latest WS cursor and resumes from it after
  reconnect via `core/realtime/realtime_cursor_store.dart`.

## Review Takeaways In Progress

- Replace runtime table creation with Alembic migrations and enforce migration
  gates during deploy.
- Optimize chat list endpoints so last message, unread count, and pinned/archive
  state are resolved in one query path instead of client-side stitching.
- Keep realtime on a global user WebSocket and move server fanout to Redis
  pub/sub.
- Continue moving non-chat state (`auth`, `profile`) to providers.

## Next step

- Move auth/profile state to providers and add integration tests for view-models.
