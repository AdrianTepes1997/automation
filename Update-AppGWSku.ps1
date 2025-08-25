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
function Ask($msg){ if($whatIf){Write-Host "[WhatIf] $msg";return $false}; if($confirm){($r=Read-Host "$msg Proceed? (y/N)") -match '^(y|yes)$'} else {Write-Host $msg; $true} }

# --- Auth / context ---
az login
az account set --subscription $subid | Out-Null

# --- 1) Load AppGW + discover PIP IDs (match your working script shape) ---
$ag = az network application-gateway show -g $rgName -n $appGwName -o json | ConvertFrom-Json
if (-not $ag) { throw "Application Gateway '$appGwName' not found in RG '$rgName'." }

$agSkuName = Coalesce @($ag.properties.sku.name, $ag.sku.name)
$agTier    = Coalesce @($ag.properties.sku.tier, $ag.sku.tier)

# Prefer .properties.frontendIPConfigurations just like your working script; fall back to top-level
$fips = Coalesce @($ag.properties.frontendIPConfigurations, $ag.frontendIPConfigurations)
if (-not $fips) { throw "No frontendIPConfigurations found on this AppGW." }

# Pull PIP IDs (prefer .properties.publicIPAddress.id; fall back to top-level)
$pipIds = @()
foreach($f in $fips){
    $pipId = Coalesce @($f.properties.publicIPAddress.id, $f.publicIPAddress.id)
    if ($pipId) { $pipIds += $pipId }
}
$pipIds = $pipIds | Select-Object -Unique
if ($pipIds.Count -eq 0) { throw "This AppGW has no Public IP references (private only)." }

Write-Host "Current AppGW SKU: $agSkuName (tier: $agTier)"
Write-Host "Found Public IP IDs:"; $pipIds | ForEach-Object { "  $_" } | Write-Host

# Choose one if multiple
$chosenPipId = $null
if ($pipIds.Count -eq 1) {
    $chosenPipId = $pipIds[0]
} else {
    for ($i=0; $i -lt $pipIds.Count; $i++) { Write-Host "[$i] $($pipIds[$i])" }
    $idx = Read-Host "Enter the index of the Public IP to upgrade (0-$($pipIds.Count-1))"
    if ($idx -notmatch '^\d+$' -or [int]$idx -ge $pipIds.Count) { throw "Invalid selection." }
    $chosenPipId = $pipIds[[int]$idx]
}
Write-Host "Selected PIP ID: $chosenPipId"

# --- 2) Detect capacity/autoscale from current AppGW ---
$capacityNode = Coalesce @($ag.properties.sku.capacity, $ag.sku.capacity)
$autoNode     = Coalesce @($ag.properties.autoscaleConfiguration, $ag.autoscaleConfiguration)

$useAutoscale = $false
$capacity     = 2
$minCap       = 2
$maxCap       = 10
if ($autoNode) {
    $useAutoscale = $true
    $minCap = Coalesce @($autoNode.minCapacity), 2
    $maxCap = Coalesce @($autoNode.maxCapacity), 10
} elseif ($capacityNode) {
    $capacity = [int]$capacityNode
}

Write-Host ("Capacity mode: " + ($(if($useAutoscale){"Autoscale ($minCap-$maxCap)"} else {"Fixed capacity ($capacity)"})))

# --- 3) Inspect Public IP (by ID) ---
$pip = az network public-ip show --ids $chosenPipId -o json | ConvertFrom-Json
if (-not $pip) { throw "Could not read Public IP by ID: $chosenPipId" }

$pipSku  = Coalesce @($pip.sku.name, $pip.properties.sku.name)
$pipTier = Coalesce @($pip.sku.tier, $pip.properties.sku.tier)
$alloc   = Coalesce @($pip.publicIPAllocationMethod, $pip.properties.publicIPAllocationMethod)
$ipAddr  = Coalesce @($pip.ipAddress, $pip.properties.ipAddress)

Write-Host "Public IP status: SKU=$pipSku, Tier=$pipTier, Allocation=$alloc, IP=$ipAddr"

# --- 4) Upgrade Public IP in-place to Standard/Static (use --ids so RG/Name not needed) ---
if ($pipSku -eq 'Basic' -or $alloc -ne 'Static') {
    if (Ask "Updating Public IP to SKU=Standard and Allocation=Static (IP preserved)...") {
        az network public-ip update --ids $chosenPipId --sku Standard --allocation-method Static
    }
} else {
    Write-Host "Public IP already Standard/Static — no change needed."
}

# --- 5) Upgrade AppGW to Standard_v2 (disruptive) ---
if ($agSkuName -eq 'Standard_v2' -or $agTier -eq 'Standard_v2') {
    Write-Host "Application Gateway already Standard_v2 — no change needed."
} else {
    if ($useAutoscale) {
        if (Ask "Upgrading AppGW '$appGwName' to Standard_v2 with autoscale ($minCap-$maxCap)...") {
            az network application-gateway update -g $rgName -n $appGwName `
              --set sku.name=Standard_v2 sku.tier=Standard_v2 autoscaleConfiguration.minCapacity=$minCap autoscaleConfiguration.maxCapacity=$maxCap
        }
    } else {
        if (Ask "Upgrading AppGW '$appGwName' to Standard_v2 with fixed capacity ($capacity)...") {
            az network application-gateway update -g $rgName -n $appGwName `
              --set sku.name=Standard_v2 sku.tier=Standard_v2 sku.capacity=$capacity
        }
    }
}

Write-Host "Done."