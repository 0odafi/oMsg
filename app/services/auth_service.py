from dataclasses import dataclass
import hashlib
import re
import secrets
from datetime import UTC, datetime, timedelta

from sqlalchemy import and_, delete, or_, select
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.core.security import (
    create_access_token,
    generate_refresh_token,
    hash_password,
    hash_refresh_token,
    verify_password,
)
from app.models.user import PhoneLoginCode, RefreshToken, User
from app.schemas.auth import (
    AuthSessionOut,
    PhoneCodeResponse,
    PhoneCodeVerifyRequest,
    RegisterRequest,
    TokenResponse,
)
from app.schemas.user import UserPublic
from app.services.user_service import (
    USERNAME_RULES_MESSAGE,
    is_probable_phone,
    normalize_phone,
    normalize_username,
    validate_username,
)
from app.services.sms_service import send_login_code


@dataclass(frozen=True, slots=True)
class ClientContext:
    device_name: str | None = None
    platform: str | None = None
    user_agent: str | None = None
    ip_address: str | None = None


_PLATFORM_PATTERNS: tuple[tuple[str, str], ...] = (
    ("android", "Android"),
    ("iphone", "iPhone"),
    ("ipad", "iPad"),
    ("ios", "iOS"),
    ("windows", "Windows"),
    ("mac os", "macOS"),
    ("macintosh", "macOS"),
    ("linux", "Linux"),
    ("web", "Web"),
)


def _now_like(reference: datetime | None = None) -> datetime:
    now = datetime.now(UTC)
    if reference is not None and reference.tzinfo is None:
        return now.replace(tzinfo=None)
    return now


def _code_hash(phone: str, code: str) -> str:
    return hashlib.sha256(f"{phone}:{code}".encode("utf-8")).hexdigest()


def _synthetic_email(seed: str) -> str:
    token = secrets.token_hex(4)
    safe_seed = re.sub(r"[^a-z0-9]+", "", normalize_username(seed))
    if not safe_seed:
        safe_seed = f"user{secrets.token_hex(2)}"
    return f"{safe_seed}.{token}@phone.omsg.local"


def _clean_text(value: str | None, max_length: int) -> str | None:
    if value is None:
        return None
    cleaned = value.strip()
    if not cleaned:
        return None
    return cleaned[:max_length]


def _detect_platform(explicit_platform: str | None, user_agent: str | None) -> str | None:
    platform = _clean_text(explicit_platform, 40)
    if platform is not None:
        normalized = platform.lower()
        for raw_token, label in _PLATFORM_PATTERNS:
            if raw_token in normalized:
                return label
        return platform

    normalized_agent = (user_agent or "").lower()
    for raw_token, label in _PLATFORM_PATTERNS:
        if raw_token in normalized_agent:
            return label
    return None


def _default_device_name(platform: str | None) -> str | None:
    if platform is None:
        return None
    return f"oMsg {platform}"


def build_client_context(
    *,
    user_agent: str | None = None,
    ip_address: str | None = None,
    platform: str | None = None,
    device_name: str | None = None,
) -> ClientContext:
    cleaned_user_agent = _clean_text(user_agent, 255)
    detected_platform = _detect_platform(platform, cleaned_user_agent)
    cleaned_device_name = _clean_text(device_name, 120) or _default_device_name(detected_platform)
    cleaned_ip = _clean_text(ip_address, 64)
    return ClientContext(
        device_name=cleaned_device_name,
        platform=detected_platform,
        user_agent=cleaned_user_agent,
        ip_address=cleaned_ip,
    )


def _merge_client_context(existing: RefreshToken, incoming: ClientContext | None) -> ClientContext:
    context = incoming or ClientContext()
    platform = context.platform or _clean_text(existing.platform, 40)
    return ClientContext(
        device_name=context.device_name or _clean_text(existing.device_name, 120) or _default_device_name(platform),
        platform=platform,
        user_agent=context.user_agent or _clean_text(existing.user_agent, 255),
        ip_address=context.ip_address or _clean_text(existing.ip_address, 64),
    )


def _cleanup_phone_codes(db: Session, now: datetime) -> None:
    db.execute(
        delete(PhoneLoginCode).where(
            or_(
                PhoneLoginCode.expires_at <= now,
                PhoneLoginCode.is_consumed.is_(True),
            )
        )
    )


def _resolve_login_code() -> str:
    settings = get_settings()
    test_code = (settings.auth_test_code or "").strip()
    if test_code:
        return test_code

    length = max(4, min(settings.login_code_length, 8))
    low = 10 ** (length - 1)
    span = 9 * low
    return f"{secrets.randbelow(span) + low}"


