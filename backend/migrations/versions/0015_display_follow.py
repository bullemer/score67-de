"""LED panels follow the game their owner opens in the control center."""
from alembic import op
import sqlalchemy as sa
revision = '0015_display_follow'
down_revision = '0014_fixture'
branch_labels = None
depends_on = None

def upgrade():
    with op.batch_alter_table('display') as batch:
        batch.add_column(sa.Column('follow', sa.Boolean(), nullable=False, server_default=sa.true()))

def downgrade():
    with op.batch_alter_table('display') as batch:
        batch.drop_column('follow')
