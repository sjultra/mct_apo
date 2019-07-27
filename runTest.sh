#!/bin/bash

set -e

REQUIRED_CONFIG_SECTIONS=("TEST" "AWS" "AZURE" "GCP")
WORK_DIR=$(dirname $(readlink -f "$0"))
TF_WORK_DIR="$WORK_DIR/terraform"
TESTS_DIR="$WORK_DIR/test_scripts/"
INSTANCE_ID="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 4 | head -n 1 | awk '{print tolower($0)}')"

CONFIG_FILE="$1"

function get_config_parameters {
    if [[ ! -e "$CONFIG_FILE" ]];then
        echo "Error: Cannot find config file"
        exit 1
    fi
    
    for section in ${REQUIRED_CONFIG_SECTIONS[@]};do
        keys=$(crudini --get $CONFIG_FILE $section)
        if [[ "$keys" == "" ]];then
            echo "Error: Cannot find parameters for section: $section"
            exit 1
        fi
        
        for key in $keys;do
            value=$(crudini --get $CONFIG_FILE $section $key)
            if [[ "$value" != "" ]];then
                echo "Info: Exporting global variable: ${key} = ${value}"
                export "${key}"="${value}"
                elif [[ "${!key}" != "" ]];then
                echo "Info: Using existing variable: ${key} = ${!key}"
            else
                echo "Error: Cannot find value for key: ${key}"
                exit 1
            fi
        done
    done
    
    export TEST_STAGES=($TEST_STAGES)
    
    LOG_DIRECTORY=$(eval "readlink -f $LOG_DIRECTORY")
    export LOG_DEPLOYMENT="${LOG_DIRECTORY}/ViewDeployments"
    export LOG_DIRECTORY="$LOG_DIRECTORY/$(date '+%Y-%m-%d-%H.%M.%S')-$INSTANCE_ID"
    export TF_VAR_instance_id=$INSTANCE_ID
    rm -rf $LOG_DIRECTORY
    mkdir -p $LOG_DIRECTORY
    echo "${INSTANCE_ID} - ${TF_VAR_aws_region} - ${TF_VAR_azure_region} - ${TF_VAR_gcp_region}" >> $LOG_DEPLOYMENT
}

function first_time_aporeto_setup {
    apoctl api create namespace --namespace $APOCTL_NAMESPACE -k name "gcp"
    apoctl api create namespace --namespace $APOCTL_NAMESPACE -k name "aws"
    apoctl api create namespace --namespace $APOCTL_NAMESPACE -k name "azure"
}

function gen_aporeto_keys {
    export APOCTL_NAMESPACE_GCP="$APOCTL_NAMESPACE/gcp"
    export APOCTL_NAMESPACE_AWS="$APOCTL_NAMESPACE/aws"
    export APOCTL_NAMESPACE_AZURE="$APOCTL_NAMESPACE/azure"
    
    
    apoctl api create namespace --namespace $APOCTL_NAMESPACE_GCP -k name $INSTANCE_ID
    cloud_namespace="$APOCTL_NAMESPACE_GCP/$INSTANCE_ID"
    export TF_VAR_gcp_token_r=$(apoctl auth appcred --path $APORTETO_CREDS --audience "aud:*:*:$cloud_namespace")
    export TF_VAR_gcp_token_u=$(apoctl auth appcred --path $APORTETO_CREDS --audience "aud:*:*:$cloud_namespace")
    
    apoctl api create namespace --namespace $APOCTL_NAMESPACE_AWS -k name $INSTANCE_ID
    cloud_namespace="$APOCTL_NAMESPACE_AWS/$INSTANCE_ID"
    export TF_VAR_aws_token_r=$(apoctl auth appcred --path $APORTETO_CREDS --audience "aud:*:*:$cloud_namespace")
    export TF_VAR_aws_token_u=$(apoctl auth appcred --path $APORTETO_CREDS --audience "aud:*:*:$cloud_namespace")
    
    apoctl api create namespace --namespace $APOCTL_NAMESPACE_AZURE -k name $INSTANCE_ID
    cloud_namespace="$APOCTL_NAMESPACE_AZURE/$INSTANCE_ID"
    export TF_VAR_azure_token_r=$(apoctl auth appcred --path $APORTETO_CREDS --audience "aud:*:*:$cloud_namespace")
    export TF_VAR_azure_token_u=$(apoctl auth appcred --path $APORTETO_CREDS --audience "aud:*:*:$cloud_namespace")
}

