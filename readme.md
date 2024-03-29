# Gentoo on a NanoPi R4S

This guide describes how to install Gentoo Linux on a NanoPi R4S board.

I will put the emphasis on creating a simple system, using the OpenRC init system and no initrd in its boot process.
Later on, I will add a few sections on how to optimize the system to minimize writes, explain better how the boot process executes and how to configure this nice device into a useful router.

The NanoPi R4S is offered in both 1GB and 4GB of RAM models. Although the 1GB model could technically be used, I strongly urge the user to go though this guide with the 4GB model. Gentoo Linux needs plenty of both RAM and disk space for package compilation, and the 4 GB model offers enough RAM space to compile most, if not all, packages without ever hitting on the SD card. Sparing the storage device will be a common concern of ours throughout the guide.

## Prerequisites

We assume in this guide that the system will be built from a x86-64 Gentoo Linux system host, and that the user is comfortable enough with this Linux distribution.

Let us set ourselves a few conventions first. Those will improve readability of the guide.

```sh
# Root work directory, make sure to have at least 10 GB of free space
R4S_WORKDIR="/home/pal/gentoo/r4s"

# Where to store temporary stuff
R4S_DOWNLOAD="${R4S_WORKDIR}/download"

# The patches to apply to some packages
R4S_PATCHES="${R4S_WORKDIR}/patches"
R4S_KPATCH_5_10="${R4S_WORKDIR}/patches/linux_5.10"

# The software that will be cross-compiled
R4S_PACKAGES="${R4S_WORKDIR}/packages"
R4S_ATF="${R4S_PACKAGES}/atf"
R4S_UBOOT="${R4S_PACKAGES}/uboot"
R4S_KERNEL="${R4S_PACKAGES}/linux"

# The root FS for the Gentoo system to build
R4S_GENTOO="${R4S_WORKDIR}/gentoo"

# The device for the SD card on which the system will be installed
R4S_DEV="/dev/sde"

mkdir -p "${R4S_WORKDIR}" \
         "${R4S_DOWNLOAD}" \
         "${R4S_KPATCH_5_10}" \
         "${R4S_GENTOO}"
```

### Arm and Arm64 cross-compilers

A couple of cross compilers for the Arm architecture are necessary in order to build AFT, the bootloader U-Boot as well as the Linux kernel.
The guide builds a 64 bits Arm system, we need the cross-compiler that targets this architecture.
ATF specifically needs a Cortex M0 compatible cross-compiler. The arm-none-eabi triplet is enforced in the ATF buildsystem, so we will comply.

Gentoo Linux makes it very easy through the crossdev tool. A dedicated local overlay is recommended.
As per its documentation, crossdev with use the first overlay matching the string "cross" in its name, or use the first available overlay if there was no match.

```sh
# Create a new overlay in /var/db/repos/cross-r4s
eselect repository add cross-r4s "" ""
# Install crossdev
emerge -a crossdev
# Build a cross-compiler targeting aarch64
crossdev -S -t aarch64-unknown-linux-gnu
# Build a 32 bits Arm target necessary for ATF
crossdev -S -t arm-none-eabi
```

### QEMU user chroot

