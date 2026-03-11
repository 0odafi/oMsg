"""device sessions metadata on refresh tokens

Revision ID: 20260310_000007
Revises: 20260310_000006
Create Date: 2026-03-10 07:40:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "20260310_000007"
down_revision: str | None = "20260310_000006"
branch_labels: Sequence[str] | None = None
depends_on: Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("refresh_tokens") as batch_op:
        batch_op.add_column(
            sa.Column("session_key", sa.String(length=64), nullable=False, server_default="")
        )
        batch_op.add_column(sa.Column("device_name", sa.String(length=120), nullable=True))
        batch_op.add_column(sa.Column("platform", sa.String(length=40), nullable=True))
        batch_op.add_column(sa.Column("user_agent", sa.String(length=255), nullable=True))
        batch_op.add_column(sa.Column("ip_address", sa.String(length=64), nullable=True))
        batch_op.create_index("ix_refresh_tokens_session_key", ["session_key"], unique=False)
        batch_op.alter_column("session_key", server_default=None)

    bind = op.get_bind()
    refresh_tokens = sa.table(
        "refresh_tokens",
        sa.column("id", sa.Integer()),
        sa.column("session_key", sa.String(length=64)),
    )
    rows = list(bind.execute(sa.select(refresh_tokens.c.id, refresh_tokens.c.session_key)))
    for row in rows:
        current_key = (row.session_key or "").strip()
        if current_key:
            continue
        bind.execute(
            refresh_tokens.update()
            .where(refresh_tokens.c.id == row.id)
            .values(session_key=f"legacy-{row.id}")
        )


def downgrade() -> None:
    with op.batch_alter_table("refresh_tokens") as batch_op:
        batch_op.drop_index("ix_refresh_tokens_session_key")
        batch_op.drop_column("ip_address")
        batch_op.drop_column("user_agent")
        batch_op.drop_column("platform")
        batch_op.drop_column("device_name")
        batch_op.drop_column("session_key")
