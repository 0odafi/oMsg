# oMsg Rewrite Plan (Messenger-First)

## Product direction

oMsg should be a **messenger first** product.
Social features stay optional and should never dominate the main UX.

Primary rule:

- If a decision conflicts with "feels like a real messenger" vs "looks demo-ready", we choose messenger realism.
- Telegram parity is the floor, not the ceiling.
- Every future feature should be evaluated against three questions:
  - Does it improve daily messaging speed?
  - Does it improve reliability and sync correctness?
  - Does it improve privacy, control, or customization compared to Telegram?

## Current backend baseline

- Schema is versioned with Alembic.
- Startup uses migration bootstrap instead of runtime `create_all`.
- Chat list backend resolves latest message, unread count, and pinned/archive state in one query path.
- Realtime fanout is Redis-aware with safe local fallback when Redis is not configured.
- Global WS now supports cursor-based replay after reconnect.

## Current client baseline

- Phone-first authentication with OTP.
- Optional public username with Telegram-like rules.
- Public profile links and app deep links.
- Chat list with folders/filters baseline, swipe actions, archive/pin.
- Thread screen with reply/edit/delete/pin/reactions.
- Message history cursor pagination.
- File attachments, image attachments, voice messages.
- Camera/gallery/file entry points in composer.
- Attachment caching and download progress.
- Windows deep-link protocol and Android link handling baseline.

## What is still missing before we can honestly say "Telegram-class"

The current system is a good technical base, but it is **not yet Telegram-class**.
The biggest missing parts are not visual polish; they are protocol completeness,
state consistency, media quality, contact graph, calls, and operational maturity.

## Architecture targets

- Backend: FastAPI + PostgreSQL + Redis + WebSocket gateway
- Realtime: delivery/read receipts, typing, presence, reconnect protocol
- Storage: object storage (S3-compatible) for media/voice/files
- Mobile/Desktop/Web client: feature-based architecture (auth, dialogs, chat, calls, settings)
- Deploy: CI/CD with canary + stable channels, health checks, migration gates
- Database changes must ship through Alembic migrations, not runtime `create_all`
- Chat list APIs must be query-efficient: latest message, unread counters, and chat state in a single backend path

## Rewrite phases

### Phase 0 - Reliability foundation

- Remove any remaining "UI refresh hides protocol weakness" behavior.
- Introduce explicit sync contracts:
  - event ids
  - replay windows
  - gap detection
  - idempotent event application
- Add server-side integration tests for:
  - reconnect
  - duplicate delivery
  - out-of-order updates
  - unread counter correctness
  - message status transitions
- Introduce proper error taxonomy in API/WS:
  - validation
  - auth/session
  - permissions
  - rate limit
  - transient infra failure

### Phase 1 - Identity, auth, and account system

- Finish Telegram-style phone onboarding:
  - country picker
  - rate-limit UX
  - resend timer
  - wrong code and expired code UX
- Username flow:
  - stricter normalization/validation edge cases
  - instant availability check
  - deep link ownership expectations
  - collision-safe rename flow
- Profile model:
  - avatar upload
  - profile photo history
  - last seen / online visibility controls
  - bio / links / public profile sharing
- Device/session management:
  - active sessions list
  - revoke one session
  - revoke all other sessions
  - suspicious login detection

### Phase 2 - Core messaging model

- Dialog model (private/group/channel)
- Message model with status (`sent`, `delivered`, `read`)
- Cursor pagination (no full list fetches)
- Message edit/delete, pin, reply, forward

Must add:

- Server-generated stable ordering guarantees.
- Forward model with original attribution.
- Mentions and clickable entities.
- Service messages:
  - user joined
  - user left
  - photo changed
  - title changed
  - pinned message changed
- Scheduled messages.
- Silent messages.
- Drafts synced across devices.
- Per-chat message search with jump-to-message.
- Local anchor restoration when navigating from search result to thread.

### Phase 3 - Realtime transport

- Dedicated WS events: `message.new`, `message.update`, `message.read`, `typing`, `presence`
- Reliable reconnect with last event cursor
- Server-side fanout via Redis pub/sub
- Global per-user WS channel as the primary transport, not one socket per chat

Must add:

- Delivery ACK model from client to server.
- Batched replay for long disconnects.
- Push notification handoff when socket is unavailable.
- App foreground/background state aware delivery.
- Multi-device consistency:
  - read state sync
  - draft sync
  - reaction sync
  - pin/archive/mute sync
- Backpressure strategy for high-traffic accounts/channels.

### Phase 4 - Client architecture

- Split giant UI file into modules:
  - `core/` (config, theme, transport, error handling)
  - `features/auth`
  - `features/chats`
  - `features/messages`
  - `features/settings`
- Unified state management (Cubit/Bloc or Riverpod)
- Offline cache for dialogs/messages
- User appearance/settings state in providers, shared by the whole app

Must add:

- Remove remaining oversized presentation files.
- Introduce explicit repositories/services between UI and API.
- Add per-feature test coverage:
  - auth
  - chat list
  - thread
  - settings
  - profile
- Add background download/upload state layer.
- Add image/audio/video cache strategy with eviction policy.
- Add app lifecycle handling:
  - app resume sync
  - socket restore
  - stale draft recovery
  - failed upload retry queue

