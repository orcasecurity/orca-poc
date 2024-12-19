#!/bin/bash
set -e

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

LOG_FILE='gcp_resource_count.log'
exec 2> >(while IFS= read -r line; do echo "$(date '+%Y-%m-%d %H:%M:%S') [stderr] $line"; done >>$LOG_FILE)

MAX_DB_SIZE_GB=1024
MAX_DISK_SIZE_GB=1024

WORKLOAD_VM_UNITS=1
WORKLOAD_FUNCTION_UNITS=50
WORKLOAD_SERVERLESS_CONTAINER_UNITS=10
WORKLOAD_VM_IMAGE_UNITS=1
WORKLOAD_CONTAINER_IMAGE_UNITS=10
WORKLOAD_CONTAINER_HOST_UNITS=1
WORKLOAD_MANAGED_DB_UNITS=1
WORKLOAD_DATAWAREHOUSE_UNITS=4
WORKLOAD_BUCKET=1
WORKLOAD_NON_BOOT_DISK_UNITS=1

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

calculate_workloads() {
    local total_count=$1
    local workload_unit=$2

    total_workload_unit_count=$(((total_count + workload_unit / 2) / workload_unit))
    if [[ total_workload_unit_count -eq 0 && total_count -gt 0 ]]; then
        total_workload_unit_count=1
    fi
    echo $total_workload_unit_count
}

calculate_resource_workloads() {
    vm_workloads=$(calculate_workloads "$total_vms" "$WORKLOAD_VM_UNITS")
    function_workloads=$(calculate_workloads "$total_functions" "$WORKLOAD_FUNCTION_UNITS")
    container_workloads=$(calculate_workloads "$total_cloud_run" "$WORKLOAD_SERVERLESS_CONTAINER_UNITS")
    container_image_workloads=$(calculate_workloads "$total_container_images" "$WORKLOAD_CONTAINER_IMAGE_UNITS")
    vm_image_workloads=$(calculate_workloads "$total_vm_images" "$WORKLOAD_VM_IMAGE_UNITS")
    container_host_workloads=$(calculate_workloads "$total_gke_nodes" "$WORKLOAD_CONTAINER_HOST_UNITS")
    managed_db_workloads=$(calculate_workloads "$total_managed_db_count_filter_smaller_than_tera" "$WORKLOAD_MANAGED_DB_UNITS")
    datawarehouse_workloads=$(calculate_workloads "$total_datawarehouses_datasets" "$WORKLOAD_DATAWAREHOUSE_UNITS")
    total_bucket_workloads=$(calculate_workloads "$total_buckets" "$WORKLOAD_BUCKET")
    private_bucket_workloads=$(calculate_workloads "$total_private_buckets" "$WORKLOAD_BUCKET")
    non_boot_disk_workloads=$(calculate_workloads "$total_non_boot_disk_count" "$WORKLOAD_NON_BOOT_DISK_UNITS")

    total_workloads=$((vm_workloads + function_workloads + container_workloads + \
        container_image_workloads + vm_image_workloads + container_host_workloads + managed_db_workloads + datawarehouse_workloads + total_bucket_workloads + non_boot_disk_workloads))
}

display_summary() {
    echo -e "${CYAN}Summary of Resources and Workload Units:${RESET}"
    echo -e "--------------------------------------"

    echo -e "Virtual Machines Count             : $total_vms (Workload Units: $vm_workloads)"
    echo -e "Serverless Functions Count         : $total_functions (Workload Units: $function_workloads)"
    echo -e "Serverless Containers Count        : $total_cloud_run (Workload Units: $container_workloads)"
    echo -e "Container Images Count             : $total_container_images (Workload Units: $container_image_workloads)"
    echo -e "VM Images Count                    : $total_vm_images (Workload Units: $vm_image_workloads)"
    echo -e "Container Hosts Count              : $total_gke_nodes (Workload Units: $container_host_workloads)"
    echo -e "Managed Databases Count (up to $((MAX_DB_SIZE_GB / 1024)) TB): $total_managed_db_count (Workload Units: $managed_db_workloads)"
    echo -e "DataWarehouses Count               : $total_datawarehouses_datasets (Workload Units: $datawarehouse_workloads)"
    echo -e "Private Buckets                    : $total_private_buckets (Workload Units: $private_bucket_workloads)"
    echo -e "Public Buckets                     : $((total_buckets - total_private_buckets)) (Workload Units: $((total_bucket_workloads - private_bucket_workloads)))"
    echo -e "Buckets Count                      : $total_buckets (Workload Units: $total_bucket_workloads)"
    echo -e "Non Boot Disks Count               : $total_non_boot_disk_count (Workload Units: $non_boot_disk_workloads)"

    echo -e "--------------------------------------"

    echo -e "${GREEN}TOTAL Estimated Workload Units:${RESET} ${YELLOW}${total_workloads}${RESET}"
}

