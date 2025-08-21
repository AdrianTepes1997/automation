# DRAFT
# variables list
$rgname = ""
$subid = ""

$appGwName  = "<APPGW_NAME>"
$pipName     = "<PUBLIC_IP_NAME>"    # leave blank to auto-detect if only one PIP is attached
$capacity    = 2                     # used if not autoscale
$useAutoscale = $false               # $true to use autoscale instead of fixed capacity
$minCap      = 2
$maxCap      = 10
$whatIf      = $false                # $true = preview only
$confirm     = $true                 # $true = ask before running each step
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
function Should-Run($msg){
    if ($whatIf) { Write-Host "[WhatIf] $msg"; return $false }
    if ($confirm) {
        $r = Read-Host "$msg  Proceed? (y/N)"
        return ($r -match '^(y|yes)$')
    }
    Write-Host $msg
    return $true
}

# --- Auth ---
az login
az account set --subscription $subid

# --- 1) Inspect AppGW ---
$agRaw = az network application-gateway show -g $rgName -n $appGwName -o json | ConvertFrom-Json
$agSkuName = Coalesce @($agRaw.properties.sku.name, $agRaw.sku.name)
$agTier    = Coalesce @($agRaw.properties.sku.tier, $agRaw.sku.tier)
$fips      = Coalesce @($agRaw.properties.frontendIPConfigurations, $agRaw.frontendIPConfigurations)

Write-Host "Current AppGW SKU: $agSkuName (tier: $agTier)"
if ($agSkuName -eq "Standard_v2" -or $agTier -eq "Standard_v2") {
    Write-Host "Already Standard_v2 — no upgrade needed." -ForegroundColor Yellow
    return
}

# --- 2) Find attached Public IP ---
$publicPipIds = @()
if ($fips) {
    foreach ($fip in $fips) {
        $pipRef = Coalesce @($fip.properties.publicIPAddress, $fip.publicIPAddress)
        if ($pipRef -and $pipRef.id) { $publicPipIds += $pipRef.id }
    }
}
$publicPipIds = $publicPipIds | Select-Object -Unique

if (-not $pipName) {
    if ($publicPipIds.Count -eq 0) { throw "No Public IP attached to this AppGW." }
    if ($publicPipIds.Count -gt 1) { throw "Multiple PIPs found. Please set `$pipName manually." }
    $parsed = Parse-PipId -id $publicPipIds[0]
    $pipRg  = $parsed.ResourceGroup
    $pipName= $parsed.Name
} else {
    $pipObj = az network public-ip show -g $rgName -n $pipName -o json 2>$null | ConvertFrom-Json
    if ($pipObj) { $pipRg = $rgName } else {
        $pipObj = az network public-ip list --query "[?name=='$pipName']" -o json | ConvertFrom-Json
        if ($pipObj) { $pipRg = $pipObj[0].resourceGroup } else { throw "Could not find Public IP $pipName" }
    }
}

# --- 3) Inspect Public IP ---
$pip = az network public-ip show -g $pipRg -n $pipName -o json | ConvertFrom-Json
$pipSku  = Coalesce @($pip.sku.name, $pip.properties.sku.name)
$alloc   = Coalesce @($pip.publicIPAllocationMethod, $pip.properties.publicIPAllocationMethod)
$ipAddr  = Coalesce @($pip.ipAddress, $pip.properties.ipAddress)

Write-Host "Attached PIP: $pipName (RG: $pipRg) — SKU: $pipSku, Allocation: $alloc, IP: $ipAddr"

# --- 4) Update Public IP if needed ---
if ($pipSku -eq "Basic" -or $alloc -ne "Static") {
    if (Should-Run "Updating PIP '$pipName' to Standard/Static...") {
        az network public-ip update -g $pipRg -n $pipName --sku Standard --allocation-method Static
    }
} else {
    Write-Host "Public IP already Standard/Static."
}

# --- 5) Update AppGW SKU ---
if ($useAutoscale) {
    if (Should-Run "Upgrading AppGW '$appGwName' to Standard_v2 (autoscale $minCap-$maxCap)...") {
        az network application-gateway update -g $rgName -n $appGwName `
            --set sku.name=Standard_v2 sku.tier=Standard_v2 autoscaleConfiguration.minCapacity=$minCap autoscaleConfiguration.maxCapacity=$maxCap
    }
} else {
    if (Should-Run "Upgrading AppGW '$appGwName' to Standard_v2 (capacity $capacity)...") {
        az network application-gateway update -g $rgName -n $appGwName `
            --set sku.name=Standard_v2 sku.tier=Standard_v2 sku.capacity=$capacity
    }
}

Write-Host "Done."