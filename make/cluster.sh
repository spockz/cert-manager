#!/usr/bin/env bash

# Copyright 2020 The cert-manager Authors.
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

# shellcheck disable=SC2059

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/config/lib.sh"
cd "$here/../"
set -e

mode=kind
k8s_version=1.23
kind_image_repo=docker.io/kindest/node
kind_cluster_name=kind

help() {
  cat <<EOF
Creates or updates a kind cluster.

Usage:
    ${bold}$0 [--mode kind] [--name NAME] [--show-image] [--help]${end}

Flags:
  --mode MODE
      Can be either kind.
  --name NAME
      The name of the cluster. Only useful when using --mode kind.
  --k8s-version VERSION
      The Kubernetes version to spin up with kind. It should be either a
      minor version e.g. 1.23 or a full version e.g. 1.23.3. You can also
      use K8S_VERSION to do the same.
  --show-image
      Show the image that will be used for the cluster and exit with 0. The
      image will be of the form docker.io/kindest/node:1.23@sha256:498...81ac.

Environment variables:
  ${green}K8S_VERSION${end}
        The Kubernetes version to use. Defaults to $k8s_version.
EOF
  exit
}

show_image=
while [ $# -ne 0 ]; do
  case "$1" in
  --*=*)
    echo "the flag $1 is invalid, please use '${1%=*} ${1#*=}'" >&2
    exit 1
    ;;
  -h | --help)
    help
    exit 0
    ;;
  --mode | --name | --k8s-version)
    if [ $# -lt 2 ]; then
      echo "$1 requires an argument" >&2
      exit 124
    fi
    var=$1
    var=${var/--/}
    var=${var//-/_}
    eval "$var=$2"
    shift
    ;;
  --show-image)
    var=$1
    var=${var/--/}
    var=${var//-/_}
    eval "$var=yes"
    ;;
  --*)
    echo "error: unknown flag: $1" >&2
    exit 124
    ;;
  *)
    echo "no positional argument is expected" >&2
    exit 124
    ;;
  esac
  shift
done

if printenv K8S_VERSION >/dev/null && [ -n "$K8S_VERSION" ]; then
  k8s_version="$K8S_VERSION"
fi

# NB: Kind cluster image digests are autogenerated by
# hack/update-kind-images.sh.
source "${here}/config/kind/kind_cluster_node_versions.env"
case "$k8s_version" in
1.18*) kind_image_sha=$KIND_IMAGE_SHA_K8S_118 ;;
1.19*) kind_image_sha=$KIND_IMAGE_SHA_K8S_119 ;;
1.20*) kind_image_sha=$KIND_IMAGE_SHA_K8S_120 ;;
1.21*) kind_image_sha=$KIND_IMAGE_SHA_K8S_121 ;;
1.22*) kind_image_sha=$KIND_IMAGE_SHA_K8S_122 ;;
1.23*) kind_image_sha=$KIND_IMAGE_SHA_K8S_123 ;;
v*) printf "${red}${redcross}Error${end}: the Kubernetes version must be given without the leading 'v'\n" >&2 && exit 1 ;;
*) printf "${red}${redcross}Error${end}: unsupported Kubernetes version ${yel}${k8s_version}${end}\n" >&2 && exit 1 ;;
esac

if [ -n "$show_image" ]; then
  echo "${kind_image_repo}:${k8s_version}@${kind_image_sha}"
  exit 0
fi

setup_kind() {
  # When running in our CI environment the Docker network's subnet choice will
  # cause issues with routing, which can manifest in errors such as this one:
  #
  #   dial tcp: lookup charts.jetstack.io on 10.8.240.10:53: read udp 10.8.0.2:54823->10.8.240.10:53: i/o timeout
  #
  # as seen in the build [1].  We create this custom network as a workaround
  # until we have a way to properly patch this.
  #
  # [1]: https://prow.build-infra.jetstack.net/view/gs/jetstack-logs/pr-logs/pull/cert-manager_approver-policy/36/pull-cert-manager-approver-policy-smoke/1447565895923666944#1:build-log.txt%3A222
  if printenv CI >/dev/null; then
    if ! docker network inspect kind >/dev/null 2>&1; then
      docker network create --driver=bridge --subnet=192.168.0.0/16 --gateway 192.168.0.1 kind
    fi

    # Wait for the network to be created so kind does not overwrite it.
    while ! docker network inspect kind; do
      sleep 100ms
    done
  fi

  # (1) Does the kind cluster already exist?
  if ! kind get clusters -q | grep -q "^$kind_cluster_name\$"; then
    trace kind create cluster --config make/config/kind/v1beta2.yaml \
      --image "${kind_image_repo}:${k8s_version}@${kind_image_sha}" \
      --name "$kind_cluster_name"
  fi

  # (2) Does the kube config contain the context for this existing kind cluster?
  if ! kubectl config get-contexts -oname 2>/dev/null | grep -q "^kind-${kind_cluster_name}$"; then
    printf "${red}${redcross}Error${end}: the kind cluster ${yel}$kind_cluster_name${end} already exists, but your current kube config does not contain the context ${yel}kind-$kind_cluster_name${end}. Run:\n" >&2
    printf "    ${cyan}kind delete cluster --name $kind_cluster_name${end}\n" >&2
    printf "and then retry.\n"
    exit 1
  fi

  # (3) Is the existing kind cluster selected as the current context in the kube
  # config?
  if [ "$(kubectl config current-context 2>/dev/null)" != "kind-$kind_cluster_name" ]; then
    printf "${red}${redcross}Error${end}: the kind cluster ${yel}$kind_cluster_name${end} already exists, but is not selected as your current context. Run:\n" >&2
    printf "    ${cyan}kubectl config use-context kind-$kind_cluster_name${end}\n" >&2
    exit 1
  fi

  # (4) Is the current context responding?
  if ! kubectl --context "kind-$kind_cluster_name" get nodes >/dev/null 2>&1; then
    printf "${red}${redcross}Error${end}: the kind cluster $kind_cluster_name isn't responding. Please run:\n" >&2
    printf "    ${cyan}kind delete cluster --name $kind_cluster_name${end}\n" >&2
    printf "and then retry.\n"
    exit 1
  fi

  # (5) Does the current context have the correct Kubernetes version?
  existing_version=$(kubectl version -oyaml | yq e '.serverVersion | .major +"."+ .minor' -)
  if ! [[ "$k8s_version" =~ ${existing_version//./\.} ]]; then
    printf "${yel}${warn}Warning${end}: your current kind cluster runs Kubernetes %s, but %s is the expected version. Run:\n" "$existing_version" "$k8s_version" >&2
    printf "    ${cyan}kind delete cluster --name $kind_cluster_name${end}\n" >&2
    printf "and then retry.\n" >&2
  fi

  # (6) Has the Corefile been patched?
  corefile=$(kubectl get -ogo-template='{{.data.Corefile}}' -n=kube-system configmap/coredns)
  to_be_appended=$'example.com:53 {\n    forward . 10.0.0.16\n}\n'
  if ! grep -q --null-data -F "$(tr -d $'\n' <<<"$to_be_appended")" <(tr -d $'\n' <<<"$corefile"); then
    kubectl create configmap -oyaml coredns --dry-run=client --from-literal=Corefile="$(printf '%s\n%s' "$corefile" "$to_be_appended")" \
      | kubectl apply -n kube-system -f - >/dev/null
  fi
}

case "$mode" in
kind) setup_kind ;;
*)
  echo "error: unknown mode: $mode" >&2
  exit 124
  ;;
esac
