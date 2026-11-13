<!--
---
name: Python HTML-to-PDF on Azure Functions Flex Consumption containers
description: >-
  This template repository contains an Azure Functions Flex Consumption
  container reference sample written in Python 3.15 and deployed with the
  Azure Developer CLI. It accepts bounded HTML and returns a PDF rendered with
  Playwright and OS-installed Chromium.
page_type: sample
languages:
- python
- bicep
- azdeveloper
- dockerfile
products:
- azure
- azure-functions
- azure-container-registry
urlFragment: flex-container-html2pdf-python
---
-->

# Python HTML-to-PDF on Azure Functions Flex Consumption containers

This sample accepts self-contained HTML in an HTTP POST request and returns a
PDF rendered with Playwright and the operating system's Chromium package.

The Azure Functions app runs from a Python 3.15 Flex Consumption container.
Azure Developer CLI (`azd`) provisions the Azure resources, builds the
container with Azure Container Registry Tasks, deploys it by immutable digest,
and verifies the live endpoint.

![Architecture diagram for Python HTML-to-PDF on Azure Functions Flex Consumption containers](./img/architecture.svg)

> [!IMPORTANT]
> Azure Functions Flex Consumption container support is currently in preview.
> Preview capabilities and deployment requirements may change before general
> availability.

## Sample workflow

1. Clone the repository.
1. Run `azd up` to build and deploy the Python 3.15 container.
1. POST your HTML to `/api/html-to-pdf`.
1. Save or display the returned `application/pdf` response.

You may use `func start` to verify your function code locally. During the
preview, testing the container locally isn't supported; deploy to Azure for
end-to-end container testing.

## Prerequisites

