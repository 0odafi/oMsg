"""realtime events log

Revision ID: 20260309_000002
Revises: 20260309_000001
Create Date: 2026-03-09 21:05:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "20260309_000002"
down_revision: str | None = "20260309_000001"
branch_labels: Sequence[str] | None = None
depends_on: Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "realtime_events",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("target_type", sa.String(length=16), nullable=False),
        sa.Column("target_id", sa.Integer(), nullable=False),
        sa.Column("payload_json", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index(
        "ix_realtime_events_target_type",
        "realtime_events",
        ["target_type"],
        unique=False,
    )
    op.create_index(
        "ix_realtime_events_target_id",
        "realtime_events",
        ["target_id"],
        unique=False,
    )
    op.create_index(
        "ix_realtime_events_created_at",
        "realtime_events",
        ["created_at"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_realtime_events_created_at", table_name="realtime_events")
    op.drop_index("ix_realtime_events_target_id", table_name="realtime_events")
    op.drop_index("ix_realtime_events_target_type", table_name="realtime_events")
    op.drop_table("realtime_events")
