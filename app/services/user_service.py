from __future__ import annotations

import re
from datetime import UTC, datetime, timedelta
from urllib.parse import urlparse

from sqlalchemy import and_, func, or_, select
from sqlalchemy.orm import Session, aliased

from app.models.chat import ChatMember
from app.models.user import (
    BlockedUser,
    Follow,
    PrivacyAudience,
    PrivacyRuleMode,
    PrivacySettingKey,
    User,
    UserDataSettings,
    UserPrivacyException,
    UserPrivacySettings,
)
from app.schemas.user import UserPublic

USERNAME_RE = re.compile(r"^[a-z][a-z0-9_]{4,31}$")
USERNAME_RULES_MESSAGE = (
    "Username format: 5-32 chars, start with a letter, use letters, numbers or underscore"
)
_ONLINE_WINDOW = timedelta(seconds=90)


def normalize_username(value: str) -> str:
    return value.strip().lstrip("@").lower()


def validate_username(value: str) -> bool:
    return bool(USERNAME_RE.fullmatch(value))


def normalize_phone(value: str) -> str:
    digits = "".join(char for char in value if char.isdigit())
    if digits.startswith("8") and len(digits) == 11:
        digits = f"7{digits[1:]}"
    if len(digits) == 10:
        digits = f"7{digits}"
    if len(digits) < 10 or len(digits) > 15:
        raise ValueError("Phone number format is invalid")
    return f"+{digits}"


def is_probable_phone(value: str) -> bool:
    digits = "".join(char for char in value if char.isdigit())
    return 10 <= len(digits) <= 15


def _phone_search_pattern(query: str) -> str | None:
    if not is_probable_phone(query):
        return None
    try:
        return f"%{normalize_phone(query).lstrip('+')}%"
    except ValueError:
        return None


def extract_lookup_query(value: str) -> str:
    cleaned = value.strip()
    if not cleaned:
        return ""

    if "://" not in cleaned:
        return cleaned

    parsed = urlparse(cleaned)
    path_parts = [part for part in parsed.path.split("/") if part]

    if parsed.netloc.lower() == "u" and path_parts:
        return path_parts[0]
    if len(path_parts) >= 2 and path_parts[0].lower() == "u":
        return path_parts[1]
    if path_parts:
        return path_parts[-1]
    return cleaned


def get_or_create_privacy_settings(db: Session, user_id: int) -> UserPrivacySettings:
    settings = db.scalar(select(UserPrivacySettings).where(UserPrivacySettings.user_id == user_id))
    if settings is not None:
        return settings

    settings = UserPrivacySettings(user_id=user_id)
    db.add(settings)
    db.commit()
    db.refresh(settings)
    return settings


def get_or_create_data_settings(db: Session, user_id: int) -> UserDataSettings:
    settings = db.scalar(select(UserDataSettings).where(UserDataSettings.user_id == user_id))
    if settings is not None:
        return settings

    settings = UserDataSettings(user_id=user_id)
    db.add(settings)
    db.commit()
    db.refresh(settings)
    return settings


def get_blocked_user_count(db: Session, user_id: int) -> int:
    return int(
        db.scalar(select(func.count(BlockedUser.id)).where(BlockedUser.blocker_id == user_id)) or 0
    )


def _has_shared_relationship(db: Session, owner_id: int, viewer_user_id: int) -> bool:
    if owner_id == viewer_user_id:
        return True

    membership_a = aliased(ChatMember)
    membership_b = aliased(ChatMember)
    shared_chat = db.scalar(
        select(membership_a.chat_id)
        .join(membership_b, membership_b.chat_id == membership_a.chat_id)
        .where(
            and_(
                membership_a.user_id == owner_id,
                membership_b.user_id == viewer_user_id,
            )
        )
        .limit(1)
    )
    if shared_chat is not None:
        return True

    shared_follow = db.scalar(
        select(Follow.id)
        .where(
            or_(
                and_(Follow.follower_id == owner_id, Follow.following_id == viewer_user_id),
                and_(Follow.follower_id == viewer_user_id, Follow.following_id == owner_id),
            )
        )
        .limit(1)
    )
    return shared_follow is not None


