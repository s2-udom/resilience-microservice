"""
resilience-healer: AWS Lambda function implementing the MAPE-K Execute phase.

This function is triggered by CloudWatch Alarms when the ECS service enters
a degraded state. It implements a tiered remediation strategy:
  - Level 1: Force a new ECS service deployment (container restart)
  - Level 2: Scale desired count to 0 then back to 1 (hard reset)
  - Level 3: SNS notification to operator (escalation - human-in-the-loop fallback)

Environment Variables (set via Terraform):
  CLUSTER_NAME    - ECS cluster name
  SERVICE_NAME    - ECS service name
  SNS_TOPIC_ARN   - ARN of SNS topic for escalation alerts
  HEALER_TABLE    - DynamoDB table name for remediation history (MAPE-K Knowledge base)
"""

import boto3
import json
import logging
import os
import time
from datetime import datetime, timezone

# Structured logging setup (emits JSON to CloudWatch Logs) 
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def log(level: int, event: str, **kwargs):
    """Emit a structured JSON log entry — feeds the MAPE-K Monitor/Knowledge phases."""
    entry = {
        "event":     event,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "service":   os.environ.get("SERVICE_NAME", "unknown"),
        **kwargs
    }
    logger.log(level, json.dumps(entry))


# AWS clients 
ecs    = boto3.client("ecs",      region_name="eu-west-2")
sns    = boto3.client("sns",      region_name="eu-west-2")
dynamo = boto3.resource("dynamodb", region_name="eu-west-2")


# MAPE-K: ANALYSE phase 
def analyse_failure(cluster: str, service: str) -> dict:
    """
    Query ECS service state to classify the failure type and severity.
    Returns a structured analysis dict consumed by the Plan phase.
    """
    response = ecs.describe_services(cluster=cluster, services=[service])
    svc      = response["services"][0]

    running  = svc["runningCount"]
    desired  = svc["desiredCount"]
    pending  = svc["pendingCount"]
    events   = svc.get("events", [])[:3]  # most recent 3 events

    # Derive failure classification
    if running == 0 and pending == 0:
        severity     = "CRITICAL"
        failure_type = "COMPLETE_OUTAGE"
    elif running < desired:
        severity     = "DEGRADED"
        failure_type = "PARTIAL_OUTAGE"
    else:
        severity     = "HEALTHY"
        failure_type = "FALSE_ALARM"

    analysis = {
        "severity":     severity,
        "failure_type": failure_type,
        "running":      running,
        "desired":      desired,
        "pending":      pending,
        "recent_events": [e.get("message", "") for e in events],
    }

    log(logging.INFO, "ANALYSE_COMPLETE", **analysis)
    return analysis


# MAPE-K: PLAN phase 
def plan_remediation(analysis: dict, remediation_count: int) -> str:
    """
    Select remediation strategy based on failure severity and prior
    remediation attempts retrieved from the Knowledge base (DynamoDB).

    Strategy ladder:
      Attempt 1 → FORCE_DEPLOY   (soft restart via ECS deployment)
      Attempt 2 → HARD_RESET     (scale to 0, then back to desired)
      Attempt 3+ → ESCALATE      (human-in-the-loop fallback via SNS)
    """
    if analysis["failure_type"] == "FALSE_ALARM":
        return "NO_ACTION"

    if remediation_count == 0:
        action = "FORCE_DEPLOY"
    elif remediation_count == 1:
        action = "HARD_RESET"
    else:
        action = "ESCALATE"

    log(logging.INFO, "PLAN_SELECTED",
        action=action,
        prior_attempts=remediation_count,
        severity=analysis["severity"])
    return action


# MAPE-K: EXECUTE phase 
def execute_force_deploy(cluster: str, service: str) -> dict:
    """
    Level 1 remediation: force a new ECS deployment.
    ECS will pull the latest task definition and replace unhealthy tasks.
    Analogous to a rolling restart — minimal blast radius.
    """
    log(logging.INFO, "EXECUTE_START", action="FORCE_DEPLOY")
    start = time.time()

    ecs.update_service(
        cluster              = cluster,
        service              = service,
        forceNewDeployment   = True
    )

    elapsed = round(time.time() - start, 3)
    log(logging.INFO, "EXECUTE_COMPLETE",
        action="FORCE_DEPLOY", elapsed_seconds=elapsed)
    return {"action": "FORCE_DEPLOY", "elapsed_seconds": elapsed, "success": True}


def execute_hard_reset(cluster: str, service: str, desired: int) -> dict:
    """
    Level 2 remediation: scale to 0 tasks, wait, scale back to desired.
    Used when a force deploy has previously failed — clears any stuck
    task state that a rolling deployment cannot resolve.
    """
    log(logging.INFO, "EXECUTE_START", action="HARD_RESET")
    start = time.time()

    # Scale down
    ecs.update_service(cluster=cluster, service=service, desiredCount=0)
    log(logging.INFO, "HARD_RESET_SCALED_DOWN", cluster=cluster, service=service)
    time.sleep(15)

    # Scale back up
    ecs.update_service(cluster=cluster, service=service, desiredCount=desired)
    log(logging.INFO, "HARD_RESET_SCALED_UP",
        cluster=cluster, service=service, desired_count=desired)

    elapsed = round(time.time() - start, 3)
    log(logging.INFO, "EXECUTE_COMPLETE",
        action="HARD_RESET", elapsed_seconds=elapsed)
    return {"action": "HARD_RESET", "elapsed_seconds": elapsed, "success": True}


