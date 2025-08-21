$subid     = "<YOUR_SUBSCRIPTION_ID>"
$rgName    = "<RESOURCE_GROUP>"
$appGwName = "<APPGW_NAME>"

az account set --subscription $subid | Out-Null

$ag = az network application-gateway show -g $rgName -n $appGwName -o json | ConvertFrom-Json

# Dump top-level keys
Write-Host "=== Keys on AppGW object ==="
$ag | Get-Member -MemberType NoteProperty

# Dump full object (be careful, big!)
$ag | ConvertTo-Json -Depth 20 | Out-File ".\AppGwDump.json" -Encoding utf8
Write-Host "Wrote full dump to AppGwDump.json"
