#!/bin/bash -e

LOCALPATH=$(pwd)
OUT=${LOCALPATH}/out
TOOLPATH=${LOCALPATH}/rkbin/tools
EXTLINUXPATH=${LOCALPATH}/build/extlinux
CHIP=""
TARGET=""
ROOTFS_PATH=""
CONFIG=${OUT}/config.img

PATH=$PATH:$TOOLPATH

source $LOCALPATH/build/partitions.sh

usage() {
	echo -e "\nUsage: build/mk-image.sh -c rk3288 -t system -r rk-rootfs-build/linaro-rootfs.img \n"
	echo -e "       build/mk-image.sh -c rk3288 -t boot\n"
}
finish() {
	echo -e "\e[31m MAKE IMAGE FAILED.\e[0m"
	exit -1
}
trap finish ERR

OLD_OPTIND=$OPTIND
while getopts "c:t:r:h" flag; do
	case $flag in
		c)
			CHIP="$OPTARG"
			;;
		t)
			TARGET="$OPTARG"
			;;
		r)
			ROOTFS_PATH="$OPTARG"
			;;
	esac
done
OPTIND=$OLD_OPTIND

if [ ! -f "${EXTLINUXPATH}/${CHIP}.conf" ]; then
	CHIP="rk3288"
fi

if [ ! $CHIP ] && [ ! $TARGET ]; then
	usage
	exit
fi

