#!/usr/bin/env bash
set -euo pipefail

CALICO_VERSION="v3.33.0"
kubectl apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/v3_projectcalico_org-v1beta1.yaml"
kubectl apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
kubectl apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl get pods -n calico-system
