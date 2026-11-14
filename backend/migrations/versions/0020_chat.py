"""Recent scoreboard chat messages."""
from alembic import op
import sqlalchemy as sa
revision = '0020_chat'
down_revision = '0019_saved_teams'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'chat_message',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('slug', sa.String(10), sa.ForeignKey('scoreboard.slug', ondelete='CASCADE'), nullable=False, index=True),
        sa.Column('name', sa.String(40), nullable=False),
        sa.Column('text', sa.String(500), nullable=False),
        sa.Column('controller', sa.Boolean(), nullable=False),
        sa.Column('created_at', sa.Float(), nullable=False),
    )


def downgrade():
    op.drop_table('chat_message')
