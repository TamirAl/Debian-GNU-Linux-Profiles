#!/bin/bash
# This script is wrapped around virsh(1) to unify some actions which needs to call virsh(1) more than once.
# The script needs some advanced function provided by bash(1).

VIRSH_CMD="virsh"

# chech if we are going to use virsh remotely. This eliminates the needs to use parameter "-c".
if [[ ${1} =~ '://' ]]; then
    VIRSH_CMD="${VIRSH_CMD} -c ${1}";
    shift;
fi

# libvirt, as well as its CLI interface virsh(1), use xml as external expressions of its objects.
# In order to work with it, we need the abilities to query and modify xml documents in scripts.
# xmlstarlet(1) provides both querying and modification abilities for xml, while xmllint(1) only
# provides querying ability, so I decide to use xmlstarlet(1). You can check its manpages for
# further usage.

delete-disks-of-vm-dump () {
    # ${DUMP} is a multi-line string expressing an xml document generated by "*dumpxml" family
    # subcommand of virsh(1).
    DUMP=${*};
    # xml nodes can be accessed via xpath expressions, one of whose tutorial can be found at
    # http://www.zvon.org/xxl/XPathTutorial/ .
    COUNT=$(echo ${DUMP} | xmlstarlet sel -t -c 'count(/domain/devices/disk[@device="disk"])');
    for i in $(seq 1 ${COUNT});do
	DISKPATH=$(echo ${DUMP} | xmlstarlet sel -t -v "/domain/devices/disk[@device=\"disk\"][${i}]/source/@file");
	${VIRSH_CMD} vol-delete ${DISKPATH};
    done
}

delete-disks-of-vm () {
    VM=${1};
    DUMP=$(${VIRSH_CMD} dumpxml ${VM});
    delete-disks-of-vm-dump ${DUMP};
}

delete-vm () {
    # If xmlstarlet(1) is absent, do not produce any side effect.
    if which xmlstarlet > /dev/null; then
	VM=${1};
	#shutdown the vm.
	${VIRSH_CMD} shutdown ${VM} || true;
	#TODO check the vm to delete really shuts down.
	DUMP=$(${VIRSH_CMD} dumpxml ${VM});
	#undefine the vm
	${VIRSH_CMD} undefine ${VM};
	#delete all disks belonging to the vm
	delete-disks-of-vm-dump ${DUMP};
    else
	echo "This subcommand needs xmlstarlet. Please install it first!"
    fi
}

add-disk () {
    POOL=${1};
    NAME=${2};
    CAPACITY=${3};
    ${VIRSH_CMD} vol-create-as --pool ${POOL} --name ${NAME}.qcow2 --capacity ${CAPACITY} --format qcow2 --prealloc-metadata ${DRY};
}

upload-iso-image () {
    POOL=${1};
    IMGPATH=${2};
    # Get the filename as volume name.
    IMGNAME=$(basename ${IMGPATH});
    # A volume to accept upload can be reserved with zero byte space, for
    # space will be allocated during upload.
    ${VIRSH_CMD} vol-create-as ${POOL} ${IMGNAME} 0 --format raw;
    ${VIRSH_CMD} vol-upload --pool ${POOL} ${IMGNAME} ${IMGPATH};
}

add-vm-with-template-file () {
    if which xmlstarlet > /dev/null; then
	TEMPLATE=${1};
	NAME=${2};
	RAMSIZE=${3};
	POOL=${4};
	DISKSIZE=${5};
	ISOPATH=${6};
	ISONAME=$(basename ${ISOPATH});
	# read template file
	DUMP=$(cat ${TEMPLATE});
	# delete uuid inside template;
	# xml string can be modified within scripts with the following syntax.
	DUMP=$(echo ${DUMP}|xmlstarlet ed -d /domain/uuid);
	# modify name
	DUMP=$(echo ${DUMP}|xmlstarlet ed -u /domain/name -v ${NAME});
	# modify ramsize in KiB
	# TODO: implement a parser for capacity string with unit[KMGT].
	DUMP=$(echo ${DUMP}|xmlstarlet ed -u /domain/memory -v ${RAMSIZE});
	# generate a new mac address
	DUMP=$(echo ${DUMP}|xmlstarlet ed -u /domain/devices/interface/mac/@address -v 52:54:$(dd if=/dev/urandom count=4 2>/dev/null | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\).*$/\1:\2:\3:\4/'));
	# upload the iso image if not exist.
	${VIRSH_CMD} vol-info --pool ${POOL} ${ISONAME} || upload-iso-image ${POOL} ${ISOPATH};
	# modify iso image path
	POOLPATH=$(${VIRSH_CMD} pool-dumpxml ${POOL}|xmlstarlet sel -t -v /pool/target/path);
	DUMP=$(echo ${DUMP}|xmlstarlet ed -u "/domain/devices/disk[@device=\"cdrom\"]/source/@file" -v ${POOLPATH}/${ISONAME});
	# add a virtual disk
	add-disk ${POOL} ${NAME} ${DISKSIZE} || true;
	# get path of the virtual disk
	VOLPATH=$(${VIRSH_CMD} vol-dumpxml --pool default ${NAME}.qcow2|xmlstarlet sel -t -v /volume/target/path);
	# modify volume path
	DUMP=$(echo ${DUMP}|xmlstarlet ed -u "/domain/devices/disk[@device=\"disk\"]/source/@file" -v ${VOLPATH});
	echo ${DUMP}|${VIRSH_CMD} define /dev/stdin;
    else
	echo "This subcommand needs xmlstarlet. Please install it first!"
    fi
}

COMMAND=${1};
case ${COMMAND} in
    delete-vm)
	shift;
	delete-vm ${1};
	;;
    add-disk)
	shift;
	add-disk ${*};
	;;
    add-vm-with-template-file)
	shift;
	add-vm-with-template-file ${*};
	;;
    start-vm)
	shift;
	${VIRSH_CMD} start ${*};
	;;
    shutdown-vm)
	shift;
	${VIRSH_CMD} shutdown ${*};
	;;
    reboot-vm)
	shift;
	${VIRSH_CMD} reboot ${*};
	;;
    list-vm)
	shift;
	${VIRSH_CMD} list --all;
	;;
    upload-iso-image)
	shift;
	upload-iso-image ${*};
	;;
    *)
	# Unrecognized sub-commands are all considered as virsh(1)'s.
	${VIRSH_CMD} $*;
	;;
esac
