"""media upload idempotency

Revision ID: 20260310_000009
Revises: 20260310_000008
Create Date: 2026-03-10 18:40:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "20260310_000009"
down_revision: str | None = "20260310_000008"
branch_labels: Sequence[str] | None = None
depends_on: Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("media_files") as batch_op:
        batch_op.add_column(sa.Column("client_upload_id", sa.String(length=64), nullable=True))
        batch_op.create_index("ix_media_files_client_upload_id", ["client_upload_id"], unique=False)
        batch_op.create_unique_constraint(
            "uq_media_file_client_upload",
            ["chat_id", "uploader_id", "client_upload_id"],
        )


def downgrade() -> None:
    with op.batch_alter_table("media_files") as batch_op:
        batch_op.drop_constraint("uq_media_file_client_upload", type_="unique")
        batch_op.drop_index("ix_media_files_client_upload_id")
        batch_op.drop_column("client_upload_id")
