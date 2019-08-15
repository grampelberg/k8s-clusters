# Cluster management tools.

export CLUSTER_NAME ?= $(shell cat tmp/current 2>/dev/null || echo $$(whoami)-dev)
export MACHINE_TYPE ?= n1-standard-2
export DISK_SIZE ?= 100
export MAX_NODES ?= 10
export NETWORK ?= dev
export PROJECT ?= test
export VERSION ?= latest
export ZONE ?= us-west1-a
GKE_DASHBOARD = http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/
AKS_DASHBOARD = http://localhost:8001/api/v1/namespaces/kube-system/services/kubernetes-dashboard/proxy

# Azure specific options
export LOCATION ?= West US
export AZURE_VM ?= Standard_DS2_v2
export AKS_VERSION ?= 1.14.5
export AKS_CNI ?= true

# EKS specific options
export EC2_VM ?= m5.large
export EC2_REGION ?= us-west-2

define gcloud_container
	gcloud beta container \
		--project "$(PROJECT)" \
		clusters \
		--zone "$(ZONE)"
endef

define gcloud_compute
	gcloud compute --project=$(PROJECT)
endef

tmp:
	mkdir tmp

HAS_GCLOUD := $(shell command -v gcloud;)
HAS_HELM := $(shell command -v helm;)
HAS_KUBECTL := $(shell command -v kubectl;)
HAS_AZ := $(shell command -v az;)
HAS_AWSCLI := $(shell command -v aws;)
HAS_EKSCTL := $(shell command -v eksctl;)

.PHONY: bootstrap
bootstrap:
	@# Bootstrap the local required binaries
ifndef HAS_GCLOUD
	curl https://sdk.cloud.google.com | bash
endif
ifndef HAS_KUBECTL
	gcloud components install kubectl
endif
ifndef HAS_HELM
	curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
endif

.PHONY: aks-bootstrap
aks-bootstrap:
	@# Bootstrap the required binaries for AKS
ifndef HAS_AZ
	echo "Run brew install azure-cli on OSX" && exit 1
endif
ifndef HAS_KUBECTL
	az aks install-cli
endif
ifndef HAS_HELM
	curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
endif

.PHONY: eks-bootstrap
eks-bootstrap:
	@# Bootstrap the required auth and binaries for EKS
ifndef HAS_AWSCLI
	echo "Run pip install awscli --upgrade --user or follow official install instructions" && exit 1
endif
	@if [ ! -f ~/.aws/credentials ]; then \
		echo "You must setup the AWS CLI first by running 'aws configure'"; \
		exit 1; \
	fi
ifndef HAS_EKSCTL
	echo "Run brew install weaveworks/tap/eksctl on OSX" && exit 1
endif

.PHONY: create
create: bootstrap
	@# Create a cluster in GKE with some sane defaults.
	@# Options:
	@#
	@#     CLUSTER_NAME                       :: ${CLUSTER_NAME}
	@#     MACHINE_TYPE                       :: ${MACHINE_TYPE}
	@#     MAX_NODES                          :: ${MAX_NODES}
	@#     NETWORK                            :: ${NETWORK}
	@#     PROJECT                            :: ${PROJECT}
	@#     VERSION                            :: ${VERSION}
	@#     ZONE                               :: ${ZONE}
	$(call gcloud_container) \
		create "$(CLUSTER_NAME)" \
		--cluster-version "$(VERSION)" \
		--machine-type "$(MACHINE_TYPE)" \
		--network "$(NETWORK)" \
		--num-nodes "1" \
		--enable-autoscaling \
		--min-nodes "1" \
		--max-nodes "$(MAX_NODES)" \
		--no-enable-basic-auth \
		--no-enable-legacy-authorization \
		--image-type "COS" \
		--disk-size "$(DISK_SIZE)" \
		--disk-type "pd-standard" \
		--min-cpu-platform "Intel Skylake" \
		--preemptible \
		--scopes "gke-default" \
		--enable-pod-security-policy \
		--enable-vertical-pod-autoscaling \
		--no-enable-cloud-logging \
		--no-enable-cloud-monitoring \
		--no-enable-stackdriver-kubernetes \
		--no-enable-ip-alias \
		--enable-network-policy \
		--no-enable-autoupgrade \
		--no-enable-autorepair \
		--no-issue-client-certificate \
		--addons HorizontalPodAutoscaling,HttpLoadBalancing,KubernetesDashboard,NetworkPolicy
	$(MAKE) get-auth set-current run-proxy
	kubectl create clusterrolebinding \
		$$(whoami)-cluster-admin \
		--clusterrole=cluster-admin \
		--user=$$(gcloud config get-value account)
	kubectl apply -f psp.yaml -f rbac.yaml -f tiller.yaml
	helm init --service-account tiller
	$(MAKE) show-dashboard

