#!/bin/bash

LOG_FILE='azure_resource_count.log'
MAX_DB_SIZE_GB=1024
WORKLOAD_VM_UNITS=1
WORKLOAD_FUNCTION_UNITS=50
WORKLOAD_SERVERLESS_CONTAINER_UNITS=10
WORKLOAD_VM_IMAGE_UNITS=1
WORKLOAD_CONTAINER_IMAGE_UNITS=10
WORKLOAD_CONTAINER_HOST_UNITS=1
WORKLOAD_DB_UNITS=1
WORKLOAD_PUBLIC_STORAGE_CONTAINER_UNITS=10
WORKLOAD_PRIVATE_STORAGE_CONTAINER_UNITS=10
WORKLOAD_DATA_DISK_UNITS=2.5

_tmp_files=$(mktemp)
cleanup() {
  rm -f $(< "${_tmp_files}") "${_tmp_files}"
}
trap cleanup EXIT

_make_temp_file() {
  local tmp_file=$(mktemp)
  echo "${tmp_file}" >> "${_tmp_files}"
  echo "${tmp_file}"
}

logger() {
    if [ -n "$1" ]; then
        IN="$1"
        echo -e $n_param $IN
    else
        read -r IN
    fi
    echo -e "[$(date -u '+%d-%m-%Y %H:%M:%S')] $IN" >>${LOG_FILE}
}


subscription=''
management_group=''

while [ "$1" != "" ]; do
    case $1 in
        -s | --subscription )    shift
                                if [ "$1" == "" ]; then
                                  echo "Error: The --subscription (-s) flag requires a value."
                                  exit 1
                                fi
                                subscription=$1
                                ;;
        -g | --management-group ) shift
                                if [ "$1" == "" ]; then
                                  echo "Error: The --management-group (-g) flag requires a value."
                                  exit 1
                                fi
                                management_group=$1
                                ;;
        -mds | --max-db-size-gb ) shift
                                if [ "$1" == "" ]; then
                                  echo "Error: The --max-db-size-gb (-s) flag requires a value."
                                  exit 1
                                fi
                                MAX_DB_SIZE_GB=$1
                                ;;
        * )                     echo "Error: Unknown input flag $1"
                                exit 1
    esac
    shift
done

if [ -z "$subscription" ] && [ -z "$management_group" ]; then
    echo "Error: At least one of the flags --subscription (-s) or --management-group (-g) is required."
    exit 1
fi

if [ -n "$subscription" ] && [ -n "$management_group" ]; then
    echo "Error: Both flags --subscription (-s) and --management-group (-g) cannot be provided at the same time."
    exit 1
fi

if [ -n "$subscription" ]; then
    echo "Start counting Azure services for Subscription: ${subscription}"
    echo
    subscriptions=$subscription
