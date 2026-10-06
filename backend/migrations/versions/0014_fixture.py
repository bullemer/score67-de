"""Game facts imported from league websites (fussball.de, basketball-bund.net)."""
from alembic import op
import sqlalchemy as sa
revision = '0014_fixture'
down_revision = '0013_firmware'
branch_labels = None
depends_on = None

def upgrade():
    with op.batch_alter_table('match') as batch:
        batch.add_column(sa.Column('fixture', sa.JSON(), nullable=True))

def downgrade():
    with op.batch_alter_table('match') as batch:
        batch.drop_column('fixture')
