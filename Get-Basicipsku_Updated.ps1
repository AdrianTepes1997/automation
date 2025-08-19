# DRAFT
# variables list
$rgname = ""
$subid = ""
################################################################################################################################
az login
az account set --subscription $subid

# Grab all Basic SKU Public IPs into a variable
$basicIpsJson = az network public-ip list --query "[?sku.name=='Basic']" -o json
$basicIps = $basicIpsJson | ConvertFrom-Json

# --- Helper: first non-empty value ---
function Coalesce { param([object[]]$vals,$default=$null) foreach($v in $vals){ if($null -ne $v -and $v -ne ""){ return $v } } $default }

# --- Get Basic SKU PIPs once ---
$basicIps = az network public-ip list --query "[?sku.name=='Basic']" -o json | ConvertFrom-Json

# --- Build results locally ---
$results = foreach ($ip in $basicIps) {

    # Handle flattened vs nested shapes
    $ipConfId   = Coalesce @($ip.ipConfiguration.id, $ip.properties.ipConfiguration.id)
    $ipAddr     = Coalesce @($ip.ipAddress, $ip.properties.ipAddress)
    $fqdn       = Coalesce @($ip.dnsSettings.fqdn, $ip.properties.dnsSettings.fqdn)
    $alloc      = Coalesce @($ip.publicIPAllocationMethod, $ip.properties.publicIPAllocationMethod)
    $ipVersion  = Coalesce @($ip.publicIPAddressVersion, $ip.properties.publicIPAddressVersion)
    $prefixId   = Coalesce @($ip.publicIPPrefix.id, $ip.properties.publicIPPrefix.id)

    # If the bulk list didn't include the address, try a targeted refresh
    if ([string]::IsNullOrWhiteSpace($ipAddr)) {
        if ($prefixId) {
            $ipAddr = "[From Prefix: $(Split-Path $prefixId -Leaf)]"
        } else {
            try {
                $fresh = az network public-ip show --ids $ip.id -o json | ConvertFrom-Json
                if ($fresh) {
                    $ipAddr    = Coalesce @($ipAddr, $fresh.ipAddress, $fresh.properties.ipAddress)
                    $alloc     = Coalesce @($alloc,  $fresh.publicIPAllocationMethod, $fresh.properties.publicIPAllocationMethod)
                    $fqdn      = Coalesce @($fqdn,   $fresh.dnsSettings.fqdn, $fresh.properties.dnsSettings.fqdn)
                    $ipVersion = Coalesce @($ipVersion, $fresh.publicIPAddressVersion, $fresh.properties.publicIPAddressVersion)
                }
            } catch { }
        }
    }

    if ([string]::IsNullOrWhiteSpace($ipAddr)) { $ipAddr = '<unallocated>' }

    # Figure out what resource it's attached to (if any)
    $associatedResourceId = if ($ipConfId) { $ipConfId -replace '/ipConfigurations/.*$','' } else { '' }

    $associationType = if (-not $associatedResourceId) { 'Unassociated' }
        elseif ($associatedResourceId -match '/networkInterfaces/')       { 'NetworkInterface' }
        elseif ($associatedResourceId -match '/loadBalancers/')           { 'LoadBalancer' }
        elseif ($associatedResourceId -match '/applicationGateways/')     { 'ApplicationGateway' }
        elseif ($associatedResourceId -match '/virtualNetworkGateways/')  { 'VpnGateway' }
        elseif ($associatedResourceId -match '/bastionHosts/')            { 'Bastion' }
        elseif ($associatedResourceId -match '/firewalls/')               { 'AzureFirewall' }
        elseif ($associatedResourceId -match '/natGateways/')             { 'NatGateway' }
        else { 'Other' }

    [pscustomobject]@{
        SubscriptionId      = $subscriptionId
        ResourceGroup       = $ip.resourceGroup
        Name                = $ip.name
        IpAddress           = $ipAddr
        FQDN                = $fqdn
        Sku                 = Coalesce @($ip.sku.name, $ip.properties.sku.name)
        AllocationMethod    = $alloc
        IpVersion           = $ipVersion
        Location            = $ip.location
        AssociationType     = $associationType
        AssociatedResource  = $associatedResourceId
        Id                  = $ip.id
    }
}

# --- Display (wide list so IPs aren't truncated) ---
$results | Select-Object ResourceGroup,Name,IpAddress,FQDN,Sku,AllocationMethod,AssociationType | Format-List

# --- Optional: just IPs ---
# $results | ForEach-Object { $_.IpAddress }

# --- Save CSV ---
$ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
$outFile = ".\BasicPublicIPs_$ts.csv"
$results | Export-Csv -NoTypeInformation -Encoding UTF8 $outFile
Write-Host "Saved: $outFile"