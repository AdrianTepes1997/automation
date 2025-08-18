# Draft
# variables list
#$rgname = ""
$subid = ""
################################################################################################################################
az login
az account set --subscription $subid

# --- 1) Pull everything once ---
$agws = az network application-gateway list -o json | ConvertFrom-Json
$pips = az network public-ip list -o json | ConvertFrom-Json

# --- 2) Index Public IPs by full resource ID (case-insensitive) ---
$pipById = @{}
foreach ($pip in $pips) {
    if ($pip -and $pip.id) { $pipById[$pip.id.ToLower()] = $pip }
}

# --- 3) Build results locally (no more az calls) ---
$result = foreach ($ag in $agws) {

    # Handle CLI flattening differences (some fields appear under .properties in certain versions)
    $fips  = if ($ag.properties -and $ag.properties.frontendIPConfigurations) { 
                $ag.properties.frontendIPConfigurations 
             } else { 
                $ag.frontendIPConfigurations 
             }

    $agSku = if ($ag.properties -and $ag.properties.sku) { 
                $ag.properties.sku.name 
             } else { 
                $ag.sku.name 
             }

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
        $pipId = $fip.properties.publicIPAddress.id
        if ($pipId) {
            $pip = $pipById[$pipId.ToLower()]
            [pscustomobject]@{
                ApplicationGateway = $ag.name
                ResourceGroup      = $ag.resourceGroup
                FrontendIPConfig   = $fip.name
                PublicIPName       = $pip.name
                PublicIPAddress    = $pip.properties.ipAddress
                PublicIPSKU        = $pip.sku.name
                PublicIPTier       = $pip.sku.tier
                AllocationMethod   = $pip.properties.publicIPAllocationMethod
                AgwSkuName         = $agSku
            }
        }
        else {
            [pscustomobject]@{
                ApplicationGateway = $ag.name
                ResourceGroup      = $ag.resourceGroup
                FrontendIPConfig   = $fip.name
                PublicIPName       = "-"
                PublicIPAddress    = "-"
                PublicIPSKU        = "None (private-only)"
                PublicIPTier       = "-"
                AllocationMethod   = "-"
                AgwSkuName         = $agSku
            }
        }
    }
}

# --- 4) Display + CSV ---
$result | Sort-Object ResourceGroup, ApplicationGateway, FrontendIPConfig | Format-Table

# Timestamped CSV (prevents accidental overwrite)
$ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
$outFile = ".\AppGateway_IPs_$ts.csv"
$result | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
Write-Host "Saved: $outFile"

# Example: find gateways using Basic public IPs (targets to upgrade)
# $result | Where-Object { $_.PublicIPSKU -eq 'Basic' } | Format-Table