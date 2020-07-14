#!/bin/bash -eu
#
# Copyright (c) 2017 SAP SE or an SAP affiliate company. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

DIR_STATE_IN="/tfstate"
DIR_STATE_OUT="/tfstate-out"
DIR_CONFIGURATION="/tf"
DIR_VARIABLES="/tfvars"
DIR_PROVIDERS="/terraform-providers"
DIR_PLUGIN_BINARIES=".terraform/plugins/linux_amd64"
DIR_IMPORTS="/terraform-imports"

PATH_STATE_CONFIG_MAP="$DIR_STATE_OUT/$TF_STATE_CONFIG_MAP_NAME"
PATH_STATE_IN="$DIR_STATE_IN/terraform.tfstate"
PATH_STATE_OUT="$DIR_STATE_OUT/terraform.tfstate"
PATH_CONFIGURATION_MAINTF="$DIR_CONFIGURATION/main.tf"
PATH_CONFIGURATION_VARIABLESTF="$DIR_CONFIGURATION/variables.tf"
PATH_VARIABLES="$DIR_VARIABLES/terraform.tfvars"
PATH_IMPORTS="$DIR_IMPORTS/terraform_imports"
PATH_IMPORT_TMP_STATE_IN="/import_in_tmp_terraform.tfstate"
PATH_IMPORT_TMP_STATE_OUT="/import_out_tmp_terraform.tfstate"

NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"

# exponential backoff functionality
: ${MAX_TIME_SEC:=1800}
: ${MAX_BACKOFF_SEC:=30}

function backoff() {
  t=1
  start="$(date +%s)"

  while ! "${@}"; do
    now="$(date +%s)"
    if [[ $((start + MAX_TIME_SEC)) -le $now ]]; then
      echo "$(date) Timeout of ${MAX_TIME_SEC}s reached. Aborting"
      return 1
    fi

    echo "$(date) Repeating command in $t sec..."
    sleep $t

    t=$((t * 2))
    if [[ "$t" -ge "${MAX_BACKOFF_SEC}" ]]; then
      t=${MAX_BACKOFF_SEC}
    fi
  done

  echo "$(date) Command executed successful."
}

# determine command
command="${1:-apply}"
exitcode=1

mkdir -p "$DIR_CONFIGURATION"
mkdir -p "$DIR_VARIABLES"
mkdir -p "$DIR_STATE_IN"
mkdir -p "$DIR_STATE_OUT"
mkdir -p "$DIR_IMPORTS"

# live lookup of terraform resources stored in configmaps
echo "Fetching configmap $NAMESPACE/$TF_CONFIGURATION_CONFIG_MAP_NAME and storing data in $PATH_CONFIGURATION_MAINTF..."
kubectl \
  --namespace="$NAMESPACE" \
  get configmap "$TF_CONFIGURATION_CONFIG_MAP_NAME" \
  --output="jsonpath={.data['main\.tf']}" \
  > "$PATH_CONFIGURATION_MAINTF"

echo "Fetching configmap $NAMESPACE/$TF_CONFIGURATION_CONFIG_MAP_NAME and storing data in $PATH_CONFIGURATION_VARIABLESTF..."
kubectl \
  --namespace="$NAMESPACE" \
  get configmap "$TF_CONFIGURATION_CONFIG_MAP_NAME" \
  --output="jsonpath={.data['variables\.tf']}" \
  > "$PATH_CONFIGURATION_VARIABLESTF"

echo "Fetching configmap $NAMESPACE/$TF_CONFIGURATION_CONFIG_MAP_NAME and storing data in $PATH_IMPORTS..."
kubectl \
  --namespace="$NAMESPACE" \
  get configmap "$TF_CONFIGURATION_CONFIG_MAP_NAME" \
  --output="jsonpath={.data['imports']}" \
  > "$PATH_IMPORTS"

echo "Fetching secret $NAMESPACE/$TF_VARIABLES_SECRET_NAME and storing data in $PATH_VARIABLES..."
kubectl \
  --namespace="$NAMESPACE" \
  get secret "$TF_VARIABLES_SECRET_NAME" \
  --output="jsonpath={.data['terraform\.tfvars']}" | \
  base64 -d > "$PATH_VARIABLES"

echo "Fetching configmap $NAMESPACE/$TF_STATE_CONFIG_MAP_NAME and storing data in $PATH_STATE_IN..."
kubectl \
  --namespace="$NAMESPACE" \
  get configmap "$TF_STATE_CONFIG_MAP_NAME" \
  --output="jsonpath={.data['terraform\.tfstate']}" \
  > "$PATH_STATE_IN"

