ARG PYTHON_BASE=python:3.15-slim-bookworm
FROM ${PYTHON_BASE} AS build

COPY worker-release-url.txt /tmp/worker-release-url.txt

RUN python -c "from pathlib import Path; from urllib.request import urlretrieve; url = Path('/tmp/worker-release-url.txt').read_text(encoding='utf-8').strip(); urlretrieve(url, '/tmp/worker.tar.gz')" \
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
COPY --from=build /tmp/worker-release-url.txt /opt/functions-worker-release-url.txt
COPY --from=build /home/site/wwwroot/.python_packages/ ./.python_packages/
COPY function_app.py render_pdf_worker.py host.json ./

USER 10001:10001
ENTRYPOINT ["python", "/opt/functions-worker/worker.py"]
