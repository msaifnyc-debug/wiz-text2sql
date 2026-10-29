# Build from the REPO ROOT so wizexercise.txt (root) and app/ + data/ are in context:
#   docker build -f app/Dockerfile -t text2sql:dev .
#
# Base image is intentionally pinned to an older patch so the pipeline's image
# scanner (Trivy) surfaces real CVEs - that is the shift-left demo, and the
# "keeping up with security news" thread. Bump it to remediate on camera.

# ---- builder: resolve dependencies into a venv -------------------------------
FROM python:3.11.6-slim-bullseye AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*
COPY app/requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install -r requirements.txt

# ---- release: minimal runtime ------------------------------------------------
FROM python:3.11.6-slim-bullseye AS release
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app
WORKDIR /app

# Non-root OS user (good hygiene). NOTE: the *Kubernetes* ServiceAccount is still
# cluster-admin - that intentional privilege lives in RBAC, not the OS user.
RUN useradd --system --uid 10001 --no-create-home appuser

COPY --from=build /opt/venv /opt/venv
COPY app/src ./src
COPY app/web ./web
COPY data ./data
COPY wizexercise.txt /app/wizexercise.txt

RUN mkdir -p /app/uploads && chown -R appuser:appuser /app/uploads
USER appuser
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz').status==200 else 1)"

CMD ["uvicorn", "web.main:app", "--host", "0.0.0.0", "--port", "8080"]