.PHONY: delete
delete:
	@# Deletes the current cluster.
	@# Options:
	@#
	@#     CLUSTER_NAME                       :: ${CLUSTER_NAME}
	@#     PROJECT                            :: ${PROJECT}
	@#     ZONE                               :: ${ZONE}
	$(call gcloud_container) delete $(CLUSTER_NAME)

.PHONY: get-auth
get-auth:
	@# Configure kubectl to connect to remote cluster.
	@# Options:
	@#
	@#     CLUSTER_NAME                       :: ${CLUSTER_NAME}
	$(call gcloud_container) \
		get-credentials \
		$(CLUSTER_NAME)
	kubectl config delete-context gke-$(CLUSTER_NAME) || true
	kubectl config rename-context \
		$$(kubectl config current-context) \
		gke-$(CLUSTER_NAME)

.PHONY: set-current
set-current:
	@# Set the current cluster and setup kubectl to use it.
	@# Options:
	@#
	@#     CLUSTER_NAME                       :: ${CLUSTER_NAME}
	kubectl config use-context gke-$(CLUSTER_NAME)

.PHONY: run-proxy
run-proxy: tmp
	@# Run the proxy so that the dashboard is accessible.
	lsof -i4TCP:8001 -sTCP:LISTEN -t | xargs kill
	kubectl proxy >tmp/proxy.log 2>&1 &

.PHONY: create-network
create-network:
	@# Create a VPC network for use by k8s clusters. Allow current IP by default.
	@# Options:
	@#
	@#     NETWORK                            :: ${NETWORK}
	@#     PROJECT                            :: ${PROJECT}
	@#     ZONE                               :: ${ZONE}
	$(call gcloud_compute) \
		networks create $(NETWORK) \
		--subnet-mode=auto
	$(call gcloud_compute) \
		firewall-rules create $(NETWORK)-allow-ssh \
		--description="allow ssh" \
		--direction=INGRESS \
		--priority=65534 \
		--network=$(NETWORK) \
		--action=ALLOW \
		--rules=tcp:22 \
		--source-ranges=0.0.0.0/0
	$(call gcloud_compute) \
		firewall-rules create $(NETWORK)-allow-internal \
		--description="allow internal" \
		--direction=INGRESS \
		--priority=65534 \
		--network=$(NETWORK) \
		--action=ALLOW \
		--rules=all \
		--source-ranges=10.128.0.0/9

.PHONY: show-dashboard
show-dashboard:
	@# Show the URL that can be used to access the dashboard
	@echo "Go to $(GKE_DASHBOARD) for the dashboard. Note: RBAC is permissive for the dashboard, no need to enter a token."

.PHONY: aks-create
aks-create: aks-bootstrap
	@# Create a AKS cluster.
	@# Options
	@#
	@#     NETWORK                            :: ${NETWORK}
	@#     CLUSTER_NAME                       :: ${CLUSTER_NAME}
	@#     AKS_VERSION                        :: ${AKS_VERSION}
	@#     AKS_CNI                            :: ${AKS_CNI}
	@#     AZURE_VM                           :: ${AZURE_VM}
	@#     LOCATION                           :: ${LOCATION}

	az group create \
		--name $(CLUSTER_NAME) \
		--location "$(LOCATION)" \
		-o table
	az network vnet create \
		--name $(CLUSTER_NAME) \
		--resource-group $(CLUSTER_NAME) \
		--address-prefix 10.0.0.0/16 \
		--subnet-name $(CLUSTER_NAME) \
		--subnet-prefix 10.0.0.0/20 \
		-o table
	az aks create \
		--name $(CLUSTER_NAME) \
		--resource-group $(CLUSTER_NAME) \
		--dns-name-prefix $(CLUSTER_NAME) \
		--generate-ssh-keys \
		--kubernetes-version $(AKS_VERSION) \
		$$($(MAKE) aks-network-plugin) \
		--location "$(LOCATION)" \
		--node-count 1 \
		--node-osdisk-size 100 \
		--node-vm-size "$(AZURE_VM)" \
		--enable-addons http_application_routing \
		-o table
	$(MAKE) aks-auth aks-autoscaler run-proxy
	kubectl apply -f rbac.yaml
	kubectl apply -f tiller.yaml
	helm init --service-account tiller
	@echo "Go to $(AKS_DASHBOARD) for the dashboard. Note: RBAC is permissive for the dashboard, no need to enter a token."

