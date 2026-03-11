from datetime import datetime

from pydantic import BaseModel, Field

from app.models.user import PrivacyAudience, PrivacyRuleMode, PrivacySettingKey


class UserPublic(BaseModel):
    id: int
    username: str | None
    phone: str | None
    first_name: str
    last_name: str
    bio: str
    avatar_url: str | None
    is_online: bool = False
    last_seen_at: datetime | None = None
    last_seen_label: str | None = None
    created_at: datetime

    model_config = {"from_attributes": True}


class PublicUserProfile(BaseModel):
    id: int
    username: str
    first_name: str
    last_name: str
    bio: str
    avatar_url: str | None
    created_at: datetime

    model_config = {"from_attributes": True}


class ProfileUpdate(BaseModel):
    bio: str | None = Field(default=None, max_length=1000)
    avatar_url: str | None = Field(default=None, max_length=500)
    username: str | None = Field(default=None, max_length=32)
    first_name: str | None = Field(default=None, min_length=1, max_length=80)
    last_name: str | None = Field(default=None, min_length=1, max_length=80)


class UsernameCheckOut(BaseModel):
    username: str
    available: bool


class UserPrivacySettingsOut(BaseModel):
    phone_visibility: PrivacyAudience
    phone_search_visibility: PrivacyAudience
    last_seen_visibility: PrivacyAudience
    show_approximate_last_seen: bool
    allow_group_invites: PrivacyAudience

    model_config = {"from_attributes": True}


class UserPrivacySettingsUpdate(BaseModel):
    phone_visibility: PrivacyAudience | None = None
    phone_search_visibility: PrivacyAudience | None = None
    last_seen_visibility: PrivacyAudience | None = None
    show_approximate_last_seen: bool | None = None
    allow_group_invites: PrivacyAudience | None = None


class UserDataSettingsOut(BaseModel):
    keep_media_days: int
    storage_limit_mb: int
    auto_download_photos: bool
    auto_download_videos: bool
    auto_download_music: bool
    auto_download_files: bool
    default_auto_delete_seconds: int | None

    model_config = {"from_attributes": True}


class UserDataSettingsUpdate(BaseModel):
    keep_media_days: int | None = Field(default=None, ge=1, le=3650)
    storage_limit_mb: int | None = Field(default=None, ge=256, le=102400)
    auto_download_photos: bool | None = None
    auto_download_videos: bool | None = None
    auto_download_music: bool | None = None
    auto_download_files: bool | None = None
    default_auto_delete_seconds: int | None = Field(default=None, ge=0, le=31536000)


class UserSettingsOut(BaseModel):
    privacy: UserPrivacySettingsOut
    data_storage: UserDataSettingsOut
    blocked_users_count: int = 0


class BlockedUserOut(BaseModel):
    user: UserPublic
    blocked_at: datetime


class UserPrivacyExceptionCreate(BaseModel):
    setting_key: PrivacySettingKey
    mode: PrivacyRuleMode
    target_user_id: int = Field(gt=0)


class UserPrivacyExceptionOut(BaseModel):
    id: int
    setting_key: PrivacySettingKey
    mode: PrivacyRuleMode
    target_user_id: int
    user: UserPublic
    created_at: datetime
