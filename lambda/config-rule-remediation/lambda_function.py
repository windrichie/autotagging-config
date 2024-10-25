import json
import boto3
import os
from datetime import datetime, timezone

ssm = boto3.client('ssm')
config = boto3.client('config')
tagging = boto3.client('resourcegroupstaggingapi')

# Load the unsupported services JSON file
with open("tagging_api_unsupported_services.json", 'r') as f:
    unsupported_services = json.load(f)


def lambda_handler(event, context):
    print("Received event:", json.dumps(event))

    for record in event['Records']:
        # Parse the SQS message body, which contains the original EventBridge event
        message_body = json.loads(record['body'])
        
        # Extract details from EventBridge event
        detail = message_body['detail']
        
        # Extract resource details
        resource_id = detail['resourceId']
        resource_type = detail['resourceType']

        print(f"Processing resource: '{resource_id}' of type '{resource_type}'")
        
        # Get Config item
        config_item = get_config_item(resource_id, resource_type)
        
        # Get required tags
        required_tags = get_required_tags()
        
        # Check if the resource type is supported by Resource Groups Tagging API
        if resource_type not in unsupported_services:
            validate_and_apply_tags_with_tagging_api(resource_id, config_item, required_tags)
        else:
            # Call the appropriate function for unsupported services
            globals()[unsupported_services[resource_type]](resource_id, config_item, required_tags)


def get_config_item(resource_id, resource_type):
    response = config.get_resource_config_history(
        resourceType=resource_type,
        resourceId=resource_id,
        limit=1
    )
    return response['configurationItems'][0]


def get_required_tags():
    required_tags = {}
    paginator = ssm.get_paginator('get_parameters_by_path')
    for page in paginator.paginate(Path='/auto-tagging/mandatory/', Recursive=True):
        for param in page['Parameters']:
            key = param['Name'].split('/')[-1]
            required_tags[key] = param['Value']
    return required_tags


def validate_and_apply_tags_with_tagging_api(resource_id, config_item, required_tags):
    # Get current tags
    current_tags = config_item.get('tags', {})
    print("current_tags:")
    print(current_tags)
    
    # Check if all required tags are already present
    missing_tags = {k: v for k, v in required_tags.items() if k not in current_tags or current_tags[k] != v}
    
    if not missing_tags:
        print("All required tags are already present. Skipping tag application.")
        return
    
    # Merge current tags with required tags
    updated_tags = {**current_tags, **required_tags}
    # Get current timestamp and add to a new tag
    current_time = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')
    updated_tags['autotagging-timestamp'] = current_time

    print("updated_tags:")
    print(updated_tags)
    
    # Apply tags
    tagging.tag_resources(
        ResourceARNList=[config_item['arn']],
        Tags=updated_tags
    )
    print(f"Applied missing tags: {missing_tags}")


def validate_and_apply_tags_eventbridge(resource_id, config_item, required_tags):
    eventbridge = boto3.client('events')
    # Get current tags
    response = eventbridge.list_tags_for_resource(ResourceARN=config_item['arn'])
    current_tags = {tag['Key']: tag['Value'] for tag in response['Tags']}
    
    # Check if all required tags are already present
    missing_tags = {k: v for k, v in required_tags.items() if k not in current_tags or current_tags[k] != v}
    
    if not missing_tags:
        print("All required tags are already present. Skipping tag application.")
        return
    
    # Merge current tags with required tags
    updated_tags = {**current_tags, **required_tags}
    
    # Apply tags
    eventbridge.tag_resource(
        ResourceARN=config_item['arn'],
        Tags=[{'Key': k, 'Value': v} for k, v in updated_tags.items()]
    )
    print(f"Applied missing tags: {missing_tags}")