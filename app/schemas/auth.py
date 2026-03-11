from datetime import datetime

from pydantic import BaseModel, Field

from app.schemas.user import UserPublic


class PhoneCodeRequest(BaseModel):
    phone: str = Field(min_length=10, max_length=24)


class PhoneCodeResponse(BaseModel):
    phone: str
    code_token: str
    expires_in_seconds: int
    is_registered: bool


class PhoneCodeVerifyRequest(BaseModel):
    phone: str = Field(min_length=10, max_length=24)
    code_token: str = Field(min_length=20, max_length=512)
    code: str = Field(min_length=4, max_length=8)
    first_name: str | None = Field(default=None, max_length=80)
    last_name: str | None = Field(default=None, max_length=80)


class RegisterRequest(BaseModel):
    username: str = Field(min_length=5, max_length=32)
    email: str = Field(min_length=5, max_length=120)
    password: str = Field(min_length=8, max_length=128)


class LoginRequest(BaseModel):
    login: str = Field(min_length=3, max_length=120, description="Username, email or phone")
    password: str = Field(min_length=8, max_length=128)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=20, max_length=512)


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    needs_profile_setup: bool = False
    user: UserPublic


class AuthSessionOut(BaseModel):
    session_id: str
    device_name: str | None = None
    platform: str | None = None
    user_agent: str | None = None
    ip_address: str | None = None
    created_at: datetime
    last_used_at: datetime | None = None
    expires_at: datetime
    is_current: bool = False


class RevokeSessionsOut(BaseModel):
    revoked: int
