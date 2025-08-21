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

# --- 1) Inspect AppGW + discover attached Public IP(s) ---
$ag = az network application-gateway show -g $rgName -n $appGwName -o json | ConvertFrom-Json
if (-not $ag) { throw "Application Gateway '$appGwName' not found in RG '$rgName'." }

$agSkuName = Coalesce @($ag.properties.sku.name, $ag.sku.name)
$agTier    = Coalesce @($ag.properties.sku.tier, $ag.sku.tier)
$fips      = Coalesce @($ag.properties.frontendIPConfigurations, $ag.frontendIPConfigurations)

Write-Host "Current AppGW SKU: $agSkuName (tier: $agTier)"

# Gather PIP IDs from all frontend IP configs
$publicPipIds = @()
if ($fips) {
    foreach ($f in $fips) {
        $pipRef = Coalesce @($f.properties.publicIPAddress, $f.publicIPAddress)
        if ($pipRef -and $pipRef.id) { $publicPipIds += $pipRef.id }
    }
}
$publicPipIds = $publicPipIds | Select-Object -Unique

if ($publicPipIds.Count -eq 0) {
    throw "No Public IP is attached to this Application Gateway."
}

# If multiple PIPs attached, prompt user to choose which to upgrade
$pipRg = $null; $pipName = $null
if ($publicPipIds.Count -eq 1) {
    $parsed  = Parse-PipId -id $publicPipIds[0]
    $pipRg   = $parsed.ResourceGroup
    $pipName = $parsed.Name
} else {
    Write-Host "Multiple Public IPs are attached to this AppGW:`n"
    for ($i=0; $i -lt $publicPipIds.Count; $i++) {
        $p = Parse-PipId -id $publicPipIds[$i]
        Write-Host ("[{0}] RG: {1}  Name: {2}" -f $i, $p.ResourceGroup, $p.Name)
    }
    $choice = Read-Host "Enter the index of the Public IP to upgrade (0 - $($publicPipIds.Count-1))"
    if ($choice -notmatch '^\d+$' -or [int]$choice -ge $publicPipIds.Count) {
        throw "Invalid choice."
    }
    $sel    = Parse-PipId -id $publicPipIds[[int]$choice]
    $pipRg   = $sel.ResourceGroup
    $pipName = $sel.Name
}
Write-Host "Selected Public IP: $pipName (RG: $pipRg)"

# --- 2) Detect capacity/autoscale from current AppGW ---
$capacityNode = Coalesce @($ag.properties.sku.capacity, $ag.sku.capacity)
$autoNode     = Coalesce @($ag.properties.autoscaleConfiguration, $ag.autoscaleConfiguration)

$useAutoscale = $false
$capacity     = 2   # default if not present
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

Write-Host ("Discovered capacity mode: " + ($(if($useAutoscale){"Autoscale ($minCap-$maxCap)"} else {"Fixed capacity ($capacity)"})))

# --- 3) Inspect the chosen Public IP ---
$pip = az network public-ip show -g $pipRg -n $pipName -o json | ConvertFrom-Json
if (-not $pip) { throw "Could not load Public IP '$pipName' in RG '$pipRg'." }

$pipSku  = Coalesce @($pip.sku.name, $pip.properties.sku.name)
$pipTier = Coalesce @($pip.sku.tier, $pip.properties.sku.tier)
$alloc   = Coalesce @($pip.publicIPAllocationMethod, $pip.properties.publicIPAllocationMethod)
$ipAddr  = Coalesce @($pip.ipAddress, $pip.properties.ipAddress)

Write-Host "Public IP state — SKU: $pipSku, Tier: $pipTier, Allocation: $alloc, IP: $ipAddr"

# --- 4) Public IP upgrade (in place) ---
$needsPipUpgrade   = ($pipSku -eq 'Basic')
$needsAllocStatic  = ($alloc -ne 'Static')

if ($needsPipUpgrade -or $needsAllocStatic) {
    if (Should-Run "Updating Public IP '$pipName' to SKU=Standard, Allocation=Static (IP preserved)...") {
        az network public-ip update -g $pipRg -n $pipName --sku Standard --allocation-method Static
    }
} else {
    Write-Host "Public IP already Standard/Static — no change needed."
}

# --- 5) AppGW upgrade (disruptive) ---
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