#!/usr/bin/env bash
# Deletes everything bootstrap.sh created. Destructive: asks before running.
set -uo pipefail
export AWS_REGION="${AWS_REGION:-eu-west-2}" AWS_DEFAULT_REGION="${AWS_REGION:-eu-west-2}" AWS_PAGER=""
export MSYS_NO_PATHCONV=1
PREFIX="${PREFIX:-amir}"; APP=hello-world; REPO="$PREFIX-hello-world"; CLUSTER="$PREFIX-hello"
read -r -p "Delete ALL hello-world AWS resources in $AWS_REGION? Type 'yes': " ok
[[ "$ok" == "yes" ]] || exit 1

aws ecs update-service --cluster $CLUSTER --service $APP --desired-count 0 >/dev/null
aws ecs delete-service --cluster $CLUSTER --service $APP --force >/dev/null
aws ecs wait services-inactive --cluster $CLUSTER --services $APP
for td in $(aws ecs list-task-definitions --family-prefix $REPO --query 'taskDefinitionArns[]' --output text); do
  aws ecs deregister-task-definition --task-definition "$td" >/dev/null
done
aws ecs delete-cluster --cluster $CLUSTER >/dev/null

ALB_ARN=$(aws elbv2 describe-load-balancers --names $PREFIX-hello-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
aws elbv2 delete-target-group --target-group-arn "$(aws elbv2 describe-target-groups --names $PREFIX-hello-tg --query 'TargetGroups[0].TargetGroupArn' --output text)"
sleep 20  # ENIs release
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
for sg in $PREFIX-hello-task-sg $PREFIX-hello-alb-sg; do
  id=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$sg" --query 'SecurityGroups[0].GroupId' --output text)
  aws ec2 delete-security-group --group-id "$id"
done

aws ecr delete-repository --repository-name $REPO --force >/dev/null
aws logs delete-log-group --log-group-name /ecs/$REPO

aws iam delete-role-policy --role-name exam-$PREFIX-hello-gha --policy-name deploy
aws iam delete-role --role-name exam-$PREFIX-hello-gha
aws iam detach-role-policy --role-name exam-$PREFIX-hello-exec --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws iam delete-role --role-name exam-$PREFIX-hello-exec
# The GitHub OIDC provider is account-wide and may be shared with others: not deleted.
echo "Teardown complete."
