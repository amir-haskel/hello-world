#!/usr/bin/env bash
# One-time AWS setup for hello-world. Idempotent: safe to re-run.
# Creates: ECR repo, GitHub OIDC provider, 2 IAM roles (exam-*, with the
# candidate-exam-boundary), log group, security groups, ALB + target group,
# ECS cluster + Fargate service (desired 0 until the pipeline's first deploy).
#
# Usage (from repo root, with AWS credentials for the exam account, e.g. AWS CloudShell):
#   bash infra/bootstrap.sh
set -euo pipefail

REGION="${AWS_REGION:-eu-west-2}"
GITHUB_REPO="${GITHUB_REPO:-amir-haskel/hello-world}"
PREFIX="${PREFIX:-amir}"          # shared account: every resource name is prefixed
APP=hello-world                   # ECS service + container name
REPO="${PREFIX}-hello-world"      # ECR repo, task family, log group
CLUSTER="${PREFIX}-hello"
GH_ROLE="exam-${PREFIX}-hello-gha"
EXEC_ROLE="exam-${PREFIX}-hello-exec"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: don't rewrite "/ecs/..." into C:/...

cd "$(dirname "$0")/.."
log() { printf '\n==> %s\n' "$*"; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [[ "$ACCOUNT_ID" != "030454160336" && -z "${ALLOW_ANY_ACCOUNT:-}" ]]; then
  echo "Refusing to run: credentials are for account $ACCOUNT_ID, expected the exam account 030454160336" >&2
  exit 1
fi
BOUNDARY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/candidate-exam-boundary"
log "Account $ACCOUNT_ID, region $REGION, repo $GITHUB_REPO"

# ---------------------------------------------------------------- ECR
log "ECR repository (immutable tags, scan on push)"
if ! aws ecr describe-repositories --repository-names "$REPO" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "$REPO" \
    --image-tag-mutability IMMUTABLE \
    --image-scanning-configuration scanOnPush=true >/dev/null
fi
aws ecr put-lifecycle-policy --repository-name "$REPO" --lifecycle-policy-text \
  '{"rules":[{"rulePriority":1,"description":"keep last 30 images","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":30},"action":{"type":"expire"}}]}' >/dev/null
ECR_URI=$(aws ecr describe-repositories --repository-names "$REPO" --query 'repositories[0].repositoryUri' --output text)

# ---------------------------------------------------------------- IAM
log "GitHub OIDC identity provider"
OIDC_HOST=token.actions.githubusercontent.com
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  aws iam create-open-id-connect-provider --url "https://${OIDC_HOST}" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
fi

ensure_role() { # name trust-policy-json
  if aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$1" --policy-document "$2"
  else
    aws iam create-role --role-name "$1" --assume-role-policy-document "$2" \
      --permissions-boundary "$BOUNDARY_ARN" >/dev/null
  fi
}

log "IAM role $EXEC_ROLE (ECS pulls image + writes logs)"
ensure_role "$EXEC_ROLE" '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name "$EXEC_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

log "IAM role $GH_ROLE (only main branch / production env of $GITHUB_REPO can assume it)"
ensure_role "$GH_ROLE" "$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Federated":"$OIDC_ARN"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{
   "StringEquals":{"${OIDC_HOST}:aud":"sts.amazonaws.com"},
   "StringLike":{"${OIDC_HOST}:sub":["repo:${GITHUB_REPO}:ref:refs/heads/main","repo:${GITHUB_REPO}:environment:production"]}}}]}
EOF
)"
aws iam put-role-policy --role-name "$GH_ROLE" --policy-name deploy --policy-document "$(cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"EcrLogin","Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Sid":"EcrPushPull","Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:DescribeImages","ecr:DescribeRepositories"],
  "Resource":"arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${REPO}"},
 {"Sid":"TaskDefs","Effect":"Allow","Action":["ecs:RegisterTaskDefinition","ecs:DescribeTaskDefinition"],"Resource":"*"},
 {"Sid":"Service","Effect":"Allow","Action":["ecs:UpdateService","ecs:DescribeServices"],
  "Resource":"arn:aws:ecs:${REGION}:${ACCOUNT_ID}:service/${CLUSTER}/${APP}"},
 {"Sid":"PassExecRole","Effect":"Allow","Action":"iam:PassRole","Resource":"arn:aws:iam::${ACCOUNT_ID}:role/${EXEC_ROLE}",
  "Condition":{"StringEquals":{"iam:PassedToService":"ecs-tasks.amazonaws.com"}}}]}
