# DRAFT
# variables list
#$rgname = ""
$subid = ""
################################################################################################################################
az login
az account set --subscription $subid

# 1. Grab all Application Gateways in the subscription in one shot
$agws = az network application-gateway list -o json | ConvertFrom-Json

# 2. Build a result set locally
$result = foreach ($ag in $agws) {
    $fips = $ag.frontendIPConfigurations
    $agSku = $ag.sku.name

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
            # Lookup the Public IP once, still local
            $pip = az network public-ip show --ids $pipId -o json | ConvertFrom-Json

            [pscustomobject]@{
                ApplicationGateway = $ag.name
                ResourceGroup      = $ag.resourceGroup
                FrontendIPConfig   = $fip.name
                PublicIPName       = $pip.name
                PublicIPAddress    = $pip.ipAddress
                PublicIPSKU        = $pip.sku.name
                PublicIPTier       = $pip.sku.tier
                AllocationMethod   = $pip.publicIPAllocationMethod
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

# 3. Now $result has everything locally — parse/filter as needed
# Table view
$result | Format-Table

# Example: filter only Basic SKUs
# $result | Where-Object { $_.PublicIPSKU -eq "Basic" }
