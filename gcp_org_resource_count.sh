#!/bin/bash
set -e
LOG_FILE='gcp_resource_count.log'
exec 2> >(while IFS= read -r line; do echo "$(date '+%Y-%m-%d %H:%M:%S') [stderr] $line"; done >>$LOG_FILE)

MAX_DB_SIZE_GB=1024

WORKLOAD_VM_UNITS=1
WORKLOAD_FUNCTION_UNITS=50
WORKLOAD_SERVERLESS_CONTAINER_UNITS=10
WORKLOAD_VM_IMAGE_UNITS=1
WORKLOAD_CONTAINER_IMAGE_UNITS=10
WORKLOAD_CONTAINER_HOST_UNITS=1
WORKLOAD_MANAGED_DB_UNITS=1
WORKLOAD_DATAWAREHOUSE_UNITS=4
WORKLOAD_BUCKET=1

# listed here https://cloud.google.com/asset-inventory/docs/asset-types
declare -A RESOURCE_TYPES=(
        ["compute.googleapis.com/Instance"]="total_vms"
        ["cloudfunctions.googleapis.com/CloudFunction"]="total_functions"
        ["run.googleapis.com/Service"]="total_cloud_run"
        ["containerregistry.googleapis.com/Image"]="total_container_images"
        ["compute.googleapis.com/Image"]="total_vm_images"
        ["k8s.io/Node"]="total_gke_nodes"
        ["sqladmin.googleapis.com/Instance"]="total_managed_db_count"
        ["bigquery.googleapis.com/Dataset"]="total_datawarehouses_datasets"
        ["storage.googleapis.com/Bucket"]="total_buckets"
)

calculate_resource_workloads() {
    vm_workloads=$(calculate_workloads "$total_vms" "$WORKLOAD_VM_UNITS")
    function_workloads=$(calculate_workloads "$total_functions" "$WORKLOAD_FUNCTION_UNITS")
    container_workloads=$(calculate_workloads "$total_cloud_run" "$WORKLOAD_SERVERLESS_CONTAINER_UNITS")
    container_image_workloads=$(calculate_workloads "$total_container_images" "$WORKLOAD_CONTAINER_IMAGE_UNITS")
    vm_image_workloads=$(calculate_workloads "$total_vm_images" "$WORKLOAD_VM_IMAGE_UNITS")
    container_host_workloads=$(calculate_workloads "$total_gke_nodes" "$WORKLOAD_CONTAINER_HOST_UNITS")
    managed_db_workloads=$(calculate_workloads "$total_managed_db_count" "$WORKLOAD_MANAGED_DB_UNITS")
    datawarehouse_workloads=$(calculate_workloads "$total_datawarehouses_datasets" "$WORKLOAD_DATAWAREHOUSE_UNITS")
    total_bucket_workloads=$(calculate_workloads "$total_buckets" "$WORKLOAD_BUCKET")
    private_bucket_workloads=$(calculate_workloads "$total_private_buckets" "$WORKLOAD_BUCKET")

    total_workloads=$((vm_workloads + function_workloads + container_workloads + \
        container_image_workloads + vm_image_workloads + container_host_workloads + managed_db_workloads + datawarehouse_workloads + total_bucket_workloads))
}

display_summary() {
    echo "Virtual Machines Count: $total_vms (Workload Units: ${vm_workloads})"
    echo "Serverless Functions Count: $total_functions (Workload Units: ${function_workloads})"
    echo "Serverless Containers Count: $total_cloud_run (Workload Units: ${container_workloads})"
    echo "Container Images Count: $total_container_images (Workload Units: ${container_image_workloads})"
    echo "VM Images Count: $total_vm_images (Workload Units: ${vm_image_workloads})"
    echo "Container Hosts Count: $total_gke_nodes (Workload Units: ${container_host_workloads})"
    echo "Managed Databases Count (up to $((MAX_DB_SIZE_GB / 1024)) TB): $total_managed_db_count (Workload Units: ${managed_db_workloads})"
    echo "DataWarehouses Count: $total_datawarehouses_datasets (Workload Units: $datawarehouse_workloads)"
    echo "Private Buckets: $total_private_buckets (Workload Units: $private_bucket_workloads)"
    echo "Public Buckets: $((total_buckets - total_private_buckets)) (Workload Units: $((total_bucket_workloads - private_bucket_workloads)))"
    echo "Buckets Count: $total_buckets (Workload Units: $total_bucket_workloads)"
    echo "--------------------------------------"
    echo "TOTAL Estimated Workload Units: ${total_workloads}"
}

parse_arguments() {
    local org_id=""

    # Parse command-line options
    while [[ $# -gt 0 ]]; do
          key="$1"
        case $key in
        -g | --organization_id)
                org_id="$2"
            shift # past argument
            shift # past value
            ;;
        -s | --max-db-size-gb)
            MAX_DB_SIZE_GB="$2"
            shift # past argument
            shift # past value
            ;;
        *)    # unknown option
            shift # past argument
            ;;
        esac
    done

    echo "$org_id"
}

get_organizations() {
    local org_id="$1"

    if [[ -z "$org_id" ]]; then
        local orgs
        orgs=$(gcloud organizations list --format="value(name)")

        echo "$orgs"
    else
        echo "$org_id"
    fi
}

initialize_counters() {
    for var in "${!RESOURCE_TYPES[@]}"; do
        declare "${RESOURCE_TYPES[$var]}=0"
    done

    total_private_buckets=0
    total_managed_db_count=0
}

