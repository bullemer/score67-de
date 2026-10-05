"""Forum: threads and replies, published after the author's email code."""
from alembic import op
import sqlalchemy as sa
revision = '0011_forum'
down_revision = '0010_accounts'
branch_labels = None
depends_on = None

def upgrade():
    op.create_table('forum_post',
                    sa.Column('id', sa.Integer(), primary_key=True, autoincrement=True),
                    sa.Column('thread_id', sa.Integer(), sa.ForeignKey('forum_post.id'), nullable=True, index=True),
                    sa.Column('title', sa.String(120), nullable=True),
                    sa.Column('body', sa.Text(), nullable=False),
                    sa.Column('author_name', sa.String(60), nullable=False),
                    sa.Column('email', sa.String(254), nullable=False),
                    sa.Column('account_id', sa.String(36), sa.ForeignKey('account.id'), nullable=True),
                    sa.Column('language', sa.String(2), nullable=False),
                    sa.Column('created_at', sa.Float(), nullable=False),
                    sa.Column('code_hash', sa.String(64), nullable=True),
                    sa.Column('code_expires_at', sa.Float(), nullable=True),
                    sa.Column('code_attempts', sa.Integer(), nullable=False),
                    sa.Column('published_at', sa.Float(), nullable=True, index=True),
                    sa.Column('hidden_at', sa.Float(), nullable=True),
                    sa.Column('moderation_hash', sa.String(64), nullable=True))

def downgrade():
    op.drop_table('forum_post')
