function upgrade_dbs() {
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

function upgrade_add_sheepdog() {
    yum install -y sheepdog
}