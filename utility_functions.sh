RDO_BASE="http://rdo.fedorapeople.org"
CIRROS="https://launchpad.net/cirros/trunk/0.3.0/+download/cirros-0.3.0-x86_64-disk.img"

AUTHORIZED_KEYS_FILE=$HOME/.ssh/authorized_keys
PRIVATE_KEY_FILE=$HOME/.ssh/id_rsa
PUBLIC_KEY_FILE=${PRIVATE_KEY_FILE}.pub
TIMEOUT=60

# A minimal CentOS install may not have these.
function install_requirements() {
    yum install -y wget dbus
}

# If dbus isn't running the compute service will fail to start.
function start_dbus() {
	service messagebus start
}

# Packstack seems to have a hard time getting things set up
# on its own, so the following functions set ssh access for
# root to root@localhost and check that it works.
function generate_ssh_key() {
    if ! [ -f $PRIVATE_KEY_FILE ]; then
        ssh-keygen -t rsa -b 2047 -f $PRIVATE_KEY_FILE -N ''
    fi
}

function configure_authorized_keys() {
    if ! grep -q -f $PUBLIC_KEY_FILE $AUTHORIZED_KEYS_FILE; then
        cat $PUBLIC_KEY_FILE >> $AUTHORIZED_KEYS_FILE
	chmod 600 $AUTHORIZED_KEYS_FILE
    fi
}

function test_ssh_connection() {
    if ! ssh -o StrictHostKeyChecking=no -o BatchMode=yes localhost true; then
        die "ssh connection to localhost failed."
    fi
}

function configure_ssh_keys() {
    generate_ssh_key
    configure_authorized_keys
    test_ssh_connection
}

function set_neutron_name() {
    neutron=quantum
    if rpm -q openstack-packstack > /dev/null && ! rpm -q openstack-packstack | grep -q 2013.1; then
        neutron=neutron
    fi
}

function install_rdo_release() {
    local release="$1"
    local package="rdo-release-${release}"

    if ! rpm -q $package > /dev/null; then
	yum install -y ${RDO_BASE}/openstack-${release}/${package}.rpm
    fi
    if rpm -q openstack-packstack > /dev/null; then
	yum update -y openstack-packstack
    else
	yum install -y openstack-packstack
    fi
}

function upgrade_rdo_release() {
    local which="$1"

    yum update -y "openstack-${which}*"
}

function get_packstack_answers() {
    ls ~/packstack-answers*txt 2>/dev/null | cut -d ' ' -f 1
}

function do_packstack() {
    local answers=$(get_packstack_answers)

    set_neutron_name

    if [ "$answers" -a -f "$answers" ]; then
        packstack --answer-file "$answers"
    else
        packstack --allinone --os-${neutron}-install=n
    fi
}

function merge_config_and_rerun_packstack() {
    local answers=$(get_packstack_answers)
    local line
    if [ ! -f "packstack-config.post" ]; then
	return
    fi
    cp ${answers} ${answers}.orig-grizzly
    for line in $(cat packstack-config.post); do
	local name=$(echo $line | cut -d= -f1)
	local value=$(echo $line | cut -d= -f2-)
	echo Setting ${name}=${value}
	sed -ri "s/^${name}=(.*)$/${name}=${value}/" $answers
    done
    do_packstack
}

function conservative_nova_check() {
    local api_ok
    local services_ok
    local services_orig=$(mktemp)
    local services_new=$(mktemp)

    nova-manage service list > $services_orig 2>&1

    for i in $(seq 0 10); do
	if nova list; then
	    api_ok=yes
	    break
	fi
    done

    if [ -z "$api_ok" ]; then
	die "nova-api appears dead"
    fi

    for i in $(seq 0 30); do
	nova-manage service list > $services_new 2>&1
	if diff -q $services_orig $services_new; then
	    sleep 1
	    continue
	fi
	if grep XXX $services_new; then
	    sleep 1
	    continue
	fi
	services_ok=yes
	break
    done

    rm -f $services_orig $services_new

    if [ -z "$services_ok" ]; then
	die "nova services appear dead"
    fi
}

function install_cirros() {
    if [ ! -f ~/cirros.img ]; then
	wget -O ~/cirros.img "$CIRROS"
    fi
    if ! glance image-show cirros >/dev/null 2>&1; then
	glance image-create --name cirros --is-public True \
	    --disk-format qcow2 --container-format bare < ~/cirros.img
    fi
}

function get_private_ip() {
    nova show $1 | awk '/private network/ { print $5 }' | sed 's/,//'
}

function associate_floating_ip() {
    local private_ip=$(get_private_ip $1)
    local port_id=$($neutron port-list | awk "/$private_ip/ { print \$2 }")
    local floating_ip_id=$($neutron floatingip-create public | \
        awk "/^\| id[ ]*\| / { print \$4 }")

    $neutron floatingip-associate $floating_ip_id $port_id
}

function get_floating_ip() {
    local private_ip=$(get_private_ip $1)
    $neutron floatingip-list | awk "/$private_ip/ { print \$6 }"
}

function create_instance_with_floatingip() {
    local name="$1"

    create_instance $name
    associate_floating_ip $name
}

function create_instance() {
    local name="$1"

    nova delete "$name" || true
    nova boot --poll --image cirros --flavor 1 "$name"
}

function die() {
    local reason="$*"
    echo "ERROR: $reason" >&2
    exit 1
}

function try_instance() {
    local cmd="$1"
    local i
    for i in $(seq 0 $TIMEOUT); do
	($cmd) >/dev/null 2>&1 && return 0
	sleep 1
    done
    return 1
}    

function check_instance_console() {
    local name="$1"
    nova console-log "$name" | grep cubswin
}

function test_instance_floating_ip() {
    local name="$1"
    local floating_ip=$(get_floating_ip $name)
    _test_instance $name $floating_ip
}

function test_instance() {
    local ipaddr=$(nova show "$1" | grep network | cut -d '|' -f 3)
    _test_instance $1 $ipaddr
}

function _test_instance() {
    local name="$1"
    local ipaddr="$2"

    try_instance "ping -c1 $ipaddr" || {
        die 'Failed to ping test instance at $ipaddr'
    }
    try_instance "check_instance_console $name" || {
        die 'Failed to connect to test instance console'
    }
    nova diagnostics $name >/tmp/diags 2>&1 || {
	die 'Failed to retrieve diagnostics for instance'
    }
    echo "*** Test instance $name looks OK ***"
}

function destroy_instance() {
    local name="$1"
    nova delete "$name"
}

function service_control() {
    local action="$1"
    local service="$2"
    local svc
    local pattern="openstack-${service}.*3:on"
    if [ "x$service" == "xneutron" -o "x$service" == "xquantum" ]; then
        pattern="${service}.*3:on"
    fi
    for svc in $(chkconfig --list | grep $pattern | \
	    awk '{print $1}'); do
	service $svc "$action"
    done
}

function ensure_openstack_kernel() {
    if ! uname -r | grep -q openstack; then
	yum upgrade -y kernel
	echo '******************************************'
	echo '* A reboot is required before continuing *'
	echo '******************************************'
	exit 1
    fi
}

function fssh() {
    ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $1 "$2"
}

function set_config() {
    local key="$1"
    local val="$2"
    local file="$3"
    sed -ri "s#\#?${key}=.*#${key}=${val}#" $file
}
