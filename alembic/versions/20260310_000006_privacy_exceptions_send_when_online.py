"""privacy exceptions and send-when-online scheduled messages

Revision ID: 20260310_000006
Revises: 20260309_000005
Create Date: 2026-03-10 03:40:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "20260310_000006"
down_revision: str | None = "20260309_000005"
branch_labels: Sequence[str] | None = None
depends_on: Sequence[str] | None = None


privacy_setting_key = sa.Enum(
    "phone_visibility",
    "phone_search_visibility",
    "last_seen_visibility",
    "allow_group_invites",
    name="privacysettingkey",
)
privacy_rule_mode = sa.Enum("allow", "disallow", name="privacyrulemode")


def upgrade() -> None:
    bind = op.get_bind()
    privacy_setting_key.create(bind, checkfirst=True)
    privacy_rule_mode.create(bind, checkfirst=True)

    op.create_table(
        "user_privacy_exceptions",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("setting_key", privacy_setting_key, nullable=False),
        sa.Column(
            "target_user_id",
            sa.Integer(),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("mode", privacy_rule_mode, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint(
            "user_id",
            "setting_key",
            "target_user_id",
            name="uq_user_privacy_exception",
        ),
    )
    op.create_index(
        "ix_user_privacy_exceptions_user_id",
        "user_privacy_exceptions",
        ["user_id"],
        unique=False,
    )
    op.create_index(
        "ix_user_privacy_exceptions_setting_key",
        "user_privacy_exceptions",
        ["setting_key"],
        unique=False,
    )
    op.create_index(
        "ix_user_privacy_exceptions_target_user_id",
        "user_privacy_exceptions",
        ["target_user_id"],
        unique=False,
    )

    with op.batch_alter_table("scheduled_messages") as batch_op:
        batch_op.add_column(
            sa.Column(
                "send_when_user_online",
                sa.Boolean(),
                nullable=False,
                server_default=sa.false(),
            )
        )
        batch_op.add_column(
            sa.Column(
                "deliver_on_user_id",
                sa.Integer(),
                nullable=True,
            )
        )
        batch_op.create_foreign_key(
            "fk_scheduled_messages_deliver_on_user_id_users",
            "users",
            ["deliver_on_user_id"],
            ["id"],
            ondelete="SET NULL",
        )
        batch_op.create_index(
            "ix_scheduled_messages_send_when_user_online",
            ["send_when_user_online"],
            unique=False,
        )
        batch_op.create_index(
            "ix_scheduled_messages_deliver_on_user_id",
            ["deliver_on_user_id"],
            unique=False,
        )
        batch_op.alter_column("send_when_user_online", server_default=None)


def downgrade() -> None:
    bind = op.get_bind()

    with op.batch_alter_table("scheduled_messages") as batch_op:
        batch_op.drop_index("ix_scheduled_messages_deliver_on_user_id")
        batch_op.drop_index("ix_scheduled_messages_send_when_user_online")
        batch_op.drop_constraint(
            "fk_scheduled_messages_deliver_on_user_id_users",
            type_="foreignkey",
        )
        batch_op.drop_column("deliver_on_user_id")
        batch_op.drop_column("send_when_user_online")

    op.drop_index(
        "ix_user_privacy_exceptions_target_user_id",
        table_name="user_privacy_exceptions",
    )
    op.drop_index(
        "ix_user_privacy_exceptions_setting_key",
        table_name="user_privacy_exceptions",
    )
    op.drop_index(
        "ix_user_privacy_exceptions_user_id",
        table_name="user_privacy_exceptions",
    )
    op.drop_table("user_privacy_exceptions")

    privacy_rule_mode.drop(bind, checkfirst=True)
    privacy_setting_key.drop(bind, checkfirst=True)
