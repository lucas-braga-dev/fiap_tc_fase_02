# syntax=docker/dockerfile:1

# ============================================================
# Estágio 1: construção das dependências
# ============================================================
FROM python:3.11-slim-bookworm AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /build

RUN python -m venv /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"

COPY requirements.txt .

RUN pip install \
    --no-cache-dir \
    --upgrade pip wheel \
    "setuptools==80.9.0" \
    && pip install \
    --no-cache-dir \
    -r requirements.txt

# ============================================================
# Estágio 2: execução
# ============================================================
FROM python:3.11-slim-bookworm AS runtime

ARG DEFAULT_PORT=8002
ARG DEFAULT_WORKERS=2

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}" \
    PORT="${DEFAULT_PORT}" \
    GUNICORN_WORKERS="${DEFAULT_WORKERS}"

WORKDIR /app

RUN groupadd --system app \
    && useradd \
       --system \
       --gid app \
       --home-dir /app \
       --no-create-home \
       app

COPY --from=builder /opt/venv /opt/venv
COPY --chown=app:app app.py /app/app.py

USER app

EXPOSE ${DEFAULT_PORT}

HEALTHCHECK \
    --interval=30s \
    --timeout=5s \
    --start-period=10s \
    --retries=3 \
    CMD python -c \
    "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:' + os.getenv('PORT', '8002') + '/health', timeout=3)"

CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${PORT} --workers ${GUNICORN_WORKERS} --threads 2 --timeout 30 --access-logfile - --error-logfile - app:app"]