def request_phone_login_code(db: Session, phone: str) -> PhoneCodeResponse:
    settings = get_settings()
    normalized_phone = normalize_phone(phone)
    now = _now_like()
    _cleanup_phone_codes(db, now)

    expire_seconds = max(60, settings.login_code_expire_seconds)
    code = _resolve_login_code()
    raw_code_token = generate_refresh_token()
    db.add(
        PhoneLoginCode(
            phone=normalized_phone,
            code_token_hash=hash_refresh_token(raw_code_token),
            code_hash=_code_hash(normalized_phone, code),
            expires_at=now + timedelta(seconds=expire_seconds),
        )
    )

    registered_user = db.scalar(select(User).where(User.phone == normalized_phone))
    try:
        send_login_code(phone=normalized_phone, code=code)
    except ValueError:
        db.rollback()
        raise

    db.commit()
    return PhoneCodeResponse(
        phone=normalized_phone,
        code_token=raw_code_token,
        expires_in_seconds=expire_seconds,
        is_registered=registered_user is not None,
    )


def verify_phone_login_code(db: Session, payload: PhoneCodeVerifyRequest) -> tuple[User, bool]:
    normalized_phone = normalize_phone(payload.phone)
    token_hash = hash_refresh_token(payload.code_token)
    now = _now_like()
    _cleanup_phone_codes(db, now)

    code_session = db.scalar(
        select(PhoneLoginCode).where(
            and_(
                PhoneLoginCode.phone == normalized_phone,
                PhoneLoginCode.code_token_hash == token_hash,
            )
        )
    )
    if not code_session:
        raise ValueError("Verification session not found. Request a new code.")
    now = _now_like(code_session.expires_at)
    if code_session.expires_at <= now:
        raise ValueError("Code expired. Request a new code.")
    if code_session.is_consumed:
        raise ValueError("Code already used. Request a new one.")
    settings = get_settings()
    max_attempts = max(1, settings.login_code_max_attempts)
    if code_session.attempts >= max_attempts:
        raise ValueError("Too many attempts. Request a new code.")

    received_code = payload.code.strip()
    if _code_hash(normalized_phone, received_code) != code_session.code_hash:
        code_session.attempts += 1
        db.add(code_session)
        db.commit()
        raise ValueError("Invalid code")

    code_session.is_consumed = True
    code_session.consumed_at = now
    db.add(code_session)

    user = db.scalar(select(User).where(User.phone == normalized_phone))
    created = False
    if user is None:
        first_name = (payload.first_name or "").strip()
        last_name = (payload.last_name or "").strip()
        user = User(
            username=None,
            phone=normalized_phone,
            first_name=first_name,
            last_name=last_name,
            email=_synthetic_email(normalized_phone),
            password_hash=hash_password(generate_refresh_token()),
        )
        db.add(user)
        created = True
    else:
        if not user.first_name and payload.first_name:
            user.first_name = payload.first_name.strip()
        if not user.last_name and payload.last_name:
            user.last_name = payload.last_name.strip()
        if not user.phone:
            user.phone = normalized_phone
        db.add(user)

    db.commit()
    db.refresh(user)
    return user, created


def register_user(db: Session, payload: RegisterRequest) -> User:
    normalized_username = normalize_username(payload.username)
    if not validate_username(normalized_username):
        raise ValueError(USERNAME_RULES_MESSAGE)

    existing = db.scalar(
        select(User).where(or_(User.username == normalized_username, User.email == payload.email))
    )
    if existing:
        raise ValueError("Username or email already exists")

    user = User(
        username=normalized_username,
        email=payload.email,
        password_hash=hash_password(payload.password),
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def authenticate_user(db: Session, login: str, password: str) -> User | None:
    normalized_login = normalize_username(login)
    criteria = [User.username == normalized_login, User.email == login]
    if is_probable_phone(login):
        try:
            criteria.append(User.phone == normalize_phone(login))
        except ValueError:
            pass

    user = db.scalar(select(User).where(or_(*criteria)))
    if not user:
        return None
    if not verify_password(password, user.password_hash):
        return None
    return user


def _issue_refresh_token(
    db: Session,
    *,
    user_id: int,
    client_context: ClientContext | None = None,
    session_key: str | None = None,
) -> tuple[RefreshToken, str]:
    settings = get_settings()
    raw_token = generate_refresh_token()
    hashed_token = hash_refresh_token(raw_token)
    now = _now_like()
    expires_at = now + timedelta(days=settings.refresh_token_expire_days)
    context = client_context or ClientContext()

    token_row = RefreshToken(
        user_id=user_id,
        session_key=session_key or secrets.token_hex(16),
        token_hash=hashed_token,
        device_name=context.device_name,
        platform=context.platform,
        user_agent=context.user_agent,
        ip_address=context.ip_address,
        expires_at=expires_at,
        last_used_at=now,
    )
    db.add(token_row)
    db.flush()
    return token_row, raw_token


def build_token_response(
    db: Session,
    user: User,
    *,
    needs_profile_setup: bool = False,
    client_context: ClientContext | None = None,
) -> TokenResponse:
    session_row, refresh_token = _issue_refresh_token(
        db,
        user_id=user.id,
        client_context=client_context,
    )
    access_token = create_access_token(str(user.id), session_id=session_row.id)
    user.last_seen_at = _now_like(user.last_seen_at)
    db.add(user)
    db.commit()
    db.refresh(user)
    return TokenResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        needs_profile_setup=needs_profile_setup,
        user=UserPublic.model_validate(user),
    )