def _privacy_allows(
    audience: PrivacyAudience,
    *,
    owner_id: int,
    viewer_user_id: int | None,
    shared_relationship: bool,
    exception_mode: PrivacyRuleMode | None = None,
) -> bool:
    if viewer_user_id == owner_id:
        return True
    if exception_mode == PrivacyRuleMode.DISALLOW:
        return False
    if exception_mode == PrivacyRuleMode.ALLOW:
        return True
    if viewer_user_id is None:
        return audience == PrivacyAudience.EVERYONE
    if audience == PrivacyAudience.EVERYONE:
        return True
    if audience == PrivacyAudience.CONTACTS:
        return shared_relationship
    return False


def _is_blocked_pair(db: Session, user_a_id: int, user_b_id: int) -> bool:
    if user_a_id == user_b_id:
        return False
    return db.scalar(
        select(BlockedUser.id)
        .where(
            or_(
                and_(BlockedUser.blocker_id == user_a_id, BlockedUser.blocked_id == user_b_id),
                and_(BlockedUser.blocker_id == user_b_id, BlockedUser.blocked_id == user_a_id),
            )
        )
        .limit(1)
    ) is not None


def _privacy_exception_mode(
    db: Session,
    *,
    owner_id: int,
    setting_key: PrivacySettingKey,
    viewer_user_id: int | None,
) -> PrivacyRuleMode | None:
    if viewer_user_id is None or viewer_user_id == owner_id:
        return None

    return db.scalar(
        select(UserPrivacyException.mode)
        .where(
            and_(
                UserPrivacyException.user_id == owner_id,
                UserPrivacyException.setting_key == setting_key,
                UserPrivacyException.target_user_id == viewer_user_id,
            )
        )
        .limit(1)
    )


def can_view_phone(db: Session, owner: User, viewer_user_id: int | None) -> bool:
    if viewer_user_id == owner.id:
        return True
    if not owner.phone:
        return False
    settings = get_or_create_privacy_settings(db, owner.id)
    shared = _has_shared_relationship(db, owner.id, viewer_user_id) if viewer_user_id is not None else False
    return _privacy_allows(
        settings.phone_visibility,
        owner_id=owner.id,
        viewer_user_id=viewer_user_id,
        shared_relationship=shared,
        exception_mode=_privacy_exception_mode(
            db,
            owner_id=owner.id,
            setting_key=PrivacySettingKey.PHONE_VISIBILITY,
            viewer_user_id=viewer_user_id,
        ),
    )


def can_find_by_phone(db: Session, owner: User, viewer_user_id: int | None) -> bool:
    if viewer_user_id == owner.id:
        return True
    if not owner.phone:
        return False
    settings = get_or_create_privacy_settings(db, owner.id)
    shared = _has_shared_relationship(db, owner.id, viewer_user_id) if viewer_user_id is not None else False
    return _privacy_allows(
        settings.phone_search_visibility,
        owner_id=owner.id,
        viewer_user_id=viewer_user_id,
        shared_relationship=shared,
        exception_mode=_privacy_exception_mode(
            db,
            owner_id=owner.id,
            setting_key=PrivacySettingKey.PHONE_SEARCH_VISIBILITY,
            viewer_user_id=viewer_user_id,
        ),
    )


def can_view_last_seen(db: Session, owner: User, viewer_user_id: int | None) -> bool:
    if viewer_user_id == owner.id:
        return True
    settings = get_or_create_privacy_settings(db, owner.id)
    shared = _has_shared_relationship(db, owner.id, viewer_user_id) if viewer_user_id is not None else False
    return _privacy_allows(
        settings.last_seen_visibility,
        owner_id=owner.id,
        viewer_user_id=viewer_user_id,
        shared_relationship=shared,
        exception_mode=_privacy_exception_mode(
            db,
            owner_id=owner.id,
            setting_key=PrivacySettingKey.LAST_SEEN_VISIBILITY,
            viewer_user_id=viewer_user_id,
        ),
    )


def touch_last_seen(db: Session, user: User) -> None:
    now = datetime.now(UTC)
    if user.last_seen_at is not None:
        last_seen = user.last_seen_at if user.last_seen_at.tzinfo else user.last_seen_at.replace(tzinfo=UTC)
        if now - last_seen < timedelta(seconds=60):
            return
    user.last_seen_at = now
    db.add(user)
    db.commit()
    db.refresh(user)


