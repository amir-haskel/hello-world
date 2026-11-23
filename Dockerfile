# syntax=docker/dockerfile:1.7
#
# Production image for hello_world.
# - multi-stage: build tools and pip caches never reach the runtime image
# - slim base, pinned deps, non-root user, healthcheck, gunicorn (not the Flask dev server)
# - the app version is baked in as ENV + OCI label, so a running container always knows what it is
#
# Base image: pin by digest in real life (Dependabot keeps the digest fresh), e.g.
#   python:3.13-slim@sha256:<digest>
ARG PYTHON_IMAGE=python:3.13-slim

# ---------- build stage: install dependencies into a venv ----------
FROM ${PYTHON_IMAGE} AS builder
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build
COPY requirements.txt .
# Cache mount = fast rebuilds locally and in CI; nothing ends up in a layer.
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m venv /opt/venv \
 && /opt/venv/bin/pip install -r requirements.txt

# ---------- runtime stage ----------
FROM ${PYTHON_IMAGE} AS runtime

RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --chown=app:app hello_world.py .

# Version args come LAST so a new version doesn't bust the dependency layer cache.
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ENV APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA}
LABEL org.opencontainers.image.title="hello-world" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/amir-haskel/hello-world"

USER app
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2)"]

# exec form -> gunicorn is PID 1 and receives SIGTERM for graceful shutdown on deploys.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--worker-tmp-dir", "/dev/shm", \
     "--access-logfile", "-", "--graceful-timeout", "20", "hello_world:app"]
