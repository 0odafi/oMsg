from datetime import UTC, datetime, timedelta

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.database import SessionLocal
from app.core.security import decode_access_token
from app.models.user import RefreshToken, User

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login")
_SESSION_TOUCH_INTERVAL = timedelta(minutes=5)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def _session_is_active(session_row: RefreshToken | None) -> bool:
    if session_row is None:
        return False
    now = datetime.now(UTC)
    if session_row.revoked_at is not None:
        return False
    expires_at = session_row.expires_at
    if expires_at.tzinfo is None:
        now = now.replace(tzinfo=None)
    return expires_at > now


def _touch_session_if_needed(db: Session, session_row: RefreshToken | None) -> None:
    if session_row is None:
        return
    now = datetime.now(UTC)
    last_used_at = session_row.last_used_at
    if last_used_at is not None:
        if last_used_at.tzinfo is None:
            now = now.replace(tzinfo=None)
        if now - last_used_at < _SESSION_TOUCH_INTERVAL:
            return
    session_row.last_used_at = now
    db.add(session_row)
    db.commit()


def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db),
) -> User:
    credentials_error = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = decode_access_token(token)
        user_id = int(payload.get("sub", ""))
        session_id = payload.get("sid")
        session_id = int(session_id) if session_id is not None else None
    except Exception as exc:
        raise credentials_error from exc

    user = db.scalar(select(User).where(User.id == user_id))
    if not user:
        raise credentials_error

    if session_id is not None:
        session_row = db.scalar(select(RefreshToken).where(RefreshToken.id == session_id))
        if session_row is None or session_row.user_id != user.id or not _session_is_active(session_row):
            raise credentials_error
        _touch_session_if_needed(db, session_row)
    return user


def get_current_session(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db),
) -> RefreshToken | None:
    credentials_error = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = decode_access_token(token)
        session_id = payload.get("sid")
        session_id = int(session_id) if session_id is not None else None
    except Exception as exc:
        raise credentials_error from exc

    if session_id is None:
        return None

    session_row = db.scalar(select(RefreshToken).where(RefreshToken.id == session_id))
    if session_row is None or not _session_is_active(session_row):
        raise credentials_error
    _touch_session_if_needed(db, session_row)
    return session_row


def get_current_user_from_raw_token(token: str, db: Session) -> User:
    try:
        payload = decode_access_token(token)
        user_id = int(payload.get("sub", ""))
        session_id = payload.get("sid")
        session_id = int(session_id) if session_id is not None else None
    except Exception as exc:
        raise ValueError("Invalid token") from exc

    user = db.scalar(select(User).where(User.id == user_id))
    if not user:
        raise ValueError("User not found")

    if session_id is not None:
        session_row = db.scalar(select(RefreshToken).where(RefreshToken.id == session_id))
        if session_row is None or session_row.user_id != user.id or not _session_is_active(session_row):
            raise ValueError("Session expired")
        _touch_session_if_needed(db, session_row)
    return user
