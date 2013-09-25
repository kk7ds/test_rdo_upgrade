#!/bin/bash -ex

basedir=$(dirname `readlink -f $0`)

source ${basedir}/utility_functions.sh
source ${basedir}/upgrade_functions.sh

# NOTE(dansmith): bug 1006484: Disable SELinux for glance-2012.2
setenforce 0

install_requirements
start_dbus
configure_ssh_keys

# Install the RDO repositories
install_rdo_release grizzly

# Install openstack with packstack
do_packstack
merge_config_and_rerun_packstack

# Gain credentials and create/test a VM
source ~/keystonerc_admin
create_instance test-grizzly
test_instance test-grizzly

# Shut down everything and upgrade to havana packages
service_control stop
install_rdo_release havana

# Do Grizzly->Havana upgrades
upgrade_dbs
upgrade_add_sheepdog
upgrade_packstack_config
do_packstack
upgrade_other_computes

# Start everything back up, test the original VM and create/test another
service_control start
test_instance test-grizzly
create_instance test-havana
test_instance test-havana
