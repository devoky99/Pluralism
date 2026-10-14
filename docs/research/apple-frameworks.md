# Apple Virtualization.framework and Hypervisor.framework for a custom VM app on M4 Pro (state: 14 October 2026)

Target: MacBook Pro 14", M4 Pro (12 CPU / 16 GPU cores, 48 GB), guests Linux ARM64 and Windows 11 ARM64 only, no x86.

## How to read this report

- **[verified]**: seen in a primary source (developer.apple.com documentation including its availability metadata, Apple WWDC session pages, Apple release notes, or the source code of the named open-source project, inspected on 2026-10-14).
- **[reported]**: blog, forum, vendor marketing, issue tracker, or third-party commentary.
- **[unclear]**: could not be verified; treat as an open question to test on the machine.
- Apple docs were read in their Markdown form (`https://developer.apple.com/documentation/<path>.md`). The availability line quoted ("macOS 14.0+") is the `availability` field in that metadata.
- Open-source code was inspected at these commits: QEMU master (hvf log up to 2026-09-14), UTM `95ae00acd0d2` (2026-10-14), Tart `12501370cc26` (2026-10-13), Lima `0fa2b92a0af4` (2026-10-14), libkrun `dc1a18ada58c` (2026-09-30), Code-Hex/vz main (2026-10-14).

---

## 0. Executive summary

| Question | Answer |
|---|---|
| Linux ARM64 on VZ | First-class. EFI boot, virtio block/NVMe, NAT, virtiofs, vsock, sound, clipboard (SPICE agent), resizable display, nested virtualization (M3+), USB passthrough (macOS 27). Weak spots: no built-in 3D GPU, save/restore of Linux VMs is unreliable/undocumented, no TPM device. [verified, details below] |
| Windows 11 ARM64 on VZ | Not supported by Apple. It has been made to boot (Oct 2026) only with a **private** API (`_setPerformanceMonitoringUnitEmulationEnabled`) plus a custom UEFI framebuffer driver, a custom WinPE install path (no TPM), virtio-win drivers. No 3D, no sound, no suspend, nested Hyper-V/WSL2 hangs. [reported] |
| GPU acceleration for Linux on VZ | None built in (virtio-gpu 2D only). macOS 27 `VZCustomVirtioDevice` makes a do-it-yourself virtio-gpu (virgl) possible; one project reports it working. [verified API; reported result] |
| Hypervisor.framework (HVF) | Full low-level control: vCPU run loop, stage-2 mapping, in-kernel GICv3 (`hv_gic_*`, macOS 15), EL2/nested (macOS 15, M3+), SME/SME2 state (macOS 15.2, M4), 4K IPA granule (macOS 26), TLB/SError/WFI helpers (macOS 27). You must provide firmware, ACPI/DT, PCIe, all devices, display, TPM. [verified] |
| Ad-hoc signing, no paid account | `com.apple.security.virtualization` and `com.apple.security.hypervisor` work ad-hoc (Lima, Code-Hex/vz, QEMU all sign with `codesign -s -`). `com.apple.vm.networking` (bridged), `com.apple.vm.device-access` and very likely `com.apple.developer.accessory-access.usb` (USB passthrough) need an Apple-authorized provisioning profile; ad-hoc use gets the process killed. vmnet custom networks via `VZVmnetNetworkDeviceAttachment` (macOS 26) are reported to work **without** `com.apple.vm.networking` and without root. [verified / reported] |
| New in macOS 26 | ASIF disks for VZ, `VZVmnetNetworkDeviceAttachment` + new vmnet network API (custom topologies, DHCP reservations, port forwarding), `VZVirtualMachine.queue`; HVF IPA granule (4 KB). [verified] |
| New in macOS 27 | USB passthrough (AccessoryAccess + `VZUSBPassthroughDevice*`), DiskImageKit (layered ASIF, overlays, cache), `VZCustomVirtioDevice` (custom virtio for Linux), EFI Secure Boot APIs for Linux, macOS guest provisioning, `VZVirtualMachineViewAdaptor`, `label`, vmnet loopback port forwarding, built-in Intel translation for Linux (irrelevant here); HVF TLB invalidate, SError, WFI time, new ID registers. [verified] |
| M4 Pro | 8 P + 4 E cores [verified]. ISA "technically ARMv9.2-A", SME + SME2, **no SVE/SVE2** [verified via LLVM]. Nested virt supported (M3 and later). |

---

## A. Virtualization.framework (VZ)

### A.0 Version map (feature first appeared)

| macOS | Linux-relevant additions (all [verified] via doc availability unless noted) |
|---|---|
| 11 | `VZVirtualMachine`, `VZVirtualMachineConfiguration`, `VZLinuxBootLoader`, `VZVirtioBlockDeviceConfiguration`, `VZDiskImageStorageDeviceAttachment`, `VZNATNetworkDeviceAttachment`, `VZBridgedNetworkDeviceAttachment`, `VZFileHandleNetworkDeviceAttachment`, `VZMACAddress`, `VZVirtioSocketDeviceConfiguration`, `VZVirtioEntropyDeviceConfiguration`, `VZVirtioTraditionalMemoryBalloonDeviceConfiguration`, `requestStop()` |
| 12 | `VZGenericPlatformConfiguration`, `VZVirtioFileSystemDeviceConfiguration`, `VZSingleDirectoryShare`/`VZMultipleDirectoryShare`, `VZVirtioSoundDeviceConfiguration`, `VZUSBKeyboardConfiguration`, `VZUSBScreenCoordinatePointingDeviceConfiguration`, `VZVirtualMachineView` (+`capturesSystemKeys`), `VZDiskImageCachingMode`, `VZDiskImageSynchronizationMode`, `stop()` |
| 13 | `VZEFIBootLoader`, `VZEFIVariableStore`, `VZGenericMachineIdentifier`, `VZVirtioGraphicsDeviceConfiguration` (2D), `VZSpiceAgentPortAttachment`, `VZVirtioConsoleDeviceConfiguration`, `VZUSBMassStorageDeviceConfiguration`, `VZVirtualMachineStartOptions`, Rosetta for Linux, `VZMacTrackpadConfiguration` |
| 14 | `saveMachineStateTo`/`restoreMachineStateFrom`, `validateSaveRestoreSupport()`, `VZNVMExpressControllerDeviceConfiguration`, `VZNetworkBlockDeviceStorageDeviceAttachment`, `VZDiskBlockDeviceStorageDeviceAttachment`, `automaticallyReconfiguresDisplay`, `VZGraphicsDisplay` (`reconfigure(sizeInPixels:)`), `VZVirtioGraphicsScanout`, `VZMacKeyboardConfiguration` |
| 15 | Nested virtualization (`isNestedVirtualizationEnabled/Supported`), `VZXHCIControllerConfiguration`, `VZUSBController` (`attach`/`detach`), `VZUSBMassStorageDevice` hot-plug |
| 26 | ASIF in `VZDiskImageStorageDeviceAttachment`, `VZVmnetNetworkDeviceAttachment`, `VZVirtualMachine.queue` |
| 27 | `VZUSBPassthroughDeviceConfiguration`/`VZUSBPassthroughDevice`/`VZUSBController.Delegate` (+AccessoryAccess), `VZDiskImageStorageDeviceAttachment(diskImage:...)` (+DiskImageKit), `VZCustomVirtioDevice*` family, Secure Boot on `VZEFIVariableStore` + `VZEFISignature*`, `VZVirtualMachineViewAdaptor`, `VZVirtualMachineConfiguration.label`, `VZMacGuestProvisioningOptions` (macOS guests) |

