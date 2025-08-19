# Draft
# variables list
#$rgname = ""
$subid = ""
################################################################################################################################
az login
az account set --subscription $subid

# --- Helpers ---
function Coalesce {
    param([object[]]$vals, $default = $null)
    foreach ($v in $vals) { if ($null -ne $v -and $v -ne "") { return $v } }
    return $default
}

function Parse-PipId {
    param([string]$id)
    # /subscriptions/.../resourceGroups/<rg>/providers/Microsoft.Network/publicIPAddresses/<name>
    $rg=$null; $name=$null
    if ($id) {
        $parts = $id.Trim('/').Split('/')
        for ($i=0; $i -lt $parts.Length; $i++) {
            if ($parts[$i] -eq 'resourceGroups' -and ($i+1) -lt $parts.Length) { $rg = $parts[$i+1] }
            if ($parts[$i] -eq 'publicIPAddresses' -and ($i+1) -lt $parts.Length) { $name = $parts[$i+1] }
        }
    }
    [pscustomobject]@{ ResourceGroup = $rg; Name = $name }
}

# --- 1) Pull once ---
$agws = az network application-gateway list -o json | ConvertFrom-Json
$pips = az network public-ip list -o json | ConvertFrom-Json

# --- 2) Index Public IPs by full resource ID (case-insensitive) ---
$pipById = @{}
foreach ($pip in $pips) {
    if ($pip -and $pip.id) { $pipById[$pip.id.ToLower()] = $pip }
}

# --- 3) Build results (uses correct properties paths) ---
$result = foreach ($ag in $agws) {

    $fips  = Coalesce @($ag.properties.frontendIPConfigurations, $ag.frontendIPConfigurations)
    $agSku = Coalesce @($ag.properties.sku.name, $ag.sku.name)

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
        # Public IP ref may be under properties or top-level depending on CLI/object shape
        $pipRef = Coalesce @($fip.properties.publicIPAddress, $fip.publicIPAddress)
        $pipId  = if ($pipRef) { $pipRef.id } else { $null }
        $pip    = if ($pipId) { $pipById[$pipId.ToLower()] } else { $null }

        $pipName = if ($pip) { $pip.name } elseif ($pipId) { Split-Path $pipId -Leaf } else { "-" }
        $skuName = if ($pip) { $pip.sku.name } else { if ($pipId) { "Unknown" } else { "None (private-only)" } }
        $skuTier = if ($pip) { $pip.sku.tier } else { "-" }
        $alloc   = if ($pip) { $pip.properties.publicIPAllocationMethod } else { "-" }

        # Primary: read from list payload (correct path is properties.ipAddress)
        $ipAddr  = if ($pip) { $pip.properties.ipAddress } else { "-" }

        # Fallback A: if prefix-backed, show prefix name
        if (-not $ipAddr -or $ipAddr -eq "") {
            $prefixId = if ($pip) { $pip.properties.publicIPPrefix.id } else { $null }
            if ($prefixId) { $ipAddr = "[From Prefix: $(Split-Path $prefixId -Leaf)]" }
        }

        # Fallback B: one-off refresh via --ids (handles occasional stale list payloads)
        if (-not $ipAddr -or $ipAddr -eq "") {
            if ($pipId) {
                try {
                    $fresh = az network public-ip show --ids $pipId -o json | ConvertFrom-Json
                    if ($fresh) {
                        if (-not $ipAddr -or $ipAddr -eq "") { $ipAddr = $fresh.properties.ipAddress }
                        if (-not $alloc  -or $alloc  -eq "-") { $alloc  = $fresh.properties.publicIPAllocationMethod }
                        if (-not $skuName -or $skuName -eq "Unknown") { $skuName = $fresh.sku.name }
                        if (-not $skuTier -or $skuTier -eq "-") { $skuTier = $fresh.sku.tier }
                    }
                } catch { }
            }
        }

        # Fallback C: direct by RG+name (some tenants return data here when --ids is stale)
        if (-not $ipAddr -or $ipAddr -eq "") {
            $parsed = Parse-PipId -id $pipId
            if ($parsed.ResourceGroup -and $parsed.Name) {
                try {
                    $fresh2 = az network public-ip show -g $parsed.ResourceGroup -n $parsed.Name -o json | ConvertFrom-Json
                    if ($fresh2) {
                        if (-not $ipAddr -or $ipAddr -eq "") { $ipAddr = $fresh2.properties.ipAddress }
                        if (-not $alloc  -or $alloc  -eq "-") { $alloc  = $fresh2.properties.publicIPAllocationMethod }
                        if (-not $skuName -or $skuName -eq "Unknown") { $skuName = $fresh2.sku.name }
                        if (-not $skuTier -or $skuTier -eq "-") { $skuTier = $fresh2.sku.tier }
                    }
                } catch { }
            }
        }

        if (-not $ipAddr -or $ipAddr -eq "") { $ipAddr = "Unallocated" }

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

# Examples:
# Only Basic Public IPs (targets to upgrade)
# $result | Where-Object { $_.PublicIPSKU -eq 'Basic' } | ft

# Rows missing an address (dynamic/unallocated or prefix-backed)
# $result | Where-Object { -not $_.PublicIPAddress -or $_.PublicIPAddress -eq 'Unallocated' -or $_.PublicIPAddress -like '[From Prefix:*' } | ft


$pipId = "<full /subscriptions/.../publicIPAddresses/...>"
az network public-ip show --ids $pipId --query "[ipAddress, properties.ipAddress, publicIPAllocationMethod, sku.name]" -o table
