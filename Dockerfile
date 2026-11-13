ARG PYTHON_BASE=python:3.15-slim-bookworm
FROM ${PYTHON_BASE} AS build

ARG WORKER_PYTHON=315
ARG WORKER_SHA256=ae40f55204cdf7b278aa80df4be03ab7fd5432de6726b250ad9b243e4725a5de
ADD https://github.com/Azure/azure-functions-python-worker/releases/download/azure_functions_worker-4.46.7/azure-functions-python-worker-4.46.7-py${WORKER_PYTHON}-linux-x64.tar.gz \
    /tmp/worker.tar.gz

RUN printf '%s  %s\n' "${WORKER_SHA256}" /tmp/worker.tar.gz \
        | sha256sum -c - \
    && mkdir -p /opt/functions-worker \
    && tar -xzf /tmp/worker.tar.gz -C /opt/functions-worker \
    && rm /tmp/worker.tar.gz

COPY requirements.txt /tmp/requirements.txt
ARG PIP_INDEX_URL=https://pypi.org/simple
RUN python -m pip install --no-cache-dir --only-binary=:all: \
    --index-url "${PIP_INDEX_URL}" \
    --target /home/site/wwwroot/.python_packages/lib/site-packages \
    -r /tmp/requirements.txt

FROM ${PYTHON_BASE}

ENV CHROMIUM_EXECUTABLE=/usr/bin/chromium \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers-disabled \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        chromium \
        chromium-sandbox \
        fonts-dejavu-core \
        fonts-liberation \
        fonts-noto-color-emoji \
        fonts-noto-core \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/playwright-browsers-disabled \
    && groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --create-home --shell /usr/sbin/nologin app

WORKDIR /home/site/wwwroot
COPY --from=build /opt/functions-worker/ /opt/functions-worker/
COPY --from=build /home/site/wwwroot/.python_packages/ ./.python_packages/
COPY function_app.py render_pdf_worker.py host.json ./

USER 10001:10001
ENTRYPOINT ["python", "/opt/functions-worker/worker.py"]