Sources: https://developer.apple.com/documentation/virtualization.md and the per-class `.md` pages cited in each section; https://developer.apple.com/documentation/updates/virtualization.md

### A.1 Boot

| API | Since | Linux guest | Notes |
|---|---|---|---|
| `VZLinuxBootLoader(kernelURL:)`, `.initialRamdiskURL`, `.commandLine` | 11 | yes | Only valid with `VZGenericPlatformConfiguration`. Apple's guide says compressed (`.gz`) kernels must be unpacked first; example command line `console=hvc0`. [verified] https://developer.apple.com/documentation/virtualization/vzlinuxbootloader.md, https://developer.apple.com/documentation/virtualization/creating-and-running-a-linux-virtual-machine.md. Encore reports arm64 EFI zboot kernels must be unwrapped first [reported] https://encore.dev/blog/firecracker-apple-silicon |
| `VZEFIBootLoader()` + `.variableStore` | 13 | yes | Boots unmodified ISOs (Apple GUI Linux sample uses ISO as `VZUSBMassStorageDeviceConfiguration`). [verified] https://developer.apple.com/documentation/virtualization/vzefibootloader.md, https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac.md |
| `VZEFIVariableStore(creatingVariableStoreAt:options:)`, `init(url:)` | 13 | yes | Persist per VM (NVRAM file). [verified] https://developer.apple.com/documentation/virtualization/vzefivariablestore.md |
| `VZEFIVariableStore.enrollDefaultSecureBootSignatures()`, `enableSecureBootUsingDefaultPlatformKey()`, `enableSecureBoot(platformKey:)`, `enrollSecureBootSignatures(_:)`, `disableSecureBoot()`, `resetSecureBoot()`, `isSecureBootEnabled`, `enrolledSecureBootSignatures`; `VZEFISignatureDatabaseConfiguration`, `VZEFISignatureList`, `VZEFISignatureX509Certificate`, `VZEFISignatureSHA256Hash` | **27** | yes | Default enrollment = Microsoft KEKs, "UEFI CA signatures", latest dbx; doc: "allows Microsoft-signed Linux distributions to boot with Secure Boot enabled". Whether the Windows Production CA is included is **[unclear]**. [verified] https://developer.apple.com/documentation/virtualization/vzefivariablestore/enrolldefaultsecurebootsignatures().md, https://developer.apple.com/documentation/virtualization/vzefisignaturedatabaseconfiguration.md |
| `VZGenericPlatformConfiguration` (`machineIdentifier`) | 12 | yes | Required for Linux/NVMe. [verified] https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration.md |
| `VZGenericMachineIdentifier` (`dataRepresentation`) | 13 | yes | Persist per VM. [verified] https://developer.apple.com/documentation/virtualization/vzgenericmachineidentifier.md |

Secure Boot setup as UTM does it (UTM `Configuration/UTMAppleConfigurationBoot.swift` lines 206-207) [verified]:

```swift
let store = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL, options: [])
try store.enrollDefaultSecureBootSignatures()          // macOS 27
try store.enableSecureBootUsingDefaultPlatformKey()    // macOS 27, Apple-managed PK
bootLoader.variableStore = store
```

Limitations: there is no API to supply your own UEFI firmware image, add a TPM, or provide ACPI tables. [verified by absence in API surface; see A.11]

### A.2 Storage

| API | Since | Linux | Notes |
|---|---|---|---|
| `VZVirtioBlockDeviceConfiguration(attachment:)`, `blockDeviceIdentifier` | 11 | yes | Default choice. [verified] https://developer.apple.com/documentation/virtualization/vzvirtioblockdeviceconfiguration.md |
| `VZNVMExpressControllerDeviceConfiguration(attachment:)` | 14 | **Linux only** | NVMe 1.1b; valid only with `VZGenericPlatformConfiguration`. WWDC23: "NVMe is for Linux virtual machines only" and virtio-blk "remains the simpler, faster choice in most cases". [verified] https://developer.apple.com/documentation/virtualization/vznvmexpresscontrollerdeviceconfiguration.md, https://developer.apple.com/videos/play/wwdc2023/10007/ |
| `VZUSBMassStorageDeviceConfiguration(attachment:)` | 13 | yes | Installer ISOs; hot-plug via `VZUSBMassStorageDevice` (15). [verified] https://developer.apple.com/documentation/virtualization/vzusbmassstoragedeviceconfiguration.md |
| `VZDiskImageStorageDeviceAttachment(url:readOnly:)`, `(url:readOnly:cachingMode:synchronizationMode:)` | 11 / 12 | yes | Formats: RAW and ASIF (26+). [verified] https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment.md |
| `VZDiskImageStorageDeviceAttachment(diskImage:cachingMode:synchronizationMode:)` | **27** | yes | Takes a DiskImageKit `DiskImage`, incl. stacks. [verified] https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment/init(diskimage:cachingmode:synchronizationmode:).md |
| `VZDiskImageCachingMode` `.automatic/.cached/.uncached` | 12 | yes | [verified] https://developer.apple.com/documentation/virtualization/vzdiskimagecachingmode.md |
| `VZDiskImageSynchronizationMode` `.full/.fsync/.none` | 12 | yes | [verified] https://developer.apple.com/documentation/virtualization/vzdiskimagesynchronizationmode.md |
| `VZNetworkBlockDeviceStorageDeviceAttachment(url:timeout:isForcedReadOnly:synchronizationMode:)` + delegate | 14 | yes | NBD client; needs `com.apple.security.network.client`. [verified] https://developer.apple.com/documentation/virtualization/vznetworkblockdevicestoragedeviceattachment.md |
| `VZDiskBlockDeviceStorageDeviceAttachment(fileHandle:readOnly:synchronizationMode:)` | 14 | yes | Raw `/dev/rdiskN`; root needed to open, Apple recommends opening in a privileged helper and passing the fd via XPC. [verified] https://developer.apple.com/documentation/virtualization/vzdiskblockdevicestoragedeviceattachment.md |

**ASIF (Apple Sparse Image Format)**

- Introduced in macOS 26; usable as a VZ backing store via `VZDiskImageStorageDeviceAttachment` [verified] (macOS 26 release notes, "Disk Images": https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes.md).
- Create: `diskutil image create blank --fs none --format ASIF --size 128GiB disk.asif` (RAW: `--format RAW`), or Disk Utility > New Image > Blank Image. [verified] (VZDiskImageStorageDeviceAttachment doc above). `hdiutil` creation of ASIF is not documented [reported] https://eclecticlight.co/2025/06/12/macos-tahoe-brings-a-new-disk-image-format/
- Programmatic creation: on macOS 27 via DiskImageKit `DiskImage(creating: .asif(url:blockCount:blockSize:))` [verified] https://developer.apple.com/documentation/diskimagekit.md. On macOS 26 there is no public API besides shelling out to `diskutil`; UTM uses the **private** DiskImages2 framework on 26 [verified in UTM `Services/UTMAppleDiskImage.swift`].
- Usable by third-party VZ apps: yes (UTM, documented by Apple). [verified]
- Properties: file size proportional to stored data, structure independent of host FS sparse support, so it stays small when copied (RAW sparse files can balloon on non-APFS targets). [verified doc / reported eclecticlight]
- Performance vs raw: Apple publishes no numbers. eclecticlight measured ~5.8 GB/s read, 6.6 GB/s write (M3 Pro, unencrypted APFS) and calls it faster than UDRW/UDSP [reported]. Direct ASIF-vs-RAW VM benchmark: **[unclear]**. A commenter reports ASIF did not reclaim space for macOS guests but did for Linux guests [reported] https://eclecticlight.co/2026/06/12/macos-virtualisation-is-leaping-forward-in-golden-gate/

