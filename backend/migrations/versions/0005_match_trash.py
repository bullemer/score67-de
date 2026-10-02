"""Trash for abandoned and never-started games."""
from alembic import op
import sqlalchemy as sa
revision = '0005_match_trash'
down_revision = '0004_board_description'
branch_labels = None
depends_on = None

def upgrade():
    op.add_column('match', sa.Column('trashed_at', sa.Float(), nullable=True))
    op.add_column('match', sa.Column('trash_reason', sa.String(20), nullable=True))
    op.add_column('match', sa.Column('touched_at', sa.Float(), nullable=True))

def downgrade():
    op.drop_column('match', 'touched_at')
    op.drop_column('match', 'trash_reason')
    op.drop_column('match', 'trashed_at')
