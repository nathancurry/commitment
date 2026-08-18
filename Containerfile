FROM python:3.13-slim AS builder

WORKDIR /build
COPY pyproject.toml README.md LICENSE ./
COPY src ./src
RUN python -m pip wheel --no-deps --wheel-dir /wheelhouse .

FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY --from=builder /wheelhouse /wheelhouse
RUN python -m pip install --no-cache-dir --no-index --find-links=/wheelhouse commitment \
    && rm -rf /wheelhouse \
    && mkdir /opt/commitment /repo \
    && chown 10001:10001 /opt/commitment /repo

USER 10001:10001
WORKDIR /opt/commitment

ENTRYPOINT ["python", "-I", "-m", "commitment"]
