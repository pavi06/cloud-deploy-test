# syntax=docker/dockerfile:1
#
# DevOps & Cloud Explainer Agent — FastAPI backend (Azure OpenAI)
#
# Base: python:3.12-alpine (Docker Official Image). Alpine's minimal package
# set means it scans with no known OS CVEs, unlike the Debian -slim tags.
# Multi-stage build: the builder compiles/installs deps into a venv (with the
# build toolchain), then only that venv + the app land in the clean runtime.
#
#   Build:  docker build -t agentic-api:v1 .
#   Run:    docker run -p 8000:8000 --env-file .env agentic-api:v1
#
# ---- build stage: install dependencies into a venv -------------------------
FROM python:3.12-alpine AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

# Toolchain so any package without a musl wheel can still build (discarded
# with this stage — none of it ends up in the final image).
RUN apk add --no-cache build-base libffi-dev cargo

WORKDIR /app
RUN python -m venv /venv
ENV PATH="/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- runtime stage: minimal official Alpine image, nonroot -----------------
FROM python:3.12-alpine

ENV PYTHONUNBUFFERED=1 \
    PATH="/venv/bin:$PATH"

# Run as an unprivileged user
RUN addgroup -S app && adduser -S -G app app

WORKDIR /app

# Bring in the ready-made venv and the app code
# (.dockerignore keeps .env, .venv and caches out of the image)
COPY --from=builder /venv /venv
COPY . .

USER app
EXPOSE 8000

# Secrets (AZURE_OPENAI_*) are injected at runtime via --env-file / app
# settings, never baked into the image.
ENTRYPOINT ["python", "-m", "uvicorn", "main:app", \
            "--host", "0.0.0.0", "--port", "8000"]
