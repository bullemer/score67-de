"""Self-registering display devices: device key, brightness, identify, firmware status."""
from alembic import op
import sqlalchemy as sa
revision = '0012_display_device'
down_revision = '0011_forum'
branch_labels = None
depends_on = None

def upgrade():
    with op.batch_alter_table('display') as batch:
        batch.add_column(sa.Column('device_key_hash', sa.String(64), nullable=True))
        batch.add_column(sa.Column('brightness', sa.Integer(), nullable=True))
        batch.add_column(sa.Column('identify_until', sa.Float(), nullable=True))
        batch.add_column(sa.Column('fw_version', sa.String(20), nullable=True))
        batch.add_column(sa.Column('rssi', sa.Integer(), nullable=True))
        batch.create_unique_constraint('uq_display_device_key_hash', ['device_key_hash'])

def downgrade():
    with op.batch_alter_table('display') as batch:
        batch.drop_constraint('uq_display_device_key_hash', type_='unique')
        for column in ('rssi', 'fw_version', 'identify_until', 'brightness', 'device_key_hash'):
            batch.drop_column(column)
