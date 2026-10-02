"""Uploaded team logos, re-encoded to PNG and stored in the database."""
from alembic import op
import sqlalchemy as sa
revision = '0009_assets'
down_revision = '0008_board_stream'
branch_labels = None
depends_on = None

def upgrade():
    op.create_table(
        'asset',
        sa.Column('id', sa.String(32), primary_key=True),
        sa.Column('slug', sa.String(10), sa.ForeignKey('scoreboard.slug'), nullable=False, index=True),
        sa.Column('content_type', sa.String(30), nullable=False),
        sa.Column('data', sa.LargeBinary(), nullable=False),
        sa.Column('created_at', sa.Float(), nullable=False),
    )

def downgrade():
    op.drop_table('asset')
