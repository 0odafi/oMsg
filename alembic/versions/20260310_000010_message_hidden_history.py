"""add per-user hidden messages for chat history controls

Revision ID: 20260310_000010
Revises: 20260310_000009
Create Date: 2026-03-10 18:20:00
"""

from alembic import op
import sqlalchemy as sa


revision = "20260310_000010"
down_revision = "20260310_000009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "message_hidden",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("message_id", sa.Integer(), sa.ForeignKey("messages.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("hidden_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("message_id", "user_id", name="uq_message_hidden_user"),
    )
    op.create_index("ix_message_hidden_message_id", "message_hidden", ["message_id"], unique=False)
    op.create_index("ix_message_hidden_user_id", "message_hidden", ["user_id"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_message_hidden_user_id", table_name="message_hidden")
    op.drop_index("ix_message_hidden_message_id", table_name="message_hidden")
    op.drop_table("message_hidden")
