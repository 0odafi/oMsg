"""scheduled messages pipeline

Revision ID: 20260309_000005
Revises: 20260309_000004
Create Date: 2026-03-10 02:05:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "20260309_000005"
down_revision: str | None = "20260309_000004"
branch_labels: Sequence[str] | None = None
depends_on: Sequence[str] | None = None


scheduled_message_status = sa.Enum(
    "pending",
    "sent",
    "canceled",
    "failed",
    name="scheduledmessagestatus",
)


def upgrade() -> None:
    bind = op.get_bind()
    scheduled_message_status.create(bind, checkfirst=True)

    op.create_table(
        "scheduled_messages",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("chat_id", sa.Integer(), sa.ForeignKey("chats.id", ondelete="CASCADE"), nullable=False),
        sa.Column("sender_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
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
        sa.Column("scheduled_for", sa.DateTime(timezone=True), nullable=False),
        sa.Column("status", scheduled_message_status, nullable=False, server_default="pending"),
        sa.Column(
            "delivered_message_id",
            sa.Integer(),
            sa.ForeignKey("messages.id", ondelete="SET NULL"),
            nullable=True,
            unique=True,
        ),
        sa.Column("failure_reason", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("sent_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_scheduled_messages_chat_id", "scheduled_messages", ["chat_id"], unique=False)
    op.create_index("ix_scheduled_messages_sender_id", "scheduled_messages", ["sender_id"], unique=False)
    op.create_index("ix_scheduled_messages_scheduled_for", "scheduled_messages", ["scheduled_for"], unique=False)
    op.create_index("ix_scheduled_messages_status", "scheduled_messages", ["status"], unique=False)
    op.create_index(
        "ix_scheduled_messages_delivered_message_id",
        "scheduled_messages",
        ["delivered_message_id"],
        unique=True,
    )

    op.create_table(
        "scheduled_message_attachments",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column(
            "scheduled_message_id",
            sa.Integer(),
            sa.ForeignKey("scheduled_messages.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("media_file_id", sa.Integer(), sa.ForeignKey("media_files.id", ondelete="CASCADE"), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint(
            "scheduled_message_id",
            "media_file_id",
            name="uq_scheduled_message_attachment_media",
        ),
    )
    op.create_index(
        "ix_scheduled_message_attachments_scheduled_message_id",
        "scheduled_message_attachments",
        ["scheduled_message_id"],
        unique=False,
    )
    op.create_index(
        "ix_scheduled_message_attachments_media_file_id",
        "scheduled_message_attachments",
        ["media_file_id"],
        unique=False,
    )

    with op.batch_alter_table("scheduled_messages") as batch_op:
        batch_op.alter_column("status", server_default=None)


def downgrade() -> None:
    bind = op.get_bind()

    op.drop_index(
        "ix_scheduled_message_attachments_media_file_id",
        table_name="scheduled_message_attachments",
    )
    op.drop_index(
        "ix_scheduled_message_attachments_scheduled_message_id",
        table_name="scheduled_message_attachments",
    )
    op.drop_table("scheduled_message_attachments")

    op.drop_index(
        "ix_scheduled_messages_delivered_message_id",
        table_name="scheduled_messages",
    )
    op.drop_index("ix_scheduled_messages_status", table_name="scheduled_messages")
    op.drop_index("ix_scheduled_messages_scheduled_for", table_name="scheduled_messages")
    op.drop_index("ix_scheduled_messages_sender_id", table_name="scheduled_messages")
    op.drop_index("ix_scheduled_messages_chat_id", table_name="scheduled_messages")
    op.drop_table("scheduled_messages")

    scheduled_message_status.drop(bind, checkfirst=True)
