#!/bin/bash
set -e
LOG_FILE='gcp_resource_count.log'
exec 2> >(while IFS= read -r line; do echo "$(date '+%Y-%m-%d %H:%M:%S') [stderr] $line"; done >> $LOG_FILE)

WORKLOAD_VM_UNITS=1
WORKLOAD_FUNCTION_UNITS=50
WORKLOAD_SERVERLESS_CONTAINER_UNITS=10
WORKLOAD_VM_IMAGE_UNITS=1
WORKLOAD_CONTAINER_IMAGE_UNITS=10
WORKLOAD_CONTAINER_HOST_UNITS=1

ORG_ID=""

while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -g|--organization_id)
        ORG_ID="$2"
        shift # past argument
        shift # past value
        ;;
        *)    # unknown option
        shift # past argument
        ;;
    esac
done

if [ -z "$ORG_ID" ]; then
    echo "[+] Getting organizations list"
    ORGS=$(gcloud organizations list --format="value(name)")
    ORGS_LEN=$(echo "$ORGS" | wc -l)
    echo "Found ${ORGS_LEN} organizations"
    echo "[+] Iterating organizations and counting resources"
else
    ORGS="$ORG_ID"
    echo "[+] counting resources for organizations id ${ORG_ID}"
fi
echo

counter=0
total_vms=0
total_functions=0
total_cloud_run=0
total_container_images=0
total_vm_images=0
total_gke_nodes=0
total_buckets=0
total_private_buckets=0
active_user=$(gcloud config get-value account)

# listed here https://cloud.google.com/asset-inventory/docs/asset-types
asset_types="compute.googleapis.com/Instance,cloudfunctions.googleapis.com/CloudFunction,run.googleapis.com/Service,containerregistry.googleapis.com/Image,compute.googleapis.com/Image,k8s.io/Node,storage.googleapis.com/Bucket"

