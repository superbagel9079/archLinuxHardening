# Arch Linux Server Deployment (Proxmox/UEFI/LVM)

## Part I - Pre-Installation Environment

### A - Boot the Live Medium

Download the latest official ISO from [archlinux.org/download](https://archlinux.org/download). Write it to a USB drive or mount it as a virtual optical device in your hypervisor. Boot the machine and ensure it starts in UEFI mode.

Verify UEFI mode by checking for the existence of EFI variables:

```bash
ls /sys/firmware/efi/efivars
```

If this directory exists and contains files, the system is booted in UEFI mode. If it does not exist, stop here — your firmware is configured for Legacy/CSM boot and this guide does not apply.

> [!WARNING] 
> Proceeding in Legacy BIOS mode will produce a system that cannot boot with systemd-boot or UKI. There is no workaround. You must reconfigure your firmware to UEFI before continuing.

### B - Set the Console Keyboard Layout

The default layout is US QWERTY. If you require a different layout, load it with `loadkeys`. For example, for a French layout:

```bash
loadkeys uk
```

Available keymaps can be listed with:

```bash
localectl list-keymaps
```

### C - Network Configuration (Static IP)

Identify the available network interface:

```bash
ip a
```

Bring the interface up and assign a static address. Replace the placeholders with your actual network parameters:

```bash
ip link set dev eth0 up
ip addr add x.x.x.x/24 dev eth0
ip route add default via y.y.y.y dev eth0
```

| Placeholder  | Description              | Example        |
| ------------ | ------------------------ | -------------- |
| `x.x.x.x/24` | Static IP with CIDR mask | `10.0.0.50/24` |
| `y.y.y.y`    | Default gateway          | `10.0.0.1`     |
| `eth0`       | Interface name           | `ens18`        |

Verify connectivity to the Arch Linux repositories:

```bash
ping -c 3 archlinux.org
```

### D - Time Synchronization

Accurate system time is required to avoid TLS certificate validation failures during package retrieval.

```bash
timedatectl set-ntp true
timedatectl set-timezone "UTC"
timedatectl status
```

> [!TIP] 
> For production servers, UTC is the standard timezone choice. Application-level timezone conversion should be handled independently.

## Part I - Pre-Installation Configuration

### A - Network Configuration (Static IP)

Identify the available network interface:

```bash
ip a
```

Bring the interface up and assign a static address. Replace the placeholders with your actual network parameters:

```bash
ip link set dev eth0 up
ip addr add x.x.x.x/24 dev eth0
ip route add default via y.y.y.y dev eth0
```

| Placeholder  | Description              | Example        |
| ------------ | ------------------------ | -------------- |
| `x.x.x.x/24` | Static IP with CIDR mask | `10.0.0.50/24` |
| `y.y.y.y`    | Default gateway          | `10.0.0.1`     |
| `eth0`       | Interface name           | `ens18`        |

Verify connectivity to the Arch Linux repositories:

```bash
ping -c 3 archlinux.org
```

---

### B - Time Synchronization

Accurate system time is required to avoid TLS certificate validation failures during package retrieval.

```bash
timedatectl set-ntp true
timedatectl set-timezone "UTC"
timedatectl status
```

> [!TIP] 
> For production servers, UTC is the standard timezone choice. Application-level timezone conversion should be handled independently.

---

### C - Disk Partitioning

We use `parted` to create a GPT partition table with two partitions: a dedicated EFI System Partition (ESP) and a single partition spanning the remaining disk to serve as the LVM Physical Volume.

**Target Layout:**

|Partition|Size|Type|Usage|
|---|---|---|---|
|`/dev/sda1`|1 GiB|FAT32|EFI System Partition (`/boot`)|
|`/dev/sda2`|Remaining|LVM PV|Physical Volume for Volume Group|

```bash
parted /dev/sda mklabel gpt
parted /dev/sda mkpart "EFI" fat32 1MiB 1025MiB
parted /dev/sda set 1 esp on
parted /dev/sda mkpart "LVM" ext4 1025MiB 100%
```

> [!WARNING]
>  `parted` writes changes to disk immediately. There is no confirmation prompt. Double-check the target device (`/dev/sda`) before executing. On Proxmox, verify with `lsblk` that you are targeting the correct virtual disk.

---

### D - LVM Configuration

Initialize the Physical Volume, create the Volume Group, and allocate Logical Volumes according to the requested distribution.

**Logical Volume Allocation Strategy:**

|Logical Volume|Allocation|Rationale|
|---|---|---|
|`swap`|Fixed (sized to RAM)|See Red Hat swap guidelines below|
|`root`|20% of remaining free space|OS binaries, libraries, `/etc`|
|`var`|70% of remaining free space|Logs, databases, spool, caches|
|`home`|100% of remaining free space|User data|

> [!NOTE] 
> The `%FREE` directive in `lvcreate` operates on the free space remaining in the Volume Group at the time of execution. The swap volume is created first with a fixed size, then the percentage-based volumes are allocated sequentially from what remains. Adjust swap size according to your server's RAM: [Red Hat — Recommended System Swap Space](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/getting-started-with-swap_managing-storage-devices#recommended-system-swap-space_getting-started-with-swap).

```bash
pvcreate /dev/sda2
vgcreate volgroup0 /dev/sda2

lvcreate -L 8G -n swap volgroup0
lvcreate -l 20%FREE -n root volgroup0
lvcreate -l 70%FREE -n var volgroup0
lvcreate -l 100%FREE -n home volgroup0
```

Verify the LVM structure:

```bash
pvdisplay
vgdisplay
lvdisplay
```

---

### E - Filesystem Formatting

Format the ESP as FAT32 and the Logical Volumes as ext4. Labels are applied for clarity in `lsblk` output and fstab generation.

```bash
mkfs.fat -F32 /dev/sda1
mkfs.ext4 -L rootfs /dev/mapper/volgroup0-root
mkfs.ext4 -L varfs /dev/mapper/volgroup0-var
mkfs.ext4 -L homefs /dev/mapper/volgroup0-home
mkswap -L swapfs /dev/mapper/volgroup0-swap
```

---

### F - Mounting the Filesystem Hierarchy

The root volume must be mounted first. All other volumes are mounted relative to it. The ESP is mounted at `/boot`, which is the standard mountpoint for `systemd-boot`.

```bash
mount /dev/mapper/volgroup0-root /mnt

mkdir -p /mnt/boot
mount /dev/sda1 /mnt/boot -o noatime,nodev,nosuid,noexec,umask=0077

mkdir -p /mnt/var
mount /dev/mapper/volgroup0-var /mnt/var -o noatime,nodev,nosuid

mkdir -p /mnt/home
mount /dev/mapper/volgroup0-home /mnt/home -o noatime,nodev,nosuid,noexec

swapon /dev/mapper/volgroup0-swap
```

**Mount Option Rationale:**

|Option|Purpose|
|---|---|
|`noatime`|Disables access-time updates on reads; reduces unnecessary writes|
|`nodev`|Prevents interpretation of device special files on this filesystem|
|`nosuid`|Blocks set-user-ID and set-group-ID bits from taking effect|
|`noexec`|Prevents direct execution of binaries (applied to `/boot` and `/home`)|
|`umask=0077`|Restricts ESP file permissions to root only|

Verify the mount structure:

```bash
lsblk -f
mount | grep /mnt
```

---

## Part II: Base System Installation

### A - Package Installation

Install the base system with both requested kernels, LVM userspace tools, Dracut for initramfs generation, and essential utilities. No graphical drivers are included — this is a headless server deployment.

```bash
pacstrap -K /mnt base linux-firmware linux-hardened linux-lts lvm2 dracut neovim man-db man-pages texinfo busybox e2fsprogs
```

**Package Justification:**

|Package|Role|
|---|---|
|`base`|Minimal Arch Linux base (glibc, bash, coreutils, systemd, etc.)|
|`linux-firmware`|Firmware blobs for common hardware (virtio drivers included in kernel)|
|`linux-hardened`|Primary kernel — grsecurity-inspired patchset, reduced attack surface|
|`linux-lts`|Fallback kernel — long-term support, maximum stability|
|`lvm2`|Userspace tools for LVM management and activation at boot|
|`dracut`|Initramfs generator (replaces mkinitcpio)|
|`busybox`|Lightweight shell/utilities for dracut's initramfs environment|
|`e2fsprogs`|ext4 filesystem utilities (mkfs, fsck)|
|`neovim`|Console text editor for post-install configuration|
|`man-db`, `man-pages`, `texinfo`|Documentation access|

> [!NOTE] 
> `linux-firmware` is included as a baseline. 

---

### B - Fstab Generation

Generate the filesystem table using UUIDs for persistent device identification:

```bash
genfstab -U /mnt >> /mnt/etc/fstab
```

> [!WARNING] 
> Inspect `/mnt/etc/fstab` before proceeding. Verify that all LVM volumes are correctly mapped and that the mount options match the ones specified during manual mounting. Errors here will prevent the system from booting.

```bash
cat /mnt/etc/fstab
```

---

### Entering the Chroot

```bash
arch-chroot /mnt
```

---

## Part III: System Configuration (Inside Chroot)

### C - Locale and Timezone

```bash
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
```

Edit `/etc/locale.gen` and uncomment the required locale:

```bash
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
```

---

### D - Hostname

```bash
echo "archserver" > /etc/hostname
```

---

### E - Dracut Configuration

Dracut replaces `mkinitcpio` as the initramfs generator. We configure it for a minimal, host-only image that includes only the modules necessary to boot this specific machine.

Create the main configuration file:

**/etc/dracut.conf.d/00-server.conf**

```ini
hostonly="yes"
hostonly_cmdline="yes"
hostonly_cmdline="strict"
uefi="yes"

kernel_cmdline= " root=/dev/mapper/volgroup0-root rootfstype=ext4 rw quiet "

use_fstab="yes"

compress="zstd"

add_dracutmodules+=" lvm "
omit_dracutmodules+=" brltty bluetooth plymouth nfs iscsi "
```

|Directive|Purpose|
|---|---|
|`hostonly="yes"`|Builds an initramfs tailored to this machine's hardware only — smaller image, faster boot|
|`hostonly_cmdline="yes"`|Embeds the detected kernel command line parameters into the initramfs|
|`use_fstab="yes"`|Reads `/etc/fstab` to determine which filesystems to mount at boot|
|`compress="zstd"`|Zstandard compression — optimal ratio of speed to size|
|`add_dracutmodules+=" lvm "`|Explicitly includes LVM support in the initramfs|
|`omit_dracutmodules+=" ... "`|Excludes unnecessary modules to reduce image size and boot time|

|Parameter|Purpose|
|---|---|
|`root=/dev/mapper/volgroup0-root`|Specifies the root device via LVM device-mapper path|
|`rootfstype=ext4`|Explicitly declares the root filesystem type — avoids probing|
|`rw`|Mounts root read-write immediately (avoids the ro-then-remount cycle)|
|`quiet`|Suppresses non-critical kernel messages during boot|

> [!NOTE] 
> Using the device-mapper path (`/dev/mapper/volgroup0-root`) is reliable for LVM setups without encryption. UUID-based root specification is equally valid: obtain it with `blkid /dev/mapper/volgroup0-root` and use `root=UUID=<uuid>` instead.


> [!TIP] 
> On a Proxmox VM with no physical peripherals, omitting `brltty`, `bluetooth`, and `plymouth` eliminates unnecessary module detection and speeds up both image generation and boot. The `nfs` and `iscsi` modules are omitted because the root filesystem is local.

---

### F - Unified Kernel Image (UKI) Generation

A Unified Kernel Image bundles the kernel, initramfs, kernel command line, and OS release metadata into a single EFI-executable `.efi` file. This simplifies the boot chain: the firmware loads `systemd-boot`, which directly boots the UKI — no separate initramfs files, no separate configuration entries.

Generate the UKI for each installed kernel. The output filename must follow the pattern that `systemd-boot` auto-discovers:

```bash
dracut --force --uefi --kver $(ls /usr/lib/modules | grep hardened) /boot/EFI/Linux/arch-linux-hardened.efi

dracut --force --uefi --kver $(ls /usr/lib/modules | grep lts) /boot/EFI/Linux/arch-linux-lts.efi
```

>[!TIP] 
The `--force` flag overwrites an existing image. The `--uefi` flag produces a UKI. The `--kver` flag targets a specific kernel version directory under `/usr/lib/modules/`. Using command substitution with `ls` avoids hardcoding version strings that change on every kernel update.

Verify that both UKIs were created:

```
ls -lh /boot/EFI/Linux/
```

You should see two `.efi` files, each typically between 15–40 MiB depending on the kernel version and included modules.

---

### G - Automated UKI Regeneration on Kernel Upgrades

Dracut ships with pacman hooks that trigger initramfs regeneration on kernel install/upgrade. However, for UKI output, we must ensure the hooks produce `.efi` files in the correct location.

Verify that the dracut pacman hooks are in place:

```bash
ls /usr/lib/initcpio/post/
ls /etc/pacman.d/hooks/
```

> [!TIP]
>  The `dracut` package on Arch Linux includes automatic hooks for pacman. With the configuration in `/etc/dracut.conf.d/` specifying `uefi="yes"`, subsequent kernel upgrades via `pacman -Syu` will automatically rebuild the UKI. Confirm after the first upgrade by checking the timestamps on `/boot/EFI/Linux/*.efi`.

---

### H - Bootloader: systemd-boot

Install `systemd-boot` to the ESP:

```bash
bootctl install
```

This writes the `systemd-boot` EFI binary to `/boot/EFI/systemd/systemd-bootx64.efi` and creates the corresponding UEFI boot entry.

Because the `.efi` UKI files reside in `/boot/EFI/Linux/`, `systemd-boot` will **automatically discover and generate boot menu entries** for them. No manual entry files under `/boot/loader/entries/` are required.

Optionally configure the loader defaults:

**/boot/loader/loader.conf**

```ini
default arch-linux-hardened.efi
timeout 3
console-mode auto
editor no
```

| Directive           | Purpose                                                                  |
| ------------------- | ------------------------------------------------------------------------ |
| `default`           | Selects the default UKI to boot                                          |
| `timeout 3`         | Displays the boot menu for 3 seconds before auto-selecting               |
| `console-mode auto` | Lets the firmware choose the best console resolution                     |
| `editor no`         | Disables the kernel command line editor at boot (basic security measure) |

> [!WARNING] 
> Setting `editor no` is important on any server. Without it, anyone with physical (or virtual console) access can edit the kernel command line at boot time — for example, appending `init=/bin/bash` to gain a root shell without authentication.

> [!NOTE] 
> With UKIs, `systemd-boot` automatically detects `.efi` files placed in `/boot/EFI/Linux/`. No individual boot entry files (under `/boot/loader/entries/`) are required. The `default` line in `loader.conf` matches the filename directly.

Verify the installation:

```bash
bootctl status
```

---

## Part IV: Network Configuration (Post-Install)

### A - systemd-networkd Setup

This configures persistent static networking for the installed system. Determine the predictable interface name:

```bash
ip a
```

Create the network profile:

**/etc/systemd/network/20-wired.network**

```ini
[Match]
Name=e*

[Network]
Address=x.x.x.x/24
Gateway=y.y.y.y
DNS=1.1.1.1
```

> [!NOTE] 
> The `Name=e*` glob matches any interface starting with `e`, which covers both `eth0` (legacy) and `ens18` (Proxmox virtio predictable naming). For a machine with a single wired NIC, this is sufficient. For multi-NIC configurations, specify the exact interface name.

|Directive|Purpose|
|---|---|
|`Address`|Static IP with CIDR notation. Must match your network topology.|
|`Gateway`|Default route. Packets destined outside the local subnet are forwarded here.|
|`DNS`|Nameservers. Two entries for redundancy. Cloudflare is used here; replace as needed.|

Enable the networking services:

```bash
systemctl enable systemd-networkd
systemctl enable systemd-resolved
```

---

## Part V: Finalization

### A - Root Password

```bash
passwd
```

---

### B - Exit, Unmount, and Reboot

```bash
exit
umount -R /mnt
swapoff /dev/mapper/volgroup0

vgchange -an volgroup0

reboot
```

---

### C - Post-Reboot Verification

After the system boots, confirm the deployment:

```bash
uname -r
```

This should report the `linux-hardened` kernel version (the default UKI).

```bash
bootctl status
lsblk -f
ip a
systemctl status systemd-networkd
systemctl status systemd-resolved
```

> [!TIP] 
> To boot the `linux-lts` fallback kernel, press any key during the 3-second `systemd-boot` timeout and select `arch-linux-lts.efi` from the menu.