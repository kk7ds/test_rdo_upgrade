#!/bin/bash -ex

basedir=$(dirname `readlink -f $0`)

source ${basedir}/utility_functions.sh
source ${basedir}/upgrade_functions.sh

if [ -f "${basedir}/local.sh" ]; then
    source ${basedir}/local.sh
fi

function usage() {
    echo "usage: test_rdo_upgrade [scenario]"
    exit 1
}

# NOTE(dansmith): bug 1006484: Disable SELinux for glance-2012.2
setenforce 0

install_requirements
start_dbus
configure_ssh_keys

if [ -z "$1" ]; then
    usage
fi

scenario_file="${basedir}/scenarios/${1}.sh"
if [ ! -f  "$scenario_file" ]; then
    echo "Scenario \`$1' not found"
    usage
fi

source $scenario_file
