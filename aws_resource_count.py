import argparse
import datetime
import dateutil
from dataclasses import dataclass
from collections import defaultdict
from typing import Any, Dict, Optional, List

import boto3
from botocove import cove, CoveSession
import logging

LOG_FILE = "aws_resource_count.log"

logging.basicConfig(level=logging.INFO,
                    filename=LOG_FILE,
                    filemode="w",
                    format='%(asctime)s %(levelname)-8s %(message)s',
                    datefmt='%Y-%m-%d %H:%M:%S')

stream_handler = logging.StreamHandler()
logger = logging.getLogger("orca")
logger.addHandler(stream_handler)
logger.setLevel(logging.INFO)

has_enumeration_errors: bool = False


@dataclass
class VmImage:
    id: str
    create_time: datetime.datetime


def get_aws_account_id(session: boto3.session) -> str:
    try:
        sts_client = session.client('sts')
        identity = sts_client.get_caller_identity()
        return identity['Account']
    except Exception:
        return "AccountIdNotFound"


def log_enumeration_failure(service: str, session: CoveSession, error) -> None:
    if hasattr(session, "session_information"):
        account_id = session.session_information['Id']
    else:
        account_id = get_aws_account_id(session)
    logger.error(f"Failed to count {service} for account: {account_id}, error: {error}")
    global has_enumeration_errors
    has_enumeration_errors = True


def retry(func):
    def wrapper(*args, **kwargs):
        session = args[0]
        service_name = args[1]
        display_name = SERVICES_CONF[service_name]["display_name"]
        error = ""
        retries = 3
        for retry in range(retries):
            try:
                return func(*args, **kwargs)
            except Exception as e:
                error = str(e)
                logger.warning(f"Failed to count {display_name} (attempt {retry + 1} of {retries})")
        log_enumeration_failure(display_name, session, error)
        return 0

    return wrapper


@retry
def get_region_serverless_containers(session: CoveSession, service_name: str, region_name: Optional[str] = None) -> int:
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    client = session.client("ecs", region_name=region_name)
    cluster_paginator = client.get_paginator('list_clusters')
    count = 0
    for cluster_page in cluster_paginator.paginate():
        for cluster in cluster_page['clusterArns']:
            task_paginator = client.get_paginator('list_tasks')
            for task_page in task_paginator.paginate(cluster=cluster, desiredStatus='RUNNING',
                                                     launchType='FARGATE'):
                task_count = len(task_page['taskArns'])
                count += task_count
    return count


@retry
def get_region_instances(session: CoveSession, service_name: str, region_name: Optional[str] = None) -> int:
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    client = session.client("ec2", region_name=region_name)
    paginator = client.get_paginator("describe_instances")
    count = 0
    for page in paginator.paginate():
        for sub_list in page["Reservations"]:
            count += len(sub_list.get("Instances", []))
    return count


@retry
def get_region_functions(session: CoveSession, service_name: str, region_name: Optional[str] = None) -> int:
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    client = session.client("lambda", region_name=region_name)
    paginator = client.get_paginator("list_functions")
    count = 0
    for page in paginator.paginate():
        count += len(page["Functions"])
    return count


@retry
def get_region_ecr_repos(session: CoveSession, service_name: str, region_name: Optional[str] = None) -> int:
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    client = session.client("ecr", region_name=region_name)
    paginator = client.get_paginator("describe_repositories")
    count = 0
    for page in paginator.paginate():
        count += len(page["repositories"])
    return count


def is_image_used(vm_image: VmImage, client: boto3.client) -> bool:
    def get_image_last_used_time(vm_image: VmImage) -> Optional[datetime.datetime]:
        params = {
            "ImageId": vm_image.id,
            "Attribute": "lastLaunchedTime",
        }
        response = client.describe_image_attribute(**params)

        if last_launched_time := response.get("LastLaunchedTime", {}).get("Value"):
            return dateutil.parser.parse(last_launched_time)
        return None

    last_valid_use_date = datetime.datetime.now(dateutil.tz.tzlocal()) - datetime.timedelta(days=30)
    if vm_image.create_time > last_valid_use_date:
        return True

    last_used = get_image_last_used_time(vm_image)
    if last_used and last_used > last_valid_use_date:
        return True
    else:
        return False


