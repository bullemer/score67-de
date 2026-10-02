import os
import time
from pathlib import Path

from sqlalchemy import JSON, Boolean, Float, ForeignKey, Integer, String, create_engine, event, text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker


class Base(DeclarativeBase):
    pass


class Board(Base):
    __tablename__ = "scoreboard"
    slug: Mapped[str] = mapped_column(String(10), primary_key=True)
    name: Mapped[str] = mapped_column(String(80))
    language: Mapped[str] = mapped_column(String(2))
    pin_hash: Mapped[str] = mapped_column(String(200))
    failed_count: Mapped[int] = mapped_column(default=0)
    locked_until: Mapped[float] = mapped_column(Float, default=0)
    active_match: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[float] = mapped_column(Float)
    location: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    description: Mapped[str | None] = mapped_column(String(300), nullable=True)


class Admin(Base):
    __tablename__ = "scoreboard_admin"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    slug: Mapped[str] = mapped_column(ForeignKey("scoreboard.slug"), index=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    label: Mapped[str] = mapped_column(String(60))
    last_seen_at: Mapped[float] = mapped_column(Float)
    revoked: Mapped[bool] = mapped_column(Boolean, default=False)


class Match(Base):
    __tablename__ = "match"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    slug: Mapped[str] = mapped_column(ForeignKey("scoreboard.slug"), index=True)
    revision: Mapped[int] = mapped_column(Integer, default=0)
    state: Mapped[dict] = mapped_column(JSON)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)
    scheduled_at: Mapped[float | None] = mapped_column(Float, nullable=True)
    archived_at: Mapped[float | None] = mapped_column(Float, nullable=True)
    deleted_at: Mapped[float | None] = mapped_column(Float, nullable=True)


class MatchEvent(Base):
    __tablename__ = "match_event"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    match_id: Mapped[str] = mapped_column(ForeignKey("match.id"), index=True)
    admin_id: Mapped[str] = mapped_column(ForeignKey("scoreboard_admin.id"))
    payload: Mapped[dict] = mapped_column(JSON)
    before: Mapped[dict] = mapped_column(JSON)
    cancelled: Mapped[bool] = mapped_column(Boolean, default=False)


class Receipt(Base):
    __tablename__ = "command_receipt"
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    fingerprint: Mapped[str] = mapped_column(String(64))


class RateLimit(Base):
    __tablename__ = "rate_limit"
    key: Mapped[str] = mapped_column(String(100), primary_key=True)
    count: Mapped[int] = mapped_column(Integer)
    reset_at: Mapped[float] = mapped_column(Float)


def database(url: str | None = None):
    url = url or os.getenv("DATABASE_URL", "sqlite:///./data/score67.db")
    if url.startswith("sqlite"):
        Path("data").mkdir(exist_ok=True)
    engine = create_engine(url, connect_args={"check_same_thread": False} if url.startswith("sqlite") else {})
    if url.startswith("sqlite"):
        @event.listens_for(engine, "connect")
        def configure(connection, _):
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA journal_mode=WAL")
    if os.getenv("AUTO_CREATE_SCHEMA", "true").lower() == "true":
        Base.metadata.create_all(engine)
    else:
        with engine.connect() as connection:
            version = connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one()
            if version != "0004_board_description":
                raise RuntimeError("Database schema does not match this release; run migrations first")
    return engine, sessionmaker(engine, expire_on_commit=False)
