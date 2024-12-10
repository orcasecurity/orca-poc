#!/bin/bash
set -e

LOG_FILE='gcp_resource_count.log'
WORKLOAD_VM_UNITS=1
WORKLOAD_FUNCTION_UNITS=50
WORKLOAD_SERVERLESS_CONTAINER_UNITS=10
WORKLOAD_VM_IMAGE_UNITS=1
WORKLOAD_CONTAINER_IMAGE_UNITS=10
WORKLOAD_CONTAINER_HOST_UNITS=1
WORKLOAD_CLOUDSQL_UNITS=1
WORKLOAD_DATASET_UNITS=1


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

PROJECT_ID=""
MAX_DB_SIZE=1100

while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -p|--project)
        PROJECT_ID="$2"
        shift # past argument
        shift # past value
        ;;
        -s|--max-db-size)
        MAX_DB_SIZE="$2"
        shift # past argument
        shift # past value
        ;;
        *)    # unknown option
        shift # past argument
        ;;
    esac
done

if [ -z "$PROJECT_ID" ]; then
    echo "[+] Getting projects list"
    PROJECTS_FILE=$(mktemp)
    gcloud -q projects list --filter="lifecycleState:ACTIVE" --format json > "${PROJECTS_FILE}"
    PROJECT_LEN="$(cat ${PROJECTS_FILE} | jq -r '. | length')"
    echo "Found ${PROJECT_LEN} projects"
    PROJECTS="$(cat ${PROJECTS_FILE} | jq -r '.[].projectId')"
    echo "[+] Iterating projects and counting resources"
else
    PROJECTS="$PROJECT_ID"
    echo "[+] counting resources for project ${PROJECT_ID}"
fi
echo
echo "Max DB Size: ${MAX_DB_SIZE}GB"

total_vms=0
total_functions=0
total_cloud_run=0
total_container_images=0
total_vm_images=0
total_gke_nodes=0
total_sql_dbs=0
total_bigquery_datasets=0
counter=0
_temp_project_output=$(_make_temp_file)
for project in $PROJECTS; do
    echo "Processing Project: $project"

    gcloud -q compute instances list --project "${project}" --format json > ${_temp_project_output} 2>> $LOG_FILE || echo "Failed to get Virtual Machines for project ${project}"
    project_vm_count=$(cat "${_temp_project_output}" | jq -r '. | length')
    if [ -n "$project_vm_count" ]; then
      total_vms=$((total_vms + project_vm_count))
      echo "Virtual Machines Count: $project_vm_count"
    fi

    gcloud -q functions list --project "${project}" --format json > ${_temp_project_output} 2>> $LOG_FILE || echo "Failed to get Serverless Functions for project ${project}"
    project_function_count=$(cat "${_temp_project_output}" | jq -r '. | length')
    if [ -n "$project_function_count" ]; then
      total_functions=$((total_functions + project_function_count))
      echo "Serverless Functions Count: $project_function_count"
    fi

    gcloud -q run services list --project "${project}" --format='json(spec.template.spec.containers)' > ${_temp_project_output} 2>> $LOG_FILE || echo "Failed to get Serverless Containers for project ${project}"
    containers_group=$(cat "${_temp_project_output}"  | jq '.[].spec.template.spec.containers | length')
    project_cloud_run_count=0
    for containers in $containers_group; do
        project_cloud_run_count=$((project_cloud_run_count + $containers))
    done
    if [[ -n "$project_cloud_run_count" && "$project_cloud_run_count" -ne 0 ]]; then
      total_cloud_run=$((total_cloud_run + project_cloud_run_count))
      echo "Serverless Containers Count: $project_cloud_run_count"
    fi

    gcrHosts=("gcr.io" "us.gcr.io" "eu.gcr.io" "asia.gcr.io")
    project_container_images_count=0
    for host in "${gcrHosts[@]}"; do
        gcloud -q container images list --repository=${host}/"${project}" --format json > ${_temp_project_output} 2>> $LOG_FILE || echo "Failed to get Container Images for project ${project}, host: [${host}]"
        host_container_images_count=$(cat "${_temp_project_output}" | jq -r '. | length')
        if [ -n "$host_container_images_count" ]; then
          project_container_images_count=$((project_container_images_count + host_container_images_count))
        fi
    done
    if [[ -n "$project_container_images_count" && "$project_container_images_count" -ne 0 ]]; then
      project_container_images_count=$(echo "$project_container_images_count*1.1" | awk '{printf "%.0f", $0}') # we scan 2 images per one repository and we decided to multiply the count by 1.1 based on production statistics
      total_container_images=$((total_container_images + project_container_images_count))
      echo "Container Images Count: $project_container_images_count"
    fi

    gcloud -q compute images list --no-standard-images --project "${project}" --format json > ${_temp_project_output} 2>> $LOG_FILE || echo "Failed to get VM images for project ${project}"
    project_vm_images_count=$(cat "${_temp_project_output}" | jq -r '. | length')
    if [ -n "$project_vm_images_count" ]; then
      total_vm_images=$((total_vm_images + project_vm_images_count))
      echo "VM images Count: $project_vm_images_count"
    fi

    gcloud -q container clusters list --project "${project}" --format='get(currentNodeCount)' --filter="NOT autopilot.enabled:true"> ${_temp_project_output} 2>> $LOG_FILE || echo "Failed to get Container Hosts for project ${project}"
    clusters_node_counts=$(cat "${_temp_project_output}")
    project_nodes_count=0
    for node_count in $clusters_node_counts; do
       project_nodes_count=$((project_nodes_count + node_count))
    done
    if [[ -n "$project_nodes_count" && "$project_nodes_count" -ne 0 ]]; then
      total_gke_nodes=$((total_gke_nodes + project_nodes_count))
      echo "Container Hosts Count: $project_nodes_count"
    fi

    # Fetch Cloud SQL databases
    gcloud -q sql instances list --project "${project}" --format json > ${_temp_project_output} 2>> $LOG_FILE || echo "Failed to get Cloud SQL DBs for project ${project}"
    project_sql_db_count=$(cat "${_temp_project_output}" | jq -r --argjson max_db_size "$MAX_DB_SIZE" '[.[] | select(.state == "RUNNABLE" and ((.settings.dataDiskSizeGb // "0") | tonumber) <= $max_db_size)] | length')
    if [ -n "$project_sql_db_count" ]; then
      total_sql_dbs=$((total_sql_dbs + project_sql_db_count))
      echo "Cloud SQL Databases Count: $project_sql_db_count"
    fi

    # Fetch BigQuery datasets
    bq -q ls --project_id "${project}" --format json > ${_temp_project_output} 2>> $LOG_FILE || echo "Failed to get BigQuery Datasets for project ${project}"
    project_bigquery_dataset_count=$(cat "${_temp_project_output}" | jq -r '. | length')
    if [ -n "$project_bigquery_dataset_count" ]; then
      total_bigquery_datasets=$((total_bigquery_datasets + project_bigquery_dataset_count))
      echo "BigQuery Datasets Count: $project_bigquery_dataset_count"
    fi


    #Increment counter
    counter=$((counter+1))
    if [ -n "$PROJECT_LEN" ]; then
        echo -n "Progress: $counter/$PROJECT_LEN projects"
    fi

    # Add a line break
    echo -e "\n"

done;


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
cloudsql_workloads=$(( ( total_sql_dbs + WORKLOAD_CLOUDSQL_UNITS / 2 ) / WORKLOAD_CLOUDSQL_UNITS ))
if [[ $cloudsql_workloads -eq 0 && total_sql_dbs -gt 0 ]]; then
    cloudsql_workloads=1
fi
dataset_workloads=$(( ( total_bigquery_datasets + WORKLOAD_DATASET_UNITS / 2 ) / WORKLOAD_DATASET_UNITS ))
if [[ $dataset_workloads -eq 0 && $total_bigquery_datasets -gt 0 ]]; then
    dataset_workloads=1
fi
total_workloads=$(( vm_workloads + function_workloads + container_workloads + container_image_workloads + vm_image_workloads + container_host_workloads + cloudsql_workloads + dataset_workloads ))

echo "=============="
echo "Total results:"
echo "=============="
echo "Virtual Machines Count: $total_vms (Workload Units: ${vm_workloads})"
echo "Serverless Functions Count: $total_functions (Workload Units: ${function_workloads})"
echo "Serverless Containers Count: $total_cloud_run (Workload Units: ${container_workloads})"
echo "Container Images Count: $total_container_images (Workload Units: ${container_image_workloads})"
echo "VM Images Count: $total_vm_images (Workload Units: ${vm_image_workloads})"
echo "Container Hosts Count: $total_gke_nodes (Workload Units: ${container_host_workloads})"
echo "CloudSQL Databases Count (up to $((MAX_DB_SIZE / 1000)) TB): $total_sql_dbs (Workload Units: ${cloudsql_workloads})"
echo "BigQuery Datasets Count: $total_bigquery_datasets (Workload Units: ${dataset_workloads})"
echo "--------------------------------------"
echo "TOTAL Estimated Workload Units: ${total_workloads}"
echo
echo "Please verify if errors were encountered during the resource enumeration in the log file: ${LOG_FILE}"