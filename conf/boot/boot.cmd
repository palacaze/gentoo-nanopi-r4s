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

