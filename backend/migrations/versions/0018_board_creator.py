"""Optional nickname of whoever created a scoreboard, shown to viewers."""
from alembic import op
import sqlalchemy as sa
revision = '0018_board_creator'
down_revision = '0017_devices'
branch_labels = None
depends_on = None

def upgrade():
    with op.batch_alter_table('scoreboard') as batch:
        batch.add_column(sa.Column('creator', sa.String(40), nullable=True))

def downgrade():
    with op.batch_alter_table('scoreboard') as batch:
        batch.drop_column('creator')