function change_kubectl_context {
    platform="$1"
    cluster_name="$2"
    region="$3"
    
    if [[ "$platform" == "aws" ]];then
        aws eks --region $region update-kubeconfig --name $cluster_name
        elif [[ "$platform" == "gcp" ]];then
        gcloud container clusters get-credentials $cluster_name --region $region
        elif [[ "$platform" == "azure" ]];then
        az aks get-credentials --name $cluster_name --resource-group $region
    fi
}

function config_aws_workers {
    terraform output aws_kube_auth > aws_nodes.conf
    change_kubectl_context aws $AWS_K8SA_NAME $AWS_K8S_REGION
    kubectl apply -f aws_nodes.conf
    change_kubectl_context aws $AWS_K8SA_NAME $AWS_K8S_REGION
    kubectl apply -f aws_nodes.conf
}

function install_aporeto_enforcer {
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tiller
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tiller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: tiller
    namespace: kube-system
EOF
    
    helm init  --service-account tiller --upgrade
    helm repo add aporeto https://charts.aporeto.com/releases/release-3.11.9/clients
    
    cat <<'EOF' | apoctl api import -n $APOCTL_NAMESPACE -f -
label: kubernetes-default-enforcerprofile
data:
  enforcerprofiles:
  - name: kubernetes-default
    metadata:
    - '@profile:name=kubernetes-default'
    description: Default Profile for Kubernetes
    excludedNetworks:
    - 127.0.0.0/8
    ignoreExpression:
    - - '@app:k8s:namespace=aporeto'
    - - '@app:k8s:namespace=aporeto-operator'
    - - '@app:k8s:namespace=kube-system'
    excludedInterfaces: []
    targetNetworks: []
    targetUDPNetworks: []
  enforcerprofilemappingpolicies:
  - name: fallback-kubernetes-default
    fallback: true
    description: "Kubernetes fallback: if there is no other profile, use the default Kubernetes profile."
    object:
    - - '@profile:name=kubernetes-default'
    subject:
    - - $identity=enforcer
EOF
    
    cat <<'EOF' | apoctl api import -n $APOCTL_NAMESPACE -f -
label: install-default-allow-all-policies
data:
  automations:
  - name: install-default-allow-all-policies
    description: Installs default allow all fallback policies for every child namespace that gets created to mimic Kubernetes default behavior.
    trigger: Event
    events:
      namespace:
      - create
    entitlements:
      externalnetwork:
      - create
      networkaccesspolicy:
      - create
    condition: |-
      function when(api, params) {
          return { continue: true, payload: { namespace: params.eventPayload.entity } };
      }
    actions:
    - |-
      function then(api, params, payload) {
          api.Create('externalnetwork', {
              name: 'external-tcp-all',
              description: 'Created by an automation on namespace creation. It is safe to be deleted, if not required.',
              metadata: ['@ext:name=tcpall'],
              entries: ['0.0.0.0/0'],
              ports: ['1:65535'],
              protocols: ['tcp'],
              propagate: true,
          }, payload.namespace.name);
          api.Create('externalnetwork', {
              name: 'external-udp-all',
              description: 'Created by an automation on namespace creation. It is safe to be deleted, if not required.',
              metadata: ['@ext:name=udpall'],
              entries: ['0.0.0.0/0'],
              ports: ['1:65535'],
              protocols: ['udp'],
              propagate: true,
          }, payload.namespace.name);
          api.Create('networkaccesspolicy', {
              name: 'default-fallback-ingress-allow-all',
              description: 'Created by an automation on namespace creation. It is safe to be deleted, if not required.',
              metadata: ['@netpol=default-fallback'],
              propagate: true,
              fallback: true,
              logsEnabled: true,
              observationEnabled: true,
              observedTrafficAction: 'Apply',
              action: 'Allow',
              applyPolicyMode: 'IncomingTraffic',
              subject: [
                  ['$identity=processingunit'],
                  ['@ext:name=tcpall'],
                  ['@ext:name=udpall'],
              ],
              object: [['$namespace='+payload.namespace.name]],
          }, payload.namespace.name);
          api.Create('networkaccesspolicy', {
              name: 'default-fallback-egress-allow-all',
              description: 'Created by an automation on namespace creation. It is safe to be deleted, if not required',
              metadata: ['@netpol=default-fallback'],
              propagate: true,
              fallback: true,
              logsEnabled: true,
              observationEnabled: true,
              observedTrafficAction: 'Apply',
              action: 'Allow',
              applyPolicyMode: 'OutgoingTraffic',
              subject: [['$namespace='+payload.namespace.name]],
              object: [
                  ['$identity=processingunit'],
                  ['@ext:name=tcpall'],
                  ['@ext:name=udpall'],
              ],
          }, payload.namespace.name);
      }
EOF
    
    kubectl create namespace aporeto-operator
    kubectl create namespace aporeto
    
    apoctl appcred create enforcerd \
    --type k8s \
    --role "@auth:role=enforcer" \
    --namespace $APOCTL_NAMESPACE \
    | kubectl apply -f - -n aporeto
    
    apoctl appcred create aporeto-operator \
    --type k8s \
    --role "@auth:role=aporeto-operator" \
    --namespace $APOCTL_NAMESPACE \
    | kubectl apply -f - -n aporeto-operator
    
    kubectl -n aporeto-operator get secrets && kubectl -n aporeto get secrets
    
    sleep 120
    helm install aporeto/aporeto-crds \
    --name aporeto-crds
    
    helm install aporeto/aporeto-operator \
    --name aporeto-operator \
    --namespace aporeto-operator
    
    helm install aporeto/enforcerd \
    --name enforcerd \
    --namespace aporeto
}