prepare_asset_types() {
    local IFS=,
    echo "${!RESOURCE_TYPES[*]}"
}

fetch_resources() {
    local asset_types
    local scope="$1"
    asset_types=$(prepare_asset_types)

    gcloud asset search-all-resources \
        --scope="$scope" \
        --format="json(displayName, assetType, parentFullResourceName)" \
        --asset-types="$asset_types"
}

get_project_bucket_details() {
    local project="$1"
    gcloud storage buckets list --project="$project" --format=json |
        jq -s "[.[][]] | {project: \"$project\", storage_url: .[].storage_url, public_access_prevention: .[].public_access_prevention}"
}

list_projects_by_type() {
    local all_resources="$1"
    local asset_type="$2"
    jq -r --arg assetType "$asset_type" '.[] | select( .assetType == $assetType) | .parentFullResourceName | split("/")[4]' <<<"$all_resources"  | sort -u
}

count_private_buckets() {
    local all_resources="$1"
    local asset_type="storage.googleapis.com/Bucket"

    local current_all_buckets_json
    current_all_buckets_json=$(list_projects_by_type "$all_resources" "$asset_type" |
        xargs -P30 -I{} bash -c "$(declare -f get_project_bucket_details); get_project_bucket_details '{}'" |
        jq -c '.' | sort -u)

    local curr_private_buckets
    curr_private_buckets=$(echo "$current_all_buckets_json" |
        jq '. | select(.public_access_prevention == "enforced")' |
        jq -s '. | length')

    local curr_private_buckets_from_policy
    local all_non_enforced_buckets

    all_non_enforced_buckets=$(echo "$current_all_buckets_json" | jq -r '. | select(.public_access_prevention != "enforced") | [.project,.storage_url] | join(" ")')

    curr_private_buckets_from_policy=$(echo "$all_non_enforced_buckets" |
        xargs -n2 -P30 bash -c "$(declare -f check_bucket_iam_policy); check_bucket_iam_policy \"\$0\" \"\$1\"" |
        awk '{sum+=$1} END {print sum}')

    echo $((curr_private_buckets + curr_private_buckets_from_policy))
}

count_managed_db_from_project() {
    local project="$1"
    gcloud -q sql instances list --project "${project}" --format json | jq -r --arg max_db_size_gb "$MAX_DB_SIZE_GB" '[.[] | select(.state == "RUNNABLE" and ((.settings.dataDiskSizeGb // "0") | tonumber) <= $max_db_size_gb)] | length'
}

count_all_managed_db() {
    local all_resources="$1"
    local current_managed_db_count=0
    local asset_type="sqladmin.googleapis.com/Instance"

    local projects
    projects=$(list_projects_by_type "$all_resources" "$asset_type")

    current_managed_db_count=$(echo "$projects" | xargs -n1 -P30 bash -c "$(declare -f count_managed_db_from_project); count_managed_db_from_project \"\$0\"" | awk '{sum+=$1} END {print sum}')
    echo "$current_managed_db_count"
}

count_non_boot_disk_from_project() {
    local project="$1"
    gcloud compute instances list --project "${project}" --format json | jq -r '[.[] | select(.disks[].boot != true)] | length'
}

count_all_non_boot_disks() {
    local all_resources="$1"
    local asset_type="compute.googleapis.com/Instance"

    local projects
    projects=$(list_projects_by_type "$all_resources" "$asset_type")

    local current_non_boot_disk_count=0
    current_non_boot_disk_count=$(echo "$projects" | xargs -n1 -P30 bash -c "$(declare -f count_non_boot_disk_from_project); count_non_boot_disk_from_project \"\$0\"" | awk '{sum+=$1} END {print sum}')
    echo "$current_non_boot_disk_count"
}

count_resources() {
    local all_resources="$1"
    local org_id="$2"

    for asset_type in "${!RESOURCE_TYPES[@]}"; do
        local var_name="${RESOURCE_TYPES[$asset_type]}"
        local count

        count=$(echo "$all_resources" | jq -r --arg type "$asset_type" \
            '[.[] | select(.assetType == $type)] | length')

        eval "$var_name=$((${!var_name} + count))"
    done

    local_private_buckets=$(count_private_buckets "$all_resources")
    total_private_buckets=$((total_private_buckets + local_private_buckets))

    local_managed_db_count=$(count_all_managed_db "$all_resources")
    total_managed_db_count=$((total_managed_db_count + local_managed_db_count))
}

check_bucket_iam_policy() {
    local project="$1"
    local bucket="$2"

    if gcloud storage buckets get-iam-policy "$bucket" --project "$project" |
        grep -qE "\"allUsers\"|\"allAuthenticatedUsers\""; then
        echo "0"
    else
        [ $? -ne 0 ] && echo "Permission error checking IAM policy for $bucket in project $project" >&2
        echo "1"
    fi
}

calculate_workloads() {
    local total_count=$1
    local workload_unit=$2

    total_workload_unit_count=$(((total_count + workload_unit / 2) / workload_unit))
    if [[ total_workload_unit_count -eq 0 && total_count -gt 0 ]]; then
        total_workload_unit_count=1
    fi
    echo $total_workload_unit_count
}

main()  {
    local org_id
    org_id=$(parse_arguments "$@")
    local orgs
    orgs=$(get_organizations "$org_id")

    initialize_counters

    for org_id in $orgs; do
        echo "Processing organization: $org_id"
        local all_resources
        all_resources=$(fetch_resources "organizations/$org_id")
        count_resources "$all_resources" "$org_id"
    done

    calculate_resource_workloads

    display_summary
}

main "$@"
