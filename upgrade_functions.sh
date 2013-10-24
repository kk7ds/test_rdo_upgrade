function upgrade_dbs() {
    local service
    for service in nova glance cinder keystone; do
	if ${service}-manage --help 2>&1 | grep -q upgrade; then
	    ${service}-manage upgrade
	elif ${service}-manage --help 2>&1 | grep -q db_sync; then
	    ${service}-manage db_sync
	else
	    ${service}-manage db sync
	fi
    done
}

function upgrade_neutron_db() {
    local from="$1"
    local to="$2"

    neutron-db-manage --config-file=/etc/neutron/neutron.conf \
	--config-file /etc/neutron/plugin.ini stamp "$from"
    neutron-db-manage --config-file=/etc/neutron/neutron.conf \
	--config-file /etc/neutron/plugin.ini upgrade "$to"
}

function upgrade_add_sheepdog() {
    yum install -y sheepdog
}

function upgrade_packstack_config() {
    local answers=$(get_packstack_answers)

    # Convert QUANTUM -> NEUTRON configs
    sed -ri 's/CONFIG_QUANTUM/CONFIG_NEUTRON/' $answers

    # Add config elements that havana packstack wants to see
    # These are defaults that might not be right
    cat >> $answers <<EOF
CONFIG_MYSQL_INSTALL=y
CONFIG_CEILOMETER_INSTALL=n
CONFIG_HEAT_INSTALL=n
CONFIG_CINDER_BACKEND=lvm
CONFIG_NOVA_NETWORK_MANAGER=nova.network.manager.FlatDHCPManager
CONFIG_HEAT_CLOUDWATCH_INSTALL=n
CONFIG_HEAT_CFN_INSTALL=n
EOF
    }

function upgrade_other_computes() {
    local answers=$(get_packstack_answers)
    local computes=$(grep 'COMPUTE_HOSTS' $answers | cut -d= -f2 | sed 's/,/ /')
    local me=$(grep 'NOVA_API_HOST' $answers | cut -d= -f2)
    local pkgs="openstack-nova-compute python-oslo-config"
    local compute
    for compute in $computes; do
	if [ "$compute" = "$me" ]; then
	    echo Skipping myself
	else
	    echo HACK: Upgrading packages on $compute
	    ssh -oStrictHostKeyChecking=no $compute "yum upgrade -y openstack-nova-compute && service openstack-nova-compute restart"
	fi
    done
}

function upgrade_migrate_quantum_config() {
    cp -f /etc/quantum/quantum.conf.rpmsave /etc/neutron/neutron.conf
    local plugin=$(readlink -f /etc/quantum/plugin.ini)
    plugin="${plugin}.rpmsave"
    rm -f /etc/neutron/plugin.ini
    cp $plugin /etc/neutron/plugin.ini
}