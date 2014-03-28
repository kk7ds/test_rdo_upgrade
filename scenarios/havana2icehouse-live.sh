
install_rdo_release havana

hosts="$2"
if [ -z "$hosts" ]; then
    echo 'Must specify compute hosts on the command line (host1,host2)'
    exit1
fi

opts="--os-neutron-install=n --os-horizon-install=n --os-swift-install=n"
opts="$opts --novacompute-hosts=$hosts"
packstack --gen-answer-file ~/answers.txt
cp ~/answers.txt ~/orig-answers.txt
sed -ri "s/COMPUTE_HOSTS=.*$/COMPUTE_HOSTS=$hosts/" ~/answers.txt
sed -ri 's/NEUTRON_INSTALL=.*/NEUTRON_INSTALL=n/' ~/answers.txt
sed -ri 's/HORIZON_INSTALL=.*/HORIZON_INSTALL=n/' ~/answers.txt
sed -ri 's/CEILOMETER_INSTALL=.*/CEILOMETER_INSTALL=n/' ~/answers.txt
sed -ri 's/SWIFT_INSTALL=.*/SWIFT_INSTALL=n/' ~/answers.txt
sed -ri 's/NAGIOS_INSTALL=.*/NAGIOS_INSTALL=n/' ~/answers.txt
packstack --answer-file ~/answers.txt

hosts=$(echo "$hosts" | sed 's/,/ /g')
hosts=($hosts)
num_hosts=${#hosts[*]}

source ~/keystonerc_admin

install_cirros

create_instance test-havana1
create_instance test-havana2
test_instance test-havana1
test_instance test-havana2

install_rdo_release icehouse

yum -y update

# HACK: https://bugzilla.redhat.com/show_bug.cgi?id=1080514
yum -y install python-pip
pip install oauthlib

# HACK: https://bugs.launchpad.net/glance/+bug/1279000
sed -ri 's/^    _db_schema_sanity_check.*$//' /usr/lib/python2.6/site-packages/glance/openstack/common/db/sqlalchemy/migration.py

# HACK: We need to upgrade the qpid_topology on the havana compute hosts
for index in $(seq 0 $(($num_hosts - 1))); do
    fssh ${hosts[$index]} "sed -ri 's/^.*qpid_topology_version.*/qpid_topology_version=2/' /etc/nova/nova.conf && service openstack-nova-compute restart"
done

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

create_instance test-icehouse1
create_instance test-icehouse2
test_instance test-icehouse1
test_instance test-icehouse2

# Upgrade the first compute node
fssh ${hosts[0]} "yum install -y ${RDO_BASE}/openstack-icehouse/rdo-release-icehouse.rpm"
fssh ${hosts[0]} "yum -y update && service openstack-nova-compute restart"

nova service-list
sleep 20
nova service-list

create_instance test-icehouse3
create_instance test-icehouse4
test_instance test-icehouse3
test_instance test-icehouse4

echo 'Instance report' > /tmp/report
echo '---------------' >> /tmp/report
instances=$(nova list | grep '[0-9a-f]-[0-9a-f]' | cut -d '|' -f 3)
for inst in $instances; do
    host=$(nova show $inst | grep hypervisor_hostname | cut -d '|' -f 3)
    echo "$inst running on $host" >> /tmp/report
done
cat /tmp/report
