from datetime import UTC, datetime
from enum import Enum
from typing import TYPE_CHECKING

from sqlalchemy import Boolean, DateTime, Enum as SqlEnum, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base

if TYPE_CHECKING:
    from app.models.chat import Chat


class PrivacyAudience(str, Enum):
    EVERYONE = "everyone"
    CONTACTS = "contacts"
    NOBODY = "nobody"


class PrivacySettingKey(str, Enum):
    PHONE_VISIBILITY = "phone_visibility"
    PHONE_SEARCH_VISIBILITY = "phone_search_visibility"
    LAST_SEEN_VISIBILITY = "last_seen_visibility"
    ALLOW_GROUP_INVITES = "allow_group_invites"


class PrivacyRuleMode(str, Enum):
    ALLOW = "allow"
    DISALLOW = "disallow"


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True, index=True)
    username: Mapped[str | None] = mapped_column(String(40), unique=True, index=True, nullable=True)
    uid: Mapped[str | None] = mapped_column(String(40), unique=True, index=True, nullable=True)
    phone: Mapped[str | None] = mapped_column(String(24), unique=True, index=True, nullable=True)
    first_name: Mapped[str] = mapped_column(String(80), default="", nullable=False)
    last_name: Mapped[str] = mapped_column(String(80), default="", nullable=False)
    email: Mapped[str] = mapped_column(String(120), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(256))
    bio: Mapped[str] = mapped_column(Text, default="", nullable=False)
    avatar_url: Mapped[str | None] = mapped_column(String(500), nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(UTC),
        onupdate=lambda: datetime.now(UTC),
    )

    owned_chats: Mapped[list["Chat"]] = relationship(back_populates="owner")
    refresh_tokens: Mapped[list["RefreshToken"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )
    privacy_settings: Mapped["UserPrivacySettings | None"] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
        uselist=False,
    )
    data_settings: Mapped["UserDataSettings | None"] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
        uselist=False,
    )
    blocked_users: Mapped[list["BlockedUser"]] = relationship(
        back_populates="blocker",
        cascade="all, delete-orphan",
        foreign_keys="BlockedUser.blocker_id",
    )
    blocked_by_users: Mapped[list["BlockedUser"]] = relationship(
        back_populates="blocked",
        cascade="all, delete-orphan",
        foreign_keys="BlockedUser.blocked_id",
    )
    privacy_exceptions: Mapped[list["UserPrivacyException"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
        foreign_keys="UserPrivacyException.user_id",
    )


class Follow(Base):
    __tablename__ = "follows"
    __table_args__ = (UniqueConstraint("follower_id", "following_id", name="uq_follow_pair"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    follower_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    following_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    session_key: Mapped[str] = mapped_column(String(64), index=True)
    token_hash: Mapped[str] = mapped_column(String(128), unique=True, index=True)
    device_name: Mapped[str | None] = mapped_column(String(120), nullable=True)
    platform: Mapped[str | None] = mapped_column(String(40), nullable=True)
    user_agent: Mapped[str | None] = mapped_column(String(255), nullable=True)
    ip_address: Mapped[str | None] = mapped_column(String(64), nullable=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    user: Mapped["User"] = relationship(back_populates="refresh_tokens")


class PhoneLoginCode(Base):
    __tablename__ = "phone_login_codes"

    id: Mapped[int] = mapped_column(primary_key=True)
    phone: Mapped[str] = mapped_column(String(24), index=True)
    code_token_hash: Mapped[str] = mapped_column(String(128), unique=True, index=True)
    code_hash: Mapped[str] = mapped_column(String(128))
    attempts: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    is_consumed: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class UserPrivacySettings(Base):
    __tablename__ = "user_privacy_settings"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"),
        unique=True,
        index=True,
    )
    phone_visibility: Mapped[PrivacyAudience] = mapped_column(
        SqlEnum(PrivacyAudience),
        default=PrivacyAudience.EVERYONE,
        nullable=False,
    )
    phone_search_visibility: Mapped[PrivacyAudience] = mapped_column(
        SqlEnum(PrivacyAudience),
        default=PrivacyAudience.EVERYONE,
        nullable=False,
    )
    last_seen_visibility: Mapped[PrivacyAudience] = mapped_column(
        SqlEnum(PrivacyAudience),
        default=PrivacyAudience.EVERYONE,
        nullable=False,
    )
    show_approximate_last_seen: Mapped[bool] = mapped_column(
        Boolean,
        default=True,
        nullable=False,
    )
    allow_group_invites: Mapped[PrivacyAudience] = mapped_column(
        SqlEnum(PrivacyAudience),
        default=PrivacyAudience.EVERYONE,
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(UTC),
        onupdate=lambda: datetime.now(UTC),
    )

    user: Mapped["User"] = relationship(back_populates="privacy_settings")


class UserDataSettings(Base):
    __tablename__ = "user_data_settings"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"),
        unique=True,
        index=True,
    )
    keep_media_days: Mapped[int] = mapped_column(Integer, default=30, nullable=False)
    storage_limit_mb: Mapped[int] = mapped_column(Integer, default=2048, nullable=False)
    auto_download_photos: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    auto_download_videos: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    auto_download_music: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    auto_download_files: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    default_auto_delete_seconds: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(UTC),
        onupdate=lambda: datetime.now(UTC),
    )

    user: Mapped["User"] = relationship(back_populates="data_settings")


class UserPrivacyException(Base):
    __tablename__ = "user_privacy_exceptions"
    __table_args__ = (
        UniqueConstraint(
            "user_id",
            "setting_key",
            "target_user_id",
            name="uq_user_privacy_exception",
        ),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    setting_key: Mapped[PrivacySettingKey] = mapped_column(
        SqlEnum(PrivacySettingKey),
        nullable=False,
        index=True,
    )
    target_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    mode: Mapped[PrivacyRuleMode] = mapped_column(
        SqlEnum(PrivacyRuleMode),
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))

    user: Mapped["User"] = relationship(back_populates="privacy_exceptions", foreign_keys=[user_id])
    target_user: Mapped["User"] = relationship(foreign_keys=[target_user_id])


class BlockedUser(Base):
    __tablename__ = "blocked_users"
    __table_args__ = (UniqueConstraint("blocker_id", "blocked_id", name="uq_blocked_user_pair"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    blocker_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    blocked_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))

    blocker: Mapped["User"] = relationship(back_populates="blocked_users", foreign_keys=[blocker_id])
    blocked: Mapped["User"] = relationship(back_populates="blocked_by_users", foreign_keys=[blocked_id])
