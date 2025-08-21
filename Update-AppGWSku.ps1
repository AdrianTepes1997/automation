# DRAFT
# variables list
$rgname = ""
$subid = ""

$appGwName  = "<APPGW_NAME>"

# Behavior flags
$whatIf  = $false   # $true = preview only
$confirm = $true    # $true = prompt before each change
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
            if ($parts[$i] -eq 'resourceGroups'    -and ($i+1) -lt $parts.Length) { $rg   = $parts[$i+1] }
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

# --- Auth / context ---
az login
az account set --subscription $subid | Out-Null

# --- 1) Load AppGW + discover Public IP(s) ---
$ag = az network application-gateway show -g $rgName -n $appGwName -o json | ConvertFrom-Json
if (-not $ag) { throw "Application Gateway '$appGwName' not found in RG '$rgName'." }

$agSkuName = Coalesce @($ag.sku.name, $ag.properties.sku.name)
$agTier    = Coalesce @($ag.sku.tier, $ag.properties.sku.tier)

# YOUR TENANT SHAPE: fips at top-level
$fips = Coalesce @($ag.frontendIPConfigurations, $ag.properties.frontendIPConfigurations)

Write-Host "Current AppGW SKU: $agSkuName (tier: $agTier)"
if (-not $fips) { throw "No frontendIPConfigurations found on this AppGW." }

$publicPipIds = @()
foreach ($f in $fips) {
    # YOUR TENANT SHAPE: PIP ref at f.publicIPAddress.id (fallback to properties.*)
    $pipId = Coalesce @($f.publicIPAddress.id, $f.properties.publicIPAddress.id)
    if ($pipId) {
        Write-Host "Discovered PIP on FrontendIP '$($f.name)': $pipId"
        $publicPipIds += $pipId
    } else {
        Write-Host "FrontendIP '$($f.name)' has no Public IP (private-only)."
    }
}
$publicPipIds = $publicPipIds | Select-Object -Unique
if ($publicPipIds.Count -eq 0) { throw "No Public IP references found on this AppGW." }

# Pick one PIP (prompt if multiple)
$pipRg = $null; $pipName = $null
if ($publicPipIds.Count -eq 1) {
    $p = Parse-PipId -id $publicPipIds[0]
    $pipRg   = $p.ResourceGroup
    $pipName = $p.Name
} else {
    Write-Host "`nMultiple Public IPs attached:"
    for ($i=0; $i -lt $publicPipIds.Count; $i++) {
        $p = Parse-PipId -id $publicPipIds[$i]
        Write-Host ("[{0}] RG: {1}  Name: {2}" -f $i, $p.ResourceGroup, $p.Name)
    }
    $choice = Read-Host "Enter the index of the Public IP to upgrade (0 - $($publicPipIds.Count-1))"
    if ($choice -notmatch '^\d+$' -or [int]$choice -ge $publicPipIds.Count) { throw "Invalid selection." }
    $sel = Parse-PipId -id $publicPipIds[[int]$choice]
    $pipRg   = $sel.ResourceGroup
    $pipName = $sel.Name
}
Write-Host "Selected Public IP: $pipName (RG: $pipRg)"

# --- 2) Detect capacity/autoscale from current AppGW ---
$capacityNode = Coalesce @($ag.sku.capacity, $ag.properties.sku.capacity)
$autoNode     = Coalesce @($ag.autoscaleConfiguration, $ag.properties.autoscaleConfiguration)

$useAutoscale = $false
$capacity     = 2
$minCap       = 2
$maxCap       = 10
if ($autoNode) {
    $useAutoscale = $true
    $minCap = Coalesce @($autoNode.minCapacity), 2
    $maxCap = Coalesce @($autoNode.maxCapacity), 10
} elseif ($capacityNode) {
    $useAutoscale = $false
    $capacity = [int]$capacityNode
}
Write-Host ("Capacity mode: " + ($(if($useAutoscale){"Autoscale ($minCap-$maxCap)"} else {"Fixed capacity ($capacity)"})))

# --- 3) Inspect Public IP ---
$pip = az network public-ip show -g $pipRg -n $pipName -o json | ConvertFrom-Json
if (-not $pip) { throw "Could not load Public IP '$pipName' in RG '$pipRg'." }

$pipSku  = Coalesce @($pip.sku.name, $pip.properties.sku.name)
$pipTier = Coalesce @($pip.sku.tier, $pip.properties.sku.tier)
$alloc   = Coalesce @($pip.publicIPAllocationMethod, $pip.properties.publicIPAllocationMethod)
$ipAddr  = Coalesce @($pip.ipAddress, $pip.properties.ipAddress)

Write-Host "Public IP: SKU=$pipSku, Tier=$pipTier, Allocation=$alloc, IP=$ipAddr"

# --- 4) Upgrade PIP (in-place) to Standard/Static if needed ---
$needsPipUpgrade  = ($pipSku -eq 'Basic')
$needsAllocStatic = ($alloc -ne 'Static')
if ($needsPipUpgrade -or $needsAllocStatic) {
    if (Should-Run "Updating Public IP '$pipName' to SKU=Standard, Allocation=Static (IP preserved)...") {
        az network public-ip update -g $pipRg -n $pipName --sku Standard --allocation-method Static
    }
} else {
    Write-Host "Public IP already Standard/Static — no change needed."
}

# --- 5) Upgrade AppGW to Standard_v2 (disruptive) ---
if ($agSkuName -eq 'Standard_v2' -or $agTier -eq 'Standard_v2') {
    Write-Host "Application Gateway already Standard_v2 — no change needed."
} else {
    if ($useAutoscale) {
        if (Should-Run "Upgrading AppGW '$appGwName' to Standard_v2 with autoscale ($minCap-$maxCap)...") {
            az network application-gateway update `
              -g $rgName -n $appGwName `
              --set sku.name=Standard_v2 sku.tier=Standard_v2 autoscaleConfiguration.minCapacity=$minCap autoscaleConfiguration.maxCapacity=$maxCap
        }
    } else {
        if (Should-Run "Upgrading AppGW '$appGwName' to Standard_v2 with fixed capacity ($capacity)...") {
            az network application-gateway update `
              -g $rgName -n $appGwName `
              --set sku.name=Standard_v2 sku.tier=Standard_v2 sku.capacity=$capacity
        }
    }
}

Write-Host "Done."