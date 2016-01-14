#!/bin/bash

#set -ex

sudo pip install python-heatclient
sudo pip install oslo.config

# Environment Binding
$PUBLIC_CLOUD_CREDENTIALS

if [[ "$RPC_RELEASE" == "juno" ]]; then
    RPC_SERIES="10.1"
elif [[ "$RPC_RELEASE" == "kilo" ]]; then
    RPC_SERIES="11.1"
elif [[ "$RPC_RELEASE" == "master" ]]; then
    RPC_SERIES="11.1"
else
    RPC_SERIES=`echo $RPC_RELEASE | sed 's/^r//g' | awk -F '[\.]' '{ print $1 "." $2 }'`
fi

STACK_NAME=rpc-jenkins-$BUILD_NUMBER-install-`echo $RPC_RELEASE | sed 's/\./-/g'`-$HEAT_ENVIRONMENT

heat stack-create -t 240 -f templates/rpc-$HEAT_TEMPLATE.yml -e environments/rpc-$RPC_SERIES-$HEAT_ENVIRONMENT.yml -e $HEAT_ENVIRONMENT_MAAS_CREDENTIALS -P rpc_release=$RPC_RELEASE -P rpc_heat_ansible_release=$RPC_HEAT_ANSIBLE_RELEASE $STACK_NAME

BUILD_COMPLETED=0
BUILD_FAILED=0

until [[ $BUILD_COMPLETED -eq 1 ]]; do
  sleep 120
  STACK_STATUS=`heat stack-list | awk '/ '$STACK_NAME' / { print $6 }'`
  RESOURCES_FAILED=`heat resource-list $STACK_NAME | grep CREATE_FAILED | wc -l`
  SWIFT_SIGNAL_FAILED=`heat event-list $STACK_NAME | grep SwiftSignalFailure | wc -l`
  if [[ "$STACK_STATUS" == 'CREATE_COMPLETE' || "$STACK_STATUS" == 'CREATE_FAILED' || $RESOURCES_FAILED -gt 0 ]]; then
    BUILD_COMPLETED=1
  fi
  if [[ "$STACK_STATUS" == 'CREATE_FAILED' || $RESOURCES_FAILED -gt 0 ]]; then
    BUILD_FAILED=1
  fi
  echo "===================================================="
  echo "Stack Status:        $STACK_STATUS"
  echo "Build Completed:     $BUILD_COMPLETED"
  echo "Build Failed:        $BUILD_FAILED"
  echo "Resources Failed:    $RESOURCES_FAILED"
  echo "Swift Signal Failed: $SWIFT_SIGNAL_FAILED"
done

if [[ $BUILD_FAILED -eq 1 ]]; then
  echo "===================================================="
  heat stack-list
  echo "===================================================="
  heat resource-list $STACK_NAME | grep -v CREATE_COMPLETE
  echo "===================================================="
  heat event-list $STACK_NAME
fi

if [[ $BUILD_FAILED -eq 1 && $SWIFT_SIGNAL_FAILED -gt 0 || ( $BUILD_FAILED -eq 0 ) ]]; then
  INFRA1_IP=`heat output-show $STACK_NAME server_infra1_ip -F raw`
  heat output-show $STACK_NAME private_key -F raw > $STACK_NAME.pem
  chmod 400 $STACK_NAME.pem
  scp -i $STACK_NAME.pem -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$INFRA1_IP:/opt/cloud-training/*.log .
  scp -i $STACK_NAME.pem -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$INFRA1_IP:/opt/cloud-training/*.err .
  scp -i $STACK_NAME.pem -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$INFRA1_IP:/var/log/cloud-init-output.log .
  echo "===================================================="
  echo "Failed Tasks"
  grep "failed: " *.log
  echo "===================================================="
  echo "Fatal Tasks"
  grep "fatal: " *.log
fi

BUILD_DELETED=1
heat stack-delete $STACK_NAME

until [[ $BUILD_DELETED -eq 0 ]]; do
  sleep 30
  STACK_STATUS=`heat stack-list | awk '/ '$STACK_NAME' / { print $6 }'`
  BUILD_DELETED=`heat stack-list | awk '/ '$STACK_NAME' / { print $6 }' | wc -l`
  echo "===================================================="
  echo "Stack Status:        $STACK_STATUS"
  echo "Build Deleted:       $BUILD_DELETED"
  if [[ "$STACK_STATUS" != 'DELETE_IN_PROGRESS' ]]; then
    heat stack-delete $STACK_NAME
  fi
done

exit $BUILD_FAILED