We cannot natively chroot a root filesytem for a different architecture. However QEMU can let us do that with a little bit of configuration.
This feature is covered on the Gentoo wiki page [Embedded Handbook](https://wiki.gentoo.org/wiki/Embedded_Handbook/General/Compiling_with_qemu_user_chroot).


I will provide a small recap.

#### Kernel support for binfmt_misc

First make sure that your kernel contains CONFIG_BINFMT_MISC as a module on built in, otherwise enable it and reboot.

```sh
zgrep CONFIG_BINFMT_MISC /proc/config.gz
```

#### Installation of QEMU

```sh
echo app-emulation/qemu static-user >> /etc/portage/package.use
echo 'QEMU_SOFTMMU_TARGETS="aarch64 arm i386 x86_64"' >> /etc/portage/make.conf
echo 'QEMU_USER_TARGETS="aarch64 arm"' >> /etc/portage/make.conf
emerge -a app-emulation/qemu
```

#### Configuration of binfmt for QEMU

This is actually pretty simple, as the `qemu-binfmt` service automates everything for you: loading the binfmt_misc module, exposing it through the procfs interface and registering all the non native binary formats supported by QEMU.

```sh
/etc/init.d/qemu-binfmt start
rc-update add qemu-binfmt
```

### Other tools

Most of the tools should already be available on the host, here is a list for reminder:

- parted
- wget
- coreutils
- make
- tar
- git
- gnupg
- e2fsprogs
- f2fs-tools (if you want F2FS-formatted partitions)

F2FS support must also be enabled on the host kernel, especially compression support.

## Preparing the SD card

We will implement a simple partition scheme on the SD card.

The ternary and secondary bootloaders are expected to start at sector 64 (assuming 512B sectors). Meaning that the first 32 kiB are reserved for the GPT partition table.

The secondary boot loader is configured to expect U-Boot to be available at sector 16384, which is 8 MiB.

U-Boot does not support the F2FS filesystem, which I would like to use for the root fs. However it does support ext4, so I will create a separate partition for /boot.

|      Start      |       End       |       Size      |         Content         | Filesystem |
|-----------------|-----------------|-----------------|-------------------------|------------|
|          0      |    64s (32 kiB) |    64s (32 kiB) | GPT                     | -          |
|    64s (32 kiB) | 16384s  (8 MiB) | 16320s          | SPL+TPL (idbloader.img) | -          |
| 16384s  (8 MiB) | 32768s (16 MiB) | 16384s  (8 MiB) | U-Boot (u-boot.itb)     | -          |
|         16 MiB  |        128 MiB  |        112 MiB  | boot                    | ext4       |
|        128 MiB  |      10368 MiB  |         10 GiB  | rootfs                  | f2fs       |
|      10368 MiB  |             -1  |      remainder  | home                    | ext4       |

The attentive reader may have noticed the absence of any swap partition. This is not a good idea on SD cards. This will be mitigated using both Zswap and zram kernel features.

### Partitioning

We will first be zeroing the first 16 MiB to start from a blank state. Zeroing the full SD Card would be ideal if the card is not new. If you encounter errors while formatting the partitions, try again after zeroing the full card.

```sh
dd if=/dev/zero bs=1M count=16 of=${R4S_DEV} && sync
```

Now we use parted for partitioning.

```sh
parted ${R4S_DEV}
  (parted) mklabel gpt
  (parted) unit mib
  (parted) mkpart primary 16 128
  (parted) name 1 boot
  (parted) mkpart primary 128 10368
  (parted) name 2 rootfs
  (parted) mkpart primary 10368 -1
  (parted) name 3 home
  (parted) set 1 boot on
  (parted) print
  (parted) quit
```

### Formatting

U-Boot expects ext4 on the boot partition. It is also often a safe bet for the home partition.
Gentoo Linux, stores all the development headers, the Linux kernel sources and the portage tree on the rootfs.
This filesystem can thus benefit from compression. F2FS st a good choice on SD cards for this use case. Let us also fine tune the filesystems to minimize writes.

```sh
R4S_BOOT="${R4S_DEV}1"
R4S_ROOTFS="${R4S_DEV}2"
R4S_HOME="${R4S_DEV}3"

mkfs.ext4 -L boot ${R4S_BOOT}
tune2fs -o journal_data_writeback ${R4S_BOOT}

mkfs.f2fs -l rootfs -O extra_attr,inode_checksum,sb_checksum,compression ${R4S_ROOTFS}

mkfs.ext4 -L home ${R4S_HOME}
tune2fs -o journal_data_writeback ${R4S_HOME}
```
## Installing the stage 3

We will now prepare the root FS to be installed on the SD Card. Only the bare minimum will be performed in the chroot to setup the system.
The remainder will be done once the system is up and running on the real hardware.

### Mounting the SD card rootfs partition

The mount options ensure proper compression.

```sh
mount -o defaults,nobarrier,noatime,nodiratime,compress_algorithm=zstd,compress_extension='*' ${R4S_ROOTFS} ${R4S_GENTOO}
```

### Copying a Stage 3

The Gentoo Linux project provides stage 3 archives for the arm64 architecture.
Get a link to the latest stage 3 archive for arm64 on the [Gentoo downloads](https://www.gentoo.org/downloads) page.

```sh
# Fetch the files
STAGE3_ARCHIVE="stage3-arm64-20210122T003400Z.tar.xz"
STAGE3_URL="http://distfiles.gentoo.org/releases/arm64/autobuilds/current-stage3/${STAGE3_ARCHIVE}"

cd "${R4S_DOWNLOAD}"
wget "${STAGE3_URL}"
wget "${STAGE3_URL}.DIGESTS"
wget "${STAGE3_URL}.DIGESTS.asc"

# Verify authenticity
gpg --keyserver hkps://hkps.pool.sks-keyservers.net --recv-keys 0xBB572E0E2D182910
gpg --verify "${STAGE3_ARCHIVE}.DIGESTS.asc"

# Verify integrity
cat "${STAGE3_ARCHIVE}.DIGESTS"
sha512sum "${STAGE3_ARCHIVE}"
```

Unpack as root user to preserve ownership rights and file attributes.

```sh
# Unpack the archive in the rootfs
tar xpvf "${STAGE3_ARCHIVE}" --xattrs-include='*.*' --numeric-owner -C "${R4S_GENTOO}"
sync
```

### Mount other partitions

```sh
mount ${R4S_BOOT} ${R4S_GENTOO}/boot
mount ${R4S_HOME} ${R4S_GENTOO}/home
```

### Copy the qemu user static executable inside the rootfs

```sh
# Allow the rootfs to be chrooted with qemu
cp /usr/bin/qemu-aarch64 "${R4S_GENTOO}/usr/bin"
```

## Linux kernel

The kernel can either be cross-compiled or compiled from inside the emulated chroot. Cross compilation is faster, this is what I will use.

FriendlyArm provides a [fork](https://github.com/friendlyarm/kernel-rockchip/tree/nanopi-r2-v5.10.y) of the Linux kernel which has been rebased on top of v5.10.2 vanilla at the time of writing.
The 5.10 release being LTS, it makes sense to cherry pick all the commits specific to the FriendlyArm fork and apply them on top of whatever patch release of the mainline kernel is currently available for this LTS version.

### Extracting the NanoPi specific patches

```sh
cd "${R4S_DOWNLOAD}"
git clone https://github.com/friendlyarm/kernel-rockchip -b nanopi-r2-v5.10.y kernel-rockchip
cd kernel-rockchip

# Find out which commit corresponds to the v5.10.2 merge
tag_5_10_2=d1988041d19d

# Obtain the diff from mainline
git diff ${tag_5_10_2}..HEAD > "${R4S_KPATCH_5_10}/nanopi-r4s.patch"
```

### Fetching the 5.10 LTS kernel

We will fetch the mainline 5.10 branch and apply the Nanopi specific patches on top of it.
Alternatively, the official `sys-kernel/gentoo-sources` could also be used from inside the chrooted rootfs.

```sh
git clone https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git --depth 1 -b linux-5.10.y "${R4S_KERNEL}"
cd "${R4S_KERNEL}"
git apply "${R4S_KPATCH_5_10}/nanopi-r4s.patch"
```

### Configuring the kernel

```sh
# An alias to simplify make invocation
export kmake=make ARCH=arm64 CROSS_COMPILE=aarch64-unknown-linux-gnu- INSTALL_MOD_PATH="${R4S_GENTOO}"

# Configure for nanopi4
${kmake} distclean
touch .scmversion
${kmake} nanopi4_linux_defconfig

# If you specifically need additional modules, add them now
${kmake} menuconfig  # select your options
```

The following paragraphs suggest a few options to enable as the guide will require them.
However, those are not strictly required to have the R4S in working order.

#### Frequency scaling

I would recommend setting the default governor to `ondemand` or `schedutil`.

```
-> CPU Power Management
  -> CPU Frequency scaling
    [*] CPU Frequency scaling
    [*]   CPU frequency transition statistics
          Default CPUFreq governor (ondemand)
    -*-   'performance' governor
    <*>   'powersave' governor
    <*>   'userspace' governor for userspace frequency scaling
    -*-   'ondemand' cpufreq policy governor
    <*>   'conservative' cpufreq governor
```

#### Zswap

Zswap is a compressed cache for swap pages that is allocated in RAM.
It will be used as a mitigation measure for the absence of a swap partition.
It works by compressing data in RAM when there is little free memory left (configurable at boot time).
I am fond of the Zstd compressor, it is fast and efficient.

```
-> Memory Management options
  [*] Compressed cache for swap pages (EXPERIMENTAL)
        Compressed cache for swap pages default compressor (zstd)  --->
        Compressed cache for swap pages default allocator (zsmalloc)  --->
  [*]   Enable the compressed cache for swap pages by default
```

#### zram

zram provides a RAM block device which is also transparently compressed. It can efficiently replace tmpfs block devices on memory constrained systems.
A zram backed block device will be configured in a later chapter for use as the temporary build directory used by portage.

```
-> Device Drivers
  -> Block devices
    < >   Null test block driver
    <M>   Block Device Driver for Micron PCIe SSDs
    <*>   Compressed RAM block device support
    [*]     Write back incompressible or idle page to backing device
    [*]     Track zRam block status
```

#### F2FS

Remember to configure the support for F2FS into the kernel.
It needs to to be built in, not as a module to allow booting a root partition F2FS formatted.

```
-> File systems
  <*> F2FS filesystem support
  [*]   F2FS Status Information
  [*]   F2FS extended attributes
  [*]     F2FS Access Control Lists
  [*]     F2FS Security Labels
  [ ]   F2FS consistency checking feature
  [ ]   F2FS IO tracer
  [ ]   F2FS fault injection facility
  [*]   F2FS compression feature
  [*]     LZ4 compression support
  [*]     ZSTD compression support
```

#### OverlayFS and SquashFS

Both will be used to implement a SquashFS compressed portage tree that will be updated in memory using a write overlay stored in a ram disk.
This has the distinct advantage of never hitting the SD card apart from a single SquashFS file update per portage sync.
Portage queries will also be faster.

```
-> File systems
  <*> Overlay filesystem support
  [*] Miscellaneous filesystems  --->
  <*>   SquashFS 4.0 - Squashed file system support
          File decompression options (Decompress files directly into the page cache)  --->
          Decompressor parallelisation options (Single threaded compression)  --->
  [*]     Squashfs XATTR support
  [*]     Include support for LZ4 compressed file systems
  [*]     Include support for XZ compressed file systems
  [*]     Include support for ZSTD compressed file systems
```

### Building and installing

```sh
# Build
${kmake} -j$(nproc)
${kmake} -j$(nproc) modules

# Install the modules in the root FS
${kmake} modules_install INSTALL_MOD_STRIP=1

R4S_KERNEL_VER=`${kmake} kernelrelease`

# And copy the kernel as well as the device tree binary in the boot directory of the root FS
cp .config "${R4S_GENTOO}/boot/config-${R4S_KERNEL_VER}"
cp arch/arm64/boot/Image "${R4S_GENTOO}/boot/Image-${R4S_KERNEL_VER}"
cp arch/arm64/boot/dts/rockchip/rk3399-nanopi-r4s.dtb "${R4S_GENTOO}/boot/"
```

## U-Boot

The Nanopi R4S is not supported on mainline yet, however, FriendlyArm maintains a recent U-Boot fork (2020-10 at the time of writing) will only a few patches over mainline.

Building U-Boot for this board depends on the `bl31.elf` binary provided by Arm Trusted Firmware (ATF) project).

### Arm Trusted Firmware (ATF)

ATF is used on recent Arm SBCs to implement a chain of trust that will ensure secure booting of the OS.

```sh
git clone --depth 1 https://github.com/ARM-software/arm-trusted-firmware "${R4S_ATF}"
cd "${R4S_ATF}"
export CROSS_COMPILE=aarch64-unknown-linux-gnu-

make PLAT=rk3399 ARCH=aarch64 DEBUG=0 bl31
export BL31="${R4S_ATF}/build/rk3399/release/bl31/bl31.elf"
```

U-Boot will find the resulting binary provided we made either a copy at the root of the repository or if the `BL31` environment variable pointing to the `bl31.elf` file is defined.

### Compilation of U-Boot

There is a defconfig file for the Nanopi R4S, which configures U-Boot specifically for this device.

```sh
git clone --depth 1 https://github.com/friendlyarm/uboot-rockchip -b nanopi4-v2020.10 "${R4S_UBOOT}"
cd "${R4S_UBOOT}"
cp ${BL31} .
# default r4s config
make ARCH=arm CROSS_COMPILE=aarch64-unknown-linux-gnu- nanopi-r4s-rk3399_defconfig

# build u-boot
make ARCH=arm CROSS_COMPILE=aarch64-unknown-linux-gnu-
```
### Installation on the SD card

Assuming the SD card to be exposed as `${R4S_DEV}`, the bootloader can be flashed onto the SD card in two steps:

```sh
# Write the tpl and spl at sector 64, then U-Boot proper at 16384 sector
dd if=idbloader.img of=${R4S_DEV} seek=64 conv=notrunc
dd if=u-boot.itb of=${R4S_DEV} seek=16384 conv=notrunc

# Alternatively, there is an image that contains everything in a single file
# dd if=u-boot-rockchip.img of=${R4S_DEV} seek=64 conv=notrunc
sync
```

## Configuring the system

### Chroot of the rootfs

```sh
cd "${R4S_GENTOO}"
mkdir -p var/db/repos/gentoo
mount --bind /var/db/repos/gentoo var/db/repos/gentoo
mount --bind /proc proc
mount --bind /sys sys
mount --bind /dev dev
mount --bind /dev/pts dev/pts

cp /etc/resolv.conf etc

# emulate an appropriate cpu
export QEMU_CPU=cortex-a72
chroot . /bin/bash --login

env-update && source /etc/profile
export PS1="(r4s) $PS1"
```

### Portage configuration

Let's adapt the `make.conf`

```sh
# No "native" march yet, we cannot expect QEMU to guess it for us.
COMMON_FLAGS="-O2 -pipe -march=armv8-a+crypto+crc -mtune=cortex-a72.cortex-a53"
# COMMON_FLAGS="-O2 -pipe -march=native -mtune=native"  # use this on the real hardware
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"

CHOST="aarch64-unknown-linux-gnu"
ACCEPT_KEYWORDS="arm64"

EMERGE_DEFAULT_OPTS="--with-bdeps=y --quiet"
MAKEOPTS="-j6"

FEATURES="noinfo nodoc"
# We must disable a couple of sandbox features in the QEMU chroot
FEATURES="$FEATURES -pid-sandbox -network-sandbox"  # remove this line once on the real hardware

PORTAGE_RSYNC_EXTRA_OPTS="--delete-excluded --exclude-from=/etc/portage/rsync_excludes"
PORTAGE_COMPRESS="bzip2"
PORTAGE_COMPRESS_FLAGS="-9"

INSTALL_MASK="/usr/share/locale"

GENTOO_MIRRORS="ftp://mirror.netcologne.de/gentoo/ https://ftp-stud.hs-esslingen.de/pub/Mirrors/gentoo/ ftp://mirror.bytemark.co.uk/gentoo/"

ACCEPT_LICENSE="*"

# A few suggestions for a base system:
# - I disabled anything GUI and systemd related
# - I do not want to any additional locales
# - I want zstd support for most tools
# - I also disabled lto, it is a major RAM consumer
# - I disabled pch for the same reasons. It may also be disabled on sys-devel/gcc only
#
USE="arm bash-completion idn ipv6 zlib -doc -test -X -bindist -gnome -gtk -gtk3 \
     -kde -kde -lto -minimal -nls -pch -perl -qt -qt4 -qt5 -sanitize -spell -systemd -zeroconf zstd"

LC_MESSAGES=C
```

### Hostname

Set it in /etc/conf.d/hostname

### Installing useful tools

#### Filesystem utilities

```sh
emerge -a f2fs-tools squashfs-tools
```

#### U-Boot tools

```sh
echo "dev-embedded/u-boot-tools ~arm64" >> /etc/portage/package.accept_keywords
emerge -a u-boot-tools
```

#### System logger

To know what broke on the first boot.

```sh
emerge -a cronie syslog-ng logrotate
rc-update add syslog-ng default
rc-update add cronie default
```

### System time

The NanoPi does have RTC support, and features a 2 pin connector to connect a battery to it.

As a complement and or alternative, it is a good idea to run an NTP server that will ensure proper software clock synchronization.

```sh
emerge -a ntpd
/etc/init.d/ntpd start
rc-update add ntpd default
```

### Configuring the network

There are 2 network interfaces.
The WAN interface is available as `eth0`, whereas the LAN one appears as `enp1s0`.
OpenRC will attempt DHCP requests on enabled but not configured interfaces.

```sh
emerge -a dhcpcd

cd /etc/init.d

ln -s net.lo net.eth0
rc-update add net.eth0 default

ln -s net.lo net.enp1s0

# If you have a DHCP server on the LAN interface, enable this one
# rc-update add net.enp1s0 default
```

Let's also enable the SSH server on boot

```sh
emerge -a openssh
rc-update add sshd default
```

And finally configure the serial console available on this device.
In `/etc/inittab`, add the following line:

```
s0:12345:respawn:/sbin/agetty 1500000 ttyS2 vt100
```

You may also comment out the `f0:` line in the inittab, it spins unsuccessfully.

### Adding a user

First, change the root password

```sh
passwd
```

Then create a new user

```sh
useradd -m -G users,wheel -s /bin/bash pal
passwd pal
```

### Configuring the fstab

First, let's get the UUIDs of each partition

```sh
uuid_boot="$(blkid -s UUID -o value ${R4S_BOOT})"
uuid_rootfs="$(blkid -s UUID -o value ${R4S_ROOTFS})"
uuid_home="$(blkid -s UUID -o value ${R4S_HOME})"
```

Now create /etc/fstab with the following (remember to substitute the UUIDs).
Notice how I enabled compression for everything and added a couple of tmpfs to minimize writes on the SD card.

```fstab
UUID=${uuid_boot}   /                f2fs  defaults,nobarrier,noatime,nodiratime,compress_algorithm=zstd,compress_extension=* 0 1
UUID=${uuid_rootfs} /boot            ext4  defaults,noauto,noatime,nodiratime,commit=600,errors=remount-ro                    0 2
UUID=${uuid_home}   /home            ext4  defaults,noatime,nodiratime,commit=600,errors=remount-ro                           0 2
tmpfs               /tmp             tmpfs defaults,nosuid                                                                    0 0
tmpfs               /var/tmp/portage tmpfs nr_inodes=1M,noatime,nodiratime,mode=0775,uid=portage,gid=portage                  0 0
```

This is as good a time as any to create /var/tmp/portage.

```sh
mkdir /var/tmp/portage
chown portage:portage /var/tmp/portage
```

### Configuring the bootloader

U-Boot contains a default boot script that gets executed after a configurable timeout. This script tries its best to find a way of booting an OS. It probes local and remote storage devices and interfaces (mmc, usb, pxe, dhcp...), then see if it can defer to another bootloader: extlinux, efi. Otherwise it looks for a user supplied bootscript that describes how to boot the system. It will typically search for a boot.scr file on partitions marked as bootable, and look into a few locations, most notably /boot.scr and /boot/boot.scr. If such a script is available it runs it.

We will store our own boot script on the boot partition. Here is one I wrote for the R4S that matches the system configuration of this guide. Put this file in `"${R4S_GENTOO}/boot/boot.cmd"` and edit it as necessary. I like my console verbose.

```txt
# U-Boot bootscript for the nanopi r4s on Gentoo Linux
# Build with: mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr

setenv rootdev "/dev/mmcblk1p2"
setenv fdtfile "rk3399-nanopi-r4s.dtb"
setenv ttyconsole "ttyS2,1500000"

setenv consoleargs "earlycon console=${ttyconsole} consoleblank=0 earlyprintk=serial,${ttyconsole} debug loglevel=7"
setenv zswapargs "zswap.enabled=1 zswap.compressor=zstd zswap.max_pool_percent=50"
setenv rootargs "root=${rootdev} rootwait rootfstype=f2fs rootflags=compress_algorithm=zstd"
setenv bootargs "${rootargs} ${consoleargs} ${zswapargs}"

echo "Boot script loaded from ${devtype} ${devnum}"

load mmc 1:1 ${kernel_addr_r} Image
load mmc 1:1 ${fdt_addr_r} ${fdtfile}
fdt addr ${fdt_addr_r}
booti ${kernel_addr_r} - ${fdt_addr_r}
```

We can now generate the corresponding `boot.scr` file using `mkimage`.

```sh
mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr
```

Note how I used `Image` for the kernel image instead of the more specific `Image_5.10.12` filename that was install into the /boot directory.
This is easier to edit a symbolic link rather than editing the boot script and regenerate the binary representation.

```sh
cd /boot
ln -sf Image_5.10.12 Image
```

### Cleanup and boot the system

Everything should now be ready. All the partitions can be unmounted, the SD card inserted into the device card slot and a serial cable plugged into the debug UART headers if you have one. Remember to cross the Rx and Tx cables on the UART adapter.

I widened the small hole connected to the fixation screw hole inside the aluminium use to 5 mm and managed to wires connected to the debug UART headers. This lets me connect a serial console to it while keeping the case closed.

Connect to the console using screen (as root or add yourself to the uucp group):

```sh
screen /dev/ttyUSB0 1500000
```

And power the device on.

## After the first boot

Open the [Gentoo Linux AMD64](https://wiki.gentoo.org/wiki/Handbook:AMD64) handbook and follow the steps that may have been skipped up to now.
Almost everything should already have been taken care of.

### Portage configuration

You may have noticed that no portage tree has bee installed yet. In the previous steps we used the tree of the host.

We will now tweak portage to reduce the load that installing packages from source may impose on the system.

The next few paragraphs introduce a few complementary approaches that will culminate into a somewhat Portage optimized setup that avoids using the SD card for most operations. The basic observation it that 4 GB of RAM and simple use of data compression let us store the portage tree as well as the build directories in RAM.

#### Partial Gentoo repository

The first step is to avoid fetching the full portage tree, as only parts of it are useful for our system.
Rsync let us do just that using the `--exclude-from` directive. Put the following line in `/etc/portage/make.conf`:

```sh
PORTAGE_RSYNC_EXTRA_OPTS="--delete-excluded --exclude-from=/etc/portage/rsync_excludes"
```

And fill the rsync_excludes file with patterns of files to exclude.
Mine is somewhat conservative right now, with some effort it may be easy to reduce the tree a lot more.

```
games-*/*
metadata/md5-cache/games-*/*
app-emacs/*
metadata/md5-cache/app-emacs/*
app-mobilephone/*
metadata/md5-cache/app-mobilephone/*
app-pda/*
metadata/md5-cache/app-pda/*
app-xemacs/*
metadata/md5-cache/app-xemacs/*
dev-ada/*
metadata/md5-cache/dev-ada/*
dev-dotnet/*
metadata/md5-cache/dev-dotnet/*
dev-erlang/*
metadata/md5-cache/dev-erlang/*
dev-games/*
metadata/md5-cache/dev-games/*
dev-haskell/*
metadata/md5-cache/dev-haskell/*
dev-java/*
metadata/md5-cache/dev-java/*
dev-ml/*
metadata/md5-cache/dev-ml/*
dev-ruby/*
metadata/md5-cache/dev-ruby/*
dev-tex/*
metadata/md5-cache/dev-tex/*
dev-texlive/*
metadata/md5-cache/dev-texlive/*
gnustep-*/*
metadata/md5-cache/gnustep-*/*
gui-*/*
metadata/md5-cache/gui-*/*
java-virtuals/*
metadata/md5-cache/java-virtuals/*
kde-*/*
metadata/md5-cache/kde-*/*
lxde-base/*
metadata/md5-cache/lxde-base/*
lxqt-base/*
metadata/md5-cache/lxqt-base/*
mate-base/*
metadata/md5-cache/mate-base/*
mate-extra/*
metadata/md5-cache/mate-extra/*
media-radio/*
metadata/md5-cache/media-radio/*
media-sound/*
metadata/md5-cache/media-sound/*
media-tv/*
metadata/md5-cache/media-tv/*
net-wireless/*
metadata/md5-cache/net-wireless/*
sci-*/*
metadata/md5-cache/sci-*/*
x11-*/*
metadata/md5-cache/x11-*/*
xfce-*/*
metadata/md5-cache/xfce-*/*
```

Portage verifies the integrity of the tree after a sync. Unfortunately there is no simple way of mixing partial trees and verification right now.
Let us make portage less strict by setting this in `/etc/portage/repos.conf/gentoo.conf`:

```conf
[DEFAULT]
main-repo = gentoo
sync-allow-hardlinks = no

[gentoo]
sync-rsync-verify-metamanifest = no
```

#### Compiling in (compressed) RAM

Software compilation can consume impressive amounts of memory and disk space, desktop and scientific packages being on the heavier side. Headless devices are not however the prime target for such packages. Most of them can be built comfortably without ever hitting the SD card, provided a tmpfs partition was setup var /var/tmp/portage as we did earlier in this guide.

GCC is the obvious outlier in the base system installation and the worst offender by far. With some precautions, it needs about 4 GB of disk space and about 2 GB of free memory to compile (a few translation units are enormous that a single process consumes that much memory). The obvious conclusion is that one cannot compile GCC in RAM.

Fortunately both source code and compiled objects are heavily compressible, and the Linux kernel offers a tool to create transparently compressed tmpfs-like ram disks: zram.

Here is the result of applying such technique with GCC, at the very end of the compilation:

```
pal@r4s ~ $ zramctl
NAME       ALGORITHM DISKSIZE  DATA COMPR TOTAL STREAMS MOUNTPOINT
/dev/zram0 zstd          7.9G  3.8G  1.1G  1.2G       6 /var/tmp/portage
```

I created a Zstd-compressed zram disk of size 8 GB. The disk space required to hold the GCC source code and compilation artifacts is about 4 GB and the effective compression ratio it over 3.5, meaning, Only 1.2 GB of RAM was ever consumed on that task and left well over 2 GB of free memory for the actual compilation processes.

The setup is surprisingly simple once zram is enabled in the kernel, as we will rely on `zram-init` instead of backing our own scripts.

**Step 1: Install zram-init**

```sh
echo "sys-block/zram-init ~arm64" >> /etc/portage/package.accept_keywords
emerge -a zram-init
```

**Step 2: Configure zram-init**

We setup in `/etc/conf.d/zram-init` a 8 GB compressed RAM disk that is limited to 3 GB of actual memory usage. The init script will take care of creating an EXT2 partition on it.

```sh
# load zram kernel module on start?
load_on_start=yes

# unload zram kernel module on stop?
unload_on_stop=yes

# Number of devices.
num_devices=1

# /var/tmp/portage - 8G
type0=/var/tmp/portage
flag0=ext2
size0=8096  # max content size
mlim0=3072  # actual memory size limit
back0= # no backup device
icmp0= # no incompressible page writing to backup device
idle0= # no idle page writing to backup device
wlim0= # no writeback_limit for idle page writing for backup device
blck0= # the default blocksize is 4096
irat0=4096 # bytes/inode ratio
inod0= # inode number
opts0="noatime,nodiratime"
mode0=1775
owgr0="portage:portage"
notr0= # keep the default on linux-3.15 or newer
maxs0=1
algo0=zstd
labl0=var_tmp_portage
uuid0=
args0=
```

**Step 3: Disable the current /var/tmp/portage configuration:**

```sh
umount /var/tmp/portage
```

Now remove the line responsible for creating a tmpfs in this directory from `/etc/fstab`. zram-init will take care of mounting the zram disk for you at boot time.

**Step 4: Enable zram-init**

```sh
rc-update add zram-init boot
/etc/init.d/zram-init start
```

`/dev/zram0` should now be mounted on `/var/tmp/portage` as an EXT2 partition. The `zramctl` can tell you more about the state of zram block devices.

#### Portage tree in a SquashFS file

The portage tree is growing rather large. It consists at the time of writing in more than 120 000 files and about 650 MB of uncompressed data on disk.
A partial SquashFS portage tree sits at 40 MB in a single file while delivering faster queries.

There is a somewhat official project that delivers squashfs delta files for this already: `dev-util/squashmerge`. However It has not seen a lot of development as of late and it relies on continued official support from the Gentoo Linux project.

I will thus provide a bash script that performs the same task using a different approach. It updates the Portage tree in RAM using an overlay filesystem consisting in a read overlay over the current squashed portage tree and a write overlay to store changes in a RAM backed disk. That way we rely on well supported in-kernel features and combine partial and squashed portage trees. The idea is not mine and I definitively got some inspiration from some other script. There are numerous articles and scripts describing this technique already.

The [portage-squash-sync.sh](conf/etc/portage/portage-squash-sync.sh) does just that. Put it somewhere, for instance in /etc/portage and make it executable. I use an alias in my `/root/.bashrc` for easy invocation.

```sh
# In /root/.bashrc
alias esync='/etc/portage/portage-squash-sync.sh'
```

Without arguments, it calls `emaint -a sync`. When passed `-w`, it calls `emerge-webrsync` instead, which may be preferable at initial setupe

The squashed tree is stored in a RAM disk and mounted from here, to we need a way to copy the squashfs file to this location at boot and them mount it. This can be done with an entry in /etc/fstab and a service script called by init on boot.

First, add the following in `/etc/fstab`:

```fstab
/var/tmp/portage/portage.sqfs  /var/db/repos/gentoo  squashfs  ro,loop,defaults,nosuid,nodev,noexec,noauto 0 0
```

And at last, copy the following script to `/etc/local.d/10-mount-portage-squashfs.start` and make it executable. Make sure the local service is enabled in the default runlevel.

```sh
#!/bin/sh
cp /var/lib/portage/portage.sqfs /var/tmp/portage && mount /var/db/repos/gentoo
```

We setup /var/tmp/portage previously to be a zram disk created and mounted in the boot init level. This one will be called later, when the RAM disk will already be available.

Everything should be in place, now open a new terminal or source your `~/.bashrc` and call `esync -w`.

### Essential tools

To each its own, here are some of mine with accompanying configuration files in the `conf` directory of this repository.

In `/etc/portage/package.accept_keywords`

```
# Neovim
app-editors/neovim ~arm64
dev-lua/luv ~arm64
dev-lua/mpack ~arm64
dev-lua/LuaBitOp ~arm64
dev-libs/libvterm ~arm64
dev-libs/msgpack ~arm64
dev-libs/libtermkey ~arm64
dev-libs/unibilium ~arm64
dev-libs/libmpack ~arm64
```

```sh
emerge -a neovim tmux git htop nmap lsof
```

## References

- [How to compile ATF](http://opensource.rock-chips.com/wiki_ATF)
- [How to build U-Boot on rockchip boards](https://gitlab.denx.de/u-boot/u-boot/-/blob/master/doc/board/rockchip/rockchip.rst)
- [NanoPi R4S Wiki](https://wiki.friendlyarm.com/wiki/index.php/NanoPi_R4S)
- [Gentoo AMD64 Handbook](https://wiki.gentoo.org/wiki/Handbook:AMD64)
- [Gentoo Embedded Handbook](https://wiki.gentoo.org/wiki/Embedded_Handbook)
- [Gentoo Cross build environment wiki page](https://wiki.gentoo.org/wiki/Cross_build_environment)
- [Gentoo partial portage tree](https://wiki.gentoo.org/wiki/Handbook:X86/Portage/CustomTree)
- [Squashed portage tree guide](https://www.brunsware.de/blog/portage-tree-squashfs-overlayfs)
- [FriendlyArm U-Boot fork](https://github.com/friendlyarm/uboot-rockchip/tree/nanopi4-v2020.10)
- [FriendlyArm Linux kernel fork](https://github.com/friendlyarm/kernel-rockchip/tree/nanopi-r2-v5.10.y)
- [Archlinux F2FS Wiki page](https://wiki.archlinux.org/index.php/F2FShttps://wiki.archlinux.org/index.php/F2FS)
- [Linux kernel boot parameters](https://www.kernel.org/doc/html/v5.10/admin-guide/kernel-parameters.html)

