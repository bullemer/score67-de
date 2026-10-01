"""Initial Score67 schema, frozen independently of future ORM changes."""
from alembic import op
import sqlalchemy as sa

revision = "0001_initial"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("scoreboard",
        sa.Column("slug", sa.String(10), primary_key=True),
        sa.Column("name", sa.String(80), nullable=False),
        sa.Column("language", sa.String(2), nullable=False),
        sa.Column("pin_hash", sa.String(200), nullable=False),
        sa.Column("failed_count", sa.Integer(), nullable=False),
        sa.Column("locked_until", sa.Float(), nullable=False),
        sa.Column("active_match", sa.String(36), nullable=False),
        sa.Column("created_at", sa.Float(), nullable=False))
    op.create_table("scoreboard_admin",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("slug", sa.String(10), sa.ForeignKey("scoreboard.slug"), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False, unique=True),
        sa.Column("label", sa.String(60), nullable=False),
        sa.Column("last_seen_at", sa.Float(), nullable=False),
        sa.Column("revoked", sa.Boolean(), nullable=False))
    op.create_index("ix_scoreboard_admin_slug", "scoreboard_admin", ["slug"])
    op.create_table("match",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("slug", sa.String(10), sa.ForeignKey("scoreboard.slug"), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("state", sa.JSON(), nullable=False))
    op.create_index("ix_match_slug", "match", ["slug"])
    op.create_table("match_event",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("match_id", sa.String(36), sa.ForeignKey("match.id"), nullable=False),
        sa.Column("admin_id", sa.String(36), sa.ForeignKey("scoreboard_admin.id"), nullable=False),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column("before", sa.JSON(), nullable=False),
        sa.Column("cancelled", sa.Boolean(), nullable=False))
    op.create_index("ix_match_event_match_id", "match_event", ["match_id"])
    op.create_table("command_receipt",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("fingerprint", sa.String(64), nullable=False))
    op.create_table("rate_limit",
        sa.Column("key", sa.String(100), primary_key=True),
        sa.Column("count", sa.Integer(), nullable=False),
        sa.Column("reset_at", sa.Float(), nullable=False))


def downgrade():
    for table in ("rate_limit", "command_receipt", "match_event", "match", "scoreboard_admin", "scoreboard"):
        op.drop_table(table)