else
    # Get the subscriptions under the management group
    echo "Start counting Azure services for Management Group: ${management_group}"
    echo
    subscriptions=$(az account management-group show --name $management_group -e -r --no-register -o json | jq 'recurse(.children[]?) | select(.type == "/subscriptions")' | jq '.. .name? // empty' | tr -d \")
fi


# Initialize counts
vmCount=0
functionAppCount=0
ContainerCount=0
containerImageCount=0
vmImageCount=0
aksNodesCount=0
dbCount=0
privateStorageContainersCount=0
publicStorageContainersCount=0
dataDisksCount=0

# Set a counter for progress indicator
counter=0

# Get the number of subscriptions
subscriptionCount=$(echo $subscriptions | wc -w | tr -d ' ')

if [ $subscriptionCount -eq 0 ]; then
    echo "No subscriptions found"
    exit 0
fi


echo "Start to count Azure Services for ${subscriptionCount} Subscriptions..."
echo

_temp_subscription_output=$(_make_temp_file)
# Iterate over subscriptions
for subscription in $subscriptions; do

    # check if subscription is disabled
    state=$(az account show --subscription $subscription --query state)
    # Remove quotes
    state="${state%\"}"
    state="${state#\"}"
    # Check if the state is not enabled
    if [ "$state" != "Enabled" ]; then
        echo "The subscription ${subscription} is disabled - skipping."
        counter=$((counter+1))
        echo
        continue
    fi

    # Show the current subscription being processed
    echo "Processing Subscription: $subscription"

    az vm list --subscription $subscription --query "length([])" -o tsv > ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Virtual Machines for subscription ${subscription}"
    currentVmCount=$(cat "${_temp_subscription_output}")
    if [ -n "$currentVmCount" ]; then
        vmCount=$((vmCount + currentVmCount))
        echo "Virtual Machines Count: $currentVmCount"
    fi

    # Get the number of Function Apps
    az functionapp list --subscription $subscription --query "length([])" -o tsv > ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Serverless Functions for subscription ${subscription}"
    currentFunctionAppCount=$(cat "${_temp_subscription_output}")
    if [ -n "$currentFunctionAppCount" ]; then
        functionAppCount=$((functionAppCount + currentFunctionAppCount))
        echo "Serverless Functions Count: $currentFunctionAppCount"
    fi

    # Get the number of ACI
    az container list --subscription $subscription --query "[].{name: name, resourceGroup: resourceGroup}" -o json > ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Serverless Containers for subscription ${subscription}"
    container_groups=$(cat "${_temp_subscription_output}")
    currentContainerCount=0
    for group in $(echo "$container_groups" | jq -c '.[]'); do
      group_name=$(echo $group | jq -r '.name')
      rg_name=$(echo $group | jq -r '.resourceGroup')
      az container show --subscription $subscription -n $group_name -g $rg_name --query 'length(containers)' -o tsv > ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Serverless Containers for subscription ${subscription}"
      currentContainerCount=$((currentContainerCount + $(cat "${_temp_subscription_output}")))
    done
    if [ -n "$currentContainerCount" ]; then
        echo "Serverless Containers Count: $currentContainerCount"
        ContainerCount=$((ContainerCount + currentContainerCount))
    fi

    # Get the number of container repositories
    az acr list --subscription $subscription --query "[].name" --output tsv > ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Container Images for subscription ${subscription}"
    acrList=$(cat "${_temp_subscription_output}")
    currentAcrCount=0
    for acrName in $acrList; do
        az acr repository list --subscription $subscription --name $acrName --output tsv | wc -l > ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Container Images for subscription ${subscription}"
        acrList=$(cat "${_temp_subscription_output}")
        currentAcrCount=$((currentAcrCount + $(cat "${_temp_subscription_output}")))
    done
    if [ -n "$currentAcrCount" ]; then
        currentAcrCount=$(echo "$currentAcrCount*1.1" | awk '{printf "%.0f", $0}') # we scan 2 images per one repository and we decided to multiply the count by 1.1 based on production statistics
        echo "Container Images Count: $currentAcrCount"
        containerImageCount=$((containerImageCount + currentAcrCount))
    fi

    # Get the number of VM images
    az image list --subscription $subscription --query "length([])" --only-show-errors -o tsv > ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get VM images for subscription ${subscription}"
    currentVmImageCount=$(cat "${_temp_subscription_output}")
    if [ -n "$currentVmImageCount" ]; then
        echo "VM images Count: $currentVmImageCount"
        vmImageCount=$((vmImageCount + currentVmImageCount))
    fi

    # Get the number of AKS nodes
    az aks list --subscription $subscription --query "[].{name: name, resourceGroup: resourceGroup}" -o json> ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Container Hosts for subscription ${subscription}"
    clusters=$(cat "${_temp_subscription_output}")
    currentNodesCount=0
    for cluster in $(echo "$clusters" | jq -c '.[]'); do
      cluster_name=$(echo $cluster | jq -r '.name')
      rg_name=$(echo $cluster | jq -r '.resourceGroup')
      az aks show --subscription $subscription --resource-group $rg_name --name $cluster_name --query "agentPoolProfiles[].count" -o tsv > ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Container Hosts for subscription ${subscription}"
      for nodes in $(cat "${_temp_subscription_output}"); do
        currentNodesCount=$((currentNodesCount + nodes))
      done
    done
    if [ -n "$currentNodesCount" ]; then
        echo "Container Hosts Count: $currentNodesCount"
        aksNodesCount=$((aksNodesCount + currentNodesCount))
    fi

        # get azure sql databases
    az sql server list --subscription $subscription --query "[].{name: name, resourceGroup: resourceGroup}" -o json> ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Azure SQL Databases for subscription ${subscription}"
    servers=$(cat "${_temp_subscription_output}")
    currentAzureDbCount=0
    db_size_threshold_in_bytes=$((MAX_DB_SIZE_GB * 1000 * 1000 * 1000))
    for server in $(echo "$servers" | jq -c '.[]'); do
      server_name=$(echo $server | jq -r '.name')
      rg_name=$(echo $server | jq -r '.resourceGroup')
      # filter out database with name "master"
      az sql db list --subscription $subscription --server $server_name --resource-group $rg_name --query "[?name!='master'].name" -o tsv > ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Azure SQL Databases for subscription ${subscription}"
      for db in $(cat "${_temp_subscription_output}"); do
        # filter out db with size greater than 1TB
        az sql db list-usages --subscription $subscription --server $server_name --resource-group $rg_name --name $db --query "[?currentValue.to_number(@) <= \`${db_size_threshold_in_bytes}\` && name=='database_allocated_size'].id" -o tsv > ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Azure SQL Databases size for subscription ${subscription}"
        # only one here
        if [ -s ${_temp_subscription_output} ]; then
          currentAzureDbCount=$((currentAzureDbCount + 1))
        fi
      done
    done
    if [ -n "$currentAzureDbCount" ]; then
        echo "Managed Databases (up to ${MAX_DB_SIZE_GB} GB): $currentAzureDbCount"
        dbCount=$((dbCount + currentAzureDbCount))
    fi

    # Get the number of public and private buckets
    az storage account list --subscription $subscription --query "[].{name: name, allowBlobPublicAccess: allowBlobPublicAccess}" -o json > ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Storage Accounts for subscription ${subscription}"
    storageAccountList=$(cat "${_temp_subscription_output}")
    currentPrivateContainersCount=0
    currentPublicContainersCount=0
    currentWebsiteCount=0
    for storageAccount in $(echo "$storageAccountList" | jq -c '.[]'); do
        storageAccountName=$(echo $storageAccount | jq -r '.name')
        allowBlobPublicAccess=$(echo $storageAccount | jq -r '.allowBlobPublicAccess')

        az storage container list --subscription $subscription --account-name $storageAccountName --auth-mode login --query "[].{name: name, publicAccess: properties.publicAccess}" -o json > ${_temp_subscription_output} 2>> $LOG_FILE ||  echo "Failed to get Storage Containers for subscription ${subscription}"

        containerList=$(cat "${_temp_subscription_output}")
        for container in $(echo "$containerList" | jq -c '.[]'); do
            containerName=$(echo $container | jq -r '.name')
            containerPublicAccess=$(echo $container | jq -r '.publicAccess')
            if [[ "$containerName" == "\$web" ]]; then
                let currentPublicContainersCount++
                let currentWebsiteCount++
            elif [[ "$allowBlobPublicAccess" == "true" && "$containerPublicAccess" != "null" ]]; then
                let currentPublicContainersCount++
            else
                let currentPrivateContainersCount++
            fi
        done
    done
    if [ -n "$currentPublicContainersCount" ]; then
        echo "Public Storage Account Containers Count: $currentPublicContainersCount (including $currentWebsiteCount websites)"
        publicStorageContainersCount=$((publicStorageContainersCount + $currentPublicContainersCount))
    fi
    if [ -n "$currentPrivateContainersCount" ]; then
        echo "Private Storage Account Containers Count: $currentPrivateContainersCount"
        privateStorageContainersCount=$((privateStorageContainersCount + $currentPrivateContainersCount))
    fi

    # Get the number of data (non-os) disks
    az vm list --query "[].storageProfile.dataDisks"  --subscription $subscription \
    | jq -r '.[][] | select(.diskSizeGb <= 1024) | .diskSizeGb' | wc -l > ${_temp_subscription_output} 2>> $LOG_FILE \
    ||  echo "Failed to get data disks for subscription ${subscription}"
    currentDataDisksCount=$(cat "${_temp_subscription_output}")
    if [ -n "$currentDataDisksCount" ]; then
        echo "Data Disks Count: $currentDataDisksCount"
        dataDisksCount=$((dataDisksCount + $currentDataDisksCount))
    fi

    #Increment counter
    counter=$((counter+1))
    if [ -n "$management_group" ]; then
        echo -n "Progress: $counter/$subscriptionCount subscriptions"
    fi

    # Add a line break
    echo -e "\n"
done


# Workloads calculation
vm_workloads=$(( ( vmCount + WORKLOAD_VM_UNITS / 2 ) / WORKLOAD_VM_UNITS ))
if [[ $vm_workloads -eq 0 && $vmCount -gt 0 ]]; then
    vm_workloads=1
fi
function_workloads=$(( ( functionAppCount + WORKLOAD_FUNCTION_UNITS / 2 ) / WORKLOAD_FUNCTION_UNITS ))
if [[ $function_workloads -eq 0 && $functionAppCount -gt 0 ]]; then
    function_workloads=1
fi
container_workloads=$(( ( ContainerCount + WORKLOAD_SERVERLESS_CONTAINER_UNITS / 2 ) / WORKLOAD_SERVERLESS_CONTAINER_UNITS ))
if [[ $container_workloads -eq 0 && $ContainerCount -gt 0 ]]; then
    container_workloads=1
fi
container_image_workloads=$(( ( containerImageCount + WORKLOAD_CONTAINER_IMAGE_UNITS / 2 ) / WORKLOAD_CONTAINER_IMAGE_UNITS ))
if [[ $container_image_workloads -eq 0 && $containerImageCount -gt 0 ]]; then
    container_image_workloads=1
fi
vm_image_workloads=$(( ( vmImageCount + WORKLOAD_VM_IMAGE_UNITS / 2 ) / WORKLOAD_VM_IMAGE_UNITS ))
if [[ $vm_image_workloads -eq 0 && $vmImageCount -gt 0 ]]; then
    vm_image_workloads=1
fi
container_host_workloads=$(( ( aksNodesCount + WORKLOAD_CONTAINER_HOST_UNITS / 2 ) / WORKLOAD_CONTAINER_HOST_UNITS ))
if [[ $container_host_workloads -eq 0 && $aksNodesCount -gt 0 ]]; then
    container_host_workloads=1
fi
db_host_workloads=$(( ( dbCount + WORKLOAD_DB_UNITS / 2 ) / WORKLOAD_DB_UNITS ))
if [[ $db_host_workloads -eq 0 && $dbCount -gt 0 ]]; then
    db_host_workloads=1
fi
public_storage_container_workloads=$(( ( publicStorageContainersCount + WORKLOAD_PUBLIC_STORAGE_CONTAINER_UNITS / 2 ) / WORKLOAD_PUBLIC_STORAGE_CONTAINER_UNITS ))
if [[ $public_storage_container_workloads -eq 0 && $publicStorageContainersCount -gt 0 ]]; then
    public_storage_container_workloads=1
fi
private_storage_container_workloads=$(( ( privateStorageContainersCount + WORKLOAD_PRIVATE_STORAGE_CONTAINER_UNITS / 2 ) / WORKLOAD_PRIVATE_STORAGE_CONTAINER_UNITS ))
if [[ $private_storage_container_workloads -eq 0 && $privateStorageContainersCount -gt 0 ]]; then
    private_storage_container_workloads=1
fi
data_disk_workloads=$(awk "BEGIN {print $dataDisksCount / $WORKLOAD_DATA_DISK_UNITS}")
data_disk_workloads=$(awk "BEGIN {print ($data_disk_workloads) == int($data_disk_workloads) ? ($data_disk_workloads) : int($data_disk_workloads) + 1}")

total_workloads=$(( vm_workloads + function_workloads + container_workloads + container_image_workloads + vm_image_workloads + \
container_host_workloads + db_host_workloads + public_storage_container_workloads + private_storage_container_workloads + data_disk_workloads))

echo "=============="
echo "Total results:"
echo "=============="
echo "Virtual Machines Count: $vmCount (Workload Units: ${vm_workloads})"
echo "Serverless Functions Count: $functionAppCount (Workload Units: ${function_workloads})"
echo "Serverless Containers Count: $ContainerCount (Workload Units: ${container_workloads})"
echo "Container Images Count: $containerImageCount (Workload Units: ${container_image_workloads})"
echo "VM Images Count: $vmImageCount (Workload Units: ${vm_image_workloads})"
echo "Container Hosts Count: $aksNodesCount (Workload Units: ${container_host_workloads})"
echo "Managed Databases Hosts Count: (up to ${MAX_DB_SIZE_GB} GB): ${db_host_workloads}"
echo "Public Storage Account Containers Count: $publicStorageContainersCount (Workload Units: ${public_storage_container_workloads})"
echo "Private Storage Account Containers Count: $privateStorageContainersCount (Workload Units: ${private_storage_container_workloads})"
echo "Data Disks Count: $dataDisksCount (Workload Units: ${data_disk_workloads})"
echo "--------------------------------------"
echo "TOTAL Estimated Workload Units: ${total_workloads}"
echo
echo "Please verify if errors were encountered during the resource enumeration in the log file: ${LOG_FILE}"
