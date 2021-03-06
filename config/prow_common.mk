# Copyright 2018 The Knative Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

SHELL := /bin/bash

# This file is used by prod and staging Makefiles

# Default settings for the CI/CD system.

CLUSTER       ?= prow
ZONE          ?= us-central1-f
JOB_NAMESPACE ?= test-pods

SKIP_CONFIG_BACKUP        ?=

# Any changes to file location must be made to staging directory also
# or overridden in the Makefile before this file is included.
PROW_PLUGINS     ?= core/plugins.yaml
PROW_CONFIG      ?= core/config.yaml
PROW_JOB_CONFIG  ?= jobs

PROW_DEPLOYS     ?= cluster
PROW_GCS         ?= knative-prow
PROW_CONFIG_GCS  ?= gs://$(PROW_GCS)/configs

BOSKOS_RESOURCES ?= boskos/boskos_resources.yaml

# Useful shortcuts.

SET_CONTEXT   := gcloud container clusters get-credentials "$(CLUSTER)" --project="$(PROJECT)" --zone="$(ZONE)"
UNSET_CONTEXT := kubectl config unset current-context

.PHONY: help get-cluster-credentials unset-cluster-credentials
help:
	@echo "Help"
	@echo "'Update' means updating the servers and can only be run by oncall staff."
	@echo "Common usage:"
	@echo " make update-prow-cluster: Update all Prow things on the server to match the current branch. Errors if not master."
	@echo " make update-testgrid-config: Update the Testgrid config"
	@echo " make get-cluster-credentials: Setup kubectl to point to Prow cluster"
	@echo " make unset-cluster-credentials: Clear kubectl context"

# Useful general targets.
get-cluster-credentials:
	$(SET_CONTEXT)

unset-cluster-credentials:
	$(UNSET_CONTEXT)

.PHONY: update-prow-config update-all-boskos-deployments update-boskos-resource update-almost-all-cluster-deployments update-single-cluster-deployment test update-testgrid-config confirm-master

# Update prow config
update-prow-config: confirm-master
	$(SET_CONTEXT)
	python3 <(curl -sSfL https://raw.githubusercontent.com/istio/test-infra/master/prow/recreate_prow_configmaps.py) \
		--prow-config-path=$(realpath $(PROW_CONFIG)) \
		--plugins-config-path=$(realpath $(PROW_PLUGINS)) \
		--job-config-dir=$(realpath $(PROW_JOB_CONFIG)) \
		--wet \
		--silent
	$(UNSET_CONTEXT)

# Update all deployments of boskos
# Boskos is separate because of patching done in staging Makefile
# Double-colon because staging Makefile piggy-backs on this
update-all-boskos-deployments:: confirm-master
	$(SET_CONTEXT)
	@for f in $(wildcard $(PROW_DEPLOYS)/*boskos*.yaml); do kubectl apply -f $${f}; done
	$(UNSET_CONTEXT)

# Update the list of resources for Boskos
update-boskos-resource: confirm-master
	$(SET_CONTEXT)
	kubectl create configmap resources --from-file=config=$(BOSKOS_RESOURCES) --dry-run --save-config -o yaml | kubectl --namespace="$(JOB_NAMESPACE)" apply -f -
	$(UNSET_CONTEXT)

# Update all deployments of cluster except Boskos
# Boskos is separate because of patching done in staging Makefile
# Double-colon because staging Makefile piggy-backs on this
update-almost-all-cluster-deployments:: confirm-master
	$(SET_CONTEXT)
	@for f in $(filter-out $(wildcard $(PROW_DEPLOYS)/*boskos*.yaml),$(wildcard $(PROW_DEPLOYS)/*.yaml)); do kubectl apply -f $${f}; done
	$(UNSET_CONTEXT)

# Update single deployment of cluster, expect passing in ${NAME} like `make update-single-cluster-deployment NAME=crier_deployment`
update-single-cluster-deployment: confirm-master
	$(SET_CONTEXT)
	kubectl apply -f $(PROW_DEPLOYS)/$(NAME).yaml
	$(UNSET_CONTEXT)

# Update all resources on Prow cluster
update-prow-cluster: update-almost-all-cluster-deployments update-all-boskos-deployments update-boskos-resource update-prow-config

# Do not allow server update from wrong branch or dirty working space
# In emergency, could easily edit this file, deleting all these lines
confirm-master:
	@if git diff-index --quiet HEAD; then true; else echo "Git working space is dirty -- will not update server"; false; fi;
# TODO(chizhg): change to `git branch --show-current` after we update the Git version in prow-tests image.
ifneq ("$(shell git rev-parse --abbrev-ref HEAD)","master")
	@echo "Branch is not master -- will not update server"
	@false
endif

# Update TestGrid config.
# Application Default Credentials must be set, otherwise the upload will fail.
# Either export $GOOGLE_APPLICATION_CREDENTIALS pointing to a valid service
# account key, or temporarily use your own credentials by running
# gcloud auth application-default login
update-testgrid-config: confirm-master
	bazel run @k8s//testgrid/cmd/configurator -- \
		--oneshot \
		--output=gs://$(TESTGRID_GCS)/config \
		--yaml=$(realpath $(TESTGRID_CONFIG))

