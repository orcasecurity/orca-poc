import argparse
from typing import Any, Dict, Optional

import boto3
from botocove import cove, CoveSession


def get_region_serverless_containers(session: CoveSession, region_name: Optional[str] = None) -> Dict[str, int]:
    results: Dict[str, int] = {}
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    client = session.client("ecs", region_name=region_name)
    cluster_paginator = client.get_paginator('list_clusters')
    retries = 3
    for retry in range(retries):
        count = 0
        try:
            for cluster_page in cluster_paginator.paginate():
                for cluster in cluster_page['clusterArns']:
                    task_paginator = client.get_paginator('list_tasks')
                    for task_page in task_paginator.paginate(cluster=cluster, desiredStatus='RUNNING',
                                                             launchType='FARGATE'):
                        task_count = len(task_page['taskArns'])
                        count += task_count
            results.update({"ecs": count})
            return results
        except Exception as e:
            print(f"Failed to count Serverless Containers, retrying (attempt {retry + 1} of {retries}")
        results.update({"ecs": count})
    return results


def get_region_instances(session: CoveSession, region_name: Optional[str] = None) -> Dict[str, int]:
    results: Dict[str, int] = {}
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    client = session.client("ec2", region_name=region_name)
    paginator = client.get_paginator("describe_instances")
    retries = 3
    for retry in range(retries):
        count = 0
        try:
            for page in paginator.paginate():
                for sub_list in page["Reservations"]:
                    count += len(sub_list.get("Instances", []))
            results.update({"ec2": count})
            return results
        except Exception as e:
            print(f"Failed to count Virtual Machines, retrying (attempt {retry + 1} of {retries}")
        results.update({"ec2": count})
    return results


def get_region_functions(session: CoveSession, region_name: Optional[str] = None) -> Dict[str, int]:
    results: Dict[str, int] = {}
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    client = session.client("lambda", region_name=region_name)
    paginator = client.get_paginator("list_functions")
    retries = 3
    for retry in range(retries):
        count = 0
        try:
            for page in paginator.paginate():
                count += len(page["Functions"])
            results.update({"lambda": count})
            return results
        except Exception as e:
            print(f"Failed to count Lambda Functions, retrying (attempt {retry + 1} of {retries}")
        results.update({"lambda": count})
    return results


def get_region_ecr_repos(session: CoveSession, region_name: Optional[str] = None) -> Dict[str, int]:
    results: Dict[str, int] = {}
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    client = session.client("ecr", region_name=region_name)
    paginator = client.get_paginator("describe_repositories")
    retries = 3
    for retry in range(retries):
        count = 0
        try:
            for page in paginator.paginate():
                count += len(page["repositories"])
            results.update({"ecr": count})
            return results
        except Exception as e:
            print(f"Failed to count Container Images, retrying (attempt {retry + 1} of {retries}")
        results.update({"ecr": count})
    return results


def get_region_vm_images(session: CoveSession, region_name: Optional[str] = None) -> Dict[str, int]:
    results: Dict[str, int] = {}
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    client = session.client("ec2", region_name=region_name)
    paginator = client.get_paginator("describe_images")
    retries = 3
    for retry in range(retries):
        count = 0
        try:
            for page in paginator.paginate(Owners=['self']):
                count += len(page["Images"])
            results.update({"ami": count})
            return results
        except Exception as e:
            print(f"Failed to count VM images, retrying (attempt {retry + 1} of {retries}")
        results.update({"ami": count})
    return results


def get_region_cluster_nodes(session: CoveSession, region_name: Optional[str] = None) -> Dict[str, int]:
    results: Dict[str, int] = {}
    if hasattr(session, "session_information"):
        region_name = session.session_information['Region']
    eks_client = session.client("eks", region_name=region_name)
    cluster_paginator = eks_client.get_paginator('list_clusters')
    ec2_client = session.client("ec2", region_name=region_name)
    instance_paginator = ec2_client.get_paginator('describe_instances')
    retries = 3
    for retry in range(retries):
        count = 0
        try:
            for clusters in cluster_paginator.paginate():
                for cluster in clusters['clusters']:
                    filter = [{
                        'Name': 'tag:aws:eks:cluster-name',
                        'Values': [cluster]
                    }]
                    for page in instance_paginator.paginate(Filters=filter):
                        for sub_list in page["Reservations"]:
                            count += len(sub_list.get("Instances", []))
            results.update({"eks": count})
            return results
        except Exception as e:
            print(f"Failed to count Container Hosts, retrying (attempt {retry + 1} of {retries}")
        results.update({"eks": count})
    return results


SERVICES_CONF: Dict[str, Any] = {
    "ec2": {
        "function": get_region_instances,
        "display_name": "Virtual Machines"
    },
    "lambda": {
        "function": get_region_functions,
        "display_name": "Serverless Functions"
    },
    "ecr": {
        "function": get_region_ecr_repos,
        "display_name": "Container Images"
    },
    "ami": {
        "function": get_region_vm_images,
        "display_name": "VM Images"
    },
    "ecs": {
        "function": get_region_serverless_containers,
        "display_name": "Serverless Containers"
    },
    "eks": {
        "function": get_region_cluster_nodes,
        "display_name": "Container Hosts"
    }
}

ALL_REGIONS = [r["RegionName"] for r in boto3.client("ec2").describe_regions()["Regions"]]


@cove(regions=ALL_REGIONS)
def get_cove_region_resources(session: CoveSession) -> Dict[str, int]:
    results: Dict[str, int] = {}
    for service_name, conf in SERVICES_CONF.items():
        results.update(conf["function"](session))
    return results


def current_account_resources_count(session: boto3.Session) -> Dict[str, int]:
    print(f"Counting resources for the current account...")
    total_results: Dict[str, int] = {}
    for i, region in enumerate(ALL_REGIONS):
        print(f"Region: {region} ({i + 1}/{len(ALL_REGIONS)})")
        region_results: Dict[str, int] = {}
        for service_name, conf in SERVICES_CONF.items():
            region_results.update(conf["function"](session, region))
        for service, count in region_results.items():
            total_results.update({service: total_results.get(service, 0) + count})
    return total_results


def print_results(results: Dict[str, int]) -> None:
    print("=========================================")
    for service, count in results.items():
        if service == "ecr":
            count = count * 2  # we scan 2 images per one repository
        print(f"Total {SERVICES_CONF[service]['display_name']} found: {count}")
    print("=========================================")
    print(f"Done counting resources.")


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
            print("Start Counting resources for all the Organization's accounts...")
            account_region_resources = get_cove_region_resources()
            for i, result in enumerate(account_region_resources["Results"]):
                for service, count in result["Result"].items():
                    total_results.update({service: total_results.get(service, 0) + count})
            print_results(total_results)

            errors = len(account_region_resources["Exceptions"] + account_region_resources["FailedAssumeRole"])
            if errors:
                print(f"encountered {errors} errors")
                print(f"Exceptions: {account_region_resources['Exceptions']}")
                print(f"FailedAssumeRole: {account_region_resources['FailedAssumeRole']}")
        except AttributeError as e:
            if "'CoveHostAccount' object has no attribute 'organization_account_ids'" in str(e):
                print("-------------------------------------------------------------------------------------------")
                print("Couldn't count resources for the nested accounts, this account is not Organization account.")
                print("-------------------------------------------------------------------------------------------")


if __name__ == "__main__":
    main()
