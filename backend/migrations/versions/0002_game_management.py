"""Game history, scheduling and recoverable lifecycle metadata."""
from alembic import op
import sqlalchemy as sa

revision = "0002_game_management"
down_revision = "0001_initial"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("scoreboard") as batch:
        batch.alter_column("active_match", existing_type=sa.String(36), nullable=True)
    op.add_column("match", sa.Column("created_at", sa.Float(), nullable=True))
    for name in ("scheduled_at", "archived_at", "deleted_at"):
        op.add_column("match", sa.Column(name, sa.Float(), nullable=True))
    op.execute(sa.text('UPDATE "match" SET created_at = (SELECT created_at FROM scoreboard WHERE scoreboard.slug = "match".slug)'))
    with op.batch_alter_table("match") as batch:
        batch.alter_column("created_at", existing_type=sa.Float(), nullable=False)


def downgrade():
    raise RuntimeError("Restore a verified backup rather than discarding game history metadata")
