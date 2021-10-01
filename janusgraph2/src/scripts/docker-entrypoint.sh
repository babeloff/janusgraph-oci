#!/bin/bash

# Copyright 2019 JanusGraph Authors
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

JG_PROPS_YAML="${JG_CONFIG_DIR}/janusgraph-graph.yaml"
JG_SERVER_YAML="${JG_CONFIG_DIR}/janusgraph-server.yaml"

echo 'running as root; step down to run as janusgraph user'
if
 test "$1" == 'janusgraph'
then
  if
   test "$(id -u)" == "0"
  then
    echo 'starting entry point as root; stepping down to run as "janusgraph" user'
    mkdir -p "${JG_DATA_DIR}" "${JG_CONFIG_DIR}"
    chown -R janusgraph:janusgraph "${JG_DATA_DIR}" "${JG_CONFIG_DIR}"
    chmod 700 "${JG_DATA_DIR}" "${JG_CONFIG_DIR}"

    exec chroot --skip-chdir --userspec janusgraph:janusgraph / "${BASH_SOURCE[0]}" "$@"
  fi
fi

echo 'running as non-root user ' "$(id -un)"
if
 test "$1" == 'janusgraph'
then
  mkdir -p "${JG_DATA_DIR}" "${JG_CONFIG_DIR}"

  # If JG_SERVER_TEMP not set, then provide a reasonable default
  JG_SERVER_YAML_SRC=$(realpath "conf/${JG_SERVER_TEMP:-janusgraph-server}.yaml")
  if
    cp "${JG_SERVER_YAML_SRC}" "${JG_SERVER_YAML}"
  then
    echo 'copied ' "${JG_SERVER_YAML_SRC}"
  else
    echo 'failed to copy ' "${JG_SERVER_YAML_SRC}"
    ls "conf/*.yaml"
  fi

  # If JG_GRAPH_TEMP not set, then provide a reasonable default
  JG_PROPS_YAML_BASE=$(realpath "conf/${JG_GRAPH_TEMP:-janusgraph-inmemory-graph}.yaml")
  if
    cp "${JG_PROPS_YAML_BASE}" "${JG_PROPS_YAML}"
  then
    echo 'copied ' "${JG_PROPS_YAML_BASE}"
  else
    echo 'failed to copy ' "${JG_PROPS_YAML_BASE}"
    ls "conf/*.yaml"
  fi

  chown -R "$(id -u):$(id -g)" "${JG_DATA_DIR}" "${JG_CONFIG_DIR}"
  chmod 700 "${JG_DATA_DIR}" "${JG_CONFIG_DIR}"
  chmod -R 600 "${JG_CONFIG_DIR}"/*

  echo 'apply configuration from environment'
  while IFS='=' read -r ENV_KEY
  do
    ENV_VAL="${!ENV_KEY}"

    # JG_SVC__*
    if [[ "${ENV_KEY}" =~ JG_SVC__([[:alnum:]_]+) ]]
    then
      EVAL_INDEX="${BASH_REMATCH[1]}"
      EVAL_CMD="$ENV_VAL"

      echo "update server '${EVAL_INDEX}' with '${EVAL_CMD}'"
      yq eval "${EVAL_CMD}" "${JG_SERVER_YAML}" --prettyPrint --inplace

    # JG_GRAPH__*
    elif [[ "${ENV_KEY}" =~ JG_GRAPH__([[:alnum:]]+)_([[:graph:]]+) ]] && [[ -n ${ENV_VAL} ]]
    then
      EVAL_END=${BASH_REMATCH[1]}
      EVAL_INDEX=${BASH_REMATCH[2]}
      EVAL_CMD="$ENV_VAL"

      JG_CFG_TGT="${JG_CONFIG_DIR}/janusgraph-${EVAL_END:-default}.yaml"
      if
       test ! -f "${JG_CFG_TGT}"
      then
        cp "${JG_PROPS_YAML}" "${JG_CFG_TGT}"
      fi
      echo "update graph back-end '$EVAL_END' and property eval '$ENV_VAL'"
      yq eval "${EVAL_CMD}" "${JG_CFG_TGT}" --prettyPrint --inplace

    # JG_SCRIPT__*
    elif [[ "${ENV_KEY}" =~ JG_SCRIPT__([[:alnum:]_]+) ]]
    then
      SCRIPT_NAME=${BASH_REMATCH[1]}
      SCRIPT_CONTENT="$ENV_VAL"

      echo "create gremlin script '$SCRIPT_NAME' with '$SCRIPT_CONTENT'"
      echo "${SCRIPT_CONTENT}" > "${JG_CONFIG_DIR}/${SCRIPT_NAME}.groovy"

    # other environment parameters that we are not concerned about
    else
      continue
    fi
  done < <(compgen -A variable | sort --ignore-nonprinting)

  # convert all the yaml files into equivalent java-properties files
  for graphYaml in "${JG_CONFIG_DIR}"/*.yaml
  do
    test -f "$graphYaml" || break
    graphProps="$(basename "$graphYaml" .yaml).properties"
    yq eval --output-format props "${graphYaml}" > "${graphProps}"
  done

  # show the requested information
  # JG_SHOW is a list of names
  show_array=($JG_SHOW)
  for (( ix=0; ix<${#show_array[@]}; ix++ ))
  do
    ITEM="${show_array[$ix]}"
    case "$ITEM" in
     env | environment)
      echo '== ENVIRONMENT =================================='
      env
      ;;
     server | config)
      echo '== GREMLIN SERVER ==============================='
      yq eval --prettyPrint '... comments=""' "${JG_CONFIG_DIR}/janusgraph-server.yaml"
      ;;
     graph | graphs)
      find "${JG_CONFIG_DIR}" -type f -name '*.properties' | while read -r configFile
      do
        echo '== PROPERTIES ==================================='
        echo "- file: $configFile "
        echo '-----------------------------------------------'
        sed '/^[[:space:]]*#[^!]/d
             /#$/d
             /^[[:space:]]*$/d' "$configFile"
      done
      ;;
     script | scripts | groovy)
      find "${JG_CONFIG_DIR}" -type f -name '*.groovy' | while read -r configFile
      do
        echo '== GROOVY SCRIPTS ================================'
        echo "- file: $configFile "
        echo '-----------------------------------------------'
        cat "$configFile"
      done
      ;;
     *)
       echo "== UNKNOWN ITEM ${ITEM} ========================"
      ;;
    esac
  done

  # JG_ACTION is a single command
  case "${JG_ACTION:-run}" in
   run)
    echo '==================================================='
    echo 'running and awaiting storage <' "${JG_STORAGE_TIMEOUT}"
    if
     test -n "${JG_STORAGE_TIMEOUT:-}"
    then
      yq eval '.graphs' "${JG_SERVER_YAML}" | while IFS=: read -r JG_GRAPH_NAME JG_FILE
      do
        F="$(mktemp --suffix .groovy)"
        echo 'graph = JanusGraphFactory.open(' "${JG_FILE}" ')' > "$F"
        echo 'waiting for graph database : ' "${JG_GRAPH_NAME}"
        timeout "${JG_STORAGE_TIMEOUT}s" bash -c \
          "until bin/gremlin.sh -e \"$F\" > /dev/null 2>&1; do echo \"waiting for storage: \"${JG_GRAPH_NAME}\"...\"; sleep 5; done"
        rm -f "$F"
      done
    else
      sleep 60
    fi
    /usr/local/bin/load-init-db.sh &
    exec "${JG_HOME}/bin/janusgraph-server.sh" "${JG_SERVER_YAML}"
    ;;
   *)
    echo "action unknown ${JG_ACTION} ; fail"
    ;;
  esac
fi

if
 test -n "${GREMLIN_REMOTE_HOSTS:-}"
then
  echo 'override hosts for remote connections with Gremlin Console'
  sed -i "s/hosts\s*:.*/hosts: [$GREMLIN_REMOTE_HOSTS]/" "${JG_HOME}/conf/remote.yaml"
fi

echo 'executing ' "$@"
exec "$@"
