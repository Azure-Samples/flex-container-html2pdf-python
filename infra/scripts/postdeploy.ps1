$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# Root-level azd hooks run with the repository as their working directory.
function Get-AzdValue {
    param([Parameter(Mandatory)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = (& azd env get-value $Name).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required azd environment value '$Name' is missing."
    }
    return $value
}

function Test-PdfFile {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 100) {
        throw "PDF '$Path' is unexpectedly small."
    }
    $prefix = [Text.Encoding]::ASCII.GetString($bytes, 0, 5)
    $tailLength = [Math]::Min(128, $bytes.Length)
    $tail = [Text.Encoding]::ASCII.GetString(
        $bytes,
        $bytes.Length - $tailLength,
        $tailLength
    )
    if ($prefix -ne '%PDF-' -or $tail -notmatch '%%EOF\s*$') {
        throw "PDF '$Path' does not contain valid PDF boundary markers."
    }
    return $bytes.Length
}

$subscriptionId = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
$resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
$functionAppName = Get-AzdValue 'AZURE_FUNCTION_NAME'
$apiUrl = (Get-AzdValue 'API_URL').TrimEnd('/')
$registryImage = Get-AzdValue 'AZURE_REGISTRY_IMAGE'
$siteId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$functionAppName"

& az account set --subscription $subscriptionId

$customPath = Join-Path ([IO.Path]::GetTempPath()) (
    "custom-$([guid]::NewGuid().ToString('N')).pdf"
)
$customHtml = @'
<!doctype html>
<html lang="en">
<body>
  <h1>Flex Consumption container validation</h1>
  <p>Rendered from bounded raw HTML.</p>
</body>
</html>
'@

try {
$deadline = [DateTime]::UtcNow.AddMinutes(6)
$restartAt = [DateTime]::UtcNow.AddMinutes(2)
$restarted = $false
$customBytes = $null

while ([DateTime]::UtcNow -lt $deadline) {
    try {
        Remove-Item -LiteralPath $customPath -Force -ErrorAction SilentlyContinue
        $response = Invoke-WebRequest `
            -Uri "$apiUrl/api/html-to-pdf" `
            -Method Post `
            -ContentType 'text/html; charset=utf-8' `
            -Body $customHtml `
            -OutFile $customPath `
            -PassThru `
            -TimeoutSec 120
        if ($response.StatusCode -eq 200 -and
            $response.Headers.'Content-Type' -match '^application/pdf') {
            $customBytes = Test-PdfFile $customPath
            break
        }
    } catch {
        $customBytes = $null
    }

    if (-not $restarted -and [DateTime]::UtcNow -ge $restartAt) {
        & az functionapp restart `
            --resource-group $resourceGroup `
            --name $functionAppName `
            --only-show-errors
        $restarted = $true
    }
    Start-Sleep -Seconds 10
}

if (-not $customBytes) {
    throw "The HTML-to-PDF endpoint did not become healthy within six minutes."
}

$inventoryDeadline = [DateTime]::UtcNow.AddMinutes(2)
$functionNames = @()
do {
    $functionNames = @(
        & az rest `
            --method get `
            --url "https://management.azure.com$siteId/functions?api-version=2026-08-01" `
            --query 'value[].name' `
            --output tsv
    )
    if ($functionNames.Count -eq 1 -and
        $functionNames -match '(^|/)HtmlToPdf$') {
        break
    }
    Start-Sleep -Seconds 5
} while ([DateTime]::UtcNow -lt $inventoryDeadline)

if ($functionNames.Count -ne 1 -or
    -not ($functionNames -match '(^|/)HtmlToPdf$')) {
    throw "Azure did not inventory only HtmlToPdf: $functionNames"
}

$deployment = & az rest `
    --method get `
    --url "https://management.azure.com$siteId`?api-version=2026-08-01" `
    --query '{state:properties.state,type:properties.functionAppConfig.deployment.storage.type,value:properties.functionAppConfig.deployment.storage.value}' `
    --output json |
    ConvertFrom-Json
if ($deployment.state -ne 'Running' -or
    $deployment.type -ne 'Registry' -or
    $deployment.value -ne $registryImage) {
    throw 'The Function App Registry deployment configuration does not match the expected image.'
}

$appSettings = (& az rest `
        --method post `
        --url "https://management.azure.com$siteId/config/appsettings/list?api-version=2026-08-01" `
        --output json |
        ConvertFrom-Json).properties
$settingNames = @($appSettings.PSObject.Properties.Name)
$appSettings = $null
foreach ($forbiddenName in @(
        'FUNCTIONS_APPLICATION_DIRECTORY',
        'AzureWebJobsScriptRoot',
        'WEBSITE_RUN_FROM_PACKAGE'
    )) {
    if ($settingNames -contains $forbiddenName) {
        throw "Forbidden application setting '$forbiddenName' is present."
    }
}

    $verifiedUtc = [DateTime]::UtcNow.ToString('o')
    & azd env set AZURE_VERIFIED_UTC $verifiedUtc --no-prompt | Out-Null

    [ordered]@{
        functionApp = $functionAppName
        state = $deployment.state
        deploymentType = $deployment.type
        image = $deployment.value
        functions = $functionNames
        pdfPostBytes = $customBytes
        verifiedUtc = $verifiedUtc
    } | ConvertTo-Json -Depth 4
} finally {
    Remove-Item -LiteralPath $customPath -Force -ErrorAction SilentlyContinue
}
