from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "oMsg API"
    environment: str = "development"
    secret_key: str = "change-this-in-production"
    access_token_expire_minutes: int = 60 * 24 * 7
    refresh_token_expire_days: int = 90
    database_url: str = "sqlite:///./omsg.db"
    database_auto_migrate: bool = True
    cors_origins: str = "*"
    release_manifest_path: str = "./releases/manifest.json"
    media_root: str = "./media"
    media_url_path: str = "/media"
    max_upload_bytes: int = 25 * 1024 * 1024
    login_code_expire_seconds: int = 300
    login_code_max_attempts: int = 5
    login_code_length: int = 5
    auth_test_code: str | None = None

    sms_provider: str = "disabled"
    sms_code_template: str = "{app_name}: {code}"
    sms_gateway_url: str | None = None
    sms_gateway_api_key: str | None = None
    sms_gateway_auth_header: str = "Authorization"
    sms_gateway_auth_prefix: str = "Bearer"
    sms_gateway_to_field: str = "to"
    sms_gateway_message_field: str = "message"
    sms_gateway_timeout_seconds: int = 12
    twilio_account_sid: str | None = None
    twilio_auth_token: str | None = None
    twilio_from: str | None = None
    twilio_messaging_service_sid: str | None = None
    redis_url: str | None = None
    redis_channel_prefix: str = "omsg"

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    @property
    def cors_origin_list(self) -> list[str]:
        if self.cors_origins.strip() == "*":
            return ["*"]
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
