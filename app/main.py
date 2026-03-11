import asyncio
import html
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session

from app.api.deps import get_db
from app.api.routers import auth, chats, media, public, realtime, releases, users
from app.core.config import get_settings
from app.core.database import SessionLocal
from app.core.migrations import run_migrations
from app.realtime.fanout import realtime_fanout
from app.realtime.manager import is_user_online
from app.services.chat_service import chat_member_ids, dispatch_due_scheduled_messages, serialize_messages
from app.services.user_service import find_user_by_username

settings = get_settings()
logger = logging.getLogger(__name__)
SCHEDULED_MESSAGE_DISPATCH_INTERVAL_SECONDS = 0.25


async def _scheduled_message_dispatch_loop() -> None:
    while True:
        db = SessionLocal()
        try:
            delivered_messages = dispatch_due_scheduled_messages(
                db,
                limit=100,
                is_user_online=is_user_online,
            )
            for message in delivered_messages:
                serialized = serialize_messages(db, [message], user_id=message.sender_id)[0]
                await realtime_fanout.broadcast_chat_event(
                    chat_id=message.chat_id,
                    member_ids=chat_member_ids(db, message.chat_id),
                    payload={
                        "type": "message",
                        "chat_id": message.chat_id,
                        "message": serialized.model_dump(mode="json"),
                    },
                )
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("Scheduled message dispatch loop iteration failed.")
        finally:
            db.close()
            await asyncio.sleep(SCHEDULED_MESSAGE_DISPATCH_INTERVAL_SECONDS)


@asynccontextmanager
async def lifespan(_: FastAPI):
    if settings.database_auto_migrate:
        run_migrations()
    await realtime_fanout.startup()
    scheduled_dispatch_task = asyncio.create_task(_scheduled_message_dispatch_loop())
    try:
        yield
    finally:
        scheduled_dispatch_task.cancel()
        try:
            await scheduled_dispatch_task
        except asyncio.CancelledError:
            pass
        await realtime_fanout.shutdown()


app = FastAPI(
    title=settings.app_name,
    version="0.1.0",
    description="A messenger API with phone auth, chats and realtime events.",
    lifespan=lifespan,
)

if settings.cors_origin_list == ["*"]:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
else:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


app.include_router(auth.router, prefix="/api")
app.include_router(users.router, prefix="/api")
app.include_router(public.router, prefix="/api")
app.include_router(chats.router, prefix="/api")
app.include_router(media.router, prefix="/api")
app.include_router(releases.router, prefix="/api")
app.include_router(realtime.router, prefix="/api/realtime")

media_dir = Path(settings.media_root).resolve()
media_dir.mkdir(parents=True, exist_ok=True)
media_path = settings.media_url_path if settings.media_url_path.startswith("/") else f"/{settings.media_url_path}"
app.mount(media_path, StaticFiles(directory=media_dir), name="media")

frontend_dir = Path(__file__).resolve().parent.parent / "web"
if frontend_dir.exists():
    app.mount("/web", StaticFiles(directory=frontend_dir), name="web")


@app.get("/", include_in_schema=False)
def web_index():
    if frontend_dir.exists():
        return FileResponse(frontend_dir / "index.html")
    return {"message": "oMsg API is running. Open /docs for API schema."}


def _display_name(first_name: str, last_name: str, username: str) -> str:
    full_name = " ".join(
        part.strip() for part in [first_name, last_name] if part and part.strip()
    ).strip()
    return full_name or f"@{username}"


@app.get("/u/{username}", include_in_schema=False, response_class=HTMLResponse)
def public_profile_page(
    username: str,
    request: Request,
    db: Session = Depends(get_db),
) -> HTMLResponse:
    user = find_user_by_username(db, username)
    if not user or not user.username:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Public profile not found",
        )

    display_name = html.escape(
        _display_name(user.first_name, user.last_name, user.username)
    )
    handle = html.escape(f"@{user.username}")
    bio = html.escape(user.bio or "No bio yet.").replace("\n", "<br />")
    page_url = html.escape(str(request.url))
    open_app_url = html.escape(f"omsg://u/{user.username}")

    markup = f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>{display_name} on oMsg</title>
    <meta name="description" content="{display_name} {handle} on oMsg" />
    <meta property="og:title" content="{display_name} on oMsg" />
    <meta property="og:description" content="{handle}" />
    <meta property="og:type" content="profile" />
    <meta property="og:url" content="{page_url}" />
    <style>
      :root {{
        color-scheme: dark;
        --bg: #060812;
        --panel: rgba(19, 25, 44, 0.92);
        --panel-border: rgba(126, 149, 203, 0.18);
        --text: #f5f8ff;
        --muted: #92a1c3;
        --accent: #6f8cff;
        --accent-2: #7be0c5;
      }}
      * {{ box-sizing: border-box; }}
      body {{
        margin: 0;
        min-height: 100vh;
        display: grid;
        place-items: center;
        padding: 24px;
        font-family: "Segoe UI", system-ui, sans-serif;
        color: var(--text);
        background:
          radial-gradient(circle at top, rgba(111, 140, 255, 0.18), transparent 42%),
          radial-gradient(circle at bottom, rgba(123, 224, 197, 0.1), transparent 35%),
          var(--bg);
      }}
      .card {{
        width: min(100%, 520px);
        padding: 32px;
        border-radius: 28px;
        background: var(--panel);
        border: 1px solid var(--panel-border);
        box-shadow: 0 24px 80px rgba(0, 0, 0, 0.36);
      }}
      .avatar {{
        width: 88px;
        height: 88px;
        border-radius: 999px;
        display: grid;
        place-items: center;
        font-size: 34px;
        font-weight: 700;
        background: linear-gradient(135deg, var(--accent), var(--accent-2));
        color: #03101f;
      }}
      h1 {{ margin: 18px 0 8px; font-size: 40px; line-height: 1; }}
      .handle {{ color: var(--muted); font-size: 18px; }}
      .bio {{
        margin: 22px 0;
        padding: 18px;
        border-radius: 18px;
        background: rgba(255, 255, 255, 0.04);
        color: #d7dff5;
        line-height: 1.5;
      }}
      .actions {{
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 12px;
      }}
      a, button {{
        appearance: none;
        border: 0;
        border-radius: 16px;
        padding: 14px 16px;
        font-size: 15px;
        font-weight: 600;
        cursor: pointer;
        text-decoration: none;
        text-align: center;
      }}
      .primary {{ background: linear-gradient(135deg, var(--accent), #94a8ff); color: #081224; }}
      .secondary {{ background: rgba(255,255,255,0.06); color: var(--text); }}
      .note {{ margin-top: 14px; color: var(--muted); font-size: 14px; }}
      @media (max-width: 520px) {{
        .card {{ padding: 24px; border-radius: 24px; }}
        h1 {{ font-size: 32px; }}
        .actions {{ grid-template-columns: 1fr; }}
      }}
    </style>
  </head>
  <body>
    <main class="card">
      <div class="avatar">{html.escape(display_name[:1].upper())}</div>
      <h1>{display_name}</h1>
      <div class="handle">{handle}</div>
      <div class="bio">{bio}</div>
      <div class="actions">
        <a class="primary" href="{open_app_url}">Open in oMsg</a>
        <button class="secondary" type="button" onclick="navigator.clipboard.writeText('{page_url}')">Copy link</button>
      </div>
      <div class="note">If the app is not installed, copy {handle} or this link and open a private chat from oMsg.</div>
    </main>
  </body>
</html>"""
    return HTMLResponse(markup)
