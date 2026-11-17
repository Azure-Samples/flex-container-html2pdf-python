#!/usr/bin/env sh
set -eu

if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null 2>&1; then
    PYTHON=python
else
    echo "Python 3 is required." >&2
    exit 1
fi

# Root-level azd hooks run with the repository as their working directory.
get_azd_value() {
    name=$1
    eval "value=\${$name:-}"
    if [ -z "$value" ]; then
        value=$(azd env get-value "$name")
    fi
    if [ -z "$value" ]; then
        echo "Required azd environment value '$name' is missing." >&2
        exit 1
    fi
    printf '%s' "$value"
}

AZURE_SUBSCRIPTION_ID=$(get_azd_value AZURE_SUBSCRIPTION_ID)
AZURE_RESOURCE_GROUP=$(get_azd_value AZURE_RESOURCE_GROUP)
AZURE_FUNCTION_NAME=$(get_azd_value AZURE_FUNCTION_NAME)
API_URL=$(get_azd_value API_URL)
AZURE_REGISTRY_IMAGE=$(get_azd_value AZURE_REGISTRY_IMAGE)
API_URL=${API_URL%/}
SITE_ID="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.Web/sites/$AZURE_FUNCTION_NAME"

az account set --subscription "$AZURE_SUBSCRIPTION_ID"

CUSTOM_PATH=$(mktemp "${TMPDIR:-/tmp}/custom.XXXXXX.pdf")
cleanup() {
    rm -f -- "$CUSTOM_PATH"
}
trap cleanup EXIT INT TERM

validate_pdf() {
    "$PYTHON" - "$1" <<'PY'
from pathlib import Path
import re
import sys

pdf = Path(sys.argv[1]).read_bytes()
if (
    len(pdf) < 100
    or not pdf.startswith(b"%PDF-")
    or re.search(rb"%%EOF\s*$", pdf[-128:]) is None
):
    raise RuntimeError(f"Invalid PDF: {sys.argv[1]}")
print(len(pdf))
PY
}

ATTEMPT=1
MAX_ATTEMPTS=36
RESTARTED=false
PDF_POST_BYTES=

while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    rm -f -- "$CUSTOM_PATH"
    RESPONSE_CONTENT_TYPE=$(curl --fail --silent --show-error --max-time 120 \
        --request POST \
        --header 'Content-Type: text/html; charset=utf-8' \
        --data-binary '<!doctype html><html lang="en"><body><h1>Flex Consumption container validation</h1><p>Rendered from bounded raw HTML.</p></body></html>' \
        "$API_URL/api/html-to-pdf" \
        --output "$CUSTOM_PATH" \
        --write-out '%{content_type}' 2>/dev/null) || RESPONSE_CONTENT_TYPE=
    if [ "$RESPONSE_CONTENT_TYPE" = "application/pdf" ] &&
        PDF_POST_BYTES=$(validate_pdf "$CUSTOM_PATH"); then
        break
    fi

    if [ "$ATTEMPT" -eq 12 ] && [ "$RESTARTED" = false ]; then
        az functionapp restart \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --name "$AZURE_FUNCTION_NAME" \
            --only-show-errors
        RESTARTED=true
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 10
done

if [ -z "$PDF_POST_BYTES" ]; then
    echo "The HTML-to-PDF endpoint did not become healthy within six minutes." >&2
    exit 1
fi

FUNCTION_NAMES=
INVENTORY_ATTEMPT=1
while [ "$INVENTORY_ATTEMPT" -le 24 ]; do
    FUNCTION_NAMES=$(az rest \
        --method get \
        --url "https://management.azure.com$SITE_ID/functions?api-version=2026-08-01" \
        --query 'value[].name' \
        --output tsv)
    FUNCTION_COUNT=$(
        printf '%s\n' "$FUNCTION_NAMES" |
            awk 'NF { count++ } END { print count + 0 }'
    )
    if [ "$FUNCTION_COUNT" -eq 1 ] &&
        printf '%s\n' "$FUNCTION_NAMES" | grep -Eq '(^|/)HtmlToPdf$'; then
        break
    fi
    INVENTORY_ATTEMPT=$((INVENTORY_ATTEMPT + 1))
    sleep 5
done

if [ "$FUNCTION_COUNT" -ne 1 ] ||
    ! printf '%s\n' "$FUNCTION_NAMES" | grep -Eq '(^|/)HtmlToPdf$'; then
    echo "Azure did not inventory only HtmlToPdf: $FUNCTION_NAMES" >&2
    exit 1
fi

DEPLOYMENT_JSON=$(az rest \
    --method get \
    --url "https://management.azure.com$SITE_ID?api-version=2026-08-01" \
    --query '{state:properties.state,type:properties.functionAppConfig.deployment.storage.type,value:properties.functionAppConfig.deployment.storage.value}' \
    --output json)
export DEPLOYMENT_JSON AZURE_REGISTRY_IMAGE
"$PYTHON" - <<'PY'
import json
import os

deployment = json.loads(os.environ["DEPLOYMENT_JSON"])
if (
    deployment["state"] != "Running"
    or deployment["type"] != "Registry"
    or deployment["value"] != os.environ["AZURE_REGISTRY_IMAGE"]
):
    raise RuntimeError(
        "The Function App Registry configuration does not match."
    )
PY

SETTING_NAMES=$(az rest \
    --method post \
    --url "https://management.azure.com$SITE_ID/config/appsettings/list?api-version=2026-08-01" \
    --query 'keys(properties)' \
    --output tsv)
for forbidden in \
    FUNCTIONS_APPLICATION_DIRECTORY \
    AzureWebJobsScriptRoot \
    WEBSITE_RUN_FROM_PACKAGE
do
    if printf '%s\n' "$SETTING_NAMES" | grep -Fxq "$forbidden"; then
        echo "Forbidden application setting '$forbidden' is present." >&2
        exit 1
    fi
done

export FUNCTION_NAMES AZURE_FUNCTION_NAME PDF_POST_BYTES
VERIFICATION_JSON=$("$PYTHON" - <<'PY'
import json
import os


print(
    json.dumps(
        {
            "functionApp": os.environ["AZURE_FUNCTION_NAME"],
            "functions": [
                name
                for name in os.environ["FUNCTION_NAMES"].splitlines()
                if name
            ],
            "pdfPostBytes": int(os.environ["PDF_POST_BYTES"]),
        },
        separators=(",", ":"),
    ),
    end="",
)
PY
)

VERIFIED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
azd env set AZURE_VERIFIED_UTC "$VERIFIED_UTC" --no-prompt >/dev/null
printf '%s\n' "$VERIFICATION_JSON"
