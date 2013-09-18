RDO_BASE="http://rdo.fedorapeople.org"
CIRROS="https://launchpad.net/cirros/trunk/0.3.0/+download/cirros-0.3.0-x86_64-disk.img"

function install_rdo_release() {
    local release="$1"

    yum install -y ${RDO_BASE}/openstack-${release}/rdo-release-${release}.rpm
    if rpm -q openstack-packstack > /dev/null; then
	yum update -y openstack-*
    else
	yum install -y openstack-packstack
    fi
}

function do_packstack() {
    answers=$(ls ~/packstack-answers*txt 2>/dev/null | cut -d ' ' -f 1)
    if rpm -q openstack-packstack | grep -q 2013.1; then
	neutron=quantum
    else
	neutron=neutron
    fi

    if [ "$answers" -a -f "$answers" ]; then
	packstack --answer-file "$answers"
    else
	packstack --allinone --os-${neutron}-install=n
    fi
}

function create_instance() {
    local name="$1"

    if [ ! -f ~/cirros.img ]; then
	wget -O ~/cirros.img "$CIRROS"
    fi

    if ! glance image-show cirros >/dev/null 2>&1; then
	glance image-create --name cirros --is-public True \
	    --disk-format qcow2 --container-format bare < ~/cirros.img
    fi

    nova delete "$name"
    nova boot --poll --image cirros --flavor 1 "$name"
}

function die() {
    reason="$*"
    echo "ERROR: $reason" >&2
    exit 1
}

function try_instance() {
    cmd="$1"
    for i in $(seq 0 20); do
	($cmd) >/dev/null 2>&1 && return 0
	sleep 1
    done
    return 1
}    

function check_instance_console() {
    local name="$1"
    nova console-log "$name" | grep cubswin
}

function test_instance() {
    local name="$1"
    ipaddr=$(nova show "$name" | grep network | cut -d '|' -f 3)
    try_instance "ping -c1 $ipaddr" || {
	die 'Failed to ping test instance at $ipaddr'
    }
    try_instance "check_instance_console $name" || {
	die 'Failed to connect to test instance console'
    }
    echo "*** Test instance $name looks OK ***"
}

function destroy_instance() {
    local name="$1"
    nova delete "$name"
}

function service_control() {
    action="$1"
    for service in $(chkconfig --list | grep 'openstack.*3:on' | awk '{print $1}'); do
	service $service "$action"
    done
}