function config_aporeto_clusters {
    base_apoctl_namespace="$APOCTL_NAMESPACE"
    
    export APOCTL_NAMESPACE="$APOCTL_NAMESPACE_GCP/$INSTANCE_ID"
    change_kubectl_context gcp $GCP_K8SA_NAME $GCP_K8SA_REGION
    echo "${INSTANCE_ID} - Aporeto kubernetes setup start - $GCP_K8SA_NAME - $GCP_K8SA_REGION - $(date '+%Y-%m-%d-%H:%M:%S')" >> $LOG_DEPLOYMENT
    install_aporeto_enforcer
    echo "${INSTANCE_ID} - Aporeto kubernetes setup finish - $GCP_K8SA_NAME - $GCP_K8SA_REGION - $(date '+%Y-%m-%d-%H:%M:%S')" >> $LOG_DEPLOYMENT
    
    export APOCTL_NAMESPACE="$APOCTL_NAMESPACE_AZURE/$INSTANCE_ID"
    change_kubectl_context azure $AZURE_K8SA_NAME $AZURE_RG_NAME
    echo "${INSTANCE_ID} - Aporeto kubernetes setup start - $AZURE_K8SA_NAME - $AZURE_RG_NAME - $(date '+%Y-%m-%d-%H:%M:%S')" >> $LOG_DEPLOYMENT
    install_aporeto_enforcer || true
    echo "${INSTANCE_ID} - Aporeto kubernetes setup finish - $AZURE_K8SA_NAME - $AZURE_RG_NAME - $(date '+%Y-%m-%d-%H:%M:%S')" >> $LOG_DEPLOYMENT
    
    export APOCTL_NAMESPACE="$APOCTL_NAMESPACE_AWS/$INSTANCE_ID"
    change_kubectl_context aws $AWS_K8SA_NAME $AWS_K8S_REGION
    echo "${INSTANCE_ID} - Aporeto kubernetes setup start - $AWS_K8SA_NAME - $AWS_K8S_REGION - $(date '+%Y-%m-%d-%H:%M:%S')" >> $LOG_DEPLOYMENT
    install_aporeto_enforcer
    echo "${INSTANCE_ID} - Aporeto kubernetes setup finish - $AWS_K8SA_NAME - $AWS_K8S_REGION - $(date '+%Y-%m-%d-%H:%M:%S')" >> $LOG_DEPLOYMENT
    
    export APOCTL_NAMESPACE="$base_apoctl_namespace"
}