**DiskImageKit (macOS 27)** [verified] https://developer.apple.com/documentation/diskimagekit.md, https://developer.apple.com/videos/play/wwdc2026/224/
- Layers: base (RAW or ASIF, can be read-only and shared), one optional cache layer (ASIF), overlay layers (ASIF, copy-on-write). Layer UUID/parent UUID tracking; `truncate(blockCount:)`; no flatten/merge of overlays [reported, comments].
- Apple: shallow stacks perform better; when cloning, also copy the EFI variable store.

```swift
// Apple's DiskImageKit overview pattern (macOS 27)
let base = try DiskImage(opening: .open(url: baseURL))
var stacked = try base.appending(.asifLayer(url: overlayURL, type: .overlay))
let attachment = try VZDiskImageStorageDeviceAttachment(diskImage: stacked) // per Apple docs
let disk = VZVirtioBlockDeviceConfiguration(attachment: attachment)
```

Performance data point (M4 Pro, macOS 27, 2 GiB write + flush) [reported] https://mustafaakin.dev/blog/windows-on-tart/: Ubuntu guest on VZ 3.4-5.5 GB/s, Windows guest on VZ 0.9-1.1 GB/s, Windows on QEMU+HVF 1.8-2.2 GB/s, host 5.5-6.0 GB/s; `synchronizationMode: .full` (Tart default) costs ~30 %.

### A.3 Networking

