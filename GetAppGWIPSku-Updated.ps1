# Draft
# variables list
#$rgname = ""
$subid = ""
################################################################################################################################
az login
az account set --subscription $subid

# --- Helpers ---
function Coalesce { param([object[]]$vals,$default=$null) foreach($v in $vals){ if($null -ne $v -and $v -ne ""){ return $v } } $default }

function Parse-PipId {
    param([string]$id)
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
foreach ($pip in $pips) { if ($pip -and $pip.id) { $pipById[$pip.id.ToLower()] = $pip } }

# --- 3) Build results ---
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

        # Fields with dual-paths to handle flattened vs properties.*
        $pipName = if ($pip) { $pip.name } elseif ($pipId) { Split-Path $pipId -Leaf } else { "-" }
        $ipAddr  = if ($pip) { Coalesce @($pip.ipAddress, $pip.properties.ipAddress) } else { "-" }
        $skuName = if ($pip) { Coalesce @($pip.sku.name, $pip.properties.sku.name) } else { if ($pipId) { "Unknown" } else { "None (private-only)" } }
        $skuTier = if ($pip) { Coalesce @($pip.sku.tier, $pip.properties.sku.tier) } else { "-" }
        $alloc   = if ($pip) { Coalesce @($pip.publicIPAllocationMethod, $pip.properties.publicIPAllocationMethod) } else { "-" }
        $prefixId= if ($pip) { Coalesce @($pip.publicIPPrefix.id, $pip.properties.publicIPPrefix.id) } else { $null }

        # If IP missing, try quick fallbacks
        if (-not $ipAddr -or $ipAddr -eq "") {
            if ($prefixId) { $ipAddr = "[From Prefix: $(Split-Path $prefixId -Leaf)]" }
        }
        if (-not $ipAddr -or $ipAddr -eq "") {
            if ($pipId) {
                try {
                    $fresh = az network public-ip show --ids $pipId -o json | ConvertFrom-Json
                    if ($fresh) {
                        $ipAddr = Coalesce @($ipAddr, $fresh.ipAddress, $fresh.properties.ipAddress)
                        $alloc  = Coalesce @($alloc, $fresh.publicIPAllocationMethod, $fresh.properties.publicIPAllocationMethod, "-")
                        $skuName= Coalesce @($skuName, $fresh.sku.name)
                        $skuTier= Coalesce @($skuTier, $fresh.sku.tier)
                    }
                } catch { }
            }
        }
        if (-not $ipAddr -or $ipAddr -eq "") {
            $parsed = Parse-PipId -id $pipId
            if ($parsed.ResourceGroup -and $parsed.Name) {
                try {
                    $fresh2 = az network public-ip show -g $parsed.ResourceGroup -n $parsed.Name -o json | ConvertFrom-Json
                    if ($fresh2) {
                        $ipAddr = Coalesce @($ipAddr, $fresh2.ipAddress, $fresh2.properties.ipAddress, "Unallocated")
                        $alloc  = Coalesce @($alloc, $fresh2.publicIPAllocationMethod, $fresh2.properties.publicIPAllocationMethod, "-")
                        $skuName= Coalesce @($skuName, $fresh2.sku.name)
                        $skuTier= Coalesce @($skuTier, $fresh2.sku.tier)
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
            PublicIPAddress    = $ipAddr            # <-- now resolves (flattened or nested)
            PublicIPSKU        = $skuName
            PublicIPTier       = $skuTier
            AllocationMethod   = $alloc             # <-- flattened or nested
            AgwSkuName         = $agSku
        }
    }
}

# --- 4) Output + CSV ---
$result | Sort-Object ResourceGroup, ApplicationGateway, FrontendIPConfig | Format-Table

$ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
$outFile = ".\AppGateway_IPs_$ts.csv"
$result | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
Write-Host "Saved: $outFile"

# how i found the right place to parse for the publicip
#$pipId = "<full /subscriptions/.../publicIPAddresses/...>"
#az network public-ip show --ids $pipId --query "[ipAddress, properties.ipAddress, publicIPAllocationMethod, sku.name]" -o table