function generate_terraform_logs {
    terraform output > "$LOG_DIRECTORY/terraform_output.log"
    cp ~/.ssh/id_rsa "$LOG_DIRECTORY"
    cat << EOT > "$LOG_DIRECTORY/ssh_instructions.log"
# {IP} can be found in: $LOG_DIRECTORY/terraform_output.log
ssh -o 'StrictHostKeyChecking no' -i $LOG_DIRECTORY/id_rsa ubuntu@{IP}
EOT
    
    log_master_dir=$(readlink -f $(dirname $LOG_DIRECTORY))
    rm -f "$log_master_dir/latest"
    ln -s $LOG_DIRECTORY "$log_master_dir/latest"
}

function deploy_terraform_infra {
    gen_aporeto_keys
    
    terraform init
    terraform plan -lock=false 2>&1 | tee "$LOG_DIRECTORY/terraform_plan.log"
    echo "${INSTANCE_ID} - plan deployment - $(date '+%Y-%m-%d-%H:%M:%S') - $LOG_DIRECTORY/terraform_plan.log " >> $LOG_DEPLOYMENT
    
    
    terraform apply -auto-approve -lock=false 2>&1 | tee "$LOG_DIRECTORY/terraform_apply.log"
    echo "${INSTANCE_ID} - apply deployment - $(date '+%Y-%m-%d-%H:%M:%S') - $LOG_DIRECTORY/terraform_apply.log " >> $LOG_DEPLOYMENT
    
    generate_terraform_logs
    
    export GCP_K8SA_NAME="$(terraform output gcp-k8s1a-name)"
    export GCP_K8SB_NAME="$(terraform output gcp-k8s1b-name)"
    export GCP_K8SA_REGION="$(terraform show -json | jq -r '.values.root_module.resources | .[] | select(.address=="google_container_cluster.k8s1a") | .values.location')"
    export GCP_K8SB_REGION="$(terraform show -json | jq -r '.values.root_module.resources | .[] | select(.address=="google_container_cluster.k8s1b") | .values.location')"
    
    export AWS_K8SA_NAME="$(terraform output aws-k8s2a-name)"
    export AWS_K8SB_NAME="$(terraform output aws-k8s2b-name)"
    export AWS_K8S_REGION="$TF_VAR_aws_region"
    
    export AZURE_K8SA_NAME="$(terraform output azure-k8s3a-name)"
    export AZURE_K8SB_NAME="$(terraform output azure-k8s3b-name)"
    export AZURE_RG_NAME="$(terraform output azure-resource-group-name)"
}

