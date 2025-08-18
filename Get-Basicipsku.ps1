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
        elseif ($associatedResourceId -match '/loadBalancers/')          { 'LoadBalancer' }
        elseif ($associatedResourceId -match '/applicationGateways/')    { 'ApplicationGateway' }
        elseif ($associatedResourceId -match '/virtualNetworkGateways/') { 'VpnGateway' }
        elseif ($associatedResourceId -match '/bastionHosts/')           { 'Bastion' }
        elseif ($associatedResourceId -match '/firewalls/')              { 'AzureFirewall' }
        elseif ($associatedResourceId -match '/natGateways/')            { 'NatGateway' }
        else { 'Other' }

    [pscustomobject]@{
        SubscriptionId      = (az account show --query id -o tsv)
        ResourceGroup       = $ip.resourceGroup
        Name                = $ip.name
        IpAddress           = $ip.properties.ipAddress
        Sku                 = $ip.sku.name
        AllocationMethod    = $ip.properties.publicIPAllocationMethod
        IpVersion           = $ip.properties.publicIPAddressVersion
        Location            = $ip.location
        AssociationType     = $associationType
        AssociatedResource  = $associatedResourceId
        Id                  = $ip.id
    }
}

# Work with it locally
$results | Format-Table -AutoSize

# Save to CSV for reference
$results | Export-Csv -NoTypeInformation -Encoding UTF8 BasicPublicIPs.csv