def _format_last_seen_label(
    *,
    user: User,
    viewer_user_id: int | None,
    privacy_settings: UserPrivacySettings,
) -> tuple[bool, datetime | None, str | None]:
    now = datetime.now(UTC)
    last_seen = user.last_seen_at
    if last_seen is None:
        return False, None, None

    if last_seen.tzinfo is None:
        last_seen = last_seen.replace(tzinfo=UTC)
    is_online = now - last_seen <= _ONLINE_WINDOW
    if viewer_user_id == user.id:
        if is_online:
            return True, last_seen, "online"
        return False, last_seen, f"last seen at {last_seen.isoformat()}"

    if privacy_settings.show_approximate_last_seen:
        if is_online:
            return True, None, "online"
        delta = now - last_seen
        if delta <= timedelta(days=3):
            return False, None, "last seen recently"
        if delta <= timedelta(days=7):
            return False, None, "last seen within a week"
        if delta <= timedelta(days=30):
            return False, None, "last seen within a month"
        return False, None, "last seen a long time ago"

    if is_online:
        return True, last_seen, "online"
    return False, last_seen, f"last seen at {last_seen.isoformat()}"


def serialize_user_public(
    db: Session,
    user: User,
    *,
    viewer_user_id: int | None,
    include_private_fields: bool = False,
) -> UserPublic:
    viewer_is_self = include_private_fields or viewer_user_id == user.id
    privacy = get_or_create_privacy_settings(db, user.id)

    phone = user.phone if viewer_is_self or can_view_phone(db, user, viewer_user_id) else None
    is_online = False
    last_seen_at = None
    last_seen_label = None
    if viewer_is_self or can_view_last_seen(db, user, viewer_user_id):
        is_online, last_seen_at, last_seen_label = _format_last_seen_label(
            user=user,
            viewer_user_id=viewer_user_id,
            privacy_settings=privacy,
        )

    return UserPublic(
        id=user.id,
        username=user.username,
        phone=phone,
        first_name=user.first_name,
        last_name=user.last_name,
        bio=user.bio,
        avatar_url=user.avatar_url,
        is_online=is_online,
        last_seen_at=last_seen_at,
        last_seen_label=last_seen_label,
        created_at=user.created_at,
    )


def search_users(
    db: Session,
    query: str,
    limit: int = 20,
    *,
    viewer_user_id: int | None = None,
) -> list[User]:
    cleaned_query = extract_lookup_query(query)
    if not cleaned_query:
        return []

    normalized_username_query = normalize_username(cleaned_query)
    display_query = cleaned_query.lower().lstrip("@")
    pattern = f"%{display_query}%"
    username_pattern = f"%{normalized_username_query}%"
    phone_pattern = _phone_search_pattern(cleaned_query)
    phone_expression = (
        User.phone.ilike(phone_pattern)
        if phone_pattern is not None
        else User.phone.ilike("%__never_match__%")
    )

    statement = (
        select(User)
        .where(
            or_(
                User.username.ilike(username_pattern),
                User.first_name.ilike(pattern),
                User.last_name.ilike(pattern),
                phone_expression,
            )
        )
        .order_by(User.username.is_(None), User.username.asc(), User.first_name.asc(), User.id.asc())
        .limit(limit * 3)
    )
    users = list(db.scalars(statement).all())
    if phone_pattern is None:
        return users[:limit]

    visible: list[User] = []
    for user in users:
        if can_find_by_phone(db, user, viewer_user_id):
            visible.append(user)
        if len(visible) >= limit:
            break
    return visible


def find_user_by_phone_or_username(
    db: Session,
    query: str,
    *,
    viewer_user_id: int | None = None,
) -> User | None:
    cleaned_query = extract_lookup_query(query)
    if not cleaned_query:
        return None

    if is_probable_phone(cleaned_query):
        try:
            normalized_phone = normalize_phone(cleaned_query)
            by_phone = db.scalar(select(User).where(User.phone == normalized_phone))
            if by_phone and can_find_by_phone(db, by_phone, viewer_user_id):
                return by_phone
        except ValueError:
            pass

    normalized_username = normalize_username(cleaned_query)
    if not normalized_username:
        return None
    return db.scalar(select(User).where(User.username == normalized_username))


