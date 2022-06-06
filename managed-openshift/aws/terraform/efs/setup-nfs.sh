#!/usr/bin/env bash

CLUSTER_URL=$1
CLUSTER_ADMIN_USERNAME=$2
CLUSTER_ADMIN_PASSWORD=$3
FILESYSTEM_ID=$4

CLUSTER_NAME=$(echo "$CLUSTER_URL" | sed -e 's|https://api\.\([^\.]*\).*|\1|')
echo "CLUSTER_NAME=$CLUSTER_NAME"
CLUSTER_VPCID=$(aws ec2 describe-vpcs | jq -r '.Vpcs[] | select(has("Tags") and (.Tags[] | select((.Key=="Name") and (.Value | test("'$CLUSTER_NAME'-vpc"))))) | .VpcId')
echo "CLUSTER_VPCID=$CLUSTER_VPCID"
if [ -z "$CLUSTER_VPCID" ]
then 
CLUSTER_VPCID=$(aws ec2 describe-vpcs | jq -r '.Vpcs[] | select(has("Tags") and (.Tags[] | select((.Key=="Name") and (.Value | test("'$CLUSTER_NAME'.*-vpc"))))) | .VpcId')
echo "CLUSTER_VPCID=$CLUSTER_VPCID"
fi

CLUSTER_VPC_CIDR=$(aws ec2 describe-vpcs | jq -r '.Vpcs[] | select(has("Tags") and (.Tags[] | select((.Key=="Name") and (.Value | test("'$CLUSTER_NAME'-vpc"))))) | .CidrBlock')
echo "CLUSTER_VPC_CIDR=$CLUSTER_VPC_CIDR"
if [ -z "$CLUSTER_VPC_CIDR" ]
then
CLUSTER_VPC_CIDR=$(aws ec2 describe-vpcs | jq -r '.Vpcs[] | select(has("Tags") and (.Tags[] | select((.Key=="Name") and (.Value | test("'$CLUSTER_NAME'.*-vpc"))))) | .CidrBlock')
echo "CLUSTER_VPC_CIDR=$CLUSTER_VPC_CIDR"
fi
CLUSTER_WORKER_SECURITY_GROUPID=$(aws ec2 describe-security-groups | jq -r '.SecurityGroups[] | select(has("Tags") and (.Tags[] | select((.Key=="Name") and (.Value | test("'$CLUSTER_NAME'-.*-worker-sg"))))) | .GroupId')
echo "CLUSTER_WORKER_SECURITY_GROUPID=$CLUSTER_WORKER_SECURITY_GROUPID"

echo "Add NFS inbound rule to Workers security group"

OUTPUT=$(\
aws ec2 authorize-security-group-ingress \
--group-id $CLUSTER_WORKER_SECURITY_GROUPID \
--protocol tcp \
--port 2049   \
--cidr $CLUSTER_VPC_CIDR \
2>&1 || true
)
if [[ "$OUTPUT" == *"already exists"* ]]; then
    echo "rule already exists"
else
    echo "Security group ingress rule created successfully"
    echo $OUTPUT
fi

echo "Setting up NFS-Subdir-Provisioner"

oc login $CLUSTER_URL --insecure-skip-tls-verify -u $CLUSTER_ADMIN_USERNAME -p $CLUSTER_ADMIN_PASSWORD
WORKER_NODE=`oc get nodes | grep worker | tail -1 | awk '/compute.internal/ {print $1}'` 
echo  "WORKER_NODE:"$WORKER_NODE
AWS_REGION=`echo "$WORKER_NODE" | cut -d'.' -f2`
echo "AWS_REGION:" $AWS_REGION
echo "waiting for the creation of  Mount-target "
sleep 30

FILESYSTEM_DNS_NAME=$FILESYSTEM_ID.efs.$AWS_REGION.amazonaws.com 
echo $FILESYSTEM_DNS_NAME

# echo "Setting up NFS-Subdir-Provisioner"
echo "FILESYSTEM_DNS_NAME:--->" $FILESYSTEM_DNS_NAME
NAMESPACE=`oc project -q`
oc adm policy add-scc-to-user hostmount-anyuid system:serviceaccount:$NAMESPACE:nfs-client-provisioner

# Create RBAC
cat <<EOF |oc create -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-client-provisioner
  # replace with namespace where provisioner is deployed
  namespace: default
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: nfs-client-provisioner-runner
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "update", "patch"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: run-nfs-client-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    # replace with namespace where provisioner is deployed
    namespace: default
roleRef:
  kind: ClusterRole
  name: nfs-client-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-client-provisioner
  # replace with namespace where provisioner is deployed
  namespace: default
rules:
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-client-provisioner
  # replace with namespace where provisioner is deployed
  namespace: default
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    # replace with namespace where provisioner is deployed
    namespace: default
roleRef:
  kind: Role
  name: leader-locking-nfs-client-provisioner
  apiGroup: rbac.authorization.k8s.io
EOF

echo "==========Creating Deployment=========="
sleep 60


# Create deployment

cat <<EOF | oc create -f - 
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-client-provisioner
  labels:
    app: nfs-client-provisioner
  # replace with namespace where provisioner is deployed
  namespace: default
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nfs-client-provisioner
  template:
    metadata:
      labels:
        app: nfs-client-provisioner
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
        - name: nfs-client-provisioner
          image: k8s.gcr.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2 
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
          env:
            - name: PROVISIONER_NAME
              value: k8s-sigs.io/nfs-subdir-external-provisioner
            - name: NFS_SERVER
              value: $FILESYSTEM_DNS_NAME
            - name: NFS_PATH
              value: /
      volumes:
        - name: nfs-client-root
          nfs:
            server: $FILESYSTEM_DNS_NAME
            path: /
EOF
sleep 10

cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner # or choose another name, must match deployment's env PROVISIONER_NAME'
parameters:
  archiveOnDelete: "false"
EOF

# To restart the deployment
# oc rollout restart deployment/nfs-client-provisioner