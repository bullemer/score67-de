"""Optional public livestream link (YouTube, Facebook, …) per scoreboard."""
from alembic import op
import sqlalchemy as sa
revision = '0008_board_stream'
down_revision = '0007_displays'
branch_labels = None
depends_on = None

def upgrade():
    op.add_column('scoreboard', sa.Column('stream_url', sa.String(300), nullable=True))

def downgrade():
    op.drop_column('scoreboard', 'stream_url')