def find_user_by_username(db: Session, username: str) -> User | None:
    normalized_username = normalize_username(extract_lookup_query(username))
    if not normalized_username or not validate_username(normalized_username):
        return None
    return db.scalar(select(User).where(User.username == normalized_username))


def ensure_username_available(db: Session, username: str, current_user_id: int | None = None) -> None:
    existing = db.scalar(select(User).where(User.username == username))
    if existing and existing.id != current_user_id:
        raise ValueError("Username is already taken")


def ensure_private_messaging_allowed(db: Session, *, requester_id: int, target_user_id: int) -> None:
    if requester_id == target_user_id:
        return
    if _is_blocked_pair(db, requester_id, target_user_id):
        raise ValueError("Private messaging is unavailable because one of the users blocked the other")


def list_blocked_users(db: Session, blocker_id: int) -> list[BlockedUser]:
    return list(
        db.scalars(
            select(BlockedUser)
            .where(BlockedUser.blocker_id == blocker_id)
            .order_by(BlockedUser.created_at.desc(), BlockedUser.id.desc())
        ).all()
    )


def block_user(db: Session, *, blocker_id: int, blocked_id: int) -> BlockedUser:
    if blocker_id == blocked_id:
        raise ValueError("You cannot block yourself")
    target = db.scalar(select(User).where(User.id == blocked_id))
    if target is None:
        raise ValueError("User not found")
    existing = db.scalar(
        select(BlockedUser).where(
            and_(BlockedUser.blocker_id == blocker_id, BlockedUser.blocked_id == blocked_id)
        )
    )
    if existing is not None:
        return existing
    row = BlockedUser(blocker_id=blocker_id, blocked_id=blocked_id)
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def list_privacy_exceptions(
    db: Session,
    *,
    user_id: int,
    setting_key: PrivacySettingKey | None = None,
) -> list[UserPrivacyException]:
    statement = select(UserPrivacyException).where(UserPrivacyException.user_id == user_id)
    if setting_key is not None:
        statement = statement.where(UserPrivacyException.setting_key == setting_key)
    return list(
        db.scalars(
            statement.order_by(
                UserPrivacyException.setting_key.asc(),
                UserPrivacyException.mode.asc(),
                UserPrivacyException.created_at.desc(),
                UserPrivacyException.id.desc(),
            )
        ).all()
    )


def upsert_privacy_exception(
    db: Session,
    *,
    user_id: int,
    setting_key: PrivacySettingKey,
    mode: PrivacyRuleMode,
    target_user_id: int,
) -> UserPrivacyException:
    if user_id == target_user_id:
        raise ValueError("You cannot add yourself to privacy exceptions")
    target = db.scalar(select(User).where(User.id == target_user_id))
    if target is None:
        raise ValueError("User not found")

    row = db.scalar(
        select(UserPrivacyException).where(
            and_(
                UserPrivacyException.user_id == user_id,
                UserPrivacyException.setting_key == setting_key,
                UserPrivacyException.target_user_id == target_user_id,
            )
        )
    )
    if row is None:
        row = UserPrivacyException(
            user_id=user_id,
            setting_key=setting_key,
            target_user_id=target_user_id,
            mode=mode,
        )
    else:
        row.mode = mode

    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def remove_privacy_exception(
    db: Session,
    *,
    user_id: int,
    setting_key: PrivacySettingKey,
    target_user_id: int,
) -> bool:
    row = db.scalar(
        select(UserPrivacyException).where(
            and_(
                UserPrivacyException.user_id == user_id,
                UserPrivacyException.setting_key == setting_key,
                UserPrivacyException.target_user_id == target_user_id,
            )
        )
    )
    if row is None:
        return False
    db.delete(row)
    db.commit()
    return True


def unblock_user(db: Session, *, blocker_id: int, blocked_id: int) -> bool:
    row = db.scalar(
        select(BlockedUser).where(
            and_(BlockedUser.blocker_id == blocker_id, BlockedUser.blocked_id == blocked_id)
        )
    )
    if row is None:
        return False
    db.delete(row)
    db.commit()
    return True
