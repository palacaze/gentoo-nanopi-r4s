# Gentoo on nanopi r4s

This guide describes how to install Gentoo Linux on a Nanopi R4S board.

I will put the emphasis on creating a simple system, which will run with the OpenRC init system and boots with no initrd.
Later on, I will add a few sections on how to optimize the system to minimize writes, explain better how the boot process executes and how to configure this nice device into a useful router.

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

We will implement a simple partition scheme to the SD card.

The ternary and secondary bootloaders are expected to start at sector 64 (assuming 512B sectors). Meaning that the first 32 kiB are reserved for the GPT partition table.

The secondary boot loader is configured to expect U-Boot to be available at sector 16384, which is 8 MiB.

U-Boot does not support the F2FS filesystem, which I would like to use for the root fs. However it does support ext4, so I will create a partition for boot.

|      Start      |       End       |       Size      |         Content         | Filesystem |
|-----------------|-----------------|-----------------|-------------------------|------------|
|          0      |    64s (32 kiB) |    64s (32 kiB) | GPT                     | -          |
|    64s (32 kiB) | 16384s  (8 MiB) | 16320s          | SPL+TPL (idbloader.img) | -          |
| 16384s  (8 MiB) | 32768s (16 MiB) | 16384s  (8 MiB) | U-Boot (u-boot.itb)     | -          |
|         16 MiB  |        128 MiB  |        112 MiB  | boot                    | ext4       |
|        128 MiB  |      10368 MiB  |         10 GiB  | rootfs                  | f2fs       |
|      10368 MiB  |             -1  |      remainder  | home                    | ext4       |

### Partitioning

We will first be zeroing the first 16 MiB to start from a blank state. Zeroing the full SD Card would be ideal.

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
Gentoo Linux, stores all the development headers, the linux kernel sources and the portage tree on the rootfs. This filesystem can thus benefit from compression. F2FS it a good choice on SD cards for this use case.

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

We will prepare the root FS to be installed on the SD Card. Only the bare minimum will be performed in the chroot to setup the system.
The remainder will be done once the system is up and running on the real hardware.

### Mounting the SD card rootfs partition

The mount options ensure proper compression.

```sh
mount -o defaults,nobarrier,noatime,nodiratime,compress_algorithm=zstd,compress_extension='*' ${R4S_ROOTFS} ${R4S_GENTOO}
```

### Copying a Stage 3

