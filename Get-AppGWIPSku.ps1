# working
# variables list
#$rgname = ""
$subid = ""
################################################################################################################################
az login
az account set --subscription $subid

# az login
# az account set --subscription "<SUBSCRIPTION_ID_OR_NAME>"

# 1) Pull resources once
$agws = az network application-gateway list -o json | ConvertFrom-Json
$pips = az network public-ip list -o json | ConvertFrom-Json

# 2) Index Public IPs by their full resource ID (case-insensitive)
$pipById = @{}
foreach ($pip in $pips) {
    $pipById[$pip.id.ToLower()] = $pip
}

# 3) Build results locally
$result = foreach ($ag in $agws) {
    $fips  = $ag.properties.frontendIPConfigurations
    $agSku = $ag.properties.sku.name

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

# 4) Display + CSV
$result | Sort-Object ResourceGroup, ApplicationGateway, FrontendIPConfig | Format-Table

# Timestamped CSV to avoid overwrites
$ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
$outFile = ".\AppGateway_IPs_$ts.csv"
$result | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
Write-Host "Saved: $outFile"
