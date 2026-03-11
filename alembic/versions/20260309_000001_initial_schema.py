"""initial schema

Revision ID: 20260309_000001
Revises:
Create Date: 2026-03-09 20:15:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "20260309_000001"
down_revision: str | None = None
branch_labels: Sequence[str] | None = None
depends_on: Sequence[str] | None = None


chat_type = sa.Enum("private", "group", "channel", name="chattype")
member_role = sa.Enum("owner", "admin", "member", name="memberrole")
message_delivery_status = sa.Enum(
    "sent",
    "delivered",
    "read",
    name="messagedeliverystatus",
)


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("username", sa.String(length=40), nullable=True),
        sa.Column("uid", sa.String(length=40), nullable=True),
        sa.Column("phone", sa.String(length=24), nullable=True),
        sa.Column("first_name", sa.String(length=80), nullable=False),
        sa.Column("last_name", sa.String(length=80), nullable=False),
        sa.Column("email", sa.String(length=120), nullable=False),
        sa.Column("password_hash", sa.String(length=256), nullable=False),
        sa.Column("bio", sa.Text(), nullable=False),
        sa.Column("avatar_url", sa.String(length=500), nullable=True),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_users_username", "users", ["username"], unique=True)
    op.create_index("ix_users_uid", "users", ["uid"], unique=True)
    op.create_index("ix_users_phone", "users", ["phone"], unique=True)
    op.create_index("ix_users_email", "users", ["email"], unique=True)

    op.create_table(
        "follows",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("follower_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("following_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("follower_id", "following_id", name="uq_follow_pair"),
    )
    op.create_index("ix_follows_follower_id", "follows", ["follower_id"], unique=False)
    op.create_index("ix_follows_following_id", "follows", ["following_id"], unique=False)

    op.create_table(
        "refresh_tokens",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("token_hash", sa.String(length=128), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_refresh_tokens_user_id", "refresh_tokens", ["user_id"], unique=False)
    op.create_index("ix_refresh_tokens_token_hash", "refresh_tokens", ["token_hash"], unique=True)
    op.create_index("ix_refresh_tokens_expires_at", "refresh_tokens", ["expires_at"], unique=False)

    op.create_table(
        "phone_login_codes",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("phone", sa.String(length=24), nullable=False),
        sa.Column("code_token_hash", sa.String(length=128), nullable=False),
        sa.Column("code_hash", sa.String(length=128), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("is_consumed", sa.Boolean(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_phone_login_codes_phone", "phone_login_codes", ["phone"], unique=False)
    op.create_index(
        "ix_phone_login_codes_code_token_hash",
        "phone_login_codes",
        ["code_token_hash"],
        unique=True,
    )
    op.create_index("ix_phone_login_codes_expires_at", "phone_login_codes", ["expires_at"], unique=False)

    op.create_table(
        "chats",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("title", sa.String(length=120), nullable=False),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column("type", chat_type, nullable=False),
        sa.Column("is_public", sa.Boolean(), nullable=False),
        sa.Column("owner_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )

    op.create_table(
        "chat_members",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("chat_id", sa.Integer(), sa.ForeignKey("chats.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("role", member_role, nullable=False),
        sa.Column("is_archived", sa.Boolean(), nullable=False),
        sa.Column("is_pinned", sa.Boolean(), nullable=False),
        sa.Column("folder", sa.String(length=32), nullable=True),
        sa.Column("joined_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("chat_id", "user_id", name="uq_chat_member"),
    )
    op.create_index("ix_chat_members_chat_id", "chat_members", ["chat_id"], unique=False)
    op.create_index("ix_chat_members_user_id", "chat_members", ["user_id"], unique=False)
    op.create_index("ix_chat_members_is_archived", "chat_members", ["is_archived"], unique=False)
    op.create_index("ix_chat_members_is_pinned", "chat_members", ["is_pinned"], unique=False)
    op.create_index("ix_chat_members_folder", "chat_members", ["folder"], unique=False)

    op.create_table(
        "messages",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("chat_id", sa.Integer(), sa.ForeignKey("chats.id", ondelete="CASCADE"), nullable=False),
        sa.Column("sender_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("edited_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_messages_chat_id", "messages", ["chat_id"], unique=False)
    op.create_index("ix_messages_sender_id", "messages", ["sender_id"], unique=False)
    op.create_index("ix_messages_created_at", "messages", ["created_at"], unique=False)

    op.create_table(
        "media_files",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("uploader_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("chat_id", sa.Integer(), sa.ForeignKey("chats.id", ondelete="CASCADE"), nullable=False),
        sa.Column("storage_name", sa.String(length=255), nullable=False),
        sa.Column("original_name", sa.String(length=255), nullable=False),
        sa.Column("mime_type", sa.String(length=120), nullable=False),
        sa.Column("size_bytes", sa.Integer(), nullable=False),
        sa.Column("is_committed", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_media_files_uploader_id", "media_files", ["uploader_id"], unique=False)
    op.create_index("ix_media_files_chat_id", "media_files", ["chat_id"], unique=False)
    op.create_index("ix_media_files_storage_name", "media_files", ["storage_name"], unique=True)
    op.create_index("ix_media_files_is_committed", "media_files", ["is_committed"], unique=False)

    op.create_table(
        "message_reactions",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("message_id", sa.Integer(), sa.ForeignKey("messages.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("emoji", sa.String(length=12), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("message_id", "user_id", "emoji", name="uq_message_reaction"),
    )
    op.create_index("ix_message_reactions_message_id", "message_reactions", ["message_id"], unique=False)
    op.create_index("ix_message_reactions_user_id", "message_reactions", ["user_id"], unique=False)

    op.create_table(
        "message_links",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("message_id", sa.Integer(), sa.ForeignKey("messages.id", ondelete="CASCADE"), nullable=False),
        sa.Column(
            "reply_to_message_id",
            sa.Integer(),
            sa.ForeignKey("messages.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column(
            "forwarded_from_message_id",
            sa.Integer(),
            sa.ForeignKey("messages.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("message_id", name="uq_message_link_message"),
    )
    op.create_index("ix_message_links_message_id", "message_links", ["message_id"], unique=False)

    op.create_table(
        "message_deliveries",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("message_id", sa.Integer(), sa.ForeignKey("messages.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("status", message_delivery_status, nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("message_id", "user_id", name="uq_message_delivery"),
    )
    op.create_index("ix_message_deliveries_message_id", "message_deliveries", ["message_id"], unique=False)
    op.create_index("ix_message_deliveries_user_id", "message_deliveries", ["user_id"], unique=False)

    op.create_table(
        "message_attachments",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("message_id", sa.Integer(), sa.ForeignKey("messages.id", ondelete="CASCADE"), nullable=False),
        sa.Column("media_file_id", sa.Integer(), sa.ForeignKey("media_files.id", ondelete="CASCADE"), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("message_id", "media_file_id", name="uq_message_attachment_media"),
    )
    op.create_index("ix_message_attachments_message_id", "message_attachments", ["message_id"], unique=False)
    op.create_index("ix_message_attachments_media_file_id", "message_attachments", ["media_file_id"], unique=False)

    op.create_table(
        "pinned_messages",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("chat_id", sa.Integer(), sa.ForeignKey("chats.id", ondelete="CASCADE"), nullable=False),
        sa.Column("message_id", sa.Integer(), sa.ForeignKey("messages.id", ondelete="CASCADE"), nullable=False),
        sa.Column("pinned_by_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("pinned_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("chat_id", "message_id", name="uq_pinned_chat_message"),
    )
    op.create_index("ix_pinned_messages_chat_id", "pinned_messages", ["chat_id"], unique=False)
    op.create_index("ix_pinned_messages_message_id", "pinned_messages", ["message_id"], unique=False)
    op.create_index("ix_pinned_messages_pinned_by_id", "pinned_messages", ["pinned_by_id"], unique=False)


def downgrade() -> None:
    bind = op.get_bind()

    op.drop_index("ix_pinned_messages_pinned_by_id", table_name="pinned_messages")
    op.drop_index("ix_pinned_messages_message_id", table_name="pinned_messages")
    op.drop_index("ix_pinned_messages_chat_id", table_name="pinned_messages")
    op.drop_table("pinned_messages")

    op.drop_index("ix_message_attachments_media_file_id", table_name="message_attachments")
    op.drop_index("ix_message_attachments_message_id", table_name="message_attachments")
    op.drop_table("message_attachments")

    op.drop_index("ix_message_deliveries_user_id", table_name="message_deliveries")
    op.drop_index("ix_message_deliveries_message_id", table_name="message_deliveries")
    op.drop_table("message_deliveries")

    op.drop_index("ix_message_links_message_id", table_name="message_links")
    op.drop_table("message_links")

    op.drop_index("ix_message_reactions_user_id", table_name="message_reactions")
    op.drop_index("ix_message_reactions_message_id", table_name="message_reactions")
    op.drop_table("message_reactions")

    op.drop_index("ix_media_files_is_committed", table_name="media_files")
    op.drop_index("ix_media_files_storage_name", table_name="media_files")
    op.drop_index("ix_media_files_chat_id", table_name="media_files")
    op.drop_index("ix_media_files_uploader_id", table_name="media_files")
    op.drop_table("media_files")

    op.drop_index("ix_messages_created_at", table_name="messages")
    op.drop_index("ix_messages_sender_id", table_name="messages")
    op.drop_index("ix_messages_chat_id", table_name="messages")
    op.drop_table("messages")

    op.drop_index("ix_chat_members_folder", table_name="chat_members")
    op.drop_index("ix_chat_members_is_pinned", table_name="chat_members")
    op.drop_index("ix_chat_members_is_archived", table_name="chat_members")
    op.drop_index("ix_chat_members_user_id", table_name="chat_members")
    op.drop_index("ix_chat_members_chat_id", table_name="chat_members")
    op.drop_table("chat_members")

    op.drop_table("chats")

    op.drop_index("ix_phone_login_codes_expires_at", table_name="phone_login_codes")
    op.drop_index("ix_phone_login_codes_code_token_hash", table_name="phone_login_codes")
    op.drop_index("ix_phone_login_codes_phone", table_name="phone_login_codes")
    op.drop_table("phone_login_codes")

    op.drop_index("ix_refresh_tokens_expires_at", table_name="refresh_tokens")
    op.drop_index("ix_refresh_tokens_token_hash", table_name="refresh_tokens")
    op.drop_index("ix_refresh_tokens_user_id", table_name="refresh_tokens")
    op.drop_table("refresh_tokens")

    op.drop_index("ix_follows_following_id", table_name="follows")
    op.drop_index("ix_follows_follower_id", table_name="follows")
    op.drop_table("follows")

    op.drop_index("ix_users_email", table_name="users")
    op.drop_index("ix_users_phone", table_name="users")
    op.drop_index("ix_users_uid", table_name="users")
    op.drop_index("ix_users_username", table_name="users")
    op.drop_table("users")

    if bind.dialect.name != "sqlite":
        message_delivery_status.drop(bind, checkfirst=False)
        member_role.drop(bind, checkfirst=False)
        chat_type.drop(bind, checkfirst=False)