The Gentoo Linux project provides stage 3 archives for the arm64 architecture.
Fetch the latest stage 3 archive for arm64 on the [Gentoo downloads](https://www.gentoo.org/downloads) page.

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

Unpack as root user and copy the static executable qemu-aarch64 for the chroot to work.

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

The kernel can be either cross-compiled or compiled from inside the emulated chroot. Cross compilation is faster, this is what I will use.

FriendlyArm provides a [fork](https://github.com/friendlyarm/kernel-rockchip/tree/nanopi-r2-v5.10.y) of the Linux kernel which has been rebased on top of v5.10.2 vanilla at the time of writing.
The 5.10 release being LTS, it makes sense to cherry pick all the commits specific to the FriendlyArm fork and apply them on top of whatever patch release of the mainline kernel is currently available for this LTS version.

### Extracting the Nanopi specific patches

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

We will fetch the mainline 5.10 branch and apply the Nanopi specific patches on top of it

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

Remember to configure the support for F2FS into the kernel.
It needs to to be built in, not as a module to allow booting a root partition F2FS formatted.

```
<*> F2FS filesystem support
[*]   F2FS Status Information
[*]   F2FS extended attributes
[*]     F2FS Access Control Lists
[*]     F2FS Security Labels
[ ]   F2FS consistency checking feature
[ ]   F2FS IO tracer
[ ]   F2FS fault injection facility
[*]   F2FS compression feature
[*]     LZO compression support
[*]     LZ4 compression support
[*]     ZSTD compression support
[*]     LZO-RLE compression suppor
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
cp arch/arm64/boot/dts/rockchip/rk3399-nanopi-r4s.dtb "${R4S_GENTOO}/boot/rk3399-nanopi-r4s-${R4S_KERNEL_VER}.dtb"
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

Assuming the SD card to be exposed as `/dev/sdX`, the bootloader can be flashed onto the SD card in two steps:

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
CFLAGS="-O2 -pipe -march=armv8-a+crc -mtune=cortex-a72.cortex-a53" # -mfpu=neon-fp-armv8 -mfloat-abi=hard
CXXFLAGS="${CFLAGS}"

MAKEOPTS="-j6"
FEATURES="noman noinfo nodoc"

PORTAGE_RSYNC_EXTRA_OPTS="--delete-excluded --exclude-from=/etc/portage/rsync_excludes"

PORTAGE_COMPRESS="bzip2"
PORTAGE_COMPRESS_FLAGS="-9"

INSTALL_MASK="/usr/share/locale"

GENTOO_MIRRORS="ftp://mirror.netcologne.de/gentoo/ https://ftp-stud.hs-esslingen.de/pub/Mirrors/gentoo/ ftp://mirror.bytemark.co.uk/gentoo/"

ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="arm64"

USE="arm bash-completion idn ipv6 zlib -doc -test -X -bindist -gnome -gtk -gtk3 -kde -kde -minimal -nls -openmp \
     -perl -python_targets_python3_9 -qt -qt4 -qt5 -spell -systemd -zeroconf zstd"
```

### Hostname

set it in /etc/conf.d/hostname

### Installing useful tools

#### F2FS utilities

```sh
emerge -a f2fs-tools
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

### Configuring the network

There are 2 network interfaces. The first one is available as eth0, the other enp1s0.

```sh
emerge -a dhcpcd

cd /etc/init.d

ln -s net.lo net.eth0
rc-update add net.eth0 default

ln -s net.lo net.enp1s0
rc-update add net.enp1s0 default
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
setenv rootdev "/dev/mmcblk1p2"
setenv fdtfile "rk3399-nanopi-r4s.dtb"
setenv consoleargs "earlycon console=ttyS2,1500000"

echo "Boot script loaded from ${devtype} ${devnum}"

part uuid mmc 1:1 partuuid

setenv bootargs "root=${rootdev} rootwait rootfstype=f2fs ${consoleargs} consoleblank=0 loglevel=7 ubootpart=${partuuid}"

load mmc 1:1 ${kernel_addr_r} Image
load mmc 1:1 ${fdt_addr_r} ${fdtfile}
fdt addr ${fdt_addr_r}

booti ${kernel_addr_r} - ${fdt_addr_r}
```

We now generate the corresponding `boot.scr` file using `mkimage`.

```sh
mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr
```

### Cleanup and boot the system

Everything should now be ready. All the partition can now be unmounted, the SD card inserted into device slot and a serial cable plugged into the debug uart headers if you have one.

Connect to the console using screen (as root or add yourself to the uucp group):

```sh
screen /dev/ttyUSB0 1500000
```

And power the device on.

## After the first boot

Open the [Gentoo Linux AMD64](https://wiki.gentoo.org/wiki/Handbook:AMD64) handbook and follow the steps that may have been skipped up to now.

## References

- [How to compile ATF](http://opensource.rock-chips.com/wiki_ATF)
- [How to build U-Boot on rockchip boards](https://gitlab.denx.de/u-boot/u-boot/-/blob/master/doc/board/rockchip/rockchip.rst)
- [NanoPi R4S Wiki](https://wiki.friendlyarm.com/wiki/index.php/NanoPi_R4S)
- [Gentoo AMD64 Handbook](https://wiki.gentoo.org/wiki/Handbook:AMD64)
- [Gentoo Embedded Handbook](https://wiki.gentoo.org/wiki/Embedded_Handbook)
- [Gentoo Cross build environment wiki page](https://wiki.gentoo.org/wiki/Cross_build_environment)
- [FriendlyArm U-Boot fork](https://github.com/friendlyarm/uboot-rockchip/tree/nanopi4-v2020.10)
- [FriendlyArm Linux kernel fork](https://github.com/friendlyarm/kernel-rockchip/tree/nanopi-r2-v5.10.y)
- [Archlinux F2FS Wiki page](https://wiki.archlinux.org/index.php/F2FShttps://wiki.archlinux.org/index.php/F2FS)
- [Linux kernel boot parameters](https://www.kernel.org/doc/html/v5.10/admin-guide/kernel-parameters.html)