parse_arguments() {
    local organization_id=""
    local project_id=""
    local folder_id=""
    local max_db_size_gb=""

    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo -e "${CYAN}Usage:${RESET} $0 [options]"
        echo -e "Options:"
        echo -e "  -g, --organization_id <id>    Specify the organization ID"
        echo -e "  -p, --project_id <id>         Specify the project ID"
        echo -e "  -f, --folder_id <id>          Specify the folder ID"
        echo -e "  -s, --max-db-size-gb <size>   Specify the max DB size in GB"
        echo -e "  -h, --help                    Display this help menu"
        echo -e "\n${YELLOW}Note:${RESET} Only one of --organization_id, --project_id, or --folder_id can be specified."
        exit 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -g | --organization_id)
                if [[ -n "$project_id" || -n "$folder_id" ]]; then
                    echo -e "${RED}Error:${RESET} Only one of --organization_id, --project_id, or --folder_id can be set." >&2
                    exit 1
            fi
                organization_id="$2"
                shift 2
                ;;
            -p | --project_id)
                if [[ -n "$organization_id" || -n "$folder_id" ]]; then
                    echo -e "${RED}Error:${RESET} Only one of --organization_id, --project_id, or --folder_id can be set." >&2
                    exit 1
            fi
                project_id="$2"
                shift 2
                ;;
            -f | --folder_id)
                if [[ -n "$organization_id" || -n "$project_id" ]]; then
                    echo -e "${RED}Error:${RESET} Only one of --organization_id, --project_id, or --folder_id can be set." >&2
                    exit 1
            fi
                folder_id="$2"
                shift 2
                ;;
            -s | --max-db-size-gb)
                max_db_size_gb="$2"
                shift 2
                ;;
            *)
                echo -e "${RED}Error:${RESET} Unknown option $1" >&2
                echo -e "Use ${CYAN}--help${RESET} to display usage information."
                exit 1
                ;;
        esac
    done

    if [[ -z "$organization_id" && -z "$project_id" && -z "$folder_id" ]]; then
        echo -e "${YELLOW}No specific scope provided.${RESET} Defaulting to all organizations in the account."
    fi

    if [[ -n "$organization_id" ]]; then
        SCOPE="organizations/$organization_id"
    elif [[ -n "$project_id" ]]; then
        SCOPE="projects/$project_id"
    elif [[ -n "$folder_id" ]]; then
        SCOPE="folders/$folder_id"
    fi

    export SCOPE
    export MAX_DB_SIZE_GB="$max_db_size_gb"

    echo -e "${GREEN}Configuration:${RESET}"
    echo -e "  Scope: ${CYAN}$SCOPE${RESET}"
    [[ -n "$max_db_size_gb" ]] && echo -e "  Max DB Size (GB): ${CYAN}$MAX_DB_SIZE_GB${RESET}"
}

list_projects_by_type() {
    local all_resources="$1"
    local asset_type="$2"
    jq -r --arg assetType "$asset_type" '.[] | select( .assetType == $assetType) | .parentFullResourceName | split("/")[4]' <<<"$all_resources"  | sort -u
}

#################################################################
######################                     ######################
######################   PRIVATE BUCKETS   ######################
######################                     ######################
#################################################################

get_project_bucket_details() {
    local project="$1"
    gcloud storage buckets list --project="$project" --format=json |
        jq -s "[.[][]] | {project: \"$project\", storage_url: .[].storage_url, public_access_prevention: .[].public_access_prevention}"
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

###################################################################
######################                       ######################
######################   MANAGED DATABASES   ######################
######################                       ######################
###################################################################

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

################################################################
######################                    ######################
######################   NON BOOT DISKS   ######################
######################                    ######################
################################################################

count_non_boot_disk_from_project() {
    local project="$1"
    local all_non_boot_disks_json
    all_non_boot_disks_json=$(gcloud compute instances list --project "${project}" --format json | jq -r --arg min_disk_size_gb '[.[] | select(.disks[].boot != true)]')
    filter_smaller_than_tera=$(echo "$all_non_boot_disks_json" | jq -r --arg min_disk_size_gb "$MAX_DISK_SIZE_GB" '[.[] | select(.disks[].sizeGb < $min_disk_size_gb)]')
    echo "$filter_smaller_than_tera" | jq -s '. | length'
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

################################################################
######################                    ######################
######################        UTILS       ######################
######################                    ######################
################################################################

initialize_counters() {
    for var in "${!RESOURCE_TYPES[@]}"; do
        declare "${RESOURCE_TYPES[$var]}=0"
    done

    total_private_buckets=0
    total_managed_db_count_filter_smaller_than_tera=0
    total_non_boot_disk_count=0
}

prepare_asset_types() {
    local IFS=,
    echo "${!RESOURCE_TYPES[*]}"
}

count_resources() {
    local all_resources="$1"

    for asset_type in "${!RESOURCE_TYPES[@]}"; do
        local var_name="${RESOURCE_TYPES[$asset_type]}"
        local count

        count=$(echo "$all_resources" | jq -r --arg type "$asset_type" \
            '[.[] | select(.assetType == $type)] | length')

        eval "$var_name=$((${!var_name} + count))"
    done

    local local_managed_db_count
    local_managed_db_count=$(count_all_managed_db "$all_resources")
    total_managed_db_count_filter_smaller_than_tera=$((total_managed_db_count_filter_smaller_than_tera + local_managed_db_count))

    local local_private_buckets
    local_private_buckets=$(count_private_buckets "$all_resources")
    total_private_buckets=$((total_private_buckets + local_private_buckets))

    local local_non_boot_disk_count
    local_non_boot_disk_count=$(count_all_non_boot_disks "$all_resources")
    total_non_boot_disk_count=$((total_non_boot_disk_count + local_non_boot_disk_count))
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

main()  {
    parse_arguments "$@"

    local target_scope="$SCOPE"

    local processed_scopes
    if [[ -z "$target_scope" ]]; then
        processed_scopes=$(gcloud organizations list --format="value(name)" | sed 's/^/organizations\//')
    else
        processed_scopes="$target_scope"
    fi

    initialize_counters

    for scope in $processed_scopes; do
        echo "Processing scope: $scope..."

        local resources
        resources=$(fetch_resources "$scope")

        count_resources "$resources"
    done

    calculate_resource_workloads

    display_summary
}

main "$@"
