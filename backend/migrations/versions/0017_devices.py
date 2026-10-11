"""Devices: one cookie per browser instead of one per board. The server keeps
which boards a device controls, so the list survives the cookie cap and can be
shared with another browser through a connect link."""
from alembic import op
import sqlalchemy as sa
revision = '0017_devices'
down_revision = '0016_drop_legacy_displays'
branch_labels = None
depends_on = None

def upgrade():
    op.create_table('device',
                    sa.Column('id', sa.String(36), primary_key=True),
                    sa.Column('link_hash', sa.String(64), nullable=True, unique=True),
                    sa.Column('created_at', sa.Float(), nullable=False))
    op.create_table('device_token',
                    sa.Column('token_hash', sa.String(64), primary_key=True),
                    sa.Column('device_id', sa.String(36), sa.ForeignKey('device.id', ondelete='CASCADE'), nullable=False, index=True),
                    sa.Column('created_at', sa.Float(), nullable=False),
                    sa.Column('last_seen_at', sa.Float(), nullable=False))
    with op.batch_alter_table('scoreboard_admin') as batch:
        batch.add_column(sa.Column('device_id', sa.String(36), sa.ForeignKey('device.id', name='fk_admin_device'), nullable=True))
        batch.create_index('ix_scoreboard_admin_device_id', ['device_id'])

def downgrade():
    with op.batch_alter_table('scoreboard_admin') as batch:
        batch.drop_index('ix_scoreboard_admin_device_id')
        batch.drop_column('device_id')
    op.drop_table('device_token')
    op.drop_table('device')
