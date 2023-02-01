import argparse
from collections import defaultdict
from typing import Any, Dict, Optional

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


def log_enumeration_failure(service: str, session: CoveSession, error) -> None:
    def _get_aws_account_id(session: boto3.session) -> str:
        try:
            sts_client = session.client('sts')
            identity = sts_client.get_caller_identity()
            return identity['Account']
        except Exception:
            return "AccountIdNotFound"

    if hasattr(session, "session_information"):
        account_id = session.session_information['Id']
    else:
        account_id = _get_aws_account_id(session)
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


@retry
def get_region_vm_images(session: CoveSession, service_name: str, region_name: Optional[str] = None) -> int:
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    client = session.client("ec2", region_name=region_name)
    paginator = client.get_paginator("describe_images")
    count = 0
    for page in paginator.paginate(Owners=['self']):
        count += len(page["Images"])
    return count


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


@cove(regions=ALL_REGIONS)
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


def print_results(results: Dict[str, int]) -> None:
    logger.info("==============\nTotal results:\n==============")
    total_workloads = 0
    for service, count in results.items():
        if service == "ecr":
            count = count * 2  # we scan 2 images per one repository
        workloads = round(count / SERVICES_CONF[service]['workload_units'])
        if workloads == 0 and count > 0:
            workloads = 1
        logger.info(f"{SERVICES_CONF[service]['display_name']} Count: {count} (Workload Units: {workloads})")
        total_workloads += workloads
    logger.info("-----------------------------------------\n"
                ""f"TOTAL Estimated Workload Units: {total_workloads}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only-current-account", action="store_true",
                        help="Count resources only for the current account")
    args = parser.parse_args()
    total_results: Dict[str, int] = current_account_resources_count(boto3.Session())
    if args.only_current_account:
        print_results(total_results)
    else:
        try:
            logger.info("Start Counting resources for all the Organization's accounts...")
            account_region_resources = get_cove_region_resources()
            for result in account_region_resources["Results"]:
                for service, count in result["Result"].items():
                    total_results[service] += count
            print_results(total_results)

            errors = len(account_region_resources["Exceptions"] + account_region_resources["FailedAssumeRole"])
            if errors:
                logger.warning(f"Encountered {errors} errors")
                logger.warning(f"Exceptions: {account_region_resources['Exceptions']}")
                logger.warning(f"FailedAssumeRole: {account_region_resources['FailedAssumeRole']}")
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