| API | Since | Entitlement | Notes |
|---|---|---|---|
| `VZVirtioNetworkDeviceConfiguration` + `.macAddress` (`VZMACAddress.randomLocallyAdministered()`, `init(string:)`) | 11 | none | Custom MACs supported. [verified] https://developer.apple.com/documentation/virtualization/vzmacaddress.md |
| `VZNATNetworkDeviceAttachment` | 11 | none | No port-forwarding API. [verified] https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment.md |
| `VZBridgedNetworkDeviceAttachment(interface:)`, `VZBridgedNetworkInterface.networkInterfaces` | 11 | **`com.apple.vm.networking`** | Without it the configuration is invalid. [verified] https://developer.apple.com/documentation/virtualization/vzbridgednetworkdeviceattachment.md |
| `VZFileHandleNetworkDeviceAttachment(fileHandle:)`, `.maximumTransmissionUnit` | 11 | none | Connected `SOCK_DGRAM` socket, raw Ethernet frames; you run a userspace network stack (e.g. gvisor-tap-vsock). Apple engineers recommend this for host-only/port forwarding on older macOS. [verified doc; reported forum https://developer.apple.com/forums/thread/783894] |
| `VZVmnetNetworkDeviceAttachment(network:)` | **26** | see below | Backed by a `vmnet_network_ref` from `vmnet_network_create`. A VM can only use a network created by the same app process; share across processes via `vmnet_network_copy_serialization` / `vmnet_network_create_with_serialization` (XPC). [verified] https://developer.apple.com/documentation/virtualization/vzvmnetnetworkdeviceattachment/init(network:).md |

vmnet changes in macOS 26 [verified] https://developer.apple.com/documentation/vmnet.md: `vmnet_network_configuration_create(mode, &status)`, `vmnet_network_create`, `..._set_ipv4_subnet`, `..._set_ipv6_prefix`, `..._set_mtu`, `..._set_external_interface`, `..._add_dhcp_reservation`, `..._add_port_forwarding_rule(config, proto, family, internal_port, external_port, &internal_addr)`, `..._disable_dhcp/_dns_proxy/_nat44/_nat66/_router_advertisement`, `vmnet_interface_start_with_network` (for non-VZ VMMs), `vmnet_port_forwarding_rule_get_details`. Limits: 32 interfaces total, 4 per guest. macOS 27: "port forwarding APIs now support port forwarding when communicating over loopback" [verified] (macOS 27 release notes, Virtualization: https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes.md). Bridged mode is not supported for vmnet DHCP reservations [reported, Apple DTS] https://developer.apple.com/forums/thread/822025?page=2. A forum user could not get port forwarding working on 26 [reported] https://developer.apple.com/forums/thread/822658.

Entitlement for vmnet via VZ: the vmnet doc says a **sandboxed** process needs `com.apple.vm.networking` [verified]. Code-Hex/vz PR #205 states `VZVmnetNetworkDeviceAttachment` "does not require the `com.apple.vm.networking` entitlement nor root privileges" and the vz tests are ad-hoc signed with only `com.apple.security.virtualization` [reported / verified in source] https://github.com/Code-Hex/vz/pull/205. Lima's vmnet PR runs without root on macOS 26, measured ~29 Gbit/s vs 1.24 Gbit/s for socket_vmnet; macOS 26.2 relaxed the "same executable" requirement [reported] https://github.com/lima-vm/lima/pull/4394. UTM exposes "NAT Network" and "Host Only" modes through this API on macOS 26 [verified, `Configuration/UTMAppleConfigurationNetwork.swift`]. Conclusion: **unsandboxed ad-hoc app: very likely works; sandboxed: likely needs the restricted entitlement [unclear, test]**.

```swift
// macOS 26: shared-mode network with a TCP port forward host:2222 -> guest:22
import vmnet
var status = vmnet_return_t.VMNET_SUCCESS
guard let cfg = vmnet_network_configuration_create(operating_modes_t.VMNET_SHARED_MODE, &status) else { fatalError("\(status)") }
var guest = in_addr(); inet_pton(AF_INET, "192.168.64.10", &guest)
_ = vmnet_network_configuration_add_port_forwarding_rule(cfg, UInt8(IPPROTO_TCP), sa_family_t(AF_INET), 22, 2222, &guest)
guard let net = vmnet_network_create(cfg, &status) else { fatalError("\(status)") }
let nic = VZVirtioNetworkDeviceConfiguration()
nic.attachment = VZVmnetNetworkDeviceAttachment(network: net)
```
(Pair with `vmnet_network_configuration_add_dhcp_reservation` so the guest IP is known in advance.)

macOS 26.0 fixed: bridge-mode VM start broke networking of running shared/host-mode VMs [verified] (macOS 26 release notes).

### A.4 Graphics and display

- `VZVirtioGraphicsDeviceConfiguration` (13) with `scanouts: [VZVirtioGraphicsScanoutConfiguration(widthInPixels:heightInPixels:)]` is the only Linux device. It is **virtio-gpu 2D** ("Virtio GPU 2D is a paravirtualized device that allows Linux to provide surfaces to the host") [verified] https://developer.apple.com/videos/play/wwdc2022/10002/, https://developer.apple.com/documentation/virtualization/vzvirtiographicsdeviceconfiguration.md
- **No 3D/virgl/venus for Linux in VZ as of macOS 27.** The Metal paravirtual GPU (`VZMacGraphicsDeviceConfiguration`) is macOS-guest only; macOS 27's Metal improvements (argument buffers, ICBs) are for macOS guests. [verified for API surface; WWDC26 224]
- macOS 27 escape hatch: `VZCustomVirtioDevice` (see A.6) lets you implement your own virtio device. RiftVM reports a working virtio-gpu (device ID 16, virgl via virglrenderer + ANGLE → Metal, presented in its own Metal layer), with 2.6x-45x glmark2 gains over llvmpipe; limitation: no callbacks for guest config-space writes yet. [reported] https://medium.com/@everettjf/riftvm-running-3d-accelerated-omarchy-on-a-mac-with-macos-27s-custom-virtio-3f845e1dd08e. UTM has an open feature request for the same [reported] https://github.com/utmapp/UTM/issues/7921.
- `VZVirtualMachineView`: `automaticallyReconfiguresDisplay` (14; applies to Linux per WWDC23), `capturesSystemKeys` (12, default false), `virtualMachine`, `adaptor: VZVirtualMachineViewAdaptor?` (27, Swift 6 Sendable wrapper). [verified] https://developer.apple.com/documentation/virtualization/vzvirtualmachineview.md, https://developer.apple.com/documentation/virtualization/vzvirtualmachineviewadaptor.md
- `VZGraphicsDisplay.reconfigure(sizeInPixels:)`, `addObserver(_:)` (14) for programmatic resolution changes. [verified] https://developer.apple.com/documentation/virtualization/vzgraphicsdisplay.md
- Multiple displays (more than one scanout) for Linux and maximum resolution: **[unclear]**, not documented.
- Forum reports: "negative scanouts" warnings and display update/focus issues when wrapping the view in SwiftUI [reported] https://developer.apple.com/forums/tags/virtualization?page=4

### A.5 Input

| API | Since | Guest |
|---|---|---|
| `VZUSBKeyboardConfiguration` | 12 | Linux and macOS [verified] |
| `VZUSBScreenCoordinatePointingDeviceConfiguration` (absolute pointer) | 12 | Linux and macOS [verified] |
| `VZMacKeyboardConfiguration` | 14 | designed for macOS guests (Globe key etc.) [verified] https://developer.apple.com/documentation/virtualization/vzmackeyboardconfiguration.md |
| `VZMacTrackpadConfiguration` | 13 | recognized by macOS 13+ guests [verified] https://developer.apple.com/documentation/virtualization/vzmactrackpadconfiguration.md |

Linux guests: use the USB keyboard + USB screen-coordinate pointer. Two-finger-tap right-click does not reach Linux guests [reported] (forum listing above).

### A.6 Integration devices

| API | Since | Linux | Notes |
|---|---|---|---|
| `VZVirtioFileSystemDeviceConfiguration(tag:)` + `VZSharedDirectory`, `VZSingleDirectoryShare`, `VZMultipleDirectoryShare` | 12 | yes | Guest: `mount -t virtiofs <tag> <dir>`, `CONFIG_VIRTIO_FS`. Share can be changed at runtime via `VZVirtioFileSystemDevice.share`. [verified] https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration.md, https://developer.apple.com/documentation/virtualization/shared-directories.md |
| `VZSpiceAgentPortAttachment` (`sharesClipboard`, `spiceAgentPortName`) on a `VZVirtioConsoleDeviceConfiguration` port | 13 | yes | **Clipboard only** (text and images), guest needs `spice-vdagent`. Dynamic resolution is handled by virtio-gpu + `automaticallyReconfiguresDisplay`, not SPICE. Drag and drop: not offered **[unclear, undocumented]**. [verified] https://developer.apple.com/documentation/virtualization/vzspiceagentportattachment.md |
| `VZVirtioConsoleDeviceConfiguration` (`ports`) | 13 | yes | Multiport console. [verified] |
| `VZVirtioSocketDeviceConfiguration` (vsock) | 11 | yes | Only one per VM. [verified] |
| `VZVirtioTraditionalMemoryBalloonDeviceConfiguration` | 11 | yes | Only one per VM. [verified] |
| `VZVirtioEntropyDeviceConfiguration` | 11 | yes | [verified] |
| `VZVirtioSoundDeviceConfiguration` + `VZHostAudioOutputStreamSink` / `VZHostAudioInputStreamSource` | 12 | yes | `CONFIG_SND_VIRTIO`; input needs `NSMicrophoneUsageDescription`. [verified] https://developer.apple.com/documentation/virtualization/audio.md |
| `VZCustomVirtioDeviceConfiguration` (`deviceID`, `pciClassID`, `pciSubclassID`, `virtioQueueCount`, `mandatoryFeatures`, `optionalFeatures`, `deviceSpecificConfiguration`, `sharedMemoryRegions`, `supportsSaveRestore`, `provider`), `VZCustomVirtioDevice` (`delegate`, `deviceQueue`, `negotiatedFeatures`, `sharedMemoryRegions`, `guestMemoryMapping(atPhysicalAddress:length:)`, `queue(at:)`, `requestReset()`, `update(_:completionHandler:)`), `VZVirtioQueue`, `VZVirtioQueueElement`, `VZVirtioSharedMemoryRegion(Configuration)` (`mapMemory(_:atOffset:size:)`), `VZCustomVirtioDeviceDelegateProvider`; `VZVirtualMachineConfiguration.customVirtioDevices` | **27** | **Linux only** | Needs a custom guest driver unless you match an existing virtio device ID. [verified] https://developer.apple.com/documentation/virtualization/vzcustomvirtiodevice.md, https://developer.apple.com/documentation/virtualization/custom-drivers.md |

Custom virtio skeleton per WWDC26 session 224 (names from the session) [verified]:
```swift
let dev = VZCustomVirtioDeviceConfiguration()
dev.deviceID = 4; dev.pciClassID = 0x10; dev.pciSubclassID = 0x00; dev.virtioQueueCount = 1
dev.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: q, delegate: myConfigDelegate)
config.customVirtioDevices = [dev]
// myConfigDelegate.customVirtioConfiguration(_:didCreateDevice:) -> device.delegate = myDeviceDelegate
// myDeviceDelegate.customVirtioDevice(_:didReceiveNotificationFor:) -> queue.nextElement(), element.returnToQueue()
```

### A.7 Lifecycle and save/restore

- `start(completionHandler:)`/`start()`, `start(options:)` (13, only `VZMacOSVirtualMachineStartOptions` subclass exists), `pause`, `resume`, `stop` (12, destructive), `requestStop()` (11), `canStart/canPause/...`, `state`, delegate `guestDidStop`, `virtualMachine(_:didStopWithError:)`, `virtualMachine(_:networkDevice:attachmentWasDisconnectedWithError:)`. All `VZVirtualMachine` calls must run on `vm.queue` (property public since 26). [verified] https://developer.apple.com/documentation/virtualization/vzvirtualmachine.md
- `saveMachineStateTo(url:)` (VM must be paused) and `restoreMachineStateFrom(url:)` (VM must be stopped; ends paused), `validateSaveRestoreSupport()`: since macOS 14. The docs do **not** restrict them to macOS guests. [verified] https://developer.apple.com/documentation/virtualization/vzvirtualmachine/savemachinestateto(url:completionhandler:).md
- Save files are hardware-encrypted and bound to Mac and user account; restore needs an unlocked login session (keychain); state files from a newer OS are rejected; device configuration (e.g. MAC address) must match. [verified WWDC23; reported DTS https://developer.apple.com/forums/thread/782007]
- **Linux guests: [unclear], evidence is negative or mixed.**
  - `validateSaveRestoreSupport` fails with "Unsupported graphics device in configuration" for `VZVirtioGraphicsDeviceConfiguration` (macOS 14.2.1) [reported] https://developer.apple.com/forums/thread/745168
  - Tart only allows `--suspendable` for macOS VMs and drops audio input and entropy devices [verified in Tart `Sources/tart/Commands/Run.swift`, `VM.swift`]. UTM: must remove Sound and Entropy devices [reported] https://newreleases.io/project/github/utmapp/UTM/release/v4.4.4
  - Encore: save of a minimal headless Linux VM fails with `VZErrorInternal` although validation passes; they suspect a private entitlement [reported, speculation] https://encore.dev/blog/firecracker-apple-silicon
  - Windows (private-API boot): "Apple's framework refuses to save the VM" [reported] https://mustafaakin.dev/blog/windows-on-tart/
  - Counter-signal: macOS 27 added `VZCustomVirtioDeviceConfiguration.supportsSaveRestore` (custom virtio is Linux-only), which implies save/restore for Linux VMs is an intended scenario [verified API].
  - Throughput: default 30-40 MB/s; ~830 MB/s save / ~380 MB/s restore after `NSAppSleepDisabled`, `ProcessInfo` `.userInitiated/.latencyCritical` activity and `IOPOL_IMPORTANT` [reported] https://developer.apple.com/forums/thread/828750
  - macOS 27 fixed save with USB passthrough devices and a restore crash with hot-plugged USB storage [verified] (macOS 27 release notes).
- Known: Linux VMs suspended on M1-M3 hang when resumed on M4; fixed in guest kernels after 3 Dec 2024 [reported, Parallels KB] https://kb.parallels.com/en/131124

### A.8 USB

- `VZXHCIControllerConfiguration` (15), `VZUSBController.attach(device:)`/`detach(device:)`/`usbDevices` (15), `VZUSBMassStorageDevice` hot-plug (15). [verified] https://developer.apple.com/documentation/virtualization/vzusbcontroller.md
- **Generic USB passthrough: macOS 27 only.** `VZUSBPassthroughDeviceConfiguration(device: AAUSBAccessory)`, `VZUSBPassthroughDevice`, `VZUSBController.Delegate.usbController(_:usbPassthroughDeviceDidDisconnect:)`; devices come from the AccessoryAccess framework (`AAUSBAccessoryManager.shared.registerListener(_:matchingCriteria:)`, `AAUSBAccessoryListener`, `AAUSBAccessoryMatchingCriteria`). Works for **macOS and Linux VMs**; user approves via a menu-bar extra; app must be a Dock app; entitlement `com.apple.developer.accessory-access.usb` ("Claim USB Accessory" capability). [verified] https://developer.apple.com/documentation/virtualization/vzusbpassthroughdeviceconfiguration.md, https://developer.apple.com/documentation/accessoryaccess/aausbaccessorymanager.md, https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-access.usb.md, https://developer.apple.com/videos/play/wwdc2026/224/
- Reported: FIDO keys, flash drives, SD readers work; a USB webcam did not (isochronous endpoints) [reported, comment] https://eclecticlight.co/2026/06/12/macos-virtualisation-is-leaping-forward-in-golden-gate/. Sandbox support was fixed during the 27 beta [verified, release notes].
- Before macOS 27 there is no generic passthrough in VZ. [verified by API history]

### A.9 Nested virtualization

- `VZGenericPlatformConfiguration.isNestedVirtualizationSupported` (class) and `.isNestedVirtualizationEnabled`, macOS 15; "available for Mac with the M3 chip, and later" → **M4 Pro: supported**. Apple frames it as Linux VM hosts in Linux VMs. [verified] https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration/isnestedvirtualizationsupported.md, https://developer.apple.com/documentation/updates/virtualization.md
- Windows Hyper-V/WSL2 inside a VZ Windows guest hangs [reported] (mustafaakin.dev). QEMU disables SME when nested virt is on because "Apple doesn't support the nested virtualisation + SME combination" [verified, QEMU commit ca34bcb0141d].

### A.10 Limits

- `VZVirtualMachineConfiguration.minimumAllowedCPUCount`, `maximumAllowedCPUCount`, `minimumAllowedMemorySize`, `maximumAllowedMemorySize` are runtime class properties; numeric values are **not documented [unclear]**; query them on the machine. [verified API] https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration.md
- vCPUs can exceed physical cores; on M1 Max >cores caused severe slowdown; recommended 2 to (cores-1) [reported] https://eclecticlight.co/2022/07/18/virtualisation-on-apple-silicon-macs-4-core-allocation-in-vms/
- Concurrent VMs: the 2-VM cap (`VZErrorVirtualMachineLimitExceeded`, kernel quota `hv_apple_isa_vm_quota`) applies **only to macOS guests**; Linux guests are limited by resources [reported] https://juergenkoller.software/en/blog/more-than-two-macos-vms-on-apple-silicon.html, https://khronokernel.com/macos/2023/08/08/AS-VM.html. Apple sample: framework supports multiple simultaneous VMs [verified].

### A.11 Windows 11 ARM64 under Virtualization.framework

Apple documents macOS and Linux guests only [verified, framework overview]. Concrete 2026 report (Tart fork, M4 Pro, macOS 26.6/27, Windows 11 25H2 build 26200 and Server 2025) [reported] https://mustafaakin.dev/blog/windows-on-tart/, https://korben.info/windows-11-mac-apple-silicon-tart.html:

| Area | Finding |
|---|---|
| CPU/PMU | Boot requires private `VZGenericPlatformConfiguration._setPerformanceMonitoringUnitEmulationEnabled`; `_setFineGrainedTrapsEmulationEnabled` optional. Consistent with QEMU source: "Windows wants at least the PMU's cycles counter to be available" [verified, `target/arm/hvf/hvf.c`]. |
| Firmware display | Apple's EFI exposes no framebuffer usable by Windows Boot Manager; VM dies ~3.5 s in. Fix: ~7 KB custom UEFI driver providing a RAM framebuffer (ramfb-like). A commenter also cites the missing public RAM framebuffer as the blocker. |
| TPM | None in VZ. Setup blocks (`TpmVersion: Hard`); worked around by a custom WinPE + DISM install. |
| Secure Boot | Passes Setup's check (using macOS 27 APIs). |
| Drivers | virtio-win ARM64: viostor, viosock, virtio-fs + WinFsp, network; display-only driver. No virtio-sound driver. |
| Missing | 3D acceleration, sound, suspend/save, nested Hyper-V/WSL2. |
| Performance | 7-Zip 90-93 % of host (same as QEMU+HVF); disk 0.9-1.1 GB/s (half of QEMU). |

Verdict for your app: Windows via VZ depends on private API and is unsupported, so it can break with any macOS update. For Windows, plan on an HVF-based VMM (QEMU/UTM-style: EDK2, ramfb, swtpm TPM 2.0, virtio-win) or accept the private-API risk. Microsoft only authorizes Parallels Desktop (and Windows 365) for Windows 11 on Apple silicon [verified] https://support.microsoft.com/windows/options-for-using-windows-11-with-mac-computers-with-apple-m1-and-m2-chips-cd15fd62-9b34-4b78-b0bc-121baa3c568c

### A.12 New in macOS 26 (WWDC25) and macOS 27 (WWDC26)

macOS 26 [verified] https://developer.apple.com/forums/thread/787491, https://developer.apple.com/documentation/updates/virtualization.md:
- ASIF for `VZDiskImageStorageDeviceAttachment`.
- `VZVmnetNetworkDeviceAttachment` + vmnet network/configuration API (custom topologies, subnet, DHCP reservations, port forwarding, NAT/DNS toggles, XPC serialization).
- `VZVirtualMachine.queue`.
- Hypervisor: IPA granule configuration down to 4 KB.
- Containerization (Apple, Apache-2.0) requires macOS 26 and uses VZ [verified] https://github.com/apple/containerization

macOS 27 [verified] https://developer.apple.com/videos/play/wwdc2026/224/, macOS 27 release notes:
- macOS guest provisioning: `VZMacGuestProvisioningOptions` (`fullName`, `username`, `password`, `logsInAutomatically`, `enablesRemoteLogin`) via `VZMacOSVirtualMachineStartOptions`.
- USB passthrough: AccessoryAccess + `VZUSBPassthroughDeviceConfiguration`/`VZUSBPassthroughDevice`/`VZUSBController.Delegate`.
- DiskImageKit + `VZDiskImageStorageDeviceAttachment(diskImage:...)`.
- `VZCustomVirtioDevice` family (Linux).
- EFI Secure Boot for Linux (`VZEFIVariableStore` Secure Boot methods, `VZEFISignature*`).
- Metal argument buffers / ICBs for macOS guests; iCloud in VMs.
- `VZVirtualMachineViewAdaptor`, `VZVirtualMachineConfiguration.label` (max 64 chars).
- vmnet port forwarding over loopback.
- Intel binary translation for Linux VMs integrated into macOS (no Rosetta install) [verified] https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms.md
- Not announced: Linux 3D GPU, TPM, generic PCI passthrough, Windows support. [verified by absence in session and docs]

### A.13 Entitlements, signing, sandbox

| Entitlement | Needed for | Ad-hoc (`codesign -s -`) on personal Mac |
|---|---|---|
| `com.apple.security.virtualization` | any VZ use | **Works.** Lima (`vz.entitlements`, `codesign ... -s -`), Code-Hex/vz tests [verified in source]. Apple: config invalid without it [verified]. Unrestricted per TN3125 category is not stated explicitly by Apple, but evidenced by these projects. |
| `com.apple.security.hypervisor` | HVF | **Works.** QEMU `scripts/entitlement.sh` signs `codesign --entitlements accel/hvf/entitlements.plist --force -s -` [verified]. |
| `com.apple.vm.networking` | bridged (VZ), legacy vmnet in sandboxed processes | **Restricted**: "restricted to developers of virtualization software... contact your Apple representative" [verified] https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.vm.networking.md. Locally signing with it gets the process killed; needs Apple-authorized provisioning profile and paid program [reported, Apple DTS] https://developer.apple.com/forums/thread/656411. UTM's ad-hoc ("unsigned") build omits it [verified]. |
| `com.apple.vm.device-access` | IOUSBHost USB capture (HVF/QEMU-style VMMs) | Restricted like above [reported DTS]; UTM ad-hoc build omits it [verified]. Not used by VZ [reported]. |
| `com.apple.developer.accessory-access.usb` | macOS 27 USB passthrough | Added as Xcode capability [verified]. Whether it works ad-hoc or with a free Personal Team: **[unclear]**; `com.apple.developer.*` entitlements are normally profile-authorized (TN3125 restricted category) and UTM's ad-hoc build omits it [verified in UTM]. |
| `com.apple.security.network.client/server` | NBD attachment, network sockets in sandbox | unrestricted |
| `com.apple.security.app-sandbox` | optional | VZ does not require sandbox (Apple's own instructions say you may remove it) [verified] https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project.md |

TN3125: macOS does not require a provisioning profile; sandbox, hardened-runtime, `get-task-allow` and application-groups entitlements are unrestricted; restricted entitlements must be authorized by a profile; standalone executables cannot carry restricted entitlements [verified] https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles.md

```sh
# personal, unsandboxed build
codesign --force --sign - --options runtime --entitlements MyVMM.entitlements MyVMM.app
# MyVMM.entitlements: com.apple.security.virtualization = true
#                     (+ com.apple.security.hypervisor if you also link HVF)
```

Practical implications for an ad-hoc app: NAT, file-handle networking, vmnet shared/host networks (26+, unsandboxed), everything except bridged networking and probably USB passthrough. Recommended: run unsandboxed for a personal tool.

---

## B. Hypervisor.framework (HVF) on Apple silicon

Model: one VM per process (`hv_vm_create`), one vCPU per pthread (`hv_vcpu_create` on that thread, never on dispatch queues), you handle exits. [verified] https://developer.apple.com/documentation/hypervisor.md, https://developer.apple.com/documentation/hypervisor/vcpu-management.md

### B.1 API surface and history

| Area | APIs | Since |
|---|---|---|
| VM | `hv_vm_create(hv_vm_config_t?)`, `hv_vm_destroy()`, `hv_vm_config_create()` | 11 / config 13 [verified] |
| IPA size | `hv_vm_config_set_ipa_size`, `hv_vm_config_get_ipa_size`, `hv_vm_config_get_default_ipa_size`, `hv_vm_config_get_max_ipa_size` | 13 [verified] |
| IPA granule | `hv_vm_config_set_ipa_granule`, `hv_vm_config_get_ipa_granule`, `hv_vm_config_get_default_ipa_granule`, `HV_IPA_GRANULE_4KB/16KB` | **26** [verified] |
| Memory | `hv_vm_map(addr, ipa, size, flags)` (page-aligned, single VM region from `mmap`/`mach_vm_allocate`), `hv_vm_unmap`, `hv_vm_protect` | 11 [verified] |
| vCPU | `hv_vcpu_config_create`, `hv_vcpu_config_get_feature_reg`, `hv_vcpu_config_get_ccsidr_el1_sys_reg_values`, `hv_vm_get_max_vcpu_count`, `hv_vcpu_create/destroy/run`, `hv_vcpus_exit`, `hv_vcpu_get/set_reg`, `..._simd_fp_reg`, `..._sys_reg`, `hv_vcpu_get/set_pending_interrupt`, `hv_vcpu_get_exec_time`, trap-debug controls | 11 [verified] |
| Exits | `hv_vcpu_exit_t`; `HV_EXIT_REASON_CANCELED`, `_EXCEPTION`, `_VTIMER_ACTIVATED`, `_UNKNOWN` | 11 [verified] https://developer.apple.com/documentation/hypervisor/hv_exit_reason_t.md |
| Timer | `hv_vcpu_get/set_vtimer_mask`, `hv_vcpu_get/set_vtimer_offset` | 11 [verified] |
| GICv3 | `hv_gic_config_create`, `hv_gic_config_set_distributor_base`, `..._redistributor_base`, `..._msi_region_base`, `..._msi_interrupt_range`, `hv_gic_create` (after `hv_vm_create`, before any vCPU; one per VM; distributor, redistributors, MSIs, ICC/ICH/ICV regs), `hv_gic_set_spi`, `hv_gic_send_msi`, state save/restore (`hv_gic_state_create`, `hv_gic_state_get_data`, `hv_gic_set_state`), size/alignment getters | **15** [verified] https://developer.apple.com/documentation/hypervisor/hv_gic_create(_:).md |
| EL2 / nested | `hv_vm_config_get_el2_supported`, `hv_vm_config_set_el2_enabled`, `hv_vm_config_get_el2_enabled` (M3+) | **15** [verified] |
| SME | `hv_sme_config_get_max_svl_bytes`, `hv_vcpu_get/set_sme_state` (PSTATE.SM/ZA), `..._sme_z_reg`, `..._sme_p_reg`, `..._sme_za_reg`, `..._sme_zt0_reg` | **15.2** [verified] https://developer.apple.com/documentation/hypervisor/hv_vcpu_get_sme_state(_:_:).md |
| New 27 | `hv_vcpu_invalidate_tlb` + `hv_tlbi_op_t` (`HV_TLBI_OP_VMALLE1IS`, `VAE1IS`, `ASIDE1IS`, range ops...), `hv_vcpu_get/set_serror`, `hv_vcpu_get_wait_for_interrupt_time` (needs `hv_gic_create`), `HV_FEATURE_REG_ID_AA64ISAR2_EL1`, `..._PFR2_EL1` (+ MMFR3/MMFR4 and matching `HV_SYS_REG_*`, listed together) | **27** [verified for invalidate_tlb, serror, WFI time, ISAR2, PFR2] |

Notes:
- Max IPA: QEMU commit message: up to macOS 15 the max was 39 bits, since macOS 15 it is 40 bits [verified, QEMU commit d54ffa54fbe0 https://qemu.googlesource.com/qemu/+/d54ffa54fbe0691f8e953b867cbe65642efbdf67%5E%21]. On M4 Max the private sysctls show `kern.hv.ipa_size_16k` = 2^42 and `kern.hv.ipa_size_4k` = 2^40, and the public API reports the smaller value [reported] https://patchew.org/QEMU/20251219183716.4379-1-j@getutm.app. M4 Pro value: **[unclear]**, query `hv_vm_config_get_max_ipa_size` on the machine.
- EL2: enabling it does not reset the vCPU into EL2; you must set `HV_REG_CPSR` (M field) and EL2 registers yourself. HVF provides no architectural reset state [reported, Apple forum accepted answer] https://developer.apple.com/forums/thread/775546. With EL2 the GIC exposes ICH registers to the guest hypervisor; HVF's interrupt-injection functions do not target nested guests [verified, hv_gic_create doc].
- SME on M4: macOS 15.2 started advertising SME to HVF guests; this broke QEMU (`cannot disable SME`) until it hid SME (Feb 2025) [reported] https://gitlab.com/qemu-project/qemu/-/issues/2665, https://patchew.org/QEMU/20250224165735.36792-1-j@getutm.app. QEMU now exposes FEAT_SME2 when available ("Starting from M4 cores and MacOS 15.2 SDK, HVF can virtualise FEAT_SME2", commit 55cd59813f14, March 2026) and saves/restores SME state, but disables SME with nested virt [verified, QEMU source]. Parallels Desktop 27: "Windows and Linux virtual machines can now use Apple's SME CPU feature on M4 and M5 chips" [verified vendor KB] https://kb.parallels.com/131168/. **For your VMM: implement SME state save/restore (Z, P, ZA, ZT0, SVCR) or mask `ID_AA64PFR1_EL1.SME`.**
- PMU: with the Apple vGIC, HVF exposes a minimal PMU if a valid `ID_AA64DFR0_EL1.PMUVer` is set [verified, QEMU commit 520320720a11 message].
- WFI: HVF only delivers `VTIMER_ACTIVATED` inside `hv_vcpu_run`; an idle-vCPU implementation must arm a host timer for `CNTV_CVAL_EL0` [verified, QEMU commit a86024eb2df5].
- macOS 26 HV_DENIED report turned out to be a missing entitlement in a broken Xcode project [reported] https://developer.apple.com/forums/thread/808360

Minimal VM bring-up order (as in QEMU `hvf_arch_vm_create`) [verified]:
```c
hv_vm_config_t cfg = hv_vm_config_create();
hv_vm_config_set_ipa_size(cfg, 40);
bool el2 = false; hv_vm_config_get_el2_supported(&el2);      // macOS 15+
if (el2) hv_vm_config_set_el2_enabled(cfg, true);            // M3+ only
hv_vm_create(cfg);
hv_gic_config_t g = hv_gic_config_create();
hv_gic_config_set_distributor_base(g, 0x08000000);
hv_gic_config_set_redistributor_base(g, 0x080A0000);
hv_gic_create(g);                 // after hv_vm_create, before hv_vcpu_create
// per thread: hv_vcpu_create(&vcpu, &exit, NULL); set MPIDR_EL1, CPSR, PC...; loop hv_vcpu_run
```

### B.2 Entitlement

`com.apple.security.hypervisor` is required "to use the Hypervisor APIs in any process" [verified] https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.hypervisor.md. Ad-hoc signing works (QEMU, UTM's unsigned QEMULauncher) [verified in source]. Using vmnet directly from an HVF VMM: `vmnet_interface_start_with_network` (26) works without root for Lima's QEMU/krunkit path [reported, Lima PR 4394]; legacy `vmnet_start_interface` needs root or `com.apple.vm.networking`. USB capture via IOUSBHost needs restricted `com.apple.vm.device-access`.

### B.3 What a custom HVF VMM must implement

Linux ARM64 (direct kernel or EFI):
- Guest memory layout + `hv_vm_map`; device tree or ACPI; vCPU reset state (PC, X0 = DTB, CPSR EL1h, MPIDR); PSCI over HVC/SMC (CPU_ON/OFF, SYSTEM_RESET/OFF); generic timer (vtimer exits, physical timer emulation if needed); GICv3 (use `hv_gic_*` on 15+, else emulate); PL011 UART and PL031 RTC (optional); virtio-mmio or PCIe ECAM host bridge + virtio-pci (blk, net, console, vsock, rng, fs, gpu, input, balloon); MSI via `hv_gic_send_msi` (QEMU uses **GICv2m-style MSI because ITS is not supported with the Apple vGIC**) [verified, QEMU `hw/arm/virt.c`]; framebuffer (virtio-gpu or ramfb); EDK2 ArmVirtQemu if you want EFI boot. [general knowledge; specific QEMU facts verified in source]

Windows 11 ARM64 additionally: UEFI (EDK2) with GOP (ramfb), ACPI tables (Windows on Arm boots via ACPI, not DT [reported, general knowledge, not verified in this session]), PMU cycle counter [verified QEMU comment], TPM 2.0 (QEMU: swtpm + `tpm-tis-device`; UTM enables TPM 2.0 + Secure Boot by default for Windows [verified] https://docs.getutm.app/updates/v4.3/), Secure Boot keys in NVRAM, XHCI + USB keyboard/tablet, virtio-pci devices with virtio-win drivers (`viostor`, `NetKVM`) [reported] https://linaro.atlassian.net/wiki/spaces/WOAR/pages/28914909194/windows-arm64+VM+using+qemu-system. No open-source 3D Windows guest driver exists for this stack [reported] https://github.com/utmapp/UTM/issues/3293. Known report: Windows 11 ARM64 ISO hang on M4 Mac mini with QEMU HVF (macOS 15.3.2), unresolved [reported] https://gitlab.com/qemu-project/qemu/-/issues/2893

Open-source building blocks:

| Project | Backend | Relevant facts | License |
|---|---|---|---|
| QEMU (`target/arm/hvf`, `hw/intc/arm_gicv3_hvf.c`) | HVF | Apple vGIC support, nested virt on HVF, SME2, PMU, WFI fix (May 2026, QEMU 11.x; "Apple HVF users can now use nested virtualization on the virt board" in 11.1 [reported] https://linuxiac.com/qemu-11-1-adds-risc-v-big-endian-support-arm-nested-virtualization/). In-kernel irqchip default on for virt-11.1+ machines [verified in source]. | GPL-2.0-or-later [verified SPDX] |
| UTM | QEMU+HVF and VZ | Uses DiskImageKit, AccessoryAccess, vmnet, Secure Boot APIs on VZ path; Windows via QEMU with TPM | Apache-2.0 [verified LICENSE] |
| libkrun / krunkit | HVF (macOS 14+) | Uses `hv_gic` (`hvfgicv3.rs`), EL2, IPA sizing; virtio-console/block/fs/gpu (venus + native context)/net/vsock/balloon/rng; firmware payload API (`krun_payload_load_firmware`) and libkrun-efi | Apache-2.0 [verified] https://github.com/containers/libkrun, https://sinrega.org/2024-03-06-enabling-containers-gpu-macos/ |
| Apple Containerization | **VZ** (not HVF) | Linux kernel ≥ 6.14.9 tested, virtio built-in | Apache-2.0 [verified] |
| Tart | VZ | macOS/Linux; suspend only macOS | FSL-1.1-ALv2 [verified LICENSE] |
| Lima | VZ and QEMU/krunkit | ad-hoc signed VZ driver | Apache-2.0 [verified] |
| Code-Hex/vz | VZ Go bindings | vmnet (26) support | MIT [verified] |
| EDK2, swtpm, virtio-win | firmware, TPM, Windows drivers | licenses **[unclear, not checked]** | |

### B.4 Performance on Apple silicon

- CPU: Windows guest 90-93 % of native, same under VZ and QEMU+HVF (M4 Pro) [reported, mustafaakin.dev].
- vCPU scheduling (VZ, M1 Max, 2022): vCPUs behave like high-QoS threads, land mostly on P cores, spill to E cores only when many vCPUs are busy; guest QoS has no effect; guest sees untyped cores [reported] https://eclecticlight.co/2022/07/18/virtualisation-on-apple-silicon-macs-4-core-allocation-in-vms/. In an HVF VMM the vCPU threads are your own pthreads, so you control QoS (`pthread_set_qos_class_self_np`); there is no core-affinity API on macOS [reported/general]. With 12 cores (8P+4E), 8 vCPUs or fewer keep a guest on P cores in the typical case **[unclear for M4 Pro, test]**.
- Memory: host pages are 16 KB; HVF stage-2 default granule is 16 KB, configurable to 4 KB on macOS 26 (needed e.g. for venus host-visible mappings) [verified API; reported patchew]. Guests freely use 4 KB stage-1 pages (Linux 4K kernels, Windows) [general knowledge]. Unified memory: no dedicated VRAM; GPU sharing via virtio-gpu blob/shared memory.
- Storage: virtio-blk is Apple's recommended fast path; NVMe exists for driverless kernels [verified WWDC23]. Sync mode matters (~30 %) [reported].
- Networking: vmnet (26) ~29 Gbit/s vs socket_vmnet 1.24 Gbit/s [reported, Lima PR]; TSO stalls under sustained load reported in Code-Hex/vz PR [reported].
- Save/restore throughput see A.7.

---

## C. M4 Pro specifics

- 12-core M4 Pro = **8 performance + 4 efficiency cores**; 16- or 20-core GPU; 273 GB/s [verified, Apple tech specs] https://support.apple.com/en-gu/121553 (also https://everymac.com/systems/apple/macbook_pro/specs/macbook-pro-m4-pro-12-core-cpu-16-core-gpu-14-2024-specs.html).
- ISA: LLVM: "Technically apple-m4 is v9.2a", modelled as v8.7a because it lacks SVE; features include SME, SME2, SMEF64F64, SMEI16I64, BF16, I8MM, LSE, PAuth, FPAC [verified, `llvm/lib/Target/AArch64/AArch64Processors.td`] https://github.com/llvm/llvm-project/blob/main/llvm/lib/Target/AArch64/AArch64Processors.td. **SVE/SVE2 absent** [verified same source; reported https://www.phoronix.com/news/Apple-M4-Added-To-LLVM-Clang].
- VM quirks:
  - SME exposure under HVF since macOS 15.2 (see B.1). Linux arm64 SME support had a run of fixes (Mark Brown, Dec 2024, including re-enabling SME in Kconfig) [reported] https://lkml.iu.edu/hypermail/linux/kernel/2412.0/02908.html; SME-only (no SVE) ptrace handling still being patched in late 2025 [reported] https://lwn.net/Articles/1042291. Whether VZ exposes SME to Linux guests on M4: **[unclear, check `/proc/cpuinfo` for `sme`/`sme2` in a VZ guest]**. Use current distro kernels.
  - Suspended Linux VMs from M1-M3 hang on M4 unless guest kernel postdates 3 Dec 2024 [reported, Parallels KB 131124].
  - macOS guests older than 13.4 do not boot on M4 (FB15774587) [reported] https://developer.apple.com/forums/thread/768674 (irrelevant for your guests).
  - Nested virtualization supported (M3+) [verified].
  - Parallels incorrectly reported SVE2 in an ARM guest on M4 Pro (26.1.1) [reported] https://forum.parallels.com/threads/parallels-26-1-1-incorrectly-reports-sve2-capability-in-arm-guest-on-apple-m4-pro.368736/

---

## D. Things to measure on the actual machine (cannot be verified remotely)

1. `VZVirtualMachineConfiguration.maximumAllowedCPUCount` / `maximumAllowedMemorySize`, `hv_vm_get_max_vcpu_count`, `hv_vm_config_get_max_ipa_size`, `sysctl kern.hv`.
2. Whether `validateSaveRestoreSupport()` passes for a Linux config without graphics, sound input and entropy on macOS 27, and whether the save actually succeeds.
3. SME visibility in a VZ Linux guest.
4. `VZVmnetNetworkDeviceAttachment` with ad-hoc signing, sandboxed vs unsandboxed; port forwarding behaviour.
5. AccessoryAccess with ad-hoc signing (expect failure "Unable to communicate with service").
6. Multi-scanout virtio-gpu for Linux.

---

## E. Main sources

Apple: https://developer.apple.com/documentation/virtualization.md · https://developer.apple.com/documentation/hypervisor.md · https://developer.apple.com/documentation/hypervisor/apple-silicon.md · https://developer.apple.com/documentation/hypervisor/hypervisor-functions.md · https://developer.apple.com/documentation/hypervisor/gic-functions.md · https://developer.apple.com/documentation/vmnet.md · https://developer.apple.com/documentation/diskimagekit.md · https://developer.apple.com/documentation/accessoryaccess.md · https://developer.apple.com/documentation/updates/virtualization.md · https://developer.apple.com/documentation/updates/hypervisor.md · https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes.md · https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes.md · https://developer.apple.com/videos/play/wwdc2026/224/ · https://developer.apple.com/videos/play/wwdc2023/10007/ · https://developer.apple.com/videos/play/wwdc2022/10002/ · https://developer.apple.com/forums/thread/787491 · https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles.md

Open source (inspected): https://github.com/qemu/qemu (commits 55cd59813f14, d7a75ea483a5, e244989abb67, ca34bcb0141d, 520320720a11, a86024eb2df5) · https://github.com/utmapp/UTM · https://github.com/cirruslabs/tart · https://github.com/lima-vm/lima · https://github.com/containers/libkrun · https://github.com/Code-Hex/vz · https://github.com/apple/containerization · https://github.com/llvm/llvm-project

Secondary: https://mustafaakin.dev/blog/windows-on-tart/ · https://eclecticlight.co/2025/06/12/macos-tahoe-brings-a-new-disk-image-format/ · https://eclecticlight.co/2026/06/12/macos-virtualisation-is-leaping-forward-in-golden-gate/ · https://juergenkoller.software/en/blog/more-than-two-macos-vms-on-apple-silicon.html · https://kb.parallels.com/131168/ · https://kb.parallels.com/en/131124 · https://encore.dev/blog/firecracker-apple-silicon · https://medium.com/@everettjf/riftvm-running-3d-accelerated-omarchy-on-a-mac-with-macos-27s-custom-virtio-3f845e1dd08e · https://github.com/Code-Hex/vz/pull/205 · https://github.com/lima-vm/lima/pull/4394 · https://bitrise.io/blog/post/wwdc26-the-virtualization-framework-updates-that-matter-for-large-mac-fleets · https://next.ink/246929/macos-27-donne-un-coup-de-fouet-a-sa-virtualisation