def execute_escalate(cluster: str, service: str, analysis: dict) -> dict:
    """
    Level 3: automated remediation exhausted — notify human operator via SNS.
    This preserves the human-in-the-loop as a safety net while demonstrating
    that autonomous remediation attempted all viable options first.
    """
    topic_arn = os.environ.get("SNS_TOPIC_ARN", "")
    if not topic_arn:
        log(logging.WARNING, "ESCALATE_NO_TOPIC")
        return {"action": "ESCALATE", "success": False, "reason": "No SNS topic configured"}

    message = (
        f"RESILIENCE ENGINE ESCALATION\n\n"
        f"Cluster:      {cluster}\n"
        f"Service:      {service}\n"
        f"Severity:     {analysis['severity']}\n"
        f"Failure type: {analysis['failure_type']}\n"
        f"Running/Desired: {analysis['running']}/{analysis['desired']}\n\n"
        f"Automated remediation (FORCE_DEPLOY + HARD_RESET) has been exhausted.\n"
        f"Manual intervention required.\n\n"
        f"Recent ECS events:\n" +
        "\n".join(f"  - {e}" for e in analysis.get("recent_events", []))
    )

    sns.publish(
        TopicArn = topic_arn,
        Subject  = f"[CRITICAL] Resilience Engine Escalation: {service}",
        Message  = message
    )

    log(logging.INFO, "ESCALATE_SENT", topic_arn=topic_arn)
    return {"action": "ESCALATE", "success": True}


# MAPE-K: KNOWLEDGE base helpers (DynamoDB)
def get_remediation_count(service: str) -> int:
    """Retrieve the number of recent remediation attempts from the Knowledge base."""
    table_name = os.environ.get("HEALER_TABLE", "")
    if not table_name:
        return 0
    try:
        table    = dynamo.Table(table_name)
        response = table.get_item(Key={"service_name": service})
        item     = response.get("Item", {})
        return int(item.get("remediation_count", 0))
    except Exception as e:
        log(logging.WARNING, "KNOWLEDGE_READ_ERROR", error=str(e))
        return 0


def record_remediation(service: str, action: str, result: dict):
    """Persist remediation attempt to the Knowledge base for future Plan decisions."""
    table_name = os.environ.get("HEALER_TABLE", "")
    if not table_name:
        return
    try:
        table = dynamo.Table(table_name)
        table.update_item(
            Key={"service_name": service},
            UpdateExpression=(
                "SET remediation_count = if_not_exists(remediation_count, :zero) + :one, "
                "last_action = :action, last_remediation_ts = :ts"
            ),
            ExpressionAttributeValues={
                ":zero":   0,
                ":one":    1,
                ":action": action,
                ":ts":     datetime.now(timezone.utc).isoformat(),
            }
        )
    except Exception as e:
        log(logging.WARNING, "KNOWLEDGE_WRITE_ERROR", error=str(e))


def reset_remediation_count(service: str):
    """Reset the counter when the service returns healthy — prevents runaway escalation."""
    table_name = os.environ.get("HEALER_TABLE", "")
    if not table_name:
        return
    try:
        table = dynamo.Table(table_name)
        table.update_item(
            Key={"service_name": service},
            UpdateExpression="SET remediation_count = :zero",
            ExpressionAttributeValues={":zero": 0}
        )
        log(logging.INFO, "KNOWLEDGE_RESET", service=service)
    except Exception as e:
        log(logging.WARNING, "KNOWLEDGE_RESET_ERROR", error=str(e))


# Lambda entry point 
def lambda_handler(event, context):
    """
    Entry point — orchestrates the full MAPE-K loop:
      Monitor  → CloudWatch alarm (external, triggers this Lambda)
      Analyse  → analyse_failure()
      Plan     → plan_remediation()
      Execute  → execute_*()
      Knowledge→ DynamoDB read/write
    """
    cluster = os.environ.get("CLUSTER_NAME", "resilience-cluster")
    service = os.environ.get("SERVICE_NAME", "resilience-service")

    # Record invocation timestamp for MTTR measurement
    invocation_ts = datetime.now(timezone.utc).isoformat()
    log(logging.INFO, "HEALER_INVOKED",
        cluster=cluster, service=service, trigger_event=str(event)[:200])

    # ANALYSE 
    try:
        analysis = analyse_failure(cluster, service)
    except Exception as e:
        log(logging.ERROR, "ANALYSE_ERROR", error=str(e))
        return {"statusCode": 500, "body": f"Analyse phase failed: {e}"}

    if analysis["failure_type"] == "FALSE_ALARM":
        log(logging.INFO, "FALSE_ALARM_NO_ACTION", **analysis)
        reset_remediation_count(service)
        return {"statusCode": 200, "body": "Service healthy — no action taken"}

    # PLAN 
    remediation_count = get_remediation_count(service)
    action            = plan_remediation(analysis, remediation_count)

    # EXECUTE 
    try:
        if action == "FORCE_DEPLOY":
            result = execute_force_deploy(cluster, service)
        elif action == "HARD_RESET":
            result = execute_hard_reset(cluster, service, analysis["desired"])
        elif action == "ESCALATE":
            result = execute_escalate(cluster, service, analysis)
        else:
            result = {"action": "NO_ACTION", "success": True}
    except Exception as e:
        log(logging.ERROR, "EXECUTE_ERROR", action=action, error=str(e))
        return {"statusCode": 500, "body": f"Execute phase failed: {e}"}

    # KNOWLEDGE: persist 
    record_remediation(service, action, result)

    # Emit final structured summary (key metric for MTTR calculation)
    log(logging.INFO, "HEALER_COMPLETE",
        invocation_ts  = invocation_ts,
        action         = action,
        result         = result,
        prior_attempts = remediation_count)

    return {
        "statusCode": 200,
        "body": json.dumps({
            "action":   action,
            "result":   result,
            "analysis": analysis,
        })
    }
