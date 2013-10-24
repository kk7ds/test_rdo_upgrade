
##############################################################################
# Install the starting environment. This is not part of the upgrade,         #
# just getting us a system that we can test the upgrade process.             #
##############################################################################

install_rdo_release grizzly
ensure_openstack_kernel

do_neutron=${do_neutron:-n}
opts="--os-quantum-install=${do_neutron} --os-horizon-install=n --os-swift-install=n"
opts="$opts --nagios-install=n"
packstack --allinone $opts

source ~/keystonerc_admin
install_cirros

# Create an instance on the grizzly system, before we do any upgrades
if [ "$do_neutron" = "y" ]; then
    source ~/keystonerc_demo
fi
create_instance test-grizzly
test_instance test-grizzly

##############################################################################
# This is the beginning of the upgrade process                               #
##############################################################################

install_rdo_release havana

if [ "$do_neutron" = "y" ]; then
    services="keystone glance cinder quantum nova"
else
    services="keystone glance cinder nova"
fi

for service in $services; do
    # Stop everything for the service we're upgrading
    service_control stop $service

    # If we're upgrading quantum, the new name is neutron
    if [ "$service" = "quantum" ]; then
	service="neutron"
    fi

    # Upgrade the packages
    yum update -y "*${service}*"

    # Upgrade the database schema
    if [ "$service" = "neutron" ]; then
	upgrade_migrate_quantum_config
	upgrade_neutron_db "grizzly" "havana"
    else
	upgrade_dbs
    fi

    # Start everything back up on the new version of this service
    service_control start $service

    # Do some checks to make sure everything is happy before we proceed
    conservative_nova_check
    create_instance test-$service
    test_instance test-$service
done