- [Git](https://git-scm.com/downloads)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- an Azure subscription enabled for the Registry-backed Flex Consumption
  container preview
- permission to create resource groups, storage, monitoring, Azure Container
  Registry, FC1 plans, and Function Apps

## Initialize the project

```shell
git clone https://github.com/Azure-Samples/flex-container-html2pdf-python.git
cd flex-container-html2pdf-python
```

## How it works

[`function_app.py`](./function_app.py) exposes one customer endpoint:

```text
POST /api/html-to-pdf
Content-Type: text/html; charset=utf-8
```

The function:

1. validates the media type, UTF-8 body, and 128 KiB input limit;
1. starts [`render_pdf_worker.py`](./render_pdf_worker.py) in a separate
   process with a 20-second hard timeout;
1. uses Playwright to launch OS-installed Chromium as a non-root user;
1. disables JavaScript and blocks external HTTP, HTTPS, and file requests;
1. validates the generated PDF and its 8 MiB output limit;
1. returns `application/pdf` as `document.pdf`.

Exact runtime and dependency pins live in the
[`Dockerfile`](./Dockerfile) and [`requirements.txt`](./requirements.txt),
which are the source of truth for version updates.

## How the container image is built

The deployment uses
[Azure Container Registry Tasks](https://learn.microsoft.com/azure/container-registry/container-registry-tasks-overview)
to build the Linux AMD64 image in Azure. Customers don't need local Docker to
deploy the sample.

During `azd up`:

1. [`imagecontext.py`](./infra/scripts/imagecontext.py) stages only files that
   affect the image and calculates a deterministic SHA-256.
1. The hash becomes the image tag: `azd-<context-hash>`.
1. An existing tag is reused; otherwise `az acr build` runs the ACR Tasks
   quick build.
1. The workflow resolves the registry manifest digest.
1. The Function App is pinned to
   `registry/repository:tag@sha256:digest`.
1. The tag is write- and delete-locked so its digest can't move.

## Deploy to Azure

Sign in:

```shell
az login
azd auth login
```

Create an `azd` environment and set the required deployment locations:

```shell
azd env new python-pdf-flex --no-prompt
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_LOCATION eastus2
azd env set AZURE_FUNCTION_LOCATION eastus2euap
```

`AZURE_LOCATION` is used for storage, ACR, Log Analytics, and Application
Insights. `AZURE_FUNCTION_LOCATION` is used for the FC1 plan and Function App.
The split is required because Log Analytics isn't available in
`eastus2euap`.

Provision the resources, build the container, deploy it, and verify the POST
endpoint:

```shell
azd up
```

For unattended execution, use `azd up --no-prompt` after all four environment
values are set.

## Test the deployed container

Get the deployed endpoint.

PowerShell:

```powershell
$apiUrl = azd env get-value API_URL
```

Bash:

```bash
API_URL=$(azd env get-value API_URL)
```

POST the included [`sample.html`](./sample.html).

PowerShell:

```powershell
curl.exe --fail --show-error `
  --request POST `
  --header "Content-Type: text/html; charset=utf-8" `
  --data-binary "@sample.html" `
  --output document.pdf `
  --write-out "HTTP %{http_code}; Content-Type %{content_type}; Bytes %{size_download}`n" `
  "$apiUrl/api/html-to-pdf"
```

Bash:

```bash
curl --fail --show-error \
  --request POST \
  --header "Content-Type: text/html; charset=utf-8" \
  --data-binary @sample.html \
  --output document.pdf \
  --write-out $'HTTP %{http_code}; Content-Type %{content_type}; Bytes %{size_download}\n' \
  "$API_URL/api/html-to-pdf"
```

Expected output resembles:

```text
HTTP 200; Content-Type application/pdf; Bytes 36404
```

The byte count varies but must be greater than zero. Verify the PDF boundaries:

```shell
python -c "from pathlib import Path; b=Path('document.pdf').read_bytes(); assert b.startswith(b'%PDF-') and b.rstrip().endswith(b'%%EOF'); print(f'Valid PDF: {len(b)} bytes')"
```

Expected output:

```text
Valid PDF: <non-zero byte count> bytes
```

Open the generated PDF.

Windows:

```powershell
Start-Process .\document.pdf
```

macOS:

```bash
open document.pdf
```

Linux:

```bash
xdg-open document.pdf
```

The displayed PDF should contain:

- **Azure Functions HTML-to-PDF**
- **Rendered with Playwright and system Chromium**
- **This document is self-contained and does not load external resources.**

## Redeploy container changes

This section isn't needed for the initial deployment. Use it later if you
change the application code, Python dependencies, or Dockerfile and want to
deploy an updated container.

Rerun `azd up`, or use the image-only workflow after the environment is
provisioned:

PowerShell:

```powershell
.\infra\scripts\deployimage.ps1 -Verify
```

Bash:

```bash
sh ./infra/scripts/deployimage.sh --verify
```

Unchanged image inputs reuse the existing digest.

## Security

Rendering untrusted HTML invokes a complex browser parser. Before production
use, add authentication, authorization, rate limiting, tenant isolation, abuse
monitoring, and workload-specific HTML sanitization.

This sample:

- uses an anonymous HTTP trigger only to simplify the sample;
- keeps ACR admin and anonymous pull disabled;
- grants the Function App a repository-scoped read-only pull credential;
- passes registry and storage secrets only as secure deployment parameters;
- doesn't write those secrets to source or `azd` environment outputs;
- runs the application and Chromium as UID/GID `10001`;
- keeps Chromium's sandbox enabled;
- disables JavaScript and external subresources;
- bounds input, output, concurrency, and execution time.

## Preview limitations

- The direct Registry deployment uses preview Azure resource APIs.
- Region and subscription enablement are required.
- Storage and ACR use public service endpoints in this sample.
- Runtime storage currently uses a connection string passed as a secure
  deployment parameter.
- The HTTP endpoint is anonymous.
- The image is Linux AMD64 only.

## Costs

The environment can incur charges for:

- Flex Consumption executions;
- Azure Container Registry storage and ACR Tasks builds;
- the storage account;
- Log Analytics and Application Insights ingestion;
- Chromium CPU time and cold starts.

## Clean up resources

Review the selected environment:

```shell
azd env get-values
```

Delete the resource group and all resources created for that environment:

```shell
azd down --force
```

This command doesn't delete the local repository.

## Resources

- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/)
- [Run Azure Functions locally](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- [Azure Functions Flex Consumption](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan)
- [Azure Functions Python developer guide](https://learn.microsoft.com/azure/azure-functions/functions-reference-python)
- [Azure Container Registry Tasks](https://learn.microsoft.com/azure/container-registry/container-registry-tasks-overview)
- [Playwright Python](https://playwright.dev/python/)

## License

This sample is licensed under the [MIT License](LICENSE.md).