.PHONY: aks-delete
aks-delete: aks-bootstrap
	@# Delete a AKS cluster.
	az aks delete \
		--name $(CLUSTER_NAME) \
		--resource-group $(CLUSTER_NAME)
	az network vnet delete \
		--name $(CLUSTER_NAME) \
		--resource-group $(CLUSTER_NAME)
	az group delete \
		--name $(CLUSTER_NAME) \
		-y
	kubectl config delete-cluster $(CLUSTER_NAME)

.PHONY: aks-auth
aks-auth:
	@# Setup kubectl context to work with AKS
	az aks get-credentials \
		--resource-group $(CLUSTER_NAME) \
		--name $(CLUSTER_NAME) \
		--overwrite-existing
	kubectl config delete-context aks-$(CLUSTER_NAME) || true
	kubectl config rename-context \
		$$(kubectl config current-context) \
		aks-$(CLUSTER_NAME)

.PHONY: aks-autoscaler
aks-autoscaler: aks-bootstrap
	@# Setup autoscaling for AKS clusters
	./azure-autoscaler | kubectl apply -f -
	kubectl apply -f aks-autoscaler.yaml

.PHONY: aks-get-subnet
aks-get-subnet: aks-bootstrap
	@# Fetch the current virtual network subnet id
	@az network vnet subnet list \
		--resource-group $(CLUSTER_NAME) \
		--vnet-name $(CLUSTER_NAME) \
		--query '[].id' \
		-o tsv

.PHONY: aks-network-plugin
aks-network-plugin: aks-bootstrap
	@# Output the CLI arguments required to configure the network plugin
	@[ "$${AKS_CNI}" == "true" ] && \
		echo \
			--network-plugin azure \
			--vnet-subnet-id $$($(MAKE) aks-get-subnet) \
			--service-cidr 192.168.0.0/16 \
			--dns-service-ip 192.168.0.10

.PHONY: eks-create
eks-create: eks-bootstrap
	@# Create an EKS cluster
	@# Options
	@#
	@#     CLUSTER_NAME                       :: ${CLUSTER_NAME}
	@#     EC2_VM.                            :: ${EC2_VM}
	@#     LOCATION                           :: ${LOCATION}
	@#     EC2_REGION                         :: ${EC2_REGION}
	@#     DISK_SIZE                          :: ${DISK_SIZE}
	@#     MAX_NODES                          :: ${MAX_NODES}

	eksctl create cluster \
		--name $(CLUSTER_NAME) \
		--asg-access \
		--full-ecr-access \
		--nodes 1 \
		--nodes-min 1 \
		--nodes-max $(MAX_NODES) \
		--node-type $(EC2_VM) \
		--node-volume-size $(DISK_SIZE) \
		--max-pods-per-node 250 \
		--region $(EC2_REGION) \
		--set-kubeconfig-context

.PHONY: eks-delete
eks-delete: eks-bootstrap
	@# Delete an EKS cluster
	eksctl delete cluster \
		--name $(CLUSTER_NAME) \
		--region $(EC2_REGION)

.PHONY: help
help: SHELL := /bin/bash
help:
	@# Output all targets available.
	@ echo "usage: make [target] ..."
	@ echo ""
	@eval "echo \"$$(grep -h -B1 $$'^\t@#' $(MAKEFILE_LIST) \
		| sed 's/@#//' \
		| awk \
			-v NO_COLOR="$(NO_COLOR)" \
			-v OK_COLOR="$(OK_COLOR)" \
			-v RS="--\n" \
			-v FS="\n" \
			-v OFS="@@" \
			'{ split($$1,target,":"); $$1=""; print OK_COLOR target[1] NO_COLOR $$0 }' \
		| sort \
		| awk \
			-v FS="@@" \
			-v OFS="\n" \
			'{ CMD=$$1; $$1=""; print CMD $$0 }')\""

.DEFAULT_GOAL := help