def rotate_refresh_token(
    db: Session,
    refresh_token: str,
    *,
    client_context: ClientContext | None = None,
) -> TokenResponse:
    token_hash = hash_refresh_token(refresh_token)
    stored_token = db.scalar(select(RefreshToken).where(RefreshToken.token_hash == token_hash))
    if not stored_token:
        raise ValueError("Invalid refresh token")
    now = _now_like(stored_token.expires_at)
    if stored_token.revoked_at is not None or stored_token.expires_at <= now:
        raise ValueError("Refresh token expired or revoked")

    user = db.scalar(select(User).where(and_(User.id == stored_token.user_id, User.is_active.is_(True))))
    if not user:
        raise ValueError("User not found or inactive")

    stored_token.revoked_at = now
    stored_token.last_used_at = now
    db.add(stored_token)

    merged_context = _merge_client_context(stored_token, client_context)
    next_session_row, new_refresh_token = _issue_refresh_token(
        db,
        user_id=user.id,
        client_context=merged_context,
        session_key=stored_token.session_key,
    )
    access_token = create_access_token(str(user.id), session_id=next_session_row.id)
    db.commit()
    db.refresh(user)
    return TokenResponse(
        access_token=access_token,
        refresh_token=new_refresh_token,
        user=UserPublic.model_validate(user),
    )


def revoke_refresh_token(db: Session, refresh_token: str) -> bool:
    token_hash = hash_refresh_token(refresh_token)
    stored_token = db.scalar(select(RefreshToken).where(RefreshToken.token_hash == token_hash))
    if not stored_token:
        return False
    if stored_token.revoked_at is not None:
        return True

    stored_token.revoked_at = _now_like(stored_token.created_at)
    db.add(stored_token)
    db.commit()
    return True


def list_active_sessions(
    db: Session,
    *,
    user_id: int,
    current_session_id: int | None = None,
) -> list[AuthSessionOut]:
    now = _now_like()
    rows = list(
        db.scalars(
            select(RefreshToken)
            .where(
                and_(
                    RefreshToken.user_id == user_id,
                    RefreshToken.revoked_at.is_(None),
                    RefreshToken.expires_at > now,
                )
            )
            .order_by(RefreshToken.last_used_at.desc(), RefreshToken.created_at.desc())
        ).all()
    )

    deduped: list[AuthSessionOut] = []
    seen_keys: set[str] = set()
    for row in rows:
        session_key = (row.session_key or "").strip() or f"legacy-{row.id}"
        if session_key in seen_keys:
            continue
        seen_keys.add(session_key)
        deduped.append(
            AuthSessionOut(
                session_id=session_key,
                device_name=row.device_name,
                platform=row.platform,
                user_agent=row.user_agent,
                ip_address=row.ip_address,
                created_at=row.created_at,
                last_used_at=row.last_used_at,
                expires_at=row.expires_at,
                is_current=current_session_id is not None and row.id == current_session_id,
            )
        )
    return deduped


def revoke_session_by_key(
    db: Session,
    *,
    user_id: int,
    session_key: str,
    current_session_key: str | None = None,
) -> bool:
    normalized_key = session_key.strip()
    if not normalized_key:
        return False
    if current_session_key is not None and normalized_key == current_session_key:
        raise ValueError("Use logout to close the current session")

    rows = list(
        db.scalars(
            select(RefreshToken).where(
                and_(
                    RefreshToken.user_id == user_id,
                    RefreshToken.session_key == normalized_key,
                    RefreshToken.revoked_at.is_(None),
                )
            )
        ).all()
    )
    if not rows:
        return False

    for row in rows:
        row.revoked_at = _now_like(row.expires_at)
        row.last_used_at = _now_like(row.last_used_at)
        db.add(row)
    db.commit()
    return True


def revoke_other_sessions(
    db: Session,
    *,
    user_id: int,
    current_session_key: str | None,
) -> int:
    if current_session_key is None or not current_session_key.strip():
        return 0

    rows = list(
        db.scalars(
            select(RefreshToken).where(
                and_(
                    RefreshToken.user_id == user_id,
                    RefreshToken.revoked_at.is_(None),
                    RefreshToken.session_key != current_session_key,
                )
            )
        ).all()
    )
    if not rows:
        return 0

    revoked_keys = {(row.session_key or "").strip() or f"legacy-{row.id}" for row in rows}
    for row in rows:
        row.revoked_at = _now_like(row.expires_at)
        row.last_used_at = _now_like(row.last_used_at)
        db.add(row)
    db.commit()
    return len(revoked_keys)
