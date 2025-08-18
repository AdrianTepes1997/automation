# Draft
# variables list
#$rgname = ""
$subid = ""
################################################################################################################################
az login
az account set --subscription $subid

# --- Helper: first non-null/non-empty from a list ---
function Coalesce {
    param([object[]]$vals, $default = $null)
    foreach ($v in $vals) {
        if ($null -ne $v -and $v -ne "") { return $v }
    }
    return $default
}

# --- 1) Pull once ---
$agws = az network application-gateway list -o json | ConvertFrom-Json
$pips = az network public-ip list -o json | ConvertFrom-Json

# --- 2) Index Public IPs by full resource ID (case-insensitive) ---
$pipById = @{}
foreach ($pip in $pips) {
    if ($pip -and $pip.id) { $pipById[$pip.id.ToLower()] = $pip }
}

# --- 3) Build results (PowerShell 5.1 safe) ---
$result = foreach ($ag in $agws) {

    $fips  = Coalesce @(
        $ag.properties.frontendIPConfigurations,
        $ag.frontendIPConfigurations
    )

    $agSku = Coalesce @(
        $ag.properties.sku.name,
        $ag.sku.name
    )

    if (-not $fips) {
        [pscustomobject]@{
            ApplicationGateway = $ag.name
            ResourceGroup      = $ag.resourceGroup
            FrontendIPConfig   = "-"
            PublicIPName       = "-"
            PublicIPAddress    = "-"
            PublicIPSKU        = "None (no frontend IPs)"
            PublicIPTier       = "-"
            AllocationMethod   = "-"
            AgwSkuName         = $agSku
        }
        continue
    }

    foreach ($fip in $fips) {

        $pipRef = Coalesce @(
            $fip.properties.publicIPAddress,
            $fip.publicIPAddress
        )

        $pipId = if ($pipRef) { $pipRef.id } else { $null }
        $pip   = if ($pipId) { $pipById[$pipId.ToLower()] } else { $null }

        # Derive fields safely (don’t touch members on $null)
        $pipName = if ($pip) { $pip.name } elseif ($pipId) { Split-Path $pipId -Leaf } else { "-" }
        $ipAddr  = if ($pip) { $pip.properties.ipAddress } else { "-" }
        $skuName = if ($pip) { $pip.sku.name } else { if ($pipId) { "Unknown" } else { "None (private-only)" } }
        $skuTier = if ($pip) { $pip.sku.tier } else { "-" }
        $alloc   = if ($pip) { $pip.properties.publicIPAllocationMethod } else { "-" }

        [pscustomobject]@{
            ApplicationGateway = $ag.name
            ResourceGroup      = $ag.resourceGroup
            FrontendIPConfig   = $fip.name
            PublicIPName       = $pipName
            PublicIPAddress    = $ipAddr
            PublicIPSKU        = $skuName
            PublicIPTier       = $skuTier
            AllocationMethod   = $alloc
            AgwSkuName         = $agSku
        }
    }
}

# --- 4) Display + CSV ---
$result | Sort-Object ResourceGroup, ApplicationGateway, FrontendIPConfig | Format-Table

$ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
$outFile = ".\AppGateway_IPs_$ts.csv"
$result | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
Write-Host "Saved: $outFile"

# Example: rows missing IPs (dynamic/unallocated or private-only)
# $result | Where-Object { -not $_.PublicIPAddress -or $_.PublicIPAddress -eq "-" } | Format-Table