function deploy_hipster {
    frontend_config="$WORK_DIR/deployment_configs/gke/main.yaml"
    linuxbox_config="$WORK_DIR/deployment_configs/linux.yaml"
    
    change_kubectl_context gcp $GCP_K8SA_NAME $GCP_K8SA_REGION
    
    kubectl get nodes -o wide 2>&1 | tee "$LOG_DIRECTORY/${cluster_name}_nodes_info.log"
    
    echo "Info: Deploying test frontend pods on cluster ${cluster_name}"
    kubectl apply -f "$frontend_config"
    
    echo "Info: Waiting for the cluster to deploy the pods"
    sleep 100
    kubectl get pods -o wide 2>&1 | tee "$LOG_DIRECTORY/${cluster_name}_pods_info.log"
    echo "Info: Deploying linuxBox pod on cluster ${cluster_name}"
    kubectl apply -f "$linuxbox_config"
    
    change_kubectl_context gcp $GCP_K8SB_NAME $GCP_K8SB_REGION
    
    kubectl get nodes -o wide 2>&1 | tee "$LOG_DIRECTORY/${cluster_name}_nodes_info.log"
    
    echo "Info: Deploying test frontend pods on cluster ${cluster_name}"
    kubectl apply -f "$frontend_config"
    
    echo "Info: Waiting for the cluster to deploy the pods"
    sleep 100
    kubectl get pods -o wide 2>&1 | tee "$LOG_DIRECTORY/${cluster_name}_pods_info.log"
    echo "Info: Deploying linuxBox pod on cluster ${cluster_name}"
    kubectl apply -f "$linuxbox_config"
    
    change_kubectl_context aws $AWS_K8SA_NAME $AWS_K8S_REGION
    echo "Info: Deploying linuxBox pod on cluster ${AWS_K8SA_NAME}"
    kubectl apply -f "$linuxbox_config"
    
    change_kubectl_context aws $AWS_K8SB_NAME $AWS_K8S_REGION
    echo "Info: Deploying linuxBox pod on cluster ${AWS_K8SB_NAME}"
    kubectl apply -f "$linuxbox_config"
    
    change_kubectl_context azure $AZURE_K8SA_NAME $AZURE_RG_NAME
    echo "Info: Deploying linuxBox pod on cluster ${AZURE_K8SA_NAME}"
    kubectl apply -f "$linuxbox_config"
    
    change_kubectl_context azure $AZURE_K8SB_NAME $AZURE_RG_NAME
    echo "Info: Deploying linuxBox pod on cluster ${AZURE_K8SB_NAME}"
    kubectl apply -f "$linuxbox_config"
}


function main {
    pushd $TF_WORK_DIR
    
    if [[ "$DEPLOY_TEST_INFRA" == "yes" ]];then
        deploy_terraform_infra
        config_aws_workers
    fi
    if [[ "$FIRST_TIME_APORETO_SETUP" == "yes" ]];then
        first_time_aporeto_setup
    fi
    
    if [[ "$CONFIG_CLUSTER_ENFORCER" == "yes" ]];then
        config_aporeto_clusters
    fi
    
    if [[ "$DEPLOY_HIPSTER_DEMO" == "yes" ]];then
        deploy_hipster
    fi
    
    if [[ "$RUN_VPN_CHECK" == "yes" ]];then
        if [[ -e "$TESTS_DIR/check_deployment.sh" ]];then
            bash "$TESTS_DIR/check_deployment.sh"
        else
            echo "Warning: Cannot find test script $TESTS_DIR/check_deployment.sh"
        fi
    fi
    
    for stage in ${TEST_STAGES[@]};do
        if [[ -e "$TESTS_DIR/test_${stage}.sh" ]];then
            bash "$TESTS_DIR/test_${stage}.sh"
        else
            echo "Warning: Cannot find test script $TESTS_DIR/test_${stage}.sh"
        fi
    done
    
    if [[ "$DESTROY_TEST_INFRA" == "yes" ]];then
        terraform destroy -auto-approve -lock=false | tee "$LOG_DIRECTORY/terraform_destroy.log"
        echo "${INSTANCE_ID} - destroy deployment - $(date '+%Y-%m-%d-%H:%M:%S') - $LOG_DIRECTORY/terraform_destroy.log " >> $LOG_DEPLOYMENT
        
    fi
    
    popd
    
}

get_config_parameters
main
