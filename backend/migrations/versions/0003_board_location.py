"""Optional scoreboard location; private unless explicitly published."""
from alembic import op
import sqlalchemy as sa
revision = '0003_board_location'
down_revision = '0002_game_management'
branch_labels = None
depends_on = None

def upgrade():
    op.add_column('scoreboard', sa.Column('location', sa.JSON(), nullable=True))

def downgrade():
    op.drop_column('scoreboard', 'location')
