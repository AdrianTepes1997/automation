# Draft
# variables list
#$rgname = ""
$subid = ""
################################################################################################################################
az login
az account set --subscription $subid

function Coalesce {
    param([object[]]$vals, $default = $null)
    foreach ($v in $vals) {
        if ($null -ne $v -and $v -ne "") { return $v }
    }
    return $default
}

# 1) Pull once
$agws = az network application-gateway list -o json | ConvertFrom-Json
$pips = az network public-ip list -o json | ConvertFrom-Json

# 2) Index PIPs by ID
$pipById = @{}
foreach ($pip in $pips) {
    if ($pip -and $pip.id) { $pipById[$pip.id.ToLower()] = $pip }
}

# 3) Build results
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
        $pipRef = Coalesce @($fip.properties.publicIPAddress, $fip.publicIPAddress)
        $pipId  = if ($pipRef) { $pipRef.id } else { $null }
        $pip    = if ($pipId) { $pipById[$pipId.ToLower()] } else { $null }

        $pipName = if ($pip) { $pip.name } elseif ($pipId) { Split-Path $pipId -Leaf } else { "-" }
        $skuName = if ($pip) { $pip.sku.name } else { if ($pipId) { "Unknown" } else { "None (private-only)" } }
        $skuTier = if ($pip) { $pip.sku.tier } else { "-" }
        $alloc   = if ($pip) { $pip.properties.publicIPAllocationMethod } else { "-" }

        # Primary source
        $ipAddr  = if ($pip) { $pip.properties.ipAddress } else { "-" }

        # If still blank, check for prefix or do a one-off fresh read
        if (-not $ipAddr -or $ipAddr -eq "") {
            $prefixId = if ($pip) { $pip.properties.publicIPPrefix.id } else { $null }
            if ($prefixId) {
                # From a Public IP Prefix but not yet allocated to a concrete address
                $ipAddr = "[From Prefix: $(Split-Path $prefixId -Leaf)]"
            }
            elseif ($pipId) {
                # One-off refresh for this IP (sometimes list payload is stale)
                try {
                    $fresh = az network public-ip show --ids $pipId -o json | ConvertFrom-Json
                    $ipAddr = Coalesce @($fresh.properties.ipAddress, $ipAddr, "Unallocated")
                } catch {
                    if (-not $ipAddr -or $ipAddr -eq "") { $ipAddr = "Unallocated" }
                }
            }
            else {
                if (-not $ipAddr -or $ipAddr -eq "") { $ipAddr = "-" }
            }
        }

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

# 4) Display + CSV
$result | Sort-Object ResourceGroup, ApplicationGateway, FrontendIPConfig | Format-Table

$ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
$outFile = ".\AppGateway_IPs_$ts.csv"
$result | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
Write-Host "Saved: $outFile"

# Optional quick checks:
# Unallocated or prefix-backed rows:
# $result | Where-Object { $_.PublicIPAddress -like "Unallocated" -or $_.PublicIPAddress -like "[From Prefix:*" } | ft