EOF
)"
GH_ROLE_ARN=$(aws iam get-role --role-name "$GH_ROLE" --query Role.Arn --output text)

# ---------------------------------------------------------------- Logs
log "CloudWatch log group"
aws logs create-log-group --log-group-name "/ecs/$REPO" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "/ecs/$REPO" --retention-in-days 14

# ---------------------------------------------------------------- Network
log "Default VPC, subnets, security groups"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
[[ "$VPC_ID" != "None" ]] || { echo "No default VPC in $REGION" >&2; exit 1; }
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" Name=default-for-az,Values=true \
  --query 'Subnets[].SubnetId' --output text)
SUBNETS_CSV=$(tr -s '[:space:]' ',' <<<"$SUBNETS" | sed 's/,$//')

ensure_sg() { # name description
  local id
  id=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$1" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [[ "$id" == "None" ]]; then
    id=$(aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC_ID" --query GroupId --output text)
  fi
  echo "$id"
}
ALB_SG=$(ensure_sg "${PREFIX}-hello-alb-sg" "HTTP from the internet to the hello-world ALB")
TASK_SG=$(ensure_sg "${PREFIX}-hello-task-sg" "Only the ALB may reach hello-world tasks")
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$TASK_SG" --protocol tcp --port 8080 --source-group "$ALB_SG" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- ALB
log "Application Load Balancer"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "${PREFIX}-hello-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
  # shellcheck disable=SC2086
  ALB_ARN=$(aws elbv2 create-load-balancer --name "${PREFIX}-hello-alb" --type application --scheme internet-facing \
    --subnets $SUBNETS --security-groups "$ALB_SG" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
fi
TG_ARN=$(aws elbv2 describe-target-groups --names "${PREFIX}-hello-tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
  TG_ARN=$(aws elbv2 create-target-group --name "${PREFIX}-hello-tg" --protocol HTTP --port 8080 --vpc-id "$VPC_ID" \
    --target-type ip --health-check-path /health --health-check-interval-seconds 10 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 3 --matcher HttpCode=200 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
fi
# Default 300s draining makes every deploy take 5+ minutes; 30s is plenty for this service.
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null
LISTENER=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`80`].ListenerArn' --output text)
if [[ -z "$LISTENER" ]]; then
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" >/dev/null
fi
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)

# ---------------------------------------------------------------- ECS
log "ECS cluster + service"
if [[ -z "$(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[?status==`ACTIVE`].clusterName' --output text)" ]]; then
  aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
fi
SVC_STATUS=$(aws ecs describe-services --cluster "$CLUSTER" --services "$APP" --query 'services[0].status' --output text 2>/dev/null || true)
if [[ "$SVC_STATUS" != "ACTIVE" ]]; then
  # Placeholder revision; desired count 0 so nothing runs until the pipeline deploys a real version.
  sed "s#IMAGE_PLACEHOLDER#${ECR_URI}:bootstrap#" ecs/task-definition.json > td-bootstrap.json
  TD_ARN=$(aws ecs register-task-definition --cli-input-json file://td-bootstrap.json \
    --query 'taskDefinition.taskDefinitionArn' --output text)
  aws ecs create-service --cluster "$CLUSTER" --service-name "$APP" --task-definition "$TD_ARN" \
    --desired-count 0 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS_CSV],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$TG_ARN,containerName=$APP,containerPort=8080" \
    --health-check-grace-period-seconds 30 \
    --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true},maximumPercent=200,minimumHealthyPercent=100" \
    >/dev/null
fi

# ---------------------------------------------------------------- GitHub
SERVICE_URL="http://$ALB_DNS"
log "GitHub repo variables"
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh variable set AWS_ROLE_ARN --repo "$GITHUB_REPO" --body "$GH_ROLE_ARN"
  gh variable set SERVICE_URL  --repo "$GITHUB_REPO" --body "$SERVICE_URL"
  echo "Set AWS_ROLE_ARN and SERVICE_URL on $GITHUB_REPO"
else
  echo "gh CLI not logged in. Set these in GitHub -> Settings -> Secrets and variables -> Actions -> Variables:"
  echo "  AWS_ROLE_ARN = $GH_ROLE_ARN"
  echo "  SERVICE_URL  = $SERVICE_URL"
fi

log "Done"
echo "ECR:     $ECR_URI"
echo "Role:    $GH_ROLE_ARN"
echo "Service: $SERVICE_URL/version   (live after the first pipeline run)"
