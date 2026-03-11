"""make username optional

Revision ID: 20260309_000003
Revises: 20260309_000002
Create Date: 2026-03-09 23:40:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "20260309_000003"
down_revision: str | None = "20260309_000002"
branch_labels: Sequence[str] | None = None
depends_on: Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("users") as batch_op:
        batch_op.alter_column(
            "username",
            existing_type=sa.String(length=40),
            nullable=True,
        )


def downgrade() -> None:
    bind = op.get_bind()
    has_null_usernames = bind.execute(sa.text("SELECT COUNT(*) FROM users WHERE username IS NULL")).scalar_one()
    if has_null_usernames:
        raise RuntimeError("Cannot downgrade while users with NULL username exist.")

    with op.batch_alter_table("users") as batch_op:
        batch_op.alter_column(
            "username",
            existing_type=sa.String(length=40),
            nullable=False,
        )
