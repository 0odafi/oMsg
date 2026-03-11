"""media metadata, privacy settings, and block lists

Revision ID: 20260309_000004
Revises: 20260309_000003
Create Date: 2026-03-10 01:15:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "20260309_000004"
down_revision: str | None = "20260309_000003"
branch_labels: Sequence[str] | None = None
depends_on: Sequence[str] | None = None


media_kind = sa.Enum("file", "image", "video", "audio", "voice", name="mediakind")
privacy_audience = sa.Enum("everyone", "contacts", "nobody", name="privacyaudience")


def upgrade() -> None:
    bind = op.get_bind()
    media_kind.create(bind, checkfirst=True)
    privacy_audience.create(bind, checkfirst=True)

    with op.batch_alter_table("users") as batch_op:
        batch_op.add_column(sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True))
        batch_op.create_index("ix_users_last_seen_at", ["last_seen_at"], unique=False)

    with op.batch_alter_table("media_files") as batch_op:
        batch_op.add_column(sa.Column("media_kind", media_kind, nullable=False, server_default="file"))
        batch_op.add_column(sa.Column("sha256", sa.String(length=64), nullable=True))
        batch_op.add_column(sa.Column("width", sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column("height", sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column("duration_seconds", sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column("thumbnail_storage_name", sa.String(length=255), nullable=True))
        batch_op.create_index("ix_media_files_media_kind", ["media_kind"], unique=False)

    op.execute("UPDATE media_files SET media_kind = 'image' WHERE mime_type LIKE 'image/%'")
    op.execute("UPDATE media_files SET media_kind = 'video' WHERE mime_type LIKE 'video/%'")
    op.execute("UPDATE media_files SET media_kind = 'audio' WHERE mime_type LIKE 'audio/%'")

    with op.batch_alter_table("media_files") as batch_op:
        batch_op.alter_column("media_kind", server_default=None)

    op.create_table(
        "user_privacy_settings",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("phone_visibility", privacy_audience, nullable=False, server_default="everyone"),
        sa.Column("phone_search_visibility", privacy_audience, nullable=False, server_default="everyone"),
        sa.Column("last_seen_visibility", privacy_audience, nullable=False, server_default="everyone"),
        sa.Column("show_approximate_last_seen", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("allow_group_invites", privacy_audience, nullable=False, server_default="everyone"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", name="uq_user_privacy_settings_user"),
    )
    op.create_index("ix_user_privacy_settings_user_id", "user_privacy_settings", ["user_id"], unique=True)

    op.create_table(
        "user_data_settings",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("keep_media_days", sa.Integer(), nullable=False, server_default="30"),
        sa.Column("storage_limit_mb", sa.Integer(), nullable=False, server_default="2048"),
        sa.Column("auto_download_photos", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("auto_download_videos", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("auto_download_music", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("auto_download_files", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("default_auto_delete_seconds", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", name="uq_user_data_settings_user"),
    )
    op.create_index("ix_user_data_settings_user_id", "user_data_settings", ["user_id"], unique=True)

    op.create_table(
        "blocked_users",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("blocker_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("blocked_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("blocker_id", "blocked_id", name="uq_blocked_user_pair"),
    )
    op.create_index("ix_blocked_users_blocker_id", "blocked_users", ["blocker_id"], unique=False)
    op.create_index("ix_blocked_users_blocked_id", "blocked_users", ["blocked_id"], unique=False)


def downgrade() -> None:
    bind = op.get_bind()

    op.drop_index("ix_blocked_users_blocked_id", table_name="blocked_users")
    op.drop_index("ix_blocked_users_blocker_id", table_name="blocked_users")
    op.drop_table("blocked_users")

    op.drop_index("ix_user_data_settings_user_id", table_name="user_data_settings")
    op.drop_table("user_data_settings")

    op.drop_index("ix_user_privacy_settings_user_id", table_name="user_privacy_settings")
    op.drop_table("user_privacy_settings")

    with op.batch_alter_table("media_files") as batch_op:
        batch_op.drop_index("ix_media_files_media_kind")
        batch_op.drop_column("thumbnail_storage_name")
        batch_op.drop_column("duration_seconds")
        batch_op.drop_column("height")
        batch_op.drop_column("width")
        batch_op.drop_column("sha256")
        batch_op.drop_column("media_kind")

    with op.batch_alter_table("users") as batch_op:
        batch_op.drop_index("ix_users_last_seen_at")
        batch_op.drop_column("last_seen_at")

    privacy_audience.drop(bind, checkfirst=True)
    media_kind.drop(bind, checkfirst=True)
