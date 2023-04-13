#!/bin/bash

LOG_FILE='azure_resource_count.log'
WORKLOAD_VM_UNITS=1
WORKLOAD_FUNCTION_UNITS=50
WORKLOAD_SERVERLESS_CONTAINER_UNITS=10
WORKLOAD_VM_IMAGE_UNITS=1
WORKLOAD_CONTAINER_IMAGE_UNITS=10
WORKLOAD_CONTAINER_HOST_UNITS=1

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
total_workloads=$(( vm_workloads + function_workloads + container_workloads + container_image_workloads + vm_image_workloads + container_host_workloads ))

echo "=============="
echo "Total results:"
echo "=============="
echo "Virtual Machines Count: $vmCount (Workload Units: ${vm_workloads})"
echo "Serverless Functions Count: $functionAppCount (Workload Units: ${function_workloads})"
echo "Serverless Containers Count: $ContainerCount (Workload Units: ${container_workloads})"
echo "Container Images Count: $containerImageCount (Workload Units: ${container_image_workloads})"
echo "VM Images Count: $vmImageCount (Workload Units: ${vm_image_workloads})"
echo "Container Hosts Count: $aksNodesCount (Workload Units: ${container_host_workloads})"
echo "--------------------------------------"
echo "TOTAL Estimated Workload Units: ${total_workloads}"
echo
echo "Please verify if errors were encountered during the resource enumeration in the log file: ${LOG_FILE}"
