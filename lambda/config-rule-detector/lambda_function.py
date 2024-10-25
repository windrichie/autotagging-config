import boto3
import json

ssm = boto3.client('ssm')
config = boto3.client('config')

def lambda_handler(event, context):
    # Extract the invoked resource from the AWS Config event
    invoking_event = json.loads(event['invokingEvent'])
    configuration_item = invoking_event['configurationItem']
    print(configuration_item)
    
    # Get the current tags of the resource
    current_tags = configuration_item.get('tags', {})
    
    # Retrieve required tags from SSM Parameter Store
    required_tags = get_required_tags()
    
    # Validate tags
    compliance_type, annotation = validate_tags(current_tags, required_tags)
    
    # Put evaluation results
    config.put_evaluations(
        Evaluations=[
            {
                'ComplianceResourceType': configuration_item['resourceType'],
                'ComplianceResourceId': configuration_item['resourceId'],
                'ComplianceType': compliance_type,
                'Annotation': annotation,
                'OrderingTimestamp': configuration_item['configurationItemCaptureTime']
            },
        ],
        ResultToken=event['resultToken']
    )

def get_required_tags():
    required_tags = {}
    paginator = ssm.get_paginator('get_parameters_by_path')
    for page in paginator.paginate(Path='/auto-tagging/mandatory/', Recursive=True):
        for param in page['Parameters']:
            key = param['Name'].split('/')[-1]
            required_tags[key] = param['Value']
    return required_tags

def validate_tags(current_tags, required_tags):
    missing_tags = []
    incorrect_tags = []
    
    for key, value in required_tags.items():
        if key not in current_tags:
            missing_tags.append(key)
        elif current_tags[key] != value:
            incorrect_tags.append(f"{key} (expected: {value}, got: {current_tags[key]})")
    
    if missing_tags or incorrect_tags:
        compliance_type = 'NON_COMPLIANT'
        annotation = "Missing tags: " + ", ".join(missing_tags) + "." if missing_tags else ""
        annotation += " Incorrect tags: " + ", ".join(incorrect_tags) + "." if incorrect_tags else ""
        annotation = annotation.strip()
    else:
        compliance_type = 'COMPLIANT'
        annotation = "All required tags are present and correct."
        
    print(compliance_type)
    print(annotation)
    
    return compliance_type, annotation