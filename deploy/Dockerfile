FROM python:3.11-slim
WORKDIR /srv/score67
RUN pip install --no-cache-dir uv==0.6.2
COPY backend/pyproject.toml backend/uv.lock backend/
RUN cd backend && uv sync --locked --no-dev
COPY backend/score67 backend/score67
COPY backend/alembic.ini backend/alembic.ini
COPY backend/migrations backend/migrations
COPY shared shared
COPY control/build/web control/build/web
RUN useradd --system --uid 10001 score67 && chown -R score67:score67 /srv/score67
USER score67
WORKDIR /srv/score67/backend
EXPOSE 8000
CMD [".venv/bin/uvicorn", "score67.app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--proxy-headers", "--forwarded-allow-ips", "172.30.67.1,127.0.0.1"]
