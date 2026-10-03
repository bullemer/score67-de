"""Optional email login: accounts, sessions, sign-in links and board owners."""
from alembic import op
import sqlalchemy as sa
revision = '0010_accounts'
down_revision = '0009_assets'
branch_labels = None
depends_on = None

def upgrade():
    op.create_table('account',
                    sa.Column('id', sa.String(36), primary_key=True),
                    sa.Column('email', sa.String(254), nullable=False, unique=True),
                    sa.Column('language', sa.String(2), nullable=False),
                    sa.Column('created_at', sa.Float(), nullable=False))
    op.create_table('account_session',
                    sa.Column('id', sa.String(36), primary_key=True),
                    sa.Column('account_id', sa.String(36), sa.ForeignKey('account.id', ondelete='CASCADE'), nullable=False, index=True),
                    sa.Column('token_hash', sa.String(64), nullable=False, unique=True),
                    sa.Column('created_at', sa.Float(), nullable=False),
                    sa.Column('last_seen_at', sa.Float(), nullable=False))
    op.create_table('login_token',
                    sa.Column('token_hash', sa.String(64), primary_key=True),
                    sa.Column('email', sa.String(254), nullable=False, index=True),
                    sa.Column('created_at', sa.Float(), nullable=False),
                    sa.Column('expires_at', sa.Float(), nullable=False),
                    sa.Column('used_at', sa.Float(), nullable=True))
    with op.batch_alter_table('scoreboard') as batch:
        batch.add_column(sa.Column('owner_id', sa.String(36), sa.ForeignKey('account.id', name='fk_scoreboard_owner'), nullable=True))
        batch.create_index('ix_scoreboard_owner_id', ['owner_id'])
    with op.batch_alter_table('scoreboard_admin') as batch:
        batch.add_column(sa.Column('account_id', sa.String(36), sa.ForeignKey('account.id', name='fk_admin_account'), nullable=True))
        batch.create_index('ix_scoreboard_admin_account_id', ['account_id'])

def downgrade():
    with op.batch_alter_table('scoreboard_admin') as batch:
        batch.drop_index('ix_scoreboard_admin_account_id')
        batch.drop_column('account_id')
    with op.batch_alter_table('scoreboard') as batch:
        batch.drop_index('ix_scoreboard_owner_id')
        batch.drop_column('owner_id')
    op.drop_table('login_token')
    op.drop_table('account_session')
    op.drop_table('account')
