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

# Now parse locally
$results = foreach ($ip in $basicIps) {
    $assoc = $ip.properties.ipConfiguration.id
    $associatedResourceId = if ($assoc) { $assoc -replace '/ipConfigurations/.*$','' } else { '' }

    $associationType = if (-not $associatedResourceId) { 'Unassociated' }
        elseif ($associatedResourceId -match '/networkInterfaces/')       { 'NetworkInterface' }
        elseif ($associatedResourceId -match '/loadBalancers/')           { 'LoadBalancer' }
        elseif ($associatedResourceId -match '/applicationGateways/')     { 'ApplicationGateway' }
        elseif ($associatedResourceId -match '/virtualNetworkGateways/')  { 'VpnGateway' }
        elseif ($associatedResourceId -match '/bastionHosts/')            { 'Bastion' }
        elseif ($associatedResourceId -match '/firewalls/')               { 'AzureFirewall' }
        elseif ($associatedResourceId -match '/natGateways/')             { 'NatGateway' }
        else { 'Other' }

    # Normalize IP + add FQDN for visibility
    $ipAddr = $ip.properties.ipAddress
    if ([string]::IsNullOrWhiteSpace($ipAddr)) { $ipAddr = '<unallocated>' }
    $fqdn = $ip.properties.dnsSettings.fqdn

    [pscustomobject]@{
        SubscriptionId      = (az account show --query id -o tsv)
        ResourceGroup       = $ip.resourceGroup
        Name                = $ip.name
        IpAddress           = $ipAddr
        FQDN                = $fqdn
        Sku                 = $ip.sku.name
        AllocationMethod    = $ip.properties.publicIPAllocationMethod
        IpVersion           = $ip.properties.publicIPAddressVersion
        Location            = $ip.location
        AssociationType     = $associationType
        AssociatedResource  = $associatedResourceId
        Id                  = $ip.id
    }
}

# Show as a wide list so IPs never get hidden
$results | Select-Object ResourceGroup,Name,IpAddress,FQDN,Sku,AllocationMethod,AssociationType | Format-List

# If you want JUST the IP strings (one per line), do this:
$results | ForEach-Object { $_.IpAddress }

# Save to CSV (includes the new FQDN column and normalized IpAddress)
$results | Export-Csv -NoTypeInformation -Encoding UTF8 BasicPublicIPs.csv