@retry
def get_region_vm_images(session: CoveSession, service_name: str, region_name: Optional[str] = None) -> int:
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    client = session.client("ec2", region_name=region_name)
    paginator = client.get_paginator("describe_images")
    vm_images: List[VmImage] = []
    for page in paginator.paginate(Owners=['self']):
        vm_images.extend([VmImage(id=image["ImageId"], create_time=datetime.datetime.fromisoformat(
            image["CreationDate"].replace("Z", "+00:00"))) for image in page["Images"]])
    used_vm_images_count = len([vm_image.id for vm_image in vm_images if is_image_used(vm_image, client)])
    return used_vm_images_count


@retry
def get_region_cluster_nodes(session: CoveSession, service_name: str, region_name: Optional[str] = None) -> int:
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    eks_client = session.client("eks", region_name=region_name)
    cluster_paginator = eks_client.get_paginator('list_clusters')
    ec2_client = session.client("ec2", region_name=region_name)
    instance_paginator = ec2_client.get_paginator('describe_instances')
    count = 0
    for clusters in cluster_paginator.paginate():
        for cluster in clusters['clusters']:
            _filter = [{
                'Name': 'tag:aws:eks:cluster-name',
                'Values': [cluster]
            }]
            for page in instance_paginator.paginate(Filters=_filter):
                for sub_list in page["Reservations"]:
                    count += len(sub_list.get("Instances", []))
    return count


SERVICES_CONF: Dict[str, Any] = {
    "ec2": {
        "function": get_region_instances,
        "display_name": "Virtual Machines",
        "workload_units": 1
    },
    "lambda": {
        "function": get_region_functions,
        "display_name": "Serverless Functions",
        "workload_units": 50
    },
    "ecr": {
        "function": get_region_ecr_repos,
        "display_name": "Container Images",
        "workload_units": 10
    },
    "ami": {
        "function": get_region_vm_images,
        "display_name": "VM Images",
        "workload_units": 1
    },
    "ecs": {
        "function": get_region_serverless_containers,
        "display_name": "Serverless Containers",
        "workload_units": 10
    },
    "eks": {
        "function": get_region_cluster_nodes,
        "display_name": "Container Hosts",
        "workload_units": 1
    }
}

ALL_REGIONS = [r["RegionName"] for r in boto3.client("ec2").describe_regions()["Regions"]]


def get_cove_region_resources(session: CoveSession) -> Dict[str, int]:
    results: Dict[str, int] = defaultdict(int)
    for service_name, conf in SERVICES_CONF.items():
        results[service_name] += conf["function"](session, service_name)
    return results


def current_account_resources_count(session: boto3.Session) -> Dict[str, int]:
    logger.info(f"Counting resources for the current account...")
    total_results: Dict[str, int] = defaultdict(int)
    for i, region in enumerate(ALL_REGIONS):
        logger.info(f"Region: {region} ({i + 1}/{len(ALL_REGIONS)})")
        for service_name, conf in SERVICES_CONF.items():
            total_results[service_name] += conf["function"](session, service_name, region)
    return total_results


def print_results(results: Dict[str, int], account_id: Optional[str]=None) -> None:
    log_total_results = account_id is None
    result_str = "\n==============\nTotal results:\n==============\n" if log_total_results else f"AWS Account number: [{account_id}]\n"
    total_workloads = 0
    for service, count in results.items():
        if service == "ecr":
            count = count * 1.1  # we scan 2 images per one repository and we decided to multiply the count by 1.1 based on production statistics
        workloads = round(count / SERVICES_CONF[service]['workload_units'])
        if workloads == 0 and count > 0:
            workloads = 1
        result_str += f"{SERVICES_CONF[service]['display_name']} Count: {round(count)}{f' (Workload Units: {workloads})' if log_total_results else ''}\n"
        total_workloads += workloads
    if log_total_results:
        result_str += f"-----------------------------------------\nTOTAL estimated workload units: {total_workloads}\n"
    logger.info(result_str)


def log_results_per_account(total_results: Dict[str, Any]) -> None:
    results_per_account: Dict[str, Dict[str, int]] = {result["Id"]: defaultdict(int) for result in total_results["Results"]}
    for result in total_results["Results"]:
        account_id = result["Id"]
        for service, count in result["Result"].items():
            results_per_account[account_id][service] += count
    for account_id, results in results_per_account.items():
        print_results(results, account_id)


def set_skip_resources(args: argparse.Namespace) -> None:
    skipped_resources: List[str] = []
    if args.skip_vms:
        skipped_resources.append(SERVICES_CONF["ec2"]['display_name'])
        SERVICES_CONF.pop("ec2")
    if args.skip_serverless_functions:
        skipped_resources.append(SERVICES_CONF["lambda"]['display_name'])
        SERVICES_CONF.pop("lambda")
    if args.skip_container_images:
        skipped_resources.append(SERVICES_CONF["ecr"]['display_name'])
        SERVICES_CONF.pop("ecr")
    if args.skip_vm_images:
        skipped_resources.append(SERVICES_CONF["ami"]['display_name'])
        SERVICES_CONF.pop("ami")
    if args.skip_serverless_containers:
        skipped_resources.append(SERVICES_CONF["ecs"]['display_name'])
        SERVICES_CONF.pop("ecs")
    if args.skip_container_hosts:
        skipped_resources.append(SERVICES_CONF["eks"]['display_name'])
        SERVICES_CONF.pop("eks")
    if skipped_resources:
        logger.info(f"Skip counting the following resources: {', '.join(skipped_resources)}.")


def main():
    _parser = argparse.ArgumentParser()
    _parser.add_argument("--only-current-account", action="store_true",
                         help="Count resources only for the current account")

    _parser.add_argument("--accounts-list", required=False,
                         help="List of accounts IDS to count resources for, if OU is provided it will count its children accounts. use comma (,) as seperator")

    _parser.add_argument("--skip-vms", action="store_true",
                         help=f"Skip counting {SERVICES_CONF['ec2']['display_name']}")

    _parser.add_argument("--skip-serverless-functions", action="store_true",
                         help=f"Skip counting {SERVICES_CONF['lambda']['display_name']}")

    _parser.add_argument("--skip-container-images", action="store_true",
                         help=f"Skip counting {SERVICES_CONF['ecr']['display_name']}")

    _parser.add_argument("--skip-vm-images", action="store_true",
                         help=f"Skip counting {SERVICES_CONF['ami']['display_name']}")

    _parser.add_argument("--skip-serverless-containers", action="store_true",
                         help=f"Skip counting {SERVICES_CONF['ecs']['display_name']}")

    _parser.add_argument("--skip-container-hosts", action="store_true",
                         help=f"Skip counting {SERVICES_CONF['eks']['display_name']}")

    _parser.add_argument("--show-logs-per-account", action="store_true",
                         help=f"Log resource count per AWS account")

    _parser.add_argument("--role-name", help="the role name to be assumed for organization member accounts. If not provided, it defaults to 'OrganizationAccountAccessRole'.")

    args = _parser.parse_args()
    set_skip_resources(args)
    if not SERVICES_CONF:
        logger.info("All AWS services requested to be skipped, please choose at least one service to count.")
        return
    show_logs_per_account: bool = args.show_logs_per_account
    role_name: bool = args.role_name
    session = boto3.Session()
    total_results: Dict[str, int] = current_account_resources_count(session)
    accounts_list: List[str] = args.accounts_list.strip().split(",") if args.accounts_list else []
    if args.only_current_account:
        if show_logs_per_account:
            print_results(total_results, account_id=get_aws_account_id(session=session))
        print_results(total_results)
    else:
        try:
            if not accounts_list:
                logger.info("Start Counting resources for all the Organization's accounts...")
                results_of_all_regions = cove(regions=ALL_REGIONS, rolename=role_name)(get_cove_region_resources)()
            else:
                logger.info(f"Start Counting resources for the following accounts: {accounts_list}...")
                results_of_all_regions = cove(regions=ALL_REGIONS, target_ids=accounts_list, rolename=role_name)(get_cove_region_resources)()
            if show_logs_per_account:  # log current account results
                print_results(total_results, account_id=get_aws_account_id(session=session))
            for result in results_of_all_regions["Results"]:
                for service, count in result["Result"].items():
                    total_results[service] += count
            if show_logs_per_account:
                log_results_per_account(results_of_all_regions)
            print_results(total_results)

            errors = len(results_of_all_regions["Exceptions"] + results_of_all_regions["FailedAssumeRole"])
            if errors:
                logger.warning(f"Encountered {errors} errors")
                logger.warning(f"Exceptions: {results_of_all_regions['Exceptions']}")
                logger.warning(f"FailedAssumeRole: {results_of_all_regions['FailedAssumeRole']}")
        except AttributeError as e:
            if "'CoveHostAccount' object has no attribute 'organization_account_ids'" in str(e):
                logger.warning(
                    "-------------------------------------------------------------------------------------------\n"
                    "Couldn't count resources for the nested accounts, this account is not an Organization account.\n"
                    "-------------------------------------------------------------------------------------------")

    if has_enumeration_errors:
        logger.warning(f"Errors encounters during resource enumeration, please look for errors in log file: {LOG_FILE}")


if __name__ == "__main__":
    main()
