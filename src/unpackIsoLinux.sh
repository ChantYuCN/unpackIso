#!/bin/bash

function log_debug {
    if [ ! -z "${LOG_DEBUG}" ]; then
        logger -p debug -t "$0[${PPID}]" -s "$@" 2>&1
    fi
}

function log_error {
    logger -p error -t "$0[${PPID}]" -s "$@"
}


function log {
    logger -p info -t "$0[${PPID}]" -s "$@" 2>&1
}


function print_status {
    if [ "$1" -eq "0" ]; then
        echo "[  OK  ]"
    else
        echo "[FAILED]"
    fi
}


function usage {
    cat <<ENDUSAGE
Usage:
   $(basename $0) -i <input bootimage.iso> -
   chant debug isolinux.cfg
   
   output files:
        isolinux-check.cfg
		structure.log
		syslinux-check.cfg
   
ENDUSAGE
}


function unmount_iso {
    if [ $UID -eq 0 ]; then
        umount ${MNTDIR}
    else
        guestunmount ${MNTDIR}
    fi
    rmdir ${MNTDIR}
}


function unmount_efiboot_img {
    if [ $UID -eq 0 ]; then
        if [ -n "${EFI_MOUNT}" ]; then
            mountpoint -q ${EFI_MOUNT} && umount ${EFI_MOUNT}
            rmdir ${EFI_MOUNT}
            EFI_MOUNT=
        fi

        if [ -n "${EFIBOOT_IMG_LOOP}" ]; then
            losetup -d ${EFIBOOT_IMG_LOOP}
            EFIBOOT_IMG_LOOP=
        fi
    else
        if [ -n "${EFIBOOT_IMG_LOOP}" ]; then
            udisksctl unmount -b ${EFIBOOT_IMG_LOOP}
            udisksctl loop-delete -b ${EFIBOOT_IMG_LOOP}
            EFI_MOUNT=
            EFIBOOT_IMG_LOOP=
        fi
    fi
}

function common_cleanup {
    unmount_efiboot_img

    if [ -n "$MNTDIR" -a -d "$MNTDIR" ]; then
        unmount_iso
    fi

    if [ -n "$BUILDDIR" -a -d "$BUILDDIR" ]; then
        \rm -rf $BUILDDIR
    fi

    if [ -n "$WORKDIR" -a -d "$WORKDIR" ]; then
        \rm -rf $WORKDIR
    fi
}

function common_check_requirements {
    local -a required_utils=(
        rsync
        mkisofs
        isohybrid
        implantisomd5
    )
    if [ $UID -ne 0 ]; then
        # If running as non-root user, additional utils are required
        required_utils+=(
            guestmount
            guestunmount
            udisksctl
        )
    fi

    local -i missing=0

    for req in ${required_utils[@]}; do
        which ${req} >&/dev/null
        if [ $? -ne 0 ]; then
            log_error "Unable to find required utility: ${req}"
            let -i missing++
        fi
    done

    if [ ${missing} -gt 0 ]; then
        log_error "One or more required utilities are missing. Aborting..."
        exit 1
    fi
}

function check_required_param {
    local param="${1}"
    local value="${2}"

    if [ -z "${value}" ]; then
        log_error "Required parameter ${param} is not set"
        exit 1
    fi
}


function check_requirements {
    common_check_requirements
}

function cleanup {
    common_cleanup
}

function mount_iso {
    local input_iso=$1

    MNTDIR=$(mktemp -d -p $PWD stx-iso-utils_mnt_XXXXXX)
    if [ -z "${MNTDIR}" -o ! -d ${MNTDIR} ]; then
        log_error "Failed to create mntdir. Aborting..."
        exit 1
    fi

    if [ $UID -eq 0 ]; then
        # Mount the ISO
        mount -o loop ${input_iso} ${MNTDIR}
        if [ $? -ne 0 ]; then
            echo "Failed to mount ${input_iso}" >&2
            exit 1
        fi
    else
        # As non-root user, mount the ISO using guestmount
        guestmount -a ${input_iso} -m /dev/sda1 --ro ${MNTDIR}
        rc=$?
        if [ $rc -ne 0 ]; then
            # Add a retry
            echo "Call to guestmount failed with rc=$rc. Retrying once..."

            guestmount -a ${input_iso} -m /dev/sda1 --ro ${MNTDIR}
            rc=$?
            if [ $rc -ne 0 ]; then
                echo "Call to guestmount failed with rc=$rc. Aborting..."
                exit $rc
            fi
        fi
    fi
}



while getopts "hi:o:a:p:d:t:" opt; do
    case $opt in
        i)
            INPUT_ISO=$OPTARG
            ;;

        *)
            usage
            exit 1
            ;;
    esac
done


function get_parameter {
    local isodir=$1

    echo "chant debug 3"

    echo "chant ls"
    tree  ${isodir} >> structure.log
    echo "chant isolinux"
    cat ${isodir}/isolinux.cfg >> ./isolinux-check.cfg
    echo "chant syslinux"
    cat ${isodir}/syslinux.cfg >> ./syslinux-check.cfg
}


check_requirements
check_required_param "-i" "${INPUT_ISO}"
if [ ! -f ${INPUT_ISO} ]; then
    echo "Input file does not exist: ${INPUT_ISO}"
    exit 1
fi
trap cleanup EXIT

BUILDDIR=$(mktemp -d -p $PWD updateiso_build_XXXXXX)
echo "chant debug 1"
echo ${BUILDDIR}
if [ -z "${BUILDDIR}" -o ! -d ${BUILDDIR} ]; then
    echo "Failed to create builddir. Aborting..."
    exit $rc
fi

mount_iso ${INPUT_ISO}

echo "chant debug 2"
echo ${MNTDIR}
rsync -a ${MNTDIR}/ ${BUILDDIR}/
rc=$?
if [ $rc -ne 0 ]; then
    echo "Call to rsync ISO content. Aborting..."
    exit $rc
fi

unmount_iso

get_parameter ${BUILDDIR}
