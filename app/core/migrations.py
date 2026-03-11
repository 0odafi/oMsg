from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import inspect

from app.core.config import get_settings
from app.core.database import engine

_LEGACY_CORE_TABLES = {
    "users",
    "refresh_tokens",
    "phone_login_codes",
    "chats",
    "chat_members",
    "messages",
}
_LEGACY_BASELINE_REVISION = "20260309_000001"


def run_migrations() -> None:
    settings = get_settings()
    config = _build_alembic_config(settings.database_url)

    inspector = inspect(engine)
    existing_tables = set(inspector.get_table_names())
    has_version_table = "alembic_version" in existing_tables
    has_legacy_app_tables = _LEGACY_CORE_TABLES.issubset(existing_tables)

    if not existing_tables:
        command.upgrade(config, "head")
        return

    if not has_version_table and has_legacy_app_tables:
        command.stamp(config, _LEGACY_BASELINE_REVISION)
        command.upgrade(config, "head")
        return

    command.upgrade(config, "head")


def _build_alembic_config(database_url: str) -> Config:
    root_dir = Path(__file__).resolve().parents[2]
    config = Config(str(root_dir / "alembic.ini"))
    config.set_main_option("script_location", str(root_dir / "alembic"))
    config.set_main_option("sqlalchemy.url", database_url)
    return config
