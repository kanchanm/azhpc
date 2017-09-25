#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$DIR/common.sh"

paramsFile=$1
echo "Reading parameters from: $paramsFile"
source $paramsFile
required_envvars githubUser githubBranch resource_group vmSku vmssName computeNodeImage instanceCount rsaPublicKey

if [ "$logToStorage" = true ]; then
        required_envvars cosmos_account cosmos_database cosmos_collection cosmos_key logStorageAccountName logStorageContainerName logStoragePath logStorageSasKey
fi

benchmarkScript=$2
echo "Benchmark script: $benchmarkScript"
source $benchmarkScript

scriptname=$(basename "$0")
scriptname="${scriptname%.*}"
paramsname=$(basename "$paramsFile")
paramsname="${paramsname%.*}"
benchmarkname=$(basename "$benchmarkScript")
benchmarkname="${benchmarkname%.*}"
timestamp=$(date +%Y-%m-%d_%H-%M-%S)
LOGDIR=$rootLogDir/${scriptname}_${paramsname}_${benchmarkname}_${timestamp}
mkdir $LOGDIR

# creating a new document with a unique id (intention to put in documentdb)
telemetryData="{ \"id\" : \"$(uuidgen)\" }"

function clear_up {
	execute "delete_resource_group" az group delete --name "$resource_group" --yes
        echo $telemetryData > $LOGDIR/telemetry.json
        if [ "$logToStorage" = true ]; then
                $DIR/cosmos_upload_doc.sh "$cosmos_account" "$cosmos_database" "$cosmos_collection" "$cosmos_key" "$telemetryData"
        fi
}

# assuming already logged in a the moment or use the Service Principal params
if [ "$azLogin" -ne "" ]; then
        echo "login to azure with Service Principal"
        az login --service-principal -u $azLogin -p $azPassword --tenant $azTenant
fi

# make sure the resource group does not exist
if [ "$(az group exists --name $resource_group)" = "true" ]; then
        echo "Error: Resource group already exists"
        exit 1
fi

# create the resource group
execute "create_resource_group" az group create --name "$resource_group" --location "$location"
subscriptionId=$(jq '.id' $(get_log "create_resource_group") | cut -d'/' -f3)
telemetryData="$(jq ".subscription=\"$subscriptionId\" | .location=\$data.location | .resourceGroup=\$data.name" --argjson data "$(<$(get_log "create_resource_group"))" <<< $telemetryData)"

parameters=$(cat << EOF
{
        "vmSku": {
                "value": "$vmSku"
        },
        "vmssName": {
                "value": "$vmssName"
        },
        "computeNodeImage": {
                "value": "$computeNodeImage"
        },
        "instanceCount": {
                "value": $instanceCount
        },
        "rsaPublicKey": {
                "value": "$rsaPublicKey"
        }
}
EOF
)

# deploy azhpc
execute "deploy_azhpc" az group deployment create \
    --resource-group "$resource_group" \
    --template-uri "https://raw.githubusercontent.com/$githubUser/azhpc/$githubBranch/azuredeploy.json" \
    --parameters "$parameters"

telemetryData="$(jq '.vmSize=$data.properties.parameters.vmSku.value | .computeNodeImage=$data.properties.parameters.computeNodeImage.value | .instanceCount=$data.properties.parameters.instanceCount.value | .provisioningState=$data.properties.provisioningState | .deploymentTimestamp=$data.properties.timestamp' --argjson data "$(<$(get_log "deploy_azhpc"))" <<< $telemetryData)"

public_ip=$(az network public-ip list --resource-group "$resource_group" --query [0].dnsSettings.fqdn | sed 's/"//g')

execute "get_hosts" ssh hpcuser@${public_ip} nmapForHosts
working_hosts=$(sed -n "s/.*sshin=\([^;]*\).*/\1/p" $(get_log "get_hosts"))
retry=1
while [ "$retry" -lt "6" -a "$working_hosts" -ne "$instanceCount" ]; do
        sleep 60
        execute "get_hosts_retry_$retry" ssh hpcuser@${public_ip} nmapForHosts
        working_hosts=$(sed -n "s/.*sshin=\([^;]*\).*/\1/p" $(get_log "get_hosts_retry_$retry"))
        let retry=$retry+1
done

telemetryData="$(jq ".clusterDeployment.sshretries=\"$retry\"" <<< $telemetryData)"

if [ "$working_hosts" -ne "$instanceCount" ]; then
        echo "Error: all hosts are not accessible with ssh."
        telemetryData="$(jq ".clusterDeployment.status=\"failed\"" <<< $telemetryData)"
        clear_up
        exit 1
fi
telemetryData="$(jq ".clusterDeployment.status=\"success\"" <<< $telemetryData)"

execute "show_bad_nodes" ssh hpcuser@${public_ip} testForBadNodes

# run the benchmark function
jsonBenchmark="{}"
run_benchmark

# TODO : need to check jsonBenchmark before merging otherwise we may lose it
echo $telemetryData > $LOGDIR/tmp.telemetry.json
telemetryData="$(jq '$data + .' --argjson data "$telemetryData" <<< $jsonBenchmark)"

clear_up