### Phase 5 - Telegram-level UX parity

- Native-like chat list and thread screen
- Pinned dialogs, unread counters, swipe actions
- Media preview, voice notes, file sending
- Polished typography, spacing, animation, skeleton loaders

Must add for parity:

- Chat list:
  - exact Telegram-style information density
  - better avatar system
  - verified badges / mute indicators / sent check marks
  - tabs/folders UX
  - unread badge behavior
- Thread UX:
  - quoted reply blocks closer to Telegram
  - grouped bubbles
  - date separators
  - unread separator
  - jump to bottom affordance
  - scroll restore after pagination/search jump
- Composer:
  - emoji/sticker/GIF panel
  - attachment sheet
  - camera shortcut
  - voice lock / cancel gesture
  - send-on-enter behavior for desktop
- Media:
  - full-screen image viewer
  - video preview/player
  - audio waveform for voice notes
  - thumbnail generation
  - upload progress per item
- Settings:
  - chat settings
  - notification settings
  - data/storage settings
  - language
  - devices
  - folders
  - privacy
- Contacts:
  - phonebook import
  - invite flow
  - recent people
  - username/phone hybrid discovery

### Phase 6 - Groups, channels, and moderation

- Group chats:
  - member list
  - roles and permissions
  - admin actions
  - invite links
  - join requests
- Supergroups/channels:
  - high-scale message fanout
  - read model optimizations
  - view counters
  - admin post controls
  - linked discussion chat
- Anti-abuse:
  - flood control
  - spam heuristics
  - temporary restrictions
  - media abuse controls
  - audit log for admin actions

### Phase 7 - Calls and live communication

- 1:1 voice calls
- 1:1 video calls
- group calls / live rooms
- screen sharing
- microphone / speaker routing
- call history
- degraded network behavior
- TURN/STUN infra and QoS monitoring

### Phase 8 - Security, privacy, and trust

- Session rotation and token hardening
- fine-grained privacy settings:
  - who can see phone
  - who can see last seen
  - who can add to groups
  - who can call
- block lists
- login alerts
- exportable security log
- optional E2EE mode / secret chat model if product direction keeps it
- encrypted media handling and safe local cache policy

### Phase 9 - Platform polish

- Android:
  - notification channels
  - inline reply
  - share intents
  - deep verified links
  - background service behavior
- Windows:
  - tray support
  - startup option
  - drag-drop attachments
  - proper single-instance deep-link handoff
  - installer/updater UX
- Web:
  - service worker strategy
  - media restrictions handling
  - browser notification behavior
  - session persistence strategy

### Phase 10 - Operations and scale

- Proper Redis deployment instead of fallback mode
- Object storage for media instead of local disk-only model
- CDN in front of public media where appropriate
- background jobs/queue:
  - thumbnail generation
  - cleanup
  - notification fanout
  - abuse processing
- observability:
  - tracing
  - metrics
  - log aggregation
  - alerting
- backups and restore drills
- migration safety checks in CI/CD
- release gates:
  - smoke checks
  - canary rollout
  - rollback path

## What we need specifically to surpass Telegram

- Better customization:
  - deeper theme controls
  - per-chat visual styles
  - per-folder notification logic
  - desktop-oriented layouts
- Better privacy transparency:
  - clearer session/device visibility
  - better control surfaces for who sees what
  - better export/logging for account activity
- Better self-hosting story:
  - easier deployment
  - reproducible infra
  - admin visibility
- Better cross-platform consistency:
  - fewer feature gaps between desktop/mobile/web
- Better productivity layer:
  - advanced search
  - saved filters
  - pinned workspaces/folders
  - power-user shortcuts
- Better update UX on desktop/mobile:
  - in-app release notes
  - delta-friendly update path where possible
- Optional AI-assisted features only if they remain local/private by design:
  - summarization
  - media transcription
  - chat organization
  - spam assistance

## Immediate backlog by priority

### P0 - must do next

1. Finish transport correctness:
   - replay batching
   - event gap detection
   - explicit read/delivery convergence
2. Finish message search:
   - in-chat search
   - navigation to result
   - highlighted jump state
3. Finish media stack:
   - video attachments
   - upload progress
   - robust cache/open flow for all file types
4. Finish thread architecture split:
   - extract composer
   - extract message bubble tree
   - extract media widgets
5. Finish settings/privacy/device flows.

### P1 - required for Telegram parity

1. Contacts sync and invite system.
2. Full folders UX.
3. Notification system parity.
4. Group/channel/admin feature set.
5. Multi-device session consistency.
6. Better desktop ergonomics.
7. Voice/video calling.

### P2 - required to exceed Telegram

1. Best-in-class customization.
2. Better self-hosting and admin controls.
3. Better privacy transparency.
4. Better desktop workflows and power-user tooling.
5. Optional private AI features that do not weaken trust.

## Immediate next sprint (what to do now)

1. Finish in-chat search and jump-to-message.
2. Add video attachments and proper media preview flows.
3. Introduce unified media/download manager.
4. Complete Redis-backed realtime deployment on server.
5. Add session/device management screens.
6. Break `chats_tab.dart` into smaller feature widgets and controllers.
