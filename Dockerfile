ARG PYTHON_BASE=python:3.15-slim-bookworm
FROM ${PYTHON_BASE} AS build

COPY worker-release-url.txt /tmp/worker-release-url.txt

RUN python -c "from pathlib import Path; from urllib.request import urlretrieve; url = Path('/tmp/worker-release-url.txt').read_text(encoding='utf-8').strip(); archive = '/tmp/azure-functions-python-worker-py315-linux-x64.tar.gz'; urlretrieve(url, archive); urlretrieve(url + '.sha256', archive + '.sha256')" \
    && cd /tmp \
    && sha256sum --check --strict azure-functions-python-worker-py315-linux-x64.tar.gz.sha256 \
    && mkdir -p /opt/functions-worker \
    && tar -xzf azure-functions-python-worker-py315-linux-x64.tar.gz -C /opt/functions-worker \
    && rm azure-functions-python-worker-py315-linux-x64.tar.gz azure-functions-python-worker-py315-linux-x64.tar.gz.sha256

COPY requirements.txt /tmp/requirements.txt
ARG PIP_INDEX_URL=https://pypi.org/simple
RUN python -m pip install --no-cache-dir --only-binary=:all: \
    --index-url "${PIP_INDEX_URL}" \
    --target /home/site/wwwroot/.python_packages/lib/site-packages \
    -r /tmp/requirements.txt

FROM ${PYTHON_BASE}

ENV PYTHONUNBUFFERED=1

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
    && groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --create-home --shell /usr/sbin/nologin app

WORKDIR /home/site/wwwroot
COPY --from=build /opt/functions-worker/ /opt/functions-worker/
COPY --from=build /tmp/worker-release-url.txt /opt/functions-worker-release-url.txt
COPY --from=build /home/site/wwwroot/.python_packages/ ./.python_packages/
COPY function_app.py render_pdf_worker.py host.json ./

USER 10001:10001
ENTRYPOINT ["python", "/opt/functions-worker/worker.py"]
