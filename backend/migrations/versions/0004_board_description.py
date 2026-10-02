"""Optional private scoreboard description."""
from alembic import op
import sqlalchemy as sa
revision = '0004_board_description'
down_revision = '0003_board_location'
branch_labels = None
depends_on = None

def upgrade():
    op.add_column('scoreboard', sa.Column('description', sa.String(300), nullable=True))

def downgrade():
    op.drop_column('scoreboard', 'description')
