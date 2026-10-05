"""LED panel firmware releases for OTA updates; per-panel channel and update status."""
from alembic import op
import sqlalchemy as sa
revision = '0013_firmware'
down_revision = '0012_display_device'
branch_labels = None
depends_on = None

def upgrade():
    op.create_table('firmware_release',
                    sa.Column('version', sa.String(20), primary_key=True),
                    sa.Column('data', sa.LargeBinary(), nullable=False),
                    sa.Column('sha256', sa.String(64), nullable=False),
                    sa.Column('size', sa.Integer(), nullable=False),
                    sa.Column('channel', sa.String(10), nullable=False),
                    sa.Column('notes', sa.String(300), nullable=True),
                    sa.Column('created_at', sa.Float(), nullable=False))
    with op.batch_alter_table('display') as batch:
        batch.add_column(sa.Column('fw_channel', sa.String(10), nullable=True))
        batch.add_column(sa.Column('ota_status', sa.String(60), nullable=True))

def downgrade():
    with op.batch_alter_table('display') as batch:
        batch.drop_column('ota_status')
        batch.drop_column('fw_channel')
    op.drop_table('firmware_release')
