#!/usr/bin/env bash
# =============================================================================
# create-vm.sh — exact VirtualBox provisioning used for the Linux-VitBox v5 round
# =============================================================================
# Host: Ubuntu 24.04 LTS @ 192.168.100.17 (was .180 before a mid-round reboot).
# Guest: Debian 13 (trixie) genericcloud, cloud-init provisioned.
#
# Disk: FRESH copy of the PRISTINE Debian 13 cloud image (NOT the QEMU-benchmarked
# overlay), grown to 40G, converted qcow2 -> VDI (dynamic). No VirtualBox needed
# to convert — qemu-img does it:
#   cp ~/qemu-bench/debian-13-genericcloud-amd64.qcow2 base.qcow2
#   qemu-img resize base.qcow2 40G
#   qemu-img convert -f qcow2 -O vdi base.qcow2 vbox-disk.vdi
#
# cloud-init seed (cidata ISO, attached as DVD on the SATA controller):
#   genisoimage -output seed.iso -volid cidata -joliet -rock \
#     user-data meta-data network-config
#
# NETWORKING — two deviations from the Windows VBox round, both deliberate:
#  1) NIC is virtio-net, NOT 82540EM/e1000. The genericcloud kernel
#     (linux-image-cloud-amd64) ships virtio-only drivers and has no e1000
#     module, so the emulated Intel NIC never appears. virtio-net also keeps
#     this guest on the SAME base image + kernel as Linux-Quemu, so the
#     hypervisor is the only variable between the two Linux VMs. The Windows
#     VBox guest was a full netinst install (all drivers) and used e1000 to
#     match Win-VMware; per plan.txt §6.6 overhead is never merged across
#     hosts, so this within-host-consistent choice is not a confound.
#  2) An explicit network-config (DHCP all en*) is required: cloud-init's
#     FALLBACK network detection brought the NIC up under QEMU/SLIRP but NOT
#     under VBox NAT (interface stayed down, no lease, ~120s networkd-wait
#     stall). The explicit config fixes it; instance-id was bumped so
#     cloud-init re-applied it.
#
# NAT is VirtualBox's own NAT engine (its native default NAT — same "each
# hypervisor on its default NAT" rule as QEMU/VMware/Hyper-V). SSH forwarded
# host:2223 -> guest:22. VBox NAT is userspace (like QEMU SLIRP), so it needs
# no host FORWARD chain and is unaffected by the Docker/lxdbr0 iptables issue.
#
# NOTE: not CPU-pinned (VBoxManage has no clean per-VM affinity; matches the
# Windows VBox round, which was also un-pinned).
# =============================================================================
set -e
VM=DebianBenchmark
VBoxManage createvm --name "$VM" --ostype Debian_64 --basefolder ~/vbox-bench/machines --register
VBoxManage modifyvm "$VM" --memory 16384 --cpus 4 --vram 16
VBoxManage modifyvm "$VM" --nic1 nat --nictype1 virtio      # NOT 82540EM — see header
VBoxManage modifyvm "$VM" --natpf1 "ssh,tcp,,2223,,22"
VBoxManage modifyvm "$VM" --vrde off --rtcuseutc on
VBoxManage storagectl "$VM" --name "SATA Controller" --add sata --controller IntelAhci --portcount 2
VBoxManage storageattach "$VM" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium ~/vbox-bench/vbox-disk.vdi
VBoxManage storageattach "$VM" --storagectl "SATA Controller" --port 1 --device 0 --type dvddrive --medium ~/vbox-bench/seed.iso
VBoxManage startvm "$VM" --type headless
