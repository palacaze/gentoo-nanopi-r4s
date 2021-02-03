# U-Boot bootscript for the nanopi r4s on Gentoo Linux
# Build with: mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr

setenv rootdev "/dev/mmcblk1p2"
setenv fdtfile "rk3399-nanopi-r4s.dtb"
setenv consoleargs "earlycon console=ttyS2,1500000"

part uuid mmc 1:1 partuuid

setenv bootargs "root=${rootdev} rootwait rootfstype=f2fs ${consoleargs} consoleblank=0 loglevel=7 ubootpart=${partuuid}"

load mmc 1:1 ${kernel_addr_r} Image
load mmc 1:1 ${fdt_addr_r} ${fdtfile}
fdt addr ${fdt_addr_r}

booti ${kernel_addr_r} - ${fdt_addr_r}

