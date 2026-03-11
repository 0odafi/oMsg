"""message idempotency and silent flags

Revision ID: 20260310_000008
Revises: 20260310_000007
Create Date: 2026-03-10 09:05:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "20260310_000008"
down_revision: str | None = "20260310_000007"
branch_labels: Sequence[str] | None = None
depends_on: Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("messages") as batch_op:
        batch_op.add_column(sa.Column("client_message_id", sa.String(length=64), nullable=True))
        batch_op.add_column(
            sa.Column("is_silent", sa.Boolean(), nullable=False, server_default=sa.false())
        )
        batch_op.create_index("ix_messages_client_message_id", ["client_message_id"], unique=False)
        batch_op.create_index("ix_messages_is_silent", ["is_silent"], unique=False)
        batch_op.create_unique_constraint(
            "uq_message_client_message",
            ["chat_id", "sender_id", "client_message_id"],
        )
        batch_op.alter_column("is_silent", server_default=None)


def downgrade() -> None:
    with op.batch_alter_table("messages") as batch_op:
        batch_op.drop_constraint("uq_message_client_message", type_="unique")
        batch_op.drop_index("ix_messages_is_silent")
        batch_op.drop_index("ix_messages_client_message_id")
        batch_op.drop_column("is_silent")
        batch_op.drop_column("client_message_id")
