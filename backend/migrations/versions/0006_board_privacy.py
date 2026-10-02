"""Private scoreboards and an overlay key that keeps OBS working while private."""
import secrets
from alembic import op
import sqlalchemy as sa
revision = '0006_board_privacy'
down_revision = '0005_match_trash'
branch_labels = None
depends_on = None

def upgrade():
    op.add_column('scoreboard', sa.Column('private', sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column('scoreboard', sa.Column('overlay_key', sa.String(32), nullable=True))
    board = sa.table('scoreboard', sa.column('slug', sa.String), sa.column('overlay_key', sa.String))
    connection = op.get_bind()
    for (slug,) in connection.execute(sa.select(board.c.slug)).all():
        connection.execute(board.update().where(board.c.slug == slug).values(overlay_key=secrets.token_urlsafe(12)))

def downgrade():
    op.drop_column('scoreboard', 'overlay_key')
    op.drop_column('scoreboard', 'private')