generate_boot_image() {
	BOOT=${OUT}/boota.img
	BOOT2=${OUT}/bootb.img
	rm -rf ${BOOT} ${BOOT2} ${CONFIG}

	echo -e "\e[36m Generate Boot image start\e[0m"

	# 100 Mb
	mkfs.vfat -n "boota" -S 512 -C ${BOOT} $((100 * 1024))

	mmd -i ${BOOT} ::/extlinux
	mcopy -i ${BOOT} -s ${EXTLINUXPATH}/${CHIP}.conf ::/extlinux/extlinux.conf
	mcopy -i ${BOOT} -s ${OUT}/kernel/* ::

	if [ "${MULTIROOTFS}" == "1" ];  then
		echo "Boot2 enabled"
		mkfs.vfat -n "bootb" -S 512 -C ${BOOT2} $((100 * 1024))
		mmd -i ${BOOT2} ::/extlinux
		sed 's/b921/c921/' ${EXTLINUXPATH}/${CHIP}.conf > /tmp/_extlinux.conf
		mcopy -i ${BOOT2} -s /tmp/_extlinux.conf ::/extlinux/extlinux.conf
		mcopy -i ${BOOT2} -s ${OUT}/kernel/* ::
		rm /tmp/_extlinux.conf
		dd if=/dev/zero of=${CONFIG} bs=1M count=0 seek=250
		mkfs.ext4 ${CONFIG}
		mkdir /tmp/mnt-config
		sudo mount ${CONFIG} /tmp/mnt-config
		sudo touch /tmp/mnt-config/boot_a
		sudo umount ${CONFIG}
		rmdir /tmp/mnt-config
	fi

	echo -e "\e[36m Generate Boot image : ${BOOT} success! \e[0m"
}

generate_system_image() {
	if [ ! -f "${OUT}/boota.img" ]; then
		echo -e "\e[31m CAN'T FIND BOOT IMAGE \e[0m"
		usage
		exit
	fi

	if [ ! -f "${ROOTFS_PATH}" ]; then
		echo -e "\e[31m CAN'T FIND ROOTFS IMAGE \e[0m"
		usage
		exit
	fi

	SYSTEM=${OUT}/system.img
	rm -rf ${SYSTEM}

	echo "Generate System image : ${SYSTEM} !"

	# last dd rootfs will extend gpt image to fit the size,
	# but this will overrite the backup table of GPT
	# will cause corruption error for GPT
	IMG_ROOTFS_SIZE=$(stat -L --format="%s" ${ROOTFS_PATH})
	if [ "${MULTIROOTFS}" == "1" ];  then
		IMG_ROOTFS_SIZE=$(expr ${IMG_ROOTFS_SIZE} \* 2)
		_IMG_CONFIG_SIZE=$(stat -L --format="%s" ${CONFIG})
		IMG_CONFIG_SIZE=$(expr ${_IMG_CONFIG_SIZE} \/ 512)
		# all these vars are sectors!!!
		GPTIMG_MIN_SIZE=$(expr $IMG_ROOTFS_SIZE + \( ${LOADER1_SIZE} + ${RESERVED1_SIZE} + ${RESERVED2_SIZE} + ${LOADER2_SIZE} + ${ATF_SIZE} + \( ${BOOT_SIZE} \* 2 \) + ${IMG_CONFIG_SIZE} + 35 \) \* 512)
	else
		# all these vars are sectors!!!
		GPTIMG_MIN_SIZE=$(expr $IMG_ROOTFS_SIZE + \( ${LOADER1_SIZE} + ${RESERVED1_SIZE} + ${RESERVED2_SIZE} + ${LOADER2_SIZE} + ${ATF_SIZE} + ${BOOT_SIZE} + 35 \) \* 512)
	fi
	GPT_IMAGE_SIZE=$(expr $GPTIMG_MIN_SIZE \/ 1024 \/ 1024 + 500)

	echo IMG_ROOTFS_SIZE=${IMG_ROOTFS_SIZE}
	echo LOADER1_SIZE=${LOADER1_SIZE}
	echo RESERVED1_SIZE=${RESERVED1_SIZE}
	echo RESERVED2_SIZE=${RESERVED2_SIZE}
	echo LOADER2_SIZE=${LOADER2_SIZE}
	echo ATF_SIZE=${ATF_SIZE}
	echo BOOT_SIZE=${BOOT_SIZE}
	echo IMG_CONFIG_SIZE=${IMG_CONFIG_SIZE}
	echo GPT_IMAGE_SIZE=${GPT_IMAGE_SIZE}
	echo GPTIMG_MIN_SIZE=${GPTIMG_MIN_SIZE}

	dd if=/dev/zero of=${SYSTEM} bs=1M count=0 seek=$GPT_IMAGE_SIZE

	parted -s ${SYSTEM} mklabel gpt
	parted -s ${SYSTEM} unit s mkpart loader1 ${LOADER1_START} $(expr ${RESERVED1_START} - 1)
	# parted -s ${SYSTEM} unit s mkpart reserved1 ${RESERVED1_START} $(expr ${RESERVED2_START} - 1)
	# parted -s ${SYSTEM} unit s mkpart reserved2 ${RESERVED2_START} $(expr ${LOADER2_START} - 1)
	parted -s ${SYSTEM} unit s mkpart loader2 ${LOADER2_START} $(expr ${ATF_START} - 1)
	parted -s ${SYSTEM} unit s mkpart trust ${ATF_START} $(expr ${BOOT_START} - 1)
	parted -s ${SYSTEM} unit s mkpart boota ${BOOT_START} $(expr ${ROOTFS_START} - 1)
	parted -s ${SYSTEM} set 4 boot on
	if [ "${MULTIROOTFS}" == "1" ];  then
		parted -s ${SYSTEM} unit s mkpart rootfs1 ${ROOTFS_START} $(expr ${BOOT2_START} - 1)
		parted -s ${SYSTEM} unit s mkpart bootb ${BOOT2_START} $(expr ${ROOTFS2_START} - 1)
		parted -s ${SYSTEM} unit s mkpart rootfs2 ${ROOTFS2_START} $(expr ${ROOTFS2_START} + ${ROOT_SIZE} - 1)
		parted -s ${SYSTEM} unit s mkpart cfg ${CONFIG_START} $(expr ${CONFIG_START} + ${IMG_CONFIG_SIZE} - 1)
	else
		parted -s ${SYSTEM} -- unit s mkpart rootfs ${ROOTFS_START} -34s
	fi

	if [ "$CHIP" == "rk3328" ] || [ "$CHIP" == "rk3399" ]; then
		ROOT_UUID="B921B045-1DF0-41C3-AF44-4C6F280D3FAE"
		if [ "${MULTIROOTFS}" == "1" ];  then
			ROOT2_UUID="C921B045-1DF0-41C3-AF44-4C6F280D3FAE"
			CONFIG_UUID="D921B045-1DF0-41C3-AF44-4C6F280D3FAE"
		fi
	else
		ROOT_UUID="69DAD710-2CE4-4E3C-B16C-21A1D49ABED3"
	fi

	gdisk ${SYSTEM} <<EOF
x
c
5
${ROOT_UUID}
w
y
EOF
	if [ "${MULTIROOTFS}" == "1" ];  then
		gdisk ${SYSTEM} <<EOF
x
c
7
${ROOT2_UUID}
x
c
8
${CONFIG_UUID}
w
y
EOF
	fi

	# burn u-boot
	echo "Writing u-boot unto system image"
	if [ "$CHIP" == "rk3288" ] || [ "$CHIP" == "rk322x" ] || [ "$CHIP" == "rk3036" ]; then
		dd if=${OUT}/u-boot/idbloader.img of=${SYSTEM} seek=${LOADER1_START} conv=notrunc
	elif [ "$CHIP" == "rk3399" ]; then
		dd if=${OUT}/u-boot/idbloader.img of=${SYSTEM} seek=${LOADER1_START} conv=notrunc

		dd if=${OUT}/u-boot/uboot.img of=${SYSTEM} seek=${LOADER2_START} conv=notrunc
		dd if=${OUT}/u-boot/trust.img of=${SYSTEM} seek=${ATF_START} conv=notrunc
	elif [ "$CHIP" == "rk3328" ]; then
		dd if=${OUT}/u-boot/idbloader.img of=${SYSTEM} seek=${LOADER1_START} conv=notrunc

		dd if=${OUT}/u-boot/uboot.img of=${SYSTEM} seek=${LOADER2_START} conv=notrunc
		dd if=${OUT}/u-boot/trust.img of=${SYSTEM} seek=${ATF_START} conv=notrunc
	fi

	# burn boot image
	echo "Writing boot.img unto system image"
	dd if=${OUT}/boota.img of=${SYSTEM} conv=notrunc seek=${BOOT_START}
	if [ "${MULTIROOTFS}" == "1" ];  then
		echo "Writing boot2 unto system image"
		dd if=${OUT}/bootb.img of=${SYSTEM} conv=notrunc seek=${BOOT2_START}
	fi

	# burn rootfs image
	echo "Writing rootfs unto system image"
	dd if=${ROOTFS_PATH} of=${SYSTEM} conv=notrunc,fsync seek=${ROOTFS_START}
	if [ "${MULTIROOTFS}" == "1" ];  then
		echo "Writing rootfs2 unto system image"
		dd if=${ROOTFS_PATH} of=${SYSTEM} conv=notrunc,fsync seek=${ROOTFS2_START}
		echo "Writing config unto system image"
		dd if=${CONFIG} of=${SYSTEM} conv=notrunc,fsync seek=${CONFIG_START}
	fi
}

if [ "$TARGET" = "boot" ]; then
	generate_boot_image
elif [ "$TARGET" == "system" ]; then
	generate_system_image
fi
