install_rdo_release grizzly

opts="--os-quantum-install=n --os-horizon-install=n --os-swift-install=n"
opts="$opts --nagios-install=n"
packstack --allinone $opts

source ~/keystonerc_admin
create_instance test-grizzly
test_instance test-grizzly

install_rdo_release havana

for service in keystone glance cinder nova; do
    service_control stop $service
    yum update -y "*${service}*"
    upgrade_dbs
    service_control start $service
    conservative_nova_check
    create_instance test-$service
    test_instance test-$service
done
