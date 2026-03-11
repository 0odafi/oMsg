# oMsg Flutter Client

Cross-platform client for `Windows + Web + Android` connected to the oMsg backend.

## 1. Backend first

Start API server from the backend folder:

```powershell
cd C:\Users\odafi\Desktop\oMsg
python -m uvicorn app.main:app --reload
```

## 2. Flutter client run

```powershell
cd C:\Users\odafi\Desktop\oMsg\omsg_app
flutter pub get
flutter run -d windows
```

Or:

- `flutter run -d chrome`
- `flutter run -d android`

## 3. Base URL rules

- Windows/Web: `http://127.0.0.1:8000`
- Android emulator: `http://10.0.2.2:8000`

You can edit base URL on the auth screen.

## 4. Implemented screens

- Login / Register
- Chats (create chat, open chat, send message)
- Feed (publish post, load feed)
- Customization (theme + accent color)

## 5. Quality checks

```powershell
flutter analyze
flutter test
```

## 6. Release builds

From project root:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1 -Version 1.0.0+1
powershell -ExecutionPolicy Bypass -File scripts\build_android.ps1 -Version 1.0.0+1 -BuildAab
```

## 7. Online updates

Client checks:

- `GET /api/releases/latest/windows`
- `GET /api/releases/latest/android`

Manifest is stored in `releases/manifest.json`.
