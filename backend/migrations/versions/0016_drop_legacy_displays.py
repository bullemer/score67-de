"""Displays created in the app for a device to pair (the Raspberry Pi idea)
never had a device; the Score67 panels register themselves. Drop the leftovers."""
from alembic import op
revision = '0016_drop_legacy_displays'
down_revision = '0015_display_follow'
branch_labels = None
depends_on = None

def upgrade():
    op.execute("DELETE FROM display_admin WHERE display_id IN (SELECT id FROM display WHERE device_key_hash IS NULL)")
    op.execute("DELETE FROM display WHERE device_key_hash IS NULL")

def downgrade():
    pass
