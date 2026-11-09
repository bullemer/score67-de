"""Teams saved for reuse: name, colour, short name and roster."""
from alembic import op
import sqlalchemy as sa
revision = '0019_saved_teams'
down_revision = '0018_board_creator'
branch_labels = None
depends_on = None

def upgrade():
    op.create_table(
        'saved_team',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('device_id', sa.String(36), sa.ForeignKey('device.id', ondelete='SET NULL'), nullable=True, index=True),
        sa.Column('account_id', sa.String(36), sa.ForeignKey('account.id', ondelete='CASCADE'), nullable=True, index=True),
        sa.Column('sport', sa.String(12), nullable=False),
        sa.Column('name', sa.String(60), nullable=False),
        sa.Column('short', sa.String(8), nullable=False),
        sa.Column('color', sa.String(7), nullable=False),
        sa.Column('players', sa.JSON(), nullable=False),
        sa.Column('updated_at', sa.Float(), nullable=False),
    )

def downgrade():
    op.drop_table('saved_team')
