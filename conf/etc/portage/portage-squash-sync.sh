#!/usr/bin/env bash

# This script updates the gentoo portage tree by calling `emaint -a sync`
# or emerge-webrsync and stores it in a compressed squashfs snapshot
# copied on tmpfs.
# Updates happen in RAM using an overlayfs.
#
# Setup instructions:
#
# /etc/fstab should have the following line:
# ${portage_tmp_sqfs} ${portdir} squashfs ro,loop,defaults,nosuid,nodev,noexec,noauto 0 0
#
# /etc/local.d/10-mount-portage-squashfs.start shoud also be created, made executable
# and contain the following (replace the variables):
#
# #!/bin/sh
# cp ${portage_sqfs} ${portage_tmp_sqfs} && mount ${portdir}


# Gentoo portage main tree location
portdir="$(portageq get_repo_path / gentoo)"

# The portage tmpdir usually created in a tmpfs to store temporary stuff
tmpdir="$(portageq envvar PORTAGE_TMPDIR)/portage"

# Where to store the SquashFS file on disk
portage_sqfs="/var/lib/portage/portage.sqfs"

# Where to store the squashfs in tmpfs for faster access
portage_tmp_sqfs="${tmpdir}/portage.sqfs"

# Store temporary overlayFS within portage temp directory
overlay_dir="${tmpdir}/portage.overlay"
overlay_workdir="${overlay_dir}_work"
overlay_label="gentoo_overlay"

# Test if squashed portage is mounted
is_portage_mounted() {
    mount -t squashfs | grep -q "${portdir}"
}

# Test if overlayfs is mounted
is_overlay_mounted() {
    mount -t overlay | grep -q "${overlay_label}"
}

# Unmount the portage tree
unmount_portage() {
    is_portage_mounted \
        && umount "${portdir}" \
        && echo "Unmounted ${portdir}"
}

# Mount the portage tree
mount_portage() {
    ! is_portage_mounted \
        && mount "${portdir}" \
        && echo "Mounted ${portdir}"
}

# Unmount overlayfs
unmount_overlay() {
    is_overlay_mounted \
        && umount "${overlay_label}" \
        && rm -rf "${overlay_dir}" "${overlay_workdir}" \
        && echo "Unmounted Overlay FS"
}

# Restore state when cancelled
cleanup() {
    unmount_overlay
    mount_portage
    rm -f "${portage_sqfs}.new"
    exit 1
}

# Stop the process when encountering a non recoverable error
die() {
    echo -e "\033[1;31m${*}\033[0m"
    cleanup
}

# Mount overlay to permit update
mount_overlay() {
    # this may not work on invocation, this is ok
    mount_portage

    # create an overlay mount the overlay on top of existing live portage tree
    mkdir -p "${overlay_dir}" \
        || die "Could not create ${overlay_dir}"
    mkdir -p "${overlay_workdir}" \
        || die "Could not create ${overlay_workdir}"

    if ! is_overlay_mounted; then
        mount -t overlay "${overlay_label}" \
               -olowerdir="${portdir}",upperdir="${overlay_dir}",workdir="${overlay_workdir}" \
               "${portdir}" \
            || die "Could not mount overlay"
        echo "Mounted Overlay FS"
    fi
}

# Create a new squashfs file
make_snapshot() {
    echo "Creating SquashFS file..."
    mksquashfs "${portdir}" "${portage_sqfs}.new" -comp zstd -noappend 1>/dev/null \
        && echo "SquashFS file created at ${portage_sqfs}.new"
}

# Replace old portage snapshot with the new one
update_snapshot() {
    [[ -f "${portage_sqfs}.new" ]] \
        || die "No new portage snapshot found"

    unmount_portage \
        || die "Could not unmount ${portdir} for some reason"

    mv "${portage_sqfs}.new" "${portage_sqfs}" \
        && cp "${portage_sqfs}" "${portage_tmp_sqfs}" \
        && mount_portage
}

# we default to emaint
portage_sync_method="emaint -a sync"

# -w for webrsync
for i in "$@"; do
    case "$i" in
    -w) 
        portage_sync_method="emerge-webrsync"
        shift
        ;;
    *)
        echo "Usage: portage-squash-sync.sh [-w]"
        exit 1
        ;;
    esac
done

# restore state on interruption
trap "cleanup" INT TERM

mount_overlay

echo 'Syncing gentoo portage tree ...'
${portage_sync_method}
make_snapshot

unmount_overlay
update_snapshot