# required to initialize the provider plugins
terraform init -plugin-dir="$DIR_PROVIDERS" "$DIR_CONFIGURATION"
# workaround for `terraform init`; required to make `terraform validate` work (plugin_path file ignored?)
cp -r "$DIR_PROVIDERS"/* "$DIR_PLUGIN_BINARIES"/.

# graceful shutdown function storing state in the configmap
function end_execution() {
  # Delete trap handler to avoid recursion
  trap - HUP QUIT PIPE INT TERM EXIT

  if [ -n "$TF_PID" ] && kill -0 "$TF_PID" &>/dev/null; then
    echo "$(date) Sending SIGTERM to terraform process $TF_PID."
    kill -SIGTERM $TF_PID
    echo "$(date) Waiting for terraform process $TF_PID to complete..."
    if wait $TF_PID; then
      echo "$(date) Terraform process $TF_PID completed."
    else
      echo "$(date) Terraform process $TF_PID exited with a non-zero code."
    fi
  fi

  # check whether the terraform state has changed
  if [[ ! -f "$PATH_STATE_OUT" ]] || diff "$PATH_STATE_IN" "$PATH_STATE_OUT" 1> /dev/null; then # passes (returns 0) if there is no diff
    # indicate success (exit code gets lost as the surrounding command pipes this script through 'tee')
    echo -e "\nNothing to do."
    if [[ $exitcode -eq 0 ]]; then
      touch /success
    fi
    exit 0
  else
    # update config map with the new terraform state
    echo -e "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: $TF_STATE_CONFIG_MAP_NAME\ndata:\n  terraform.tfstate: |" > "$PATH_STATE_CONFIG_MAP"
    cat "$PATH_STATE_OUT" | sed -n 's/^/    /gp' >> "$PATH_STATE_CONFIG_MAP"

    function update_state_configmap() {
      kubectl \
        replace \
        -f "$PATH_STATE_CONFIG_MAP" \
        > /dev/null

      # validate that the current terraform state is properly reflected in the config map
      kubectl \
        --namespace="$NAMESPACE" \
        get configmap "$TF_STATE_CONFIG_MAP_NAME" \
        --output="jsonpath={.data['terraform\.tfstate']}" \
        > "$PATH_STATE_CONFIG_MAP.put"

      if diff "$PATH_STATE_OUT" "$PATH_STATE_CONFIG_MAP.put" 1> /dev/null; then # passes (returns 0) if there is no diff
        # indicate success (exit code gets lost as the surrounding command pipes this script through 'tee')
        echo -e "\nConfigMap successfully updated with terraform state."
        if [[ $exitcode -eq 0 ]]; then
          touch /success
        fi
        return 0
      else
        return 1
      fi
    }

    if ! backoff update_state_configmap; then
      # dump terraform state so that we can find it at least in the logs
      echo -e "\nConfigMap could not be updated with terraform state! Dumping state file now to have it in the logs:"
      cat "$PATH_STATE_OUT"
      exit 1
    fi
  fi
}

if [[ "$command" == "validate" ]]; then
  terraform \
    validate \
    -var-file="$PATH_VARIABLES" \
    "$DIR_CONFIGURATION"
  if [[ "$?" == "0" ]]; then
    terraform \
      plan \
      -parallelism=4 \
      -detailed-exitcode \
      -state="$PATH_STATE_IN" \
      -var-file="$PATH_VARIABLES" \
      "$DIR_CONFIGURATION"
  else
    exit $?
  fi
else
  # Install trap handler for proper cleanup, summary and result code
  trap "exit 100" HUP QUIT PIPE
  trap end_execution INT TERM EXIT

  TF_PID=

  if [[ "$command" == "apply" ]]; then
    terraform \
      apply \
      -auto-approve \
      -parallelism=4 \
      -state="$PATH_STATE_IN" \
      -state-out="$PATH_STATE_OUT" \
      -var-file="$PATH_VARIABLES" \
      "$DIR_CONFIGURATION" &
    TF_PID=$!
    wait $TF_PID
    exitcode=$?
  elif [[ "$command" == "destroy" ]]; then
    terraform \
      destroy \
      -auto-approve \
      -parallelism=4 \
      -state="$PATH_STATE_IN" \
      -state-out="$PATH_STATE_OUT" \
      -var-file="$PATH_VARIABLES" \
      "$DIR_CONFIGURATION" &
    TF_PID=$!
    wait $TF_PID
    exitcode=$?
  elif [[ "$command" == "import" ]]; then
    cat $PATH_STATE_IN > $PATH_IMPORT_TMP_STATE_IN
    while read -r line; do
      [[ "$line" == '' ]] && continue
      resource_ref="$(echo $line | cut -d ' ' -f1 | tr -d ' ')"
      resource_value="$(echo $line | cut -d ' ' -f2 | tr -d ' ')"

      terraform \
        import \
        -config="$DIR_CONFIGURATION" \
        -state="$PATH_IMPORT_TMP_STATE_IN" \
        -state-out="$PATH_IMPORT_TMP_STATE_OUT" \
        -var-file="$PATH_VARIABLES" \
        "$resource_ref" "$resource_value" &
      TF_PID=$!
      wait $TF_PID
      exitcode=$?

      [[ "$exitcode" == "0" ]] && cat $PATH_IMPORT_TMP_STATE_OUT > $PATH_IMPORT_TMP_STATE_IN
    done < "$PATH_IMPORTS"
    rm -f $PATH_IMPORT_TMP_STATE_IN

    if [[ -f $PATH_IMPORT_TMP_STATE_OUT ]]; then
      echo "Patching configmap $NAMESPACE/$TF_CONFIGURATION_CONFIG_MAP_NAME to remove imports as they are applied to state..."
      kubectl \
      --namespace="$NAMESPACE" \
      patch configmap "$TF_CONFIGURATION_CONFIG_MAP_NAME" \
      --type=json \
      -p='[{"op": "remove", "path": "/data/imports"}]'

      echo "Write the state containing import(s) for persisting to $PATH_STATE_OUT"
      cat $PATH_IMPORT_TMP_STATE_OUT > $PATH_STATE_OUT
      rm -f $PATH_IMPORT_TMP_STATE_OUT
    fi
  else
    # Delete trap handler - nothing to do
    trap - HUP INT QUIT PIPE TERM EXIT
    echo -e "\nUnknown command: $command"
    exit 1
  fi
fi
