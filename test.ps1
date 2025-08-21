$subid     = "<YOUR_SUBSCRIPTION_ID>"
$rgName    = "<RESOURCE_GROUP>"
$appGwName = "<APPGW_NAME>"

az account set --subscription $subid | Out-Null

# Get raw JSON
$ag = az network application-gateway show -g $rgName -n $appGwName -o json | ConvertFrom-Json

Write-Host "=== Dumping frontendIPConfigurations ==="
$ag.properties.frontendIPConfigurations | ConvertTo-Json -Depth 10
