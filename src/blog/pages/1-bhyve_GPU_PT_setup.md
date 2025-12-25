# Setting up a FreeBSD bhyve VM with GPU passthrough

## Preamble

So, I need Windows for a [piece of software](https://redscientist.com/rtc)
and my PC is running FreeBSD.

I don't want to dualboot, so let's set up a GPU Passthrough virtual machine!


We got the following in our setup:
- FreeBSD 14.3-RELEASE-p4
- Ryzen 7 5800X
- AMD Radeon RX 7600
- Intel ARC A770
- 64 GB RAM
- 512 GB NVMe

Sooo... Let's begin!

## Preparation

First, let's think about which PCI devices will I pass through.

Intel ARC is still quite experimental in bhyve and only works with Linux VMs, so I will settle on
the Radeon RX 7600. I'm going to be using the VM remotely through a second PC, so we won't need USB and audio devices.
For remote access, because I'm going to be playing games with emulators I will use
[Sunshine](https://github.com/LizardByte/Sunshine) and [Moonlight](https://github.com/moonlight-stream/moonlight-qt).


!var bugs=When passing through on-board Realtek audio controllers to a VM, you will discover that they don't seem to
!var bugs={$bugs$} work. This is because of the infamous "reset bug" where the state of the config space turns out
!var bugs={$bugs$} incorrectly set. If you need audio in your VM, use a USB audio adapter.
||[Spoiler: audio passthrough bugs]{$bugs$}||


Okay, let's first find our GPU in `pciconf -lv`
```
# pciconf -lv
...
pcib5@pci0:4:0:0:       class=0x060400 rev=0x12 hdr=0x01 vendor=0x1002 device=0x1478 subvendor=0x0000 subdevice=0x0000
    vendor     = 'Advanced Micro Devices, Inc. [AMD/ATI]'
    device     = 'Navi 10 XL Upstream Port of PCI Express Switch'
    class      = bridge
    subclass   = PCI-PCI
pcib6@pci0:5:0:0:       class=0x060400 rev=0x12 hdr=0x01 vendor=0x1002 device=0x1479 subvendor=0x1002 subdevice=0x1479
    vendor     = 'Advanced Micro Devices, Inc. [AMD/ATI]'
    device     = 'Navi 10 XL Downstream Port of PCI Express Switch'
    class      = bridge
    subclass   = PCI-PCI
vgapci0@pci0:6:0:0:     class=0x030000 rev=0xcf hdr=0x00 vendor=0x1002 device=0x7480 subvendor=0x1da2 subdevice=0xe452
    vendor     = 'Advanced Micro Devices, Inc. [AMD/ATI]'
    device     = 'Navi 33 [Radeon RX 7600/7600 XT/7600M XT/7600S/7700S / PRO W7600]'
    class      = display
    subclass   = VGA
none0@pci0:6:0:1:       class=0x040300 rev=0x00 hdr=0x00 vendor=0x1002 device=0xab30 subvendor=0x1002 subdevice=0xab30
    vendor     = 'Advanced Micro Devices, Inc. [AMD/ATI]'
    device     = 'Navi 31 HDMI/DP Audio'
    class      = multimedia
    subclass   = HDA
...
```
We have four PCI devices that reference the GPU in `pciconf -lv`, the only ones we can pass through
without headaches are `pci0:6:0:0` (VGA) and `pci0:6:0:1` (audio).

We'll only pass through the VGA device since passing through DP/HDMI audio is not necessary on AMD and may result in
more pronounced reset bug (and Error 43 under Windows)

As for the VM storage, we'll use a ZFS zvol. I will create mine on zroot/opt/windows, sized at an appropriate 256G.
```
# zfs create -V 256G zroot/opt/windows
```
The VM OS will be Windows 11 LTSC.


Let's take a look at the VM script I'm going to be using:
```
#!/bin/sh

vm_name=winpt
pptdevs="6/0/0"

_gpu="
	-s 7:0,passthru,6/0/0,rom=rom/rx7600-techpowerup.bin
"
	# -s 7:1,passthru,6/0/1

_fbuf="
	-s 5:0,fbuf,tcp=0.0.0.0:5900
	-s 5:1,xhci,tablet
"

# bind the gpu to ppt
pptdevs=$pptdevs "/home/alex/Desktop/dev/ptnotes/scripts/pci/bind.sh"

_d(){ [ -e /dev/vmm/$vm_name ] && bhyvectl --destroy --vm $vm_name; }
trap _d INT EXIT
_d
bhyve -DSHAw \
	-c 8 -m 16g \
	-l bootrom,/usr/local/share/edk2-bhyve/BHYVE_UEFI_CODE.fd \
	-l com1,/dev/nmdm0A \
	-s 0,hostbridge -s 31,lpc \
	\
	-s 1:0,nvme,/dev/zvol/zroot/opt/windows \
	-s 1:1,ahci-cd,disk/windows11.iso \
	-s 2,virtio-net,tap0 \
	\
	$_fbuf \
	\
	$vm_name

echo $?
```

What does everything here do?
- `-DSHAw`:
	- Destroy VM (clear RAM) on shutdown
	- Wire memory (VM RAM is in the vmm.ko kernel module, not the bhyve process)
	- Free the vCPU cycles to the system when encountering a HLT instruction
	- Generate ACPI tables
	- Ignore unimplemented MSRs
- `.../pci/bind.sh` (*from [here!](https://github.com/9vlc/ptnotes)*):
	- Bind the GPU's PCI device to the `ppt` driver without editing loader.conf
- `_d`
	- Clean up before and after shutdown

If you're not going to use `bind.sh`, make sure to add the following to `/boot/loader.conf.d/vm.conf`:
```
vmm_load=YES

# only needed for AMD, set to 0 if intel
hw.vmm.amdvi.enable=1

# example pci devices, replace with whatever you want to passthrough
pptdevs="2/0/0 6/0/0 6/0/1"
```

Also, add the following to `/etc/sysctl.conf`
```
kern.consmute=1
```
.. to mute dmesg output on tty0 *(or switch to tty1+ to escape any dmesg output)*

Why? Any output on the screen while the GPU is passed into the VM will result in memory corruption and driver crash.
We do not want that. So, avoid having any movement, blinking, etc. on the screen when the VM is running.
I recommend running the VM through SSH or redirecting the logs to a file. Also disable moused,
the mouse will be of no use while the VM is running.


Oh, almost forgot, `rx7600-techpowerup.bin` set in `,rom=...` of the GPU device
is the *[VBIOS](https://en.wikipedia.org/wiki/Video_BIOS)*.
You can dump yours with [GPU-Z](https://www.techpowerup.com/gpuz/) under Windows, using
[my method](https://github.com/9vlc/ptnotes/blob/main/notes/dumping_igpu_vbios_freebsd.md) under FreeBSD or
[download a dump from TechPowerUp](https://www.techpowerup.com/vgabios/).

If you're going to download a dump from TechPowerUp, make sure it's:
- for the same GPU model
- the VRAM amount matches
- the PCI IDs match
- *(optional)* the clock frequencies match *(you might get a free over/underclock if they don't :D)*

## Sooo... Let's start!

A quick Windows install later (with choosing my country as Ireland for all of the EU benefits of course),
here we arrive at the desktop!

![alt: A clean Windows 11 desktop with start menu open](img/1/firstlaunch.png)

No networking yet, so let's replace the Windows iso with virtio tools and install ethernet drivers.
```
...
	-s 1:1,ahci-cd,disk/virtio-win.iso \
...
```
You can grab the VirtIO iso from [here](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio).

After getting access to the interwebs, install all the needed Windows updates.


Set the VM how you like and take a snapshot in case something goes wrong
```
# zfs snap zroot/opt/windows@clean
```
.. you can later revert back to the snapshot with `zfs rollback zroot/opt/windows@clean`

## Sunshine and Moonlight

### Installation

Sunshine is the server I'm going to be using for the Moonlight remote desktop app.
I'm going to be installing Sunshine with [Chocolatey](https://chocolatey.org).

||[Chocolatey Installation]Refer to [here](https://chocolatey.org/install#individual) for Chocolatey installation instructions.||

Installing Sunshine with Choco is as simple as
```
# choco install sunshine
```
.. ran in a PowerShell prompt as Administrator.


After this, grab Moonlight for your client device over
[here](https://github.com/moonlight-stream/moonlight-qt) if you want the full QT interface or
[here](https://github.com/moonlight-stream/moonlight-embedded) if you only need a CLI for the connection and configuration.

FreeBSD has the Moonlight client in the `games/moonlight-qt` package.
If you don't want the full QT interface, you can use `games/moonlight-embedded`.

### Configuration

For most Sunshine configuration, please refer to
[the official documentation](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html).

If you need audio, install [Steam](https://store.steampowered.com/about) since it provides a virtual audio driver compatible with Sunshine.


!var ms=Pair with the VM using `moonlight pair ***IP***`, then connect to it with
!var ms={$ms$} `moonlight stream ***IP*** -width 1920 -height 1080 -fps 60 -bitrate 50000`
!var ms={$ms$} *(the bitrate is in Kbps, adjust the values as desired)*
||[moonlight-embedded setup]{$ms$}||
!var ms=Pair with the VM using the QT interface, go to moonlight settings *(cogwheel at top right)*
!var ms={$ms$} and adjust resolution, bitrate and FPS as desired. After that you can connect to the VM at any time.
||[moonlight-qt setup]{$ms$}||

Now, with a working, usable VM, let's move on to fixing the problems we've created for ourselves.

## It might be usable, but we're nowhere near done!

### Less annoying reset bug

First, let's address the elephant in the room: **reset bug.**
Every time you restart the VM you need to restart the entire host, else you would get *Error 43* in Device Manager on the GPU.


To combat that, we can use [RadeonResetBugFix](https://github.com/inga-lovinde/RadeonResetBugFix).
Grab the latest tag exe from [here](https://github.com/inga-lovinde/RadeonResetBugFix/releases/download/v0.1.7/RadeonResetBugFixService.exe),
drop it into `C:\ResetBugFix.exe`, open PowerShell as Administrator and run `C:\ResetBugFix.exe install`, then wait for it to install the service.


> Please note that RadeonResetBugFix slows down the GPU initialization by about 30 seconds!
>
> The VM may also some times take a while to boot.


Will the reset bug still happen? Yeah, but only when:
- You force shutdown the VM
- The VM bluescreens
- bhyve crashes

So just be careful and shut the VM down via the Windows power options or sending a SIGTERM to bhyve *(as that causes an ACPI shutdown)*.

### CPU pinning

If you're going to do heavy workloads in the VM, you may notice it stuttering a lot. Most of the cases it's because of the vCPUs
jumping all over the place in the scheduler which you can see in a utility like `htop` or `btop`.
The fix for this is pinning the CPUs with bhyve's `-p` option.

Though, I've seen many people do this wrong, so let me show you how to do it correctly.


If you have multithreading enabled (multiple threads per core), which you can check with
```
# sysctl kern.smp.threads_per_core
```
.. you cannot just pin your VM's vCPUs to random cores.
Instead, you need to pin the vCPUs to cores from correct groups, else you might even degrade perfomance.


So, here's how to do that.

Check you scheduling topology:
```
# sysctl kern.sched.topology_spec
kern.sched.topology_spec:
<groups>
  <group level="1" cache-level="3">
    <cpu count="12" mask="fff,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0">0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11</cpu>
    <children>
      <group level="2" cache-level="2">
        <cpu count="2" mask="3,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0">0, 1</cpu>
        <flags>
          <flag name="THREAD">THREAD group</flag>
          <flag name="SMT">SMT group</flag>
        </flags>
      </group>
      <group level="2" cache-level="2">
        <cpu count="2" mask="c,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0">2, 3</cpu>
        <flags>
          <flag name="THREAD">THREAD group</flag>
          <flag name="SMT">SMT group</flag>
        </flags>
      </group>
      <group level="2" cache-level="2">
        <cpu count="2" mask="30,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0">4, 5</cpu>
        <flags>
          <flag name="THREAD">THREAD group</flag>
          <flag name="SMT">SMT group</flag>
        </flags>
      </group>
      <group level="2" cache-level="2">
        <cpu count="2" mask="c0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0">6, 7</cpu>
        <flags>
          <flag name="THREAD">THREAD group</flag>
          <flag name="SMT">SMT group</flag>
        </flags>
      </group>
      <group level="2" cache-level="2">
        <cpu count="2" mask="300,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0">8, 9</cpu>
        <flags>
          <flag name="THREAD">THREAD group</flag>
          <flag name="SMT">SMT group</flag>
        </flags>
      </group>
      <group level="2" cache-level="2">
        <cpu count="2" mask="c00,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0">10, 11</cpu>
        <flags>
          <flag name="THREAD">THREAD group</flag>
          <flag name="SMT">SMT group</flag>
        </flags>
      </group>
    </children>
  </group>
</groups>
```
*(XML beautified for better viewing)*

We have a bunch of groups, and in this scenario each cpu core is split in
two smt threads next to one another.


I've seen two scenarios of the sched topo:

Separate groups for cores, each containing two threads:
```
Group 0: Core 0 (Thread 0, Thread 1)
Group 1: Core 1 (Thread 2, Thread 3)
Group 2: Core 2 (Thread 4, Thread 5)
Group 3: Core 3 (Thread 6, Thread 7)
...
```
.., and two groups, first half of threads in one, second half in the other:
```
Group 0: Core 0, Core 1, Core 2, Core 3 (Thread 0, Thread 1, Thread 2, Thread 3)
Group 1: Core 0, Core 1, Core 2, Core 3 (Thread 4, Thread 5, Thread 6, Thread 7)
```

So, to avoid placing pairs of VM cores on a single core from its pairs of SMT threads,
we have to do this for either of the scenarios:


Scenario 1: Pin the vCPUs only to odd or even cores:
```
-p 0,0
-p 1,2
-p 2,4
```

Scenario 2: Pin the vCPUs only to the first or last half of your cores:
```
-p 0,5
-p 1,6
-p 2,7
```

Notice that the logic here only works if the number of your VMs vCPUs is half the number of
your actual CPU cores. If you're assigning more cores to the VM than half of your cores and
want to use pinning, pin all the cores you can like you're supposed to, and leave the rest
to your scheduler or pin them to the secondary SMT threads. I personally recommend pinning
them to the highest threads corresponding to the already pinned ones.

> There is also a third scenario: Intel CPUs with hybrid cores. I do not own one, but after seeing
> its topology, I'm feeling incredible dread and don't even want to imagine vCPU pinning on them.

### Partly spoofing the VM

Some software refuses to work under virtual machines for "security reasons".

If you're using software that does that, you should probably find an alternative to it since that
is a very dumb move from its creators.

... But if you still want to use it, here's how you can attempt to hide that you are running it under bhyve:

#### Enabling a VM lessens Anti-VM

Enable Hyper-V on Windows. I know, this sounds dumb, why would you enable the hypervisor
when bhyve doesn't even support nested virtualization??

The reason is that when software with Anti-VM sees that you have Hyper-V enabled, it lessens its protection.
Why? Hyper-V is a *type 1 hypervisor*. That means when you enable Hyper-V, your entire host system turns into a
virtual machine and what you call Windows is being ran as a guest inside!
Of course, that would trigger lots of Anti-VM checks, so software developers have to lessen their VM detection if
Windows has Hyper-V enabled.

#### SMBIOS vars

Change SMBIOS variables by adding this to bhyve's commandline:
```
-o bios.vendor="American Megatrends Inc."
-o bios.version="L4"
-o bios.release_date="12/15/2022"
-o bios.family_name="To be filled with Skymont"
-o system.manufacturer="ASSUSTeK COMPUTER INC."
-o system.product_name="Z890-I STRIX"
-o system.serial_number="2123111111"
-o system.sku="Z890-I STRIX"
-o system.version="1.0"
-o board.manufacturer="ASSUSTeK COMPUTER INC."
-o board.product_name="Z890-I STRIX"
-o board.version="arrowlake"
-o board.serial_number="2123111111"
-o board.asset_tag="To be filled by ruben991"
-o board.location="To be filled by O.E.M."
-o chasis.manufacturer="ASSUSTeK COMPUTER INC."
-o chasis.version="1.0"
-o chasis.serial_number="C444444789"
-o chasis.asset_tag="To be filled by vlc"
-o chasis.sku="Z890-I STRIX"
```
Just example values, please change this to something else!

#### LPC

Change LPC configuration to host's, especially if your motherboard is for the same CPU
as the one you're spoofing is for:
```
-o pci.0.31.0.pcireg.vendor=host
-o pci.0.31.0.pcireg.device=host
-o pci.0.31.0.pcireg.subvendor=host
-o pci.0.31.0.pcireg.subdevice=host
```

#### Don't.

Recompile bhyve with alternative PCI device IDs, find behavior to change.

How do you do that? Too lazy to docment. Maybe sometime in a future blogpost.

![No.](img/1/glendano.jpg)

## At last - screenshots!

### Early Sunshine
![alt: Connected to the Windows VM with Sunshine while it is still at the boot screen](img/1/early-sunshine.png)

Sunshine is started pretty early in boot as a service, so as long as Windows has network access you get display!

----
### Fortnite
![alt: Playing the game Lego Fortnite Brick World in the VM](img/1/fortnite.png)

----
### Windows Experience(tm) 1
![alt: Error message: "The system detected an overrun of a stack-based buffer in this application. Blah blah..." in a system app at boot](img/1/windows-moment-1.png)

----
### Windows Experience(tm) 2
![alt: Audacity sound editor saying "Failed to send crash report"](img/1/windows-moment-2.png)
