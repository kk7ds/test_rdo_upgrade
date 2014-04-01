hosts="$2"
if [ -z "$hosts" ]; then
    echo 'Must specify compute hosts on the command line (host1,host2)'
    exit1
fi

# Configure and run packstack from Havana
install_rdo_release havana
packstack --gen-answer-file ~/answers.txt
set_config COMPUTE_HOSTS "$hosts" ~/answers.txt
set_config NEUTRON_INSTALL n ~/answers.txt
set_config HORIZON_INSTALL n ~/answers.txt
set_config CEILOMETER_INSTALL n ~/answers.txt
set_config SWIFT_INSTALL n ~/answers.txt
set_config NAGIOS_INSTALL n ~/answers.txt
packstack --answer-file ~/answers.txt
source ~/keystonerc_admin

# Convert compute hosts list to an array
hosts=$(echo "$hosts" | sed 's/,/ /g')
hosts=($hosts)
num_hosts=${#hosts[*]}

# Create some test instances on havana
install_cirros
create_instance test-havana1
create_instance test-havana2
test_instance test-havana1
test_instance test-havana2

# Upgrade to icehouse
install_rdo_release icehouse
yum -y update

# UPGRADE HACK: https://bugzilla.redhat.com/show_bug.cgi?id=1080514
# Need to make sure python-oauthlib is installed
yum -y install python-pip
pip install oauthlib

# UPGRADE HACK: https://bugs.launchpad.net/glance/+bug/1279000
# Remove UTF-8 sanity check from glance database upgrade
sed -ri 's/^    _db_schema_sanity_check.*$//' /usr/lib/python2.6/site-packages/glance/openstack/common/db/sqlalchemy/migration.py

# UPGRADE STEP: We need to upgrade the qpid_topology on the havana compute hosts
for index in $(seq 0 $(($num_hosts - 1))); do
    fssh ${hosts[$index]} "sed -ri 's/^.*qpid_topology_version.*/qpid_topology_version=2/' /etc/nova/nova.conf && service openstack-nova-compute restart"
done

# UPGRADE STEP: We need to cap the compute RPC API version on the
# new controller infrastructure until all computes have been upgraded
set_config compute icehouse-compat /etc/nova/nova.conf

# Stop all the controller services, upgrade the database,
# and then start them back up
service_control stop nova
service_control stop keystone
service_control stop glance
service_control stop cinder
upgrade_dbs
service_control start nova
service_control start keystone
service_control start glance
service_control start cinder

# Give some time for the compute nodes to check back in
nova service-list
sleep 20
nova service-list

# Create some test instances when the controller node is on icehouse and
# all the computes are still on havana
create_instance test-icehouse1
create_instance test-icehouse2
test_instance test-icehouse1
test_instance test-icehouse2

# Upgrade the first compute node
fssh ${hosts[0]} "yum install -y ${RDO_BASE}/openstack-icehouse/rdo-release-icehouse.rpm"
fssh ${hosts[0]} "yum -y update && service openstack-nova-compute restart"

# Give some time for the compute node to check back in
nova service-list
sleep 20
nova service-list

# Create some test instances when the controller node is on icehouse,
# and the first compute host is on icehouse, but the rest are still on
# havana
create_instance test-icehouse3
create_instance test-icehouse4
test_instance test-icehouse3
test_instance test-icehouse4

# Generate a report of all the running instances and where they are,
# to allow verification that the instances are spread across computes
echo 'Instance report' > /tmp/report
echo '---------------' >> /tmp/report
instances=$(nova list | grep '[0-9a-f]-[0-9a-f]' | cut -d '|' -f 3)
for inst in $instances; do
    host=$(nova show $inst | grep hypervisor_hostname | cut -d '|' -f 3)
    echo "$inst running on $host" >> /tmp/report
done
cat /tmp/report

# Install user and host keys between all compute nodes
for host in ${hosts[*]}; do
    fssh $host "rm -Rf /var/lib/nova/.ssh && cp -r /root/.ssh /var/lib/nova/ && chown -R nova.nova /var/lib/nova/.ssh"
    fssh $host "setenforce 0; usermod -s /bin/bash nova"
done
for host in ${hosts[*]}; do
    fssh $host "for host in ${hosts[*]}; do su - nova -c 'ssh -oStrictHostKeyChecking=no \$host true'; done"
done
