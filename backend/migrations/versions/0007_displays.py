"""Physical displays (Anzeigetafeln) paired with a code and assigned to a scoreboard."""
from alembic import op
import sqlalchemy as sa
revision = '0007_displays'
down_revision = '0006_board_privacy'
branch_labels = None
depends_on = None

def upgrade():
    op.create_table(
        'display',
        sa.Column('id', sa.String(12), primary_key=True),
        sa.Column('name', sa.String(60), nullable=False),
        sa.Column('token_hash', sa.String(64), nullable=True, unique=True),
        sa.Column('pairing_code', sa.String(6), nullable=True, unique=True),
        sa.Column('pairing_expires_at', sa.Float(), nullable=True),
        sa.Column('board_slug', sa.String(10), sa.ForeignKey('scoreboard.slug'), nullable=True),
        sa.Column('created_at', sa.Float(), nullable=False),
        sa.Column('paired_at', sa.Float(), nullable=True),
        sa.Column('last_seen_at', sa.Float(), nullable=True),
    )
    op.create_table(
        'display_admin',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('display_id', sa.String(12), sa.ForeignKey('display.id', ondelete='CASCADE'), nullable=False, index=True),
        sa.Column('token_hash', sa.String(64), nullable=False, unique=True),
        sa.Column('created_at', sa.Float(), nullable=False),
    )

def downgrade():
    op.drop_table('display_admin')
    op.drop_table('display')