for org_id in $ORGS; do
  echo "Processing organization: $org_id"

  all_resources=$(gcloud asset search-all-resources --scope="organizations/$org_id" --format="json(displayName, assetType, project)" --asset-types="$asset_types")
  curr_vms=$(echo "$all_resources" | jq -r '.[] | select(.assetType == "compute.googleapis.com/Instance") | .displayName' | wc -l)
  curr_functions=$(echo "$all_resources" | jq -r '.[] | select(.assetType == "cloudfunctions.googleapis.com/CloudFunction") | .displayName' | wc -l)
  curr_cloud_run=$(echo "$all_resources" | jq -r '.[] | select(.assetType == "run.googleapis.com/Service") | .displayName' | wc -l)
  curr_container_images=$(echo "$all_resources" | jq -r '.[] | select(.assetType == "containerregistry.googleapis.com/Image") | .displayName' | wc -l)
  curr_vm_images=$(echo "$all_resources" | jq -r '.[] | select(.assetType == "compute.googleapis.com/Image") | .displayName' | wc -l)
  curr_gke_nodes=$(echo "$all_resources" | jq -r '.[] | select(.assetType == "k8s.io/Node") | .displayName' | wc -l)
  curr_buckets=$(echo "$all_resources" | jq -r '.[] | select(.assetType == "storage.googleapis.com/Bucket") | .displayName' | wc -l)

  total_vms=$((total_vms + curr_vms))
  total_functions=$((total_functions + curr_functions))
  total_cloud_run=$((total_cloud_run + curr_cloud_run))
  total_container_images=$((total_container_images + curr_container_images))
  total_vm_images=$((total_vm_images + curr_vm_images))
  total_gke_nodes=$((total_gke_nodes + curr_gke_nodes))
  total_buckets=$((total_buckets + curr_buckets))



  is_public_access_prevention_enabled_from_org_level=$(gcloud resource-manager org-policies describe storage.publicAccessPrevention --organization="$org_id" --effective --format json |  jq '.booleanPolicy.enforced == true')

  if [[ $is_public_access_prevention_enabled_from_org_level == "true" ]]; then
      total_private_buckets=$((total_private_buckets + curr_buckets))
  else
      current_all_buckets_json=$(gcloud projects list --filter="parent.id=$org_id" --format="value(projectId)" | xargs -P30 -I{} sh -c "gcloud storage buckets list --project={} --format=json | jq -s '[.[][]] | {project: \"{}\", storage_url: .[].storage_url, public_access_prevention: .[].public_access_prevention}'" | jq -c '.' | sort -u)
      curr_private_buckets=$(echo "$current_all_buckets_json" | jq '. | select(.public_access_prevention == "enforced")' | jq -s '. | length')

      curr_private_buckets_from_policy=$(echo "$current_all_buckets_json" | jq -r '. | select(.public_access_prevention != "enforced") | [.project,.storage_url] | join(" ")' | xargs -n2 -P30 sh -c 'if gcloud storage buckets get-iam-policy "$1" --project "$0" | grep -qE "\"allUsers\"|\"allAuthenticatedUsers\""; then
    echo "0"
else
    [ $? -ne 0 ] && echo "Permission error to command \"gcloud storage buckets get-iam-policy\" for $1 in project $0, see $LOG_FILE logs for more details" >&2
    echo "1"
fi' | awk '{sum+=$1} END {print sum}')
      total_private_buckets=$((total_private_buckets + curr_private_buckets + curr_private_buckets_from_policy))
  fi


  echo "$org_id Virtual Machines Count: $curr_vms"
  echo "$org_id Serverless Functions Count: $curr_functions"
  echo "$org_id Serverless Containers Count: $curr_cloud_run"
  echo "$org_id Container Images Count: $curr_container_images"
  echo "$org_id VM Images Count: $curr_vm_images"
  echo "$org_id Container Hosts Count: $curr_gke_nodes"
  echo "$org_id Private Buckets: $((curr_private_buckets + curr_private_buckets_from_policy))"
  echo "$org_id Public Buckets: $((curr_buckets - curr_private_buckets))"
  echo "$org_id Buckets Count: $curr_buckets"
  echo "--------------------------------------"
  echo "--------------------------------------"
  counter=$((counter+1))
  if [ -n "$ORGS_LEN" ]; then
      echo -n "Progress: $counter/$ORGS_LEN organizations"
  fi

  # Add a line break
  echo -e "\n"
done

# Workloads calculation
vm_workloads=$(( ( total_vms + WORKLOAD_VM_UNITS / 2 ) / WORKLOAD_VM_UNITS ))
if [[ $vm_workloads -eq 0 && $total_vms -gt 0 ]]; then
    vm_workloads=1
fi
function_workloads=$(( ( total_functions + WORKLOAD_FUNCTION_UNITS / 2 ) / WORKLOAD_FUNCTION_UNITS ))
if [[ $function_workloads -eq 0 && $total_functions -gt 0 ]]; then
    function_workloads=1
fi
container_workloads=$(( ( total_cloud_run + WORKLOAD_SERVERLESS_CONTAINER_UNITS / 2 ) / WORKLOAD_SERVERLESS_CONTAINER_UNITS ))
if [[ $container_workloads -eq 0 && $total_cloud_run -gt 0 ]]; then
    container_workloads=1
fi
container_image_workloads=$(( ( total_container_images + WORKLOAD_CONTAINER_IMAGE_UNITS / 2 ) / WORKLOAD_CONTAINER_IMAGE_UNITS ))
if [[ $container_image_workloads -eq 0 && $total_container_images -gt 0 ]]; then
    container_image_workloads=1
fi
vm_image_workloads=$(( ( total_vm_images + WORKLOAD_VM_IMAGE_UNITS / 2 ) / WORKLOAD_VM_IMAGE_UNITS ))
if [[ $vm_image_workloads -eq 0 && $total_vm_images -gt 0 ]]; then
    vm_image_workloads=1
fi
container_host_workloads=$(( ( total_gke_nodes + WORKLOAD_CONTAINER_HOST_UNITS / 2 ) / WORKLOAD_CONTAINER_HOST_UNITS ))
if [[ $container_host_workloads -eq 0 && $total_gke_nodes -gt 0 ]]; then
    container_host_workloads=1
fi
total_workloads=$(( vm_workloads + function_workloads + container_workloads + container_image_workloads + vm_image_workloads + container_host_workloads ))

echo "=============="
echo "Total results:"
echo "=============="
echo "Virtual Machines Count: $total_vms (Workload Units: ${vm_workloads})"
echo "Serverless Functions Count: $total_functions (Workload Units: ${function_workloads})"
echo "Serverless Containers Count: $total_cloud_run (Workload Units: ${container_workloads})"
echo "Container Images Count: $total_container_images (Workload Units: ${container_image_workloads})"
echo "VM Images Count: $total_vm_images (Workload Units: ${vm_image_workloads})"
echo "Container Hosts Count: $total_gke_nodes (Workload Units: ${container_host_workloads})"
echo "Private Buckets: $total_private_buckets"
echo "Public Buckets: $((total_buckets - total_private_buckets))"
echo "Buckets Count: $total_buckets"
echo "--------------------------------------"
echo "TOTAL Estimated Workload Units: ${total_workloads}"
echo
echo "Please verify if errors were encountered during the resource enumeration in the log file: ${LOG_FILE}"