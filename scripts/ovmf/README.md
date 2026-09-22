# Windows UEFI firmware fix (OVMF 4M)

Replaces a hypervisor's own OVMF firmware with the host's 4M firmware, so that the
Windows images (built with the host's 4M OVMF by `windows-image-builder`) boot.

**Do you need this? Not always.** What is known (checked against package lists and the
snap sources) and what is not:

| Hypervisor | Firmware it uses | Status |
|---|---|---|
| Managed OpenStack | provider's | not your business |
| libvirt from Ubuntu 24.04 packages | `ovmf` in noble ships **only 4M** files, same layout as the image builder | fix not needed |
| libvirt from Ubuntu 22.04 packages | `ovmf` in jammy ships **both** 2M and 4M files | unverified which one QEMU picks |
| MicroStack | own firmware inside the snap (2M) | black screen observed, fix needed |
| `openstack-hypervisor` (Sunbeam) | bundles jammy's `ovmf` (2M **and** 4M files) and redirects `/usr/share/OVMF` into the snap (source: archived 2023 snapshot of its `snapcraft.yaml`; current packaging not verifiable) | **unverified**: boot a Windows VM first |

So "the hypervisor bundles firmware" is not the same as "the 2M firmware is used": which
variant libvirt picks depends on QEMU's firmware descriptors. The reliable check is a test.
To see what a running Windows VM actually uses, dump its definition and look at the
`<loader>` path (`OVMF_CODE_4M...` = fine, `OVMF_CODE.secboot.fd` = the 2M file). If the VM
boots normally, do nothing.

Nova cannot pick the firmware variant per image (only `hw_firmware_type=uefi`); libvirt
on the hypervisor chooses it. That is why the fix needs root on the hypervisor host.

## Layout: one engine, providers to find the firmware

| Script | Job |
|---|---|
| `ovmf-apply.sh` | **Generic engine.** Gets the directories that hold the hypervisor's `OVMF_*.fd` files, bind-mounts the 4M files over them, persists this via `cave-ovmf-bindmount.service`. Does not search for anything. |
| `ovmf-snap.sh` | **Provider for snaps** (MicroStack, `openstack-hypervisor`, ...). Finds the firmware inside `/snap/*/current`, adds the snap's nova-compute/libvirt units as `--before`, calls the engine. |

Both support `--dry-run` (shows what would change, needs no root) and `--remove`
(unmount and clean up). Full options: `./ovmf-apply.sh --help`, `./ovmf-snap.sh --help`.

## Usage

```bash
./ovmf-snap.sh --dry-run                    # what would be touched on this host
sudo ./ovmf-snap.sh microstack              # MicroStack
sudo ./ovmf-snap.sh openstack-hypervisor    # Sunbeam, only if its Windows VMs fail

# by hand, any layout (find the directory yourself, e.g. `find / -name 'OVMF_CODE*.fd'`)
./ovmf-apply.sh --dry-run /path/to/dir
sudo ./ovmf-apply.sh --before some-nova-compute.service /path/to/dir

sudo ./ovmf-snap.sh --remove                # undo
```

Point the tool at paths that survive updates (`/snap/<name>/current/...`, not a revision
number). A snap refresh replaces the firmware again: `systemctl restart cave-ovmf-bindmount.service`.

## Adding a provider for another layout

A provider only has to find the directories and call the engine, see `ovmf-snap.sh`
(about 40 lines). For example a container-based hypervisor (Kolla) would resolve the
directory of the libvirt container's firmware and call
`ovmf-apply.sh --before <unit> <dir>`; note that firmware inside a container image
is typically better replaced by mounting the host files into the container.
