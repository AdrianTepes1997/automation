# Draft
# variables list
#$rgname = ""
$subid = ""
################################################################################################################################
az login
az account set --subscription $subid

# --- 1) Pull once ---
$agws = az network application-gateway list -o json | ConvertFrom-Json
$pips = az network public-ip list -o json | ConvertFrom-Json

# --- 2) Index Public IPs by full resource ID (case-insensitive) ---
$pipById = @{}
foreach ($pip in $pips) {
    if ($pip -and $pip.id) { $pipById[$pip.id.ToLower()] = $pip }
}

# Helper to coalesce JSON paths safely
function Get-First {
    param($vals)
    foreach ($v in $vals) { if ($null -ne $v -and $v -ne "") { return $v } }
    return $null
}

# --- 3) Build results locally (robust across shapes) ---
$result = foreach ($ag in $agws) {
    $fips = Get-First @(
        $ag.properties.frontendIPConfigurations,
        $ag.frontendIPConfigurations
    )
    $agSku = Get-First @(
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
        # Public IP reference can be in either place depending on CLI/object shape
        $pipRef = Get-First @(
            $fip.properties.publicIPAddress,
            $fip.publicIPAddress
        )
        $pipId = $pipRef.id

        if ($pipId) {
            $pip = $pipById[$pipId.ToLower()]

            # If for some reason the ID lookup failed, we still emit a useful row
            $pipName = Get-First @($pip.name, (Split-Path $pipId -Leaf))
            $ipAddr  = Get-First @($pip.properties.ipAddress)
            $skuName = Get-First @($pip.sku.name)
            $skuTier = Get-First @($pip.sku.tier)
            $alloc   = Get-First @($pip.properties.publicIPAllocationMethod)

            [pscustomobject]@{
                ApplicationGateway = $ag.name
                ResourceGroup      = $ag.resourceGroup
                FrontendIPConfig   = $fip.name
                PublicIPName       = $pipName
                PublicIPAddress    = $ipAddr
                PublicIPSKU        = ($skuName ? $skuName : "Unknown")
                PublicIPTier       = ($skuTier ? $skuTier : "-")
                AllocationMethod   = ($alloc   ? $alloc   : "-")
                AgwSkuName         = $agSku
            }
        }
        else {
            # No public IP ref on this frontend (likely private-only frontend bound to a subnet)
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