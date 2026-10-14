# Windows 11 ARM64 guests on Apple silicon (M4 Pro), state as of 2026-10-14

Scope: running Windows 11 ARM64 (and by extension Linux ARM64) as a guest in a self-built macOS virtualization app. No x86 guests, no x86 emulation.

Tags used on every claim:

- **[verified]**: I read the primary source myself (source code, vendor docs, official pages, git history).
- **[reported]**: secondary source (blog, forum, issue tracker, news article).
- **[unclear]**: not confirmed, conflicting, or from my own background knowledge only.

Method note: I cloned and read the source of `utmapp/UTM` (main, HEAD 2026-10-14), `utmapp/qemu` (branch `utm-edition`, QEMU 10.0.12-utm), upstream `qemu/qemu` at tag `v11.1.2` (2026-09-28), `virtio-win/kvm-guest-drivers-windows` (HEAD 2026-10-14), `virtio-win/virtio-win-pkg-scripts`, `utmapp/spice-nsis` (UTM guest tools installer), `osy/kvm-guest-drivers-windows` (branch `neptune`), `tianocore/edk2` (master), and the Homebrew `qemu` and `swtpm` formulas. I could not execute anything on macOS from this environment, so none of the command lines below were run by me. The "UTM-equivalent" command line is reconstructed from UTM's argument generator (that is what UTM actually passes to QEMU); the upstream variant is assembled from QEMU source and docs. My web search budget ran out near the end; the few points I could not confirm afterwards are marked [unclear].

---

## 0. Executive summary

1. **Best viable path for a self-built app: QEMU + Hypervisor.framework (`-accel hvf`), using UTM's QEMU fork (or its patches), not Apple's Virtualization.framework.** UTM's fork carries the pieces Windows 11 ARM needs that upstream QEMU still lacks or that are unproven on HVF: a `tpm-crb-device` that Windows ARM64 accepts, Secure Boot firmware with Microsoft 2023 keys for aarch64, the `virtio-ramfb` display device and the 3D (Neptune/Triton) stack. [verified, see sections 2 to 5]
2. **Virtualization.framework (VZ) can boot Windows 11 ARM in 2026 only with hacks**: private platform switches (PMU), a custom UEFI framebuffer driver, a WinPE-based custom installer because there is no vTPM, fixed 1024x768 display, no GPU, no sound, no TPM, no Secure Boot. Two projects did it in Oct 2026 (tart fork, MacVisor beta). Not a Parallels-class base. [reported]
3. **Driver situation**: NVMe disk, USB xHCI keyboard/tablet, usb-storage for the ISO and ramfb/GOP display work with inbox Windows drivers. **Networking needs NetKVM (virtio-win)**, there is no verified inbox-driver NIC for Windows ARM64 under QEMU. virtio-win ships ARM64 builds of viostor, vioscsi, NetKVM, Balloon, vioserial, viorng, vioinput, viogpudo, viofs, viomem, pvpanic, attestation-signed for Windows 10+. No ARM64: qemupciserial, fwcfg, smbus, qxl, sriov; viosock is built for ARM64 but not packaged. qemu-ga has no ARM64 MSI (UTM installs the x64 MSI under emulation). [verified]
4. **TPM is the hardest part.** Upstream QEMU 11.1 only allows `tpm-tis-device` on `virt`; Windows ARM64 historically failed with it, and on Apple silicon Windows does an `LDP` to TPM MMIO that HVF cannot decode. UTM solved this with its own `tpm-crb-device` (ROM-device mapping). Upstream added PPI for `tpm-tis-device` in 11.1 and Red Hat tested Win11 ARM64 on KVM, but there is no evidence it works on HVF; an Oct 2026 report shows TPM Code 10 on HVF with QEMU 10.0.2 `tpm-tis-device`. [verified + reported]
5. **Parallels-like integration achievable with QEMU**: clipboard (spice-vdagent ARM64 build in UTM guest tools), dynamic resolution (viogpudo + its resolution service), shared folders via SPICE WebDAV (UTM) since virtiofsd does not run on macOS hosts, and experimental DirectX 11/12 via UTM's Neptune/Triton stack (unstable, needs UTM fork + virglrenderer fork + DXMT or non-redistributable D3DMetal). [verified + reported]

---

## 1. Approaches that work today and how each vendor does it

### 1.1 Microsoft's support position

- Microsoft's support article "Options for using Windows 11 with Mac computers with Apple M1, M2, and M3 chips" (page metadata `ms.date 06/04/2026`, updated 2026-09-28) names **only Parallels Desktop 18, 19 and 20** as "authorized solutions" for Arm versions of Windows 11 Pro and Enterprise, plus Windows 365 Cloud PC. It does **not** mention M4, VMware Fusion or UTM. [verified] https://support.microsoft.com/en-us/windows/options-for-using-windows-11-with-mac-computers-with-apple-m1-and-m2-chips-cd15fd62-9b34-4b78-b0bc-121baa3c568c
- The same article lists limitations: no nested virtualization (WSL, Windows Sandbox, VBS), DirectX 12 limits, no 32-bit Arm Store apps on M1 to M3, and **a separate Windows 11 Pro license per instance** (Enterprise via volume licensing). [verified] (same URL)
- Parallels' own page claims Parallels is "the only virtualization solution" authorized by Microsoft for Windows 11 Pro/Enterprise and that the authorization covers M1 to M5 and the "MacBook Neo", with vTPM and Secure Boot. This is a vendor claim not mirrored on the Microsoft page. [verified as Parallels' claim] https://www.parallels.com/de/products/desktop/microsoft-authorized-solution-windows-11-arm
- Microsoft Learn: "Windows 11 Arm ISO files overview" says the primary use of the ARM64 ISO is creating VMs, and links the Mac options article. [verified] https://learn.microsoft.com/en-us/windows/arm/iso

### 1.2 Parallels Desktop

- **VMM approach**: Parallels' PD20 user guide says: "Virtual machines created on Apple Silicon Macs always use the Apple hypervisor" (i.e. Hypervisor.framework with Parallels' own device model/VMM on top). [verified] https://docs.parallels.com/landing/pdfm-ug/v20-en-us/parallels-desktop-for-mac-20-users-guide/parallels-desktop-preferences-and-virtual-machine-settings/virtual-machine-settings/hardware-settings/cpu-and-memory-settings
- macOS guests on Apple silicon are instead built on Apple's Virtualization framework (KB 128867, reviewed 2026-01-27). [verified] https://kb.parallels.com/en/128867
- Current product: Parallels Desktop 27 user guide; Intel Mac support deprecated in 27. [verified] https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-26-users-guide/readme/what-versions-of-windows-you-can-install
- **Graphics**: "3D acceleration is currently supported at the level of DirectX 11.1 and OpenGL 4.3" for Windows 11 on Apple silicon; nested virtualization (Hyper-V, WSL2, VBS) not available, WSL1 suggested (KB 129497, reviewed 2026-08-25). OpenGL 4.3 driver new since PD 27 (KB 115487). [verified] https://kb.parallels.com/en/129497 , https://kb.parallels.com/en/115487
- Parallels Tools features (clipboard, shared folders, Coherence, dynamic resolution) were not re-verified in this session. [unclear]

### 1.3 VMware Fusion

- Broadcom KB 315609 feature table for Windows 11 (Arm) on Apple silicon, Fusion 25H2: 3D acceleration (DirectX 11) yes, clipboard yes, drag-drop yes, VMware Tools installer yes, auto-fit resolution yes, **Shared Folders only for Linux guests**, Unity no. [verified] https://knowledge.broadcom.com/external/article/315609/features-of-windows-11-vm-on-vmware-fusi.html
- Broadcom KB 315602: Windows 11 or later only; **recommended storage NVMe with the inbox Microsoft driver**, recommended NIC **vmxnet3**, UEFI required, "The virtual TPM 2.0 device is available", nested-virt features (VBS, WSL2, Sandbox) do not work. The same KB says VMware Tools for Windows Arm only provides vmxnet3 and a basic 2D display driver and lacks copy-paste; this **conflicts** with KB 315609 and is probably stale. [verified, conflict noted] https://knowledge.broadcom.com/external/article/315602/compatibility-considerations-for-arm-gue.html
- Microsoft does not list Fusion as authorized. [verified, see 1.1]
- Fusion's VMM approach on Apple silicon (Hypervisor.framework-based) could not be verified in this session. [unclear]

### 1.4 UTM (QEMU + HVF): exact configuration UTM generates for Windows 11 ARM64

Source files (all [verified], read at UTM `main` HEAD `95ae00ac`, 2026-10-14):
`Configuration/UTMQemuConfiguration+Arguments.swift`, `Platform/Shared/VMWizardState.swift`, `Configuration/UTMQemuConfigurationQEMU.swift`, `...Display.swift`, `...Network.swift`, `...Sound.swift`, `...Drive.swift`, `...Input.swift`, `...Sharing.swift`, `Services/UTMSWTPM.swift`, `Services/UTMQemuVirtualMachine.swift`, `Platform/UTMDownloadSupportToolsTask.swift`, `patches/sources`.
Base URL: https://github.com/utmapp/UTM/tree/main

What the wizard sets for OS = Windows, arch = aarch64, target = `virt` (`VMWizardState.generateQemuConfig()`):

| Area | UTM value for Windows 11 ARM64 | Where |
|---|---|---|
| QEMU binary | UTM fork `qemu-10.0.12-utm` (`https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/qemu-10.0.12-utm.tar.xz`), built as shared lib, `--disable-cocoa --disable-sdl` | `patches/sources`, `scripts/build_dependencies.sh` |
| Accelerator | `-accel hvf` (adds `ipa-granule-size=0x1000` when Vulkan path is on; fork-only property) | `machineArguments` |
| Machine | `-machine virt,gic-version=3` (highmem left at default on macOS >= 12.4; `virtualization=on` only for TCG) | `machineProperties` |
| CPU | `-cpu host`; vCPUs default to the **number of performance cores** (`hw.perflevel0.physicalcpu`), `-smp cpus=N,sockets=1,cores=N,threads=1` | `cpuArguments`, `emulatedCpuCount` |
| RAM | wizard default 4096 MiB | `VMWizardState` |
| Firmware | `-drive if=pflash,format=raw,unit=0,file.filename=<res>/edk2-aarch64-secure-code.fd,file.locking=off,readonly=on` and `-drive if=pflash,unit=1,file.filename=<vm>/efi_vars.fd`; vars copied from `edk2-arm-secure-vars.fd` when "Preload Secure Boot Keys" is on (default when TPM on) | `architectureArguments`, `UTMQemuConfigurationQEMU.saveData` |
| TPM | `-chardev socket,id=chrtpm0,path=<uuid>.swtpm` `-tpmdev emulator,id=tpm0,chardev=chrtpm0` `-device tpm-crb-device,tpmdev=tpm0` (for any `virt*` target) | `tpmArguments` |
| swtpm | in-process from libswtpm: `--ctrl type=unixio,path=<sock>,terminate --tpmstate backend-uri=file://<vm>/tpmdata --tpm2` (UTM fork of swtpm 0.8.99, libtpms 0.9.6) | `Services/UTMSWTPM.swift`, `patches/sources` |
| Display | `-device virtio-ramfb-gl` (wizard appends `-gl` for Windows); with default renderer also `hostmem=8G,blob=true,venus=true,neptune=true` | `UTMQemuConfigurationDisplay`, `displayArguments` |
| Spice | `-spice unix=on,addr=<uuid>.spice,disable-ticketing=on,image-compression=off,playback-compression=off,streaming-video=off,gl=es` ; QMP over `-chardev spiceport,name=org.qemu.monitor.qmp.0` ; `-nodefaults -vga none` | `spiceArguments` |
| System disk | **NVMe**: `-device nvme,drive=drive<ID>,serial=<ID>,bootindex=N` + `-drive if=none,media=disk,id=drive<ID>,file.filename=...,discard=unmap,detect-zeroes=unmap` | `VMWizardState` (`mainDriveInterface = .nvme` for aarch64+Windows), `driveArgument` |
| Installer ISO | **USB mass storage**: `-device usb-storage,drive=drive<ID>,removable=true,bootindex=0,bus=usb-bus.0` + `-drive if=none,media=cdrom,...,readonly=on` (default CD interface on `virt` is `.usb`) | `UTMQemuConfigurationDrive.defaultInterface` |
| Guest tools CD | extra empty removable USB CD; UTM downloads `https://getutm.app/downloads/utm-guest-tools-3d-latest.iso` and mounts it | `VMWizardState`, `UTMDownloadSupportToolsTask` |
| USB | `-device nec-usb-xhci,id=usb-bus` + `usb-tablet`, `usb-mouse`, `usb-kbd` on `usb-bus.0`; plus `qemu-xhci` controllers and `usb-redir` (spicevmc) for USB passthrough | `usbArguments` |
| Network | `-device virtio-net-pci,mac=...,netdev=net0` + `-netdev vmnet-shared,id=net0` (macOS default mode `.shared`) | `UTMQemuConfigurationNetwork`, `networkArguments` |
| Sound | `-audiodev spice,id=audio0` + `-device intel-hda` + `-device hda-duplex,audiodev=audio0` (CoreAudio backend optional) | `UTMQemuConfigurationSound`, `soundArguments` |
| Agent channels | `-device virtio-serial`; `virtserialport name=org.qemu.guest_agent.0`; `virtserialport chardev=vdagent,name=com.redhat.spice.0` + `-chardev spicevmc,id=vdagent,debug=0,name=vdagent`; WebDAV `virtserialport name=org.spice-space.webdav.0` | `sharingArguments` |
| Sharing | Windows on `virt`: SPICE **WebDAV** directory sharing + clipboard (virtio-9p only used for Linux) | `UTMQemuConfigurationSharing` |
| Misc | `-rtc base=localtime` (Windows), `-device virtio-rng-pci`, balloon off by default | `miscArguments`, `UTMQemuConfigurationQEMU.init` |
| Snapshots | UTM refuses suspend/save state when NVMe or GL display is active | `UTMQemuVirtualMachine.determineSnapshotSupport` |

UTM release notes: v5.0.5 (beta, 2 Sep) "For ARM64 configs, GICv3 is now selected by default", "DirectX graphics support for Windows", DirectX 12 via D3DMetal "when available"; v5.0.6 (Sep/Oct 2026) known issue dated 9/24/26: "The Windows 3D driver requires an update that is not released yet." v4.7.1 removed VHDX import "because Microsoft now provides ARM64 ISO images". Latest non-beta marked "Latest" is v4.7.5. [verified for v5.0.4/v5.0.5 GitHub pages and releases list; reported for v5.0.6 via newreleases.io] https://github.com/utmapp/UTM/releases , https://newreleases.io/project/github/utmapp/UTM/release/v5.0.6

UTM Windows guide: use CrystalFetch or the Microsoft ARM64 ISO page; keep "Install drivers and SPICE tools"; Windows needs at least 2 cores; newer UTM enables TPM and Secure Boot automatically; known 24H2 black screen (eject guest tools ISO and reboot); `OOBE\BYPASSNRO` blocked on newer builds, use `start ms-cxh:localonly`; LabConfig bypass for older UTM. [verified] https://docs.getutm.app/guides/windows/

UTM QEMU settings page: TPM 2.0 + UEFI enables Secure Boot; "Preload Secure Boot Keys" enrolls the **UTM Platform Key and Microsoft UEFI keys (KEK + DB)**. [verified] https://docs.getutm.app/settings-qemu/qemu/

### 1.5 Apple Virtualization.framework (VZEFIBootLoader)

- **tart fork by Mustafa Akın (blog 2026-10-01)**: Windows 11 and Server 2025 on VZ. Needed: private generic-platform switches (PMU emulation, "Only the first one is actually needed"), a ~7 KB custom UEFI framebuffer driver modelled on QEMU ramfb because Apple's firmware gives no framebuffer (Boot Manager crashed otherwise), and **custom install media via WinPE + DISM** because Setup hard-blocks on the missing TPM. Uses virtio-win (viostor etc.), virtio-fs + WinFsp as `Z:`, Windows port of the tart guest agent for clipboard. Not working: audio ("virtio-win has no driver" for virtio-sound), suspend, nested virt, TPM. Tested only on macOS 26.6 and 27. [reported] https://mustafaakin.dev/blog/windows-on-tart/
- **MacVisor 27.0.0 beta 5 "Technology Preview"** (perf numbers dated 2026-10-13): requires macOS 27 because "Windows needs CPU features that Apple's Virtualization framework offers only on recent macOS 27 builds"; display **fixed at 1024x768** ("the one size the virtio-win display driver renders right"), software rendering only, "No TPM and no Secure Boot", BitLocker/Hello unavailable, virtio-win 0.1.302 + WinFsp 2.1, community virtio-snd driver only test-signed (test-signing watermark), network must be restarted after resume. [reported] https://scaleninja.com/docs/macvisor/windows/
- WWDC26 (macOS 27) Virtualization updates: USB passthrough, layered disk images, `VZMacGuestProvisioningOptions`, vmnet integration, `VZCustomVirtioDevice`. Nothing Windows-, TPM- or Secure-Boot-related. [reported] https://next.ink/246929/macos-27-donne-un-coup-de-fouet-a-sa-virtualisation , https://wwdcnotes.com/documentation/wwdc26-224-expand-the-capabilities-of-your-virtualization-app/
- **Conclusion**: VZ is not a practical base for a Parallels-like Windows experience in 2026 (no vTPM, no GPU path for Windows, display constraints, private APIs). Its advantage is built-in virtio-fs and simpler code for Linux guests. [inference from the above]

---

## 2. Windows 11 ARM64 setup requirements in a VM

### 2.1 Hardware minimums
- Microsoft Learn "Windows 11 requirements, Virtual machine support": Generation 2 (UEFI), **64 GB** storage, Secure Boot capable + vTPM, **4 GB** RAM, **2+ vCPUs**. ARM64 CPUs must support `PF_ARM_V81_ATOMIC_INSTRUCTIONS_AVAILABLE`. [verified] https://learn.microsoft.com/windows/whats-new/windows-11-requirements#virtual-machine-support , https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/windows-11-support-azure-virtual-machines#criteria-for-windows-11-eligibility
- QEMU HVF source: "Windows wants at least the PMU's cycles counter to be available"; QEMU emulates it (kernel-irqchip=off) or exposes PMUVer=1 with the in-kernel vGIC. [verified] `target/arm/hvf/hvf.c` in https://github.com/qemu/qemu/tree/v11.1.2
- A gist comment (Nov 2025) says 25 GB is too small for 25H2, 52 GB needed. [reported] https://gist.github.com/Vogtinator/293c4f90c5e92838f7e72610725905fd

### 2.2 TPM 2.0 on QEMU aarch64 `virt`

- swtpm on macOS: Homebrew formula `swtpm` 0.10.2 (BSD-3-Clause), depends on `libtpms`, `openssl@4`, `glib`, `json-glib`, `gmp`, `libtasn1`; bottles for arm64 Sequoia, Tahoe, Golden Gate. Install: `brew install swtpm`. [verified] https://github.com/Homebrew/homebrew-core/blob/main/Formula/s/swtpm.rb
- QEMU docs (`docs/specs/tpm.rst`, v11.1.2) for Arm virt:
  ```
  swtpm socket --tpmstate dir=/tmp/mytpm1 \
    --ctrl type=unixio,path=/tmp/mytpm1/swtpm-sock --tpm2 --log level=20
  qemu-system-aarch64 -machine virt,gic-version=3,acpi=off ... \
    -chardev socket,id=chrtpm,path=/tmp/mytpm1/swtpm-sock \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis-device,tpmdev=tpm0
  ```
  Note `acpi=off` in that example is for Linux; Windows needs ACPI. [verified] https://github.com/qemu/qemu/blob/v11.1.2/docs/specs/tpm.rst
- **Upstream QEMU 11.1 `virt` only allows `tpm-tis-device`** as a dynamic sysbus TPM (`machine_class_allow_dynamic_sysbus_dev(mc, TYPE_TPM_TIS_SYSBUS)`); `tpm-crb-device` does not exist upstream. [verified] `hw/arm/virt.c`, `include/system/tpm.h` at v11.1.2
- History: QEMU issue #830 and swtpm issue #493 (2021/2022): Windows ARM64 could not initialize the TPM via `tpm-tis-device`; osy (UTM) found CRB works. [reported] https://gitlab.com/qemu-project/qemu/-/issues/830 , https://github.com/stefanberger/swtpm/issues/493
- UTM fork commits (Joelle van Dyne / osy, 2023-11-13), merged into `utm-edition`:
  - `tpm_crb_sysbus: introduce TPM CRB SysBus device`: "This interface is currently the only one supported by QEMU that works on Windows 11 ARM64 as 'tpm-tis-device' does not work with current Windows drivers." [verified] https://github.com/utmapp/qemu/commit/4653477a1
  - `tpm_crb: use a single read-as-mem/write-as-mmio mapping`: "On Apple Silicon, when Windows performs a LDP on the CRB MMIO space, the exception is not decoded by hardware and we cannot trap the MMIO read", solved by a ROM-device style mapping. [verified] https://github.com/utmapp/qemu/commit/156a7df98
  - The fork's `hw/core/sysbus-fdt.c` binds `TYPE_TPM_CRB_SYSBUS` to `add_tpm_tis_fdt_node` so edk2 finds it. [verified]
- Upstream 2026 progress: QEMU 11.1 added PPI (ACPI `_DSM`) to `tpm-tis-device` on ARM64 virt so "Windows 11 ARM64 guests no longer log Event ID 15 errors" (commit 46cd2c1, 2026-03-27); `ppi` property default on, disabled for machine types <= 11.0 (5f0348b, 5e33de4). Tested on "aarch64 KVM, upstream QEMU, Win11 ARM64 25H2, swtpm"; RHEL backport "RHEL-112608 ([ARM64] Windows 11 VM should install without TPM Bypass)". [verified commits; reported test claims] https://github.com/qemu/qemu/commit/46cd2c1 , https://patchew.org/QEMU/20260327173209.148180-1-mbawa@redhat.com , https://git.almalinux.org/rpms/qemu-kvm/commit/404985d3a47c6cbacea6e5d2c8a699d0e0710a1d
- In that thread, Mohamed Mediouni: "Windows guests LDP accesses on the TPM register range which doesn't match ISV=1"; on KVM the workaround depends on host FEAT_S2FWB, proper ISV=0 emulation pending. [reported] https://ratatoskr.run/qemu-devel/2026/03/14436695/t
- Upstream HVF data-abort handler still has `assert(isv)` ("TODO: ISV will be 0 for SIMD or SVE accesses"). So an `LDP` on TIS MMIO under HVF would hit that assert. I did not find an upstream fix. [verified code; impact on Windows is my inference, unclear]
- Field report 2026-10-09: QEMU 10.0.2 + HVF on macOS 27.2 with `tpm-tis-device` + swtpm: Windows shows "Trusted Platform Module 2.0" with **Code 10**, blocking stable-channel updates. [reported] https://github.com/allisonfm85/accessible-virtual-machine/issues/17
- **Verdict**: For Windows 11 ARM on HVF use **UTM's `tpm-crb-device`** (port the 5 to 6 UTM TPM commits or build the UTM fork). Upstream `tpm-tis-device` on HVF is [unclear], probably broken.

### 2.3 Secure Boot firmware for aarch64

- Upstream QEMU 11.1.2 ships only `edk2-aarch64-code.fd` and `edk2-arm-vars.fd` for aarch64 (no secure variant); x86 has `*-secure-code.fd`. With `install_blobs` default true they install to `share/qemu/`. Homebrew does not override this, so `$(brew --prefix)/share/qemu/edk2-aarch64-code.fd` and `edk2-arm-vars.fd` should exist. [verified source/meson; Homebrew install path inferred, unclear]
- edk2 ArmVirtQemu build defaults `SECURE_BOOT_ENABLE = FALSE`, `TPM2_ENABLE = FALSE`; QEMU's `roms/edk2-build.config` aa64 build enables `TPM2_ENABLE`/`TPM2_CONFIG_ENABLE` via `opts.common` but not Secure Boot. Firmware includes `QemuRamfbDxe`, `VirtioGpuDxe`, `NvmExpressDxe`, `XhciDxe`, `UsbKbDxe`, `UsbMassStorageDxe`, `VirtioNet/Blk/Scsi`. [verified] https://github.com/tianocore/edk2/blob/master/ArmVirtPkg/ArmVirtQemuFvMain.fdf.inc , https://github.com/qemu/qemu/blob/v11.1.2/roms/edk2-build.config
- UTM fork ships `pc-bios/edk2-aarch64-secure-code.fd.bz2` (added 2023-07-08, rebuilt 2024-09-28 "replace BIOS with UTM variants") and `edk2-arm-secure-vars.fd.bz2` (2025-08-10: "pc-bios: use 2023 Microsoft UEFI certificates"). Note the arm vars file is used for aarch64 (`uefiImagePrefix(isVars:true)` returns `edk2-arm`). [verified] https://github.com/utmapp/qemu/tree/utm-edition/pc-bios
- UTM's edk2 fork (`utm` branch) adds virtio-ramfb support, "obtain ramfb from BAR" (2024-12), re-enabled ramfb (2024-12) and VGA driver (2025-03). [verified] https://github.com/utmapp/edk2/tree/utm
- Alternatives:
  - Debian `qemu-efi-aarch64`: `AAVMF_CODE.ms.fd` (symlink to `AAVMF_CODE.secboot.fd`) + `AAVMF_VARS.ms.fd` (Secure Boot active, distro PK/KEK1 + Microsoft keys). [verified] https://metadata-backend.ftp-master.debian.org/changelogs/main/e/edk2/stable_qemu-efi-aarch64.README.Debian
  - `virt-fw-vars` (virt-firmware 26.9): `--enroll-microsoft`, `--microsoft-db {...win23,uefi23,all}`, `--microsoft-kek {2011,2023,all}`, `--secure-boot`. Requires a firmware build with `SECURE_BOOT_ENABLE`. [verified man page] https://www.mankier.com/1/virt-fw-vars
- Secure Boot needs an SB-enabled **code** image too (variables alone are not enough). [unclear, general edk2 knowledge]

### 2.4 Bypasses without TPM/Secure Boot
- LabConfig: `HKLM\SYSTEM\Setup\LabConfig` DWORDs `BypassTPMCheck`, `BypassSecureBootCheck` (=1). UTM's guest tools `Autounattend.xml` sets `BypassCPUCheck`, `BypassRAMCheck`, `BypassSecureBootCheck`, `BypassTPMCheck` via `RunSynchronous` in the windowsPE pass for both amd64 and arm64. [verified] https://github.com/utmapp/spice-nsis/blob/master/Autounattend.xml , https://docs.getutm.app/guides/windows/
- Name gotcha: `BypassSecureBootCheck` works, `BypassSecureBoot` does not (Sep 2025). [reported] https://gist.github.com/Vogtinator/293c4f90c5e92838f7e72610725905fd
- Bypass status in 2026 for 26H2 builds was not re-verified. [unclear]

### 2.5 OOBE without network / local account (2026)
- `oobe\bypassnro` script removed in build 26300.8289 (26H2 Insider); the `BypassNRO` registry value reportedly still works. [reported] https://www.elevenforum.com/t/microsoft-removed-oobe-bypassnro-command-in-latest-windows-11-26h2-builds.46471/latest
- `start ms-cxh:localonly` blocked in Insider 26120.6772 / 26220.6772 (Oct 2025), Microsoft: "removing known mechanisms for creating a local account". Forum users still report it working on some builds (conflict). [reported] https://pureinfotech.com/microsoft-blocks-windows-11-microsoft-account-bypass/
- Methods reported working on 24H2/25H2 (Mar 2026, 26H2 not tested): `reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f` + reboot; `WinJS.Application.restart("ms-cxh://LOCALONLY")` from Ctrl+Shift+J; `HideOnlineAccountScreens` registry; Pro "Domain join instead"; autounattend.xml local accounts. [reported] https://pureinfotech.com/bypass-microsoft-account-windows-11-oobe/
- **Robust option for an app: generate `autounattend.xml`** with `Microsoft-Windows-Shell-Setup/UserAccounts/LocalAccounts/LocalAccount` and `OOBE/HideOnlineAccountScreens` in the `oobeSystem` pass (Microsoft-documented unattend settings). UTM already ships such a file (arm64 components, `HideOnlineAccountScreens`, `HideWirelessSetupInOOBE`, `PnpCustomizationsWinPE` driver paths, FirstLogon runs `E:\utm-guest-tools.exe`). [verified] https://learn.microsoft.com/windows-hardware/customize/desktop/automate-oobe , https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-oobe-hideonlineaccountscreens , https://github.com/utmapp/spice-nsis/blob/master/Autounattend.xml

---

## 3. Getting the installer, licensing

- **Official ARM64 ISO**: https://www.microsoft.com/en-us/software-download/windows11arm64, page title "Download Windows 11 Arm64", "Current release: Windows 11 2026 Update l Version 26H2", multi-edition ISO (product key selects edition), Enterprise via Microsoft 365 admin center. [verified]
- When the ISO page first appeared (commonly said Nov 2024) I could not confirm; UTM v4.7.1 already says Microsoft provides ARM64 ISOs. [unclear on date]
- 26H2 GA reportedly 2026-09-29. [reported] https://pureinfotech.com/?p=192070
- CrystalFetch (App Store id6454431289, GitHub `TuringSoftware/CrystalFetch`) recommended by UTM. [verified mention in UTM docs] https://docs.getutm.app/guides/windows/
- UUP dump and Insider ARM64 VHDX availability in 2026: not verified. [unclear]
- **Licensing/activation**: Microsoft requires a Windows 11 Pro license per VM instance (Enterprise via volume licensing) on Macs. [verified, MS support article] UTM's Autounattend uses the public KMS client setup key `W269N-WFGWX-YVC9B-4J6C9-T83GX` (Pro), which only selects the edition and does not activate without KMS. [verified file; activation behaviour is general knowledge, unclear]

---

## 4. Drivers for Windows ARM64 guests

### 4.1 Inbox (no extra driver)
| Device | Status | Source |
|---|---|---|
| NVMe (`-device nvme`) | Works inbox; UTM uses it for Windows ARM64 system disk; VMware recommends "NVMe with inbox Microsoft driver" | [verified] UTM `VMWizardState.swift`; Broadcom KB 315602 |
| USB xHCI + `usb-kbd`/`usb-tablet`/`usb-mouse` | Works inbox; used by UTM, Linaro, virtio-win KB | [verified UTM source; reported guides] |
| `usb-storage` (ISO and driver CD) | Works for Windows Setup; UTM default CD bus on `virt` | [verified UTM source] https://virtio-win.github.io/Knowledge-Base/Windows-arm64-vm-using-qemu.html |
| `ramfb` | Works as GOP framebuffer (Basic Display) during setup; low/fixed resolution | [reported] virtio-win KB, Vogtinator gist |
| Network | **No verified inbox NIC.** `usb-net` (QEMU RNDIS/CDC-ECM): QEMU issue #198 reports Windows does not bind it (x86 Windows), ARM64 untested. `e1000e` on ARM64: no evidence found. | [reported/unclear] https://gitlab.com/qemu-project/qemu/-/issues/198 |
| HD Audio (`intel-hda` + `hda-duplex`) | UTM's default; whether Windows ARM64's inbox HDAudio binds was not confirmed | [unclear] |
| PL031 RTC, PSCI, GICv3 | Base `virt` platform used by all working setups | [inference] |

Windows inbox RNDIS (`Rndismp.sys`, `Usb8023.sys`) needs an IHV INF or class/subclass 0xEF/04/01 match; Microsoft recommends NCM instead. [verified] https://learn.microsoft.com/windows-hardware/drivers/usbcon/supported-usb-classes

Related regression: Windows 11 ARM64 KB5124008 (build 26200.9445, Sep 2026) breaks `usbncm.sys` with Code 10 on VirtualBox's usbnet device. [reported] https://github.com/VirtualBox/virtualbox/issues/877

### 4.2 virtio-win ARM64 status (2026)
- Repo HEAD 2026-10-14; latest internal tag `mm324` (14 Sep 2026, "Switch build environment to EWDK 26H1"); `status.txt` lists recent fixes incl. viofs polling notifications, viogpu pointer DDIs, stdvga KMDOD. [verified] https://github.com/virtio-win/kvm-guest-drivers-windows/blob/master/status.txt
- `win11_arm64.ddf` (cab for Win11 ARM64) contains: **Balloon, NetKvm, pvpanic, viofs (+virtiofs.exe), vioinput (+viohidkmdf), viorng (+viorngum.dll), vioscsi, vioserial, viostor, viogpudo (+vgpusrv.exe, viogpuap.exe), fwcfg (INF only), viomem, viosock**. [verified] https://github.com/virtio-win/kvm-guest-drivers-windows/blob/master/win11_arm64.ddf
- Packaging (`util/filemap.py`) maps `Win11/ARM64` for Balloon, NetKVM, pvpanic, vioinput, viorng, vioscsi, vioserial, viostor, viofs (w10/w11 only), viogpudo, viomem. **No ARM64** for qemupciserial, qemufwcfg/fwcfg, smbus, qxl/qxldod, sriov (commented out), and viosock is mapped only for amd64. [verified] https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/util/filemap.py
- Signing: "Windows 10+ drivers are signed with Microsoft attestation signature", not WHQL; WHQL only with RHEL subscription. [verified] https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md
- Downloads (static): `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso` and `.../stable-virtio/virtio-win.iso`, plus `virtio-win-guest-tools.exe`. [verified README; could not fetch the server itself]
- Latest public release 0.1.302 (changelog 2026-08-27, with qemu-ga-win 110.2.3). Public spec in GitHub still shows 0.1.285 (qemu-ga-win 110.0.2). [reported for 0.1.302] https://forum.proxmox.com/threads/virtio-win-releases.164979/
- Linaro: virtio-win guest tools installer "works out of the box on arm64 (tested virtio-win-0.1.271)"; load storage from `viostor/w11/ARM64`. [reported] https://linaro.atlassian.net/wiki/spaces/WOAR/pages/28914909194/windows-arm64+VM+using+qemu-system
- License: BSD-3-Clause style (redistributable). [verified] `LICENSE` in kvm-guest-drivers-windows

### 4.3 virtio-fs on Windows ARM64
- Guest side: `viofs` ARM64 driver + `virtiofs.exe` service exist [verified]; WinFsp supports ARM64 (WinFsp "2022+ARM64", v1.12) [reported] https://winfsp.dev/doc/WinFsp-on-ARM64 , https://newreleases.io/project/github/winfsp/winfsp/release/v1.12 ; service started with `sc start VirtioFsSvc` [verified for RHEL docs] https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/configuring_and_managing_windows_virtual_machines/sharing-files-between-the-host-and-its-virtual-machines
- **Host side under QEMU on macOS is the blocker**: virtio-fs needs a vhost-user daemon (virtiofsd), which is Linux-only (macOS support issue #169 open); QEMU >= 9.1 has `memory-backend-shm` for vhost-user on POSIX, but frontend enablement patches were not all upstream (FOSDEM 2025). [reported] https://fosdem.org/2025/events/attachments/fosdem-2025-5100-can-qemu-and-vhost-user-devices-be-used-on-macos-and-bsd-/slides/237342/FOSDEM_20_O6dJsKR.pdf
- UTM's guest tools do **not** install viofs on ARM64 (it sits inside `${IfNot} ${IsNativeARM64}`). [verified] https://github.com/utmapp/spice-nsis/blob/master/win-guest-tools.nsis
- Under VZ, virtio-fs works (Apple provides the host side): tart and MacVisor use viofs + WinFsp. [reported]

### 4.4 SPICE agent, WebDAV, qemu-guest-agent on ARM64
UTM's guest tools installer (`utmapp/spice-nsis`, last commit 2026-08-30) on native ARM64 installs [verified]:
- `vdagent.exe`/`vdservice.exe` from `bin\vdagent_arm64` (ARM64 spice-vdagent, built outside the Fedora mingw chain: Makefile notes the ARM64 path is "TODO: not available"),
- `spice-webdavd-arm64-latest.msi` (repo `utmapp/spice-webdavd-arm64`),
- `vc_redist.arm64.exe`,
- drivers: vioserial, Balloon, viostor, vioscsi, NetKVM, viorng, pvpanic, vioinput, **viogpudo or viogpu3d** (checkbox "Enable experimental 3D acceleration"), viomem,
- **qemu-ga: installs `qemu-ga-x86_64.msi` on ARM64** (x64 emulation; no ARM64 qemu-ga MSI). virtio-win's spec also only packages i386 and x86_64 qemu-ga MSIs. [verified] https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/virtio-win.spec
- Skipped on ARM64: qxl/qxldod, qemupciserial, sriov, smbus, qemufwcfg, viofs.
- ISO URLs: `https://getutm.app/downloads/utm-guest-tools-latest.iso` (docs) and `.../utm-guest-tools-3d-latest.iso` (app). [verified] https://docs.getutm.app/guest-support/windows/

### 4.5 Display and GPU acceleration for Windows ARM guests
- **viogpudo** (WDDM display-only, ARM64 build): has EDID handling, `VIRTIO_GPU_EVENT_DISPLAY` config-change handling and a user-mode helper (`vgpusrv`/`viogpuap`) that applies host-requested resolutions with `SetDisplayConfig`, i.e. dynamic resolution. [verified source] `viogpu/viogpudo/viogpudo.cpp`, `viogpu/viogpuap/GpuAdapter.cpp`
- Known issues: UTM issue #6332 black screen with 24H2 after the display driver loads (unresolved through 2025); UTM's Autounattend comments out viogpu injection "due to black screen issues"; MacVisor says only 1024x768 renders correctly under VZ. [reported/verified file] https://github.com/utmapp/UTM/issues/6332
- UTM's `Uninstall-VirtioGpu.cmd`: viogpudo "cannot be unloaded safely" (reset loop holding the PnP lock), so uninstall is a 2-phase reboot process; "ARM64 and x64 use the same driver, service and device names". [verified] https://github.com/utmapp/spice-nsis/blob/master/Uninstall-VirtioGpu.cmd
- **3D for Windows ARM under QEMU (UTM, 2026)**:
  - KMD `viogpu3d` (osy fork `kvm-guest-drivers-windows`, branch `neptune`, HEAD 2026-10-13, `viogpu3d.vcxproj` has ARM64 configs); UMD "Triton" (`osy/virtio-win-mesa`, branch `neptune`) implementing the DirectX DDI; protocol "Neptune" (virglrenderer extension, "a Venus clone with D3D11 substituted for Vulkan"). [verified repo/branch; reported architecture] https://blog.getutm.app/2026/introducing-neptune-direct3d-virtualization-for-qemu/ , https://blog.getutm.app/2026/introducing-triton-directx-11-driver-for-qemu/
  - Triton blog (2026-07-24): "You need a Windows ARM64 guest"; QEMU device `-device virtio-ramfb-gl,hostmem=8G,blob=true,venus=true,neptune=true` with `-display cocoa,gl=es` (UTM fork); on vanilla QEMU use `ramfb`, install drivers, then switch to `virtio-gpu-gl-pci`; host backends DXMT (arm64, redistributable) or D3DMetal (x86_64 under Rosetta, from Apple's Game Porting Toolkit, licence prohibits bundling); "very unstable". [reported]
  - UTM 5.0.4/5.0.5: DX11 (and DX12 with D3DMetal) for Windows 11, experimental; 5.0.6 known issue: Windows 3D driver needs an unreleased update. [verified/reported]
  - UTM `Documentation/Graphics.md`: without the 3D driver, picking a `-gl` device still lets QEMU blit to an EGL canvas, lower latency. [verified]
- Parallels: DirectX 11.1, OpenGL 4.3 via its own guest drivers. VMware: DirectX 11. [verified]

---

## 5. QEMU on macOS (Apple silicon) in 2026

- **Latest upstream**: v11.1.2 (tag dated 2026-09-28); 11.1.0 released 2026-08-11 ("'hvf' accelerator now supports nested virtualization and vGIC"); 11.0 released 2026-04-21. [verified tags; verified release page] https://www.qemu.org/2026/08/11/qemu-11-1-0/
- **HVF on aarch64 (v11.1.2 source)** [verified]:
  - In-kernel vGIC via `hv_gic_create` (macOS 15+); **default on for `virt-11.1`** (commit 37863ff "hvf: arm: enable vGIC by default for virt-11.1 and later"), off for `virt-11.0` and older; override with `-accel hvf,kernel-irqchip=on|off` (`split` rejected). With hardware vGIC, MSI uses GICv2m and ITS is refused.
  - Nested virtualization (`-machine virt,virtualization=on`) via `hv_vm_config_set_el2_enabled` (commit 6f8f256); requires `hv_vm_config_get_el2_supported()`; GICv3 with EL2 needs kernel-irqchip; SME is hidden when nested virt is on ("SME is not implemented with nested virt on the Apple side").
  - SME2 state save/restore on macOS 15.2+ when supported.
  - Apple docs: `hv_gic_create` available macOS 15.0+ (June 2024 Hypervisor update added EL2 + GIC; June 2025 added IPA granule config). [verified] https://developer.apple.com/documentation/hypervisor/hv_gic_create(_:) , https://developer.apple.com/documentation/updates/hypervisor
  - Nested virt needs M3 or newer + macOS 15 (so M4 Pro qualifies). [reported] https://instagit.com/apple/container/container-nested-virtualization-requirements/ , https://lwn.net/Articles/1038917
- **Homebrew `qemu`**: 11.1.2, license `GPL-2.0-only`, `--enable-cocoa --disable-gtk --disable-sdl`, `--disable-guest-agent`, `--enable-slirp`, `--enable-virtfs`; HVF disabled on arm hosts <= Sonoma ("needs the macOS 15 SDK for its EL2 sysregs and vGIC"); `--disable-pvg` on Golden Gate. Depends on `spice-protocol` (build) only, **no spice-server**, so no `-spice`, but the `qemu-vdagent` chardev is compiled (gated on `CONFIG_SPICE_PROTOCOL`). [verified] https://github.com/Homebrew/homebrew-core/blob/main/Formula/q/qemu.rb , `ui/meson.build`
- **Display backends on macOS** [verified `qemu-options.hx` v11.1.2]:
  - `-display cocoa[,full-grab=on|off][,swap-opt-cmd=on|off][,show-cursor=on|off][,left-command-key=on|off][,full-screen=on|off][,zoom-to-fit=on|off]` (no `gl=` upstream; the `gl=es` in the Triton blog is UTM-fork behaviour). Cocoa implements the QEMU clipboard peer and forwards window size to the guest via `qemu_console_set_ui_info`.
  - `-display dbus[,addr=...][,gl=on|core|es|off]` exists if built with glib >= 2.64 and gdbus-codegen; whether Homebrew's build has it was not checked. [unclear]
  - VNC and SPICE (SPICE only if built with spice-server, as UTM does).
- **Firmware files in Homebrew**: upstream installs `edk2-aarch64-code.fd` and `edk2-arm-vars.fd` (plus descriptor `60-edk2-aarch64.json`); no aarch64 Secure Boot variant. [verified upstream meson; Homebrew path inferred]
- **HVF entitlement**: QEMU signs with `com.apple.security.hypervisor` (`accel/hvf/entitlements.plist`); HVF returns `HV_DENIED` otherwise. Your app/helper needs the same entitlement. [verified]
- **vmnet**: `-netdev vmnet-shared|vmnet-host|vmnet-bridged` exist. They need root or Apple's restricted `com.apple.vm.networking` entitlement. [verified options; entitlement requirement unclear, from background knowledge]
- **Licensing for bundling QEMU**: QEMU "as a whole is released under the GNU General Public License, version 2" (parts BSD/MIT). [verified LICENSE] For a personal, non-distributed app nothing is triggered. If you distribute: keep QEMU as a separate helper process/dylib with complete corresponding source of your QEMU build and patches (UTM does: Apache-2.0 app, GPL QEMU built as shared lib, launched in `QEMULauncher`). Linking QEMU into your main binary would make the combined work GPL. [general GPL interpretation, unclear, not legal advice] Other licences: swtpm BSD-3 [verified Homebrew], virtio-win BSD-3 [verified], D3DMetal not redistributable [reported, Triton blog].

---

## 6. Command lines

### 6.1 Variant A: UTM-equivalent (UTM QEMU fork, recommended for Windows 11 with TPM + Secure Boot)

Reconstructed from `UTMQemuConfiguration+Arguments.swift` for the wizard defaults (Windows, aarch64, `virt`, hypervisor on, TPM on, guest tools on). This is what UTM runs; I removed `-S` (UTM starts paused) and simplified the SPICE/QMP plumbing that only matters with UTM's CocoaSpice client. Requires the UTM fork (`tpm-crb-device`, `virtio-ramfb`, secure firmware). [verified as UTM's generator output, not executed by me]

```sh
# 0) one-time per VM
cp edk2-arm-secure-vars.fd ~/VMs/win11/efi_vars.fd            # UTM: copied from bundle on create
qemu-img create -f qcow2 ~/VMs/win11/disk.qcow2 80G

# 1) swtpm (UTM style; UTM's swtpm fork accepts backend-uri)
swtpm socket --tpm2 \
  --ctrl type=unixio,path=$HOME/VMs/win11/swtpm.sock,terminate \
  --tpmstate backend-uri=file://$HOME/VMs/win11/tpmdata &

# 2) QEMU (UTM fork, qemu-10.0.12-utm)
qemu-system-aarch64 \
  -L "$QEMU_RES" \
  -spice unix=on,addr=$HOME/VMs/win11/spice.sock,disable-ticketing=on,image-compression=off,playback-compression=off,streaming-video=off,gl=es \
  -nodefaults -vga none \
  -device virtio-net-pci,mac=52:54:00:12:34:56,netdev=net0 \
  -netdev vmnet-shared,id=net0 \
  -device virtio-ramfb-gl \
  -cpu host -smp cpus=10,sockets=1,cores=10,threads=1 \
  -machine virt,gic-version=3 \
  -accel hvf \
  -drive if=pflash,format=raw,unit=0,file.filename="$QEMU_RES/edk2-aarch64-secure-code.fd",file.locking=off,readonly=on \
  -drive if=pflash,unit=1,file.filename=$HOME/VMs/win11/efi_vars.fd \
  -m 8192 \
  -audiodev spice,id=audio0 \
  -device intel-hda -device hda-duplex,audiodev=audio0 \
  -device nec-usb-xhci,id=usb-bus \
  -device usb-tablet,bus=usb-bus.0 -device usb-mouse,bus=usb-bus.0 -device usb-kbd,bus=usb-bus.0 \
  -device usb-storage,drive=cd0,removable=true,bootindex=0,bus=usb-bus.0 \
  -drive if=none,media=cdrom,id=cd0,file.filename=$HOME/ISO/Win11_26H2_ARM64.iso,file.locking=off,readonly=on \
  -device nvme,drive=disk0,serial=disk0,bootindex=1 \
  -drive if=none,media=disk,id=disk0,file.filename=$HOME/VMs/win11/disk.qcow2,discard=unmap,detect-zeroes=unmap \
  -device usb-storage,drive=cd1,removable=true,bootindex=2,bus=usb-bus.0 \
  -drive if=none,media=cdrom,id=cd1,file.filename=$HOME/ISO/utm-guest-tools-latest.iso,file.locking=off,readonly=on \
  -device virtio-serial \
  -device virtserialport,chardev=org.qemu.guest_agent,name=org.qemu.guest_agent.0 \
  -chardev spiceport,name=org.qemu.guest_agent.0,id=org.qemu.guest_agent \
  -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
  -chardev spicevmc,id=vdagent,debug=0,name=vdagent \
  -device virtserialport,chardev=charchannel1,id=channel1,name=org.spice-space.webdav.0 \
  -chardev spiceport,name=org.spice-space.webdav.0,id=charchannel1 \
  -name Win11 -uuid 6C2A2E8E-0000-4000-8000-000000000001 \
  -rtc base=localtime \
  -device virtio-rng-pci \
  -chardev socket,id=chrtpm0,path=$HOME/VMs/win11/swtpm.sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm0 \
  -device tpm-crb-device,tpmdev=tpm0
```
Notes:
- `-smp 10`: UTM's default equals the P-core count (`hw.perflevel0.physicalcpu`); a 14-core M4 Pro has 10 P-cores, the 12-core variant 8. [verified logic; core counts from background knowledge, unclear]
- UTM puts relative socket names (`addr=<uuid>.spice`, `path=<uuid>.swtpm`) and sets the working directory; absolute paths are used above for readability. [verified]
- With the default renderer UTM additionally appends `hostmem=8G,blob=true,venus=true,neptune=true` to the display device and `ipa-granule-size=0x1000` to `-accel hvf` when the 3D/Vulkan path is active. [verified]
- Network during setup: `virtio-net-pci` has no inbox driver, so either load `NetKVM\w11\ARM64` (or `w10\ARM64`) from a virtio-win/UTM tools CD at "Load driver" / via `Autounattend.xml` `PnpCustomizationsWinPE` (UTM injects `E:\Drivers\NetKVM\w10\ARM64`), or go through OOBE offline (2.5).

### 6.2 Variant B: upstream QEMU 11.1.2 from Homebrew (no SPICE, TPM unproven on HVF)

Assembled from QEMU v11.1.2 source/docs, the Linaro/virtio-win KB command and UTM's device choices. [each flag verified to exist in v11.1.2 source/docs; the combination was not executed by me]

```sh
brew install qemu swtpm
SHARE="$(brew --prefix)/share/qemu"
mkdir -p ~/VMs/win11 && cp "$SHARE/edk2-arm-vars.fd" ~/VMs/win11/vars.fd
qemu-img create -f qcow2 ~/VMs/win11/disk.qcow2 80G

# optional TPM (see 2.2: likely fails on HVF with tpm-tis-device; else use LabConfig bypass)
swtpm socket --tpm2 --tpmstate dir=$HOME/VMs/win11/tpm \
  --ctrl type=unixio,path=$HOME/VMs/win11/tpm/swtpm.sock,terminate --log level=20 &

qemu-system-aarch64 \
  -machine virt,gic-version=3 \
  -accel hvf \
  -cpu host -smp 8 -m 8G \
  -drive if=pflash,format=raw,unit=0,file="$SHARE/edk2-aarch64-code.fd",readonly=on \
  -drive if=pflash,format=raw,unit=1,file=$HOME/VMs/win11/vars.fd \
  -device ramfb \
  -device qemu-xhci,id=xhci \
  -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 \
  -drive if=none,id=inst,media=cdrom,readonly=on,file=$HOME/ISO/Win11_26H2_ARM64.iso \
  -device usb-storage,drive=inst,removable=on,bootindex=0 \
  -drive if=none,id=vwin,media=cdrom,readonly=on,file=$HOME/ISO/virtio-win.iso \
  -device usb-storage,drive=vwin,removable=on \
  -drive if=none,id=sys,format=qcow2,file=$HOME/VMs/win11/disk.qcow2,discard=unmap \
  -device nvme,drive=sys,serial=win11sys,bootindex=1 \
  -nic user,model=virtio-net-pci \
  -device virtio-serial-pci \
  -chardev qemu-vdagent,id=vdagent,name=vdagent,clipboard=on \
  -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
  -audiodev coreaudio,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 \
  -device virtio-rng-pci \
  -rtc base=localtime \
  -display cocoa,zoom-to-fit=on \
  -chardev socket,id=chrtpm,path=$HOME/VMs/win11/tpm/swtpm.sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis-device,tpmdev=tpm0
```
Notes:
- `-machine virt` = `virt-11.1` = in-kernel vGIC under HVF. If Windows misbehaves with GICv2m MSIs, try `-accel hvf,kernel-irqchip=off` or `-machine virt-11.0`. [option verified; Windows behaviour unclear]
- Secure Boot: swap the pflash pair for an SB build plus MS-keyed vars (UTM's `edk2-aarch64-secure-code.fd` + `edk2-arm-secure-vars.fd`, or Debian `AAVMF_CODE.ms.fd` + `AAVMF_VARS.ms.fd`). [verified files exist]
- After install: boot once with `-device virtio-gpu-pci` (replacing or in addition to `ramfb`), install viogpudo + NetKVM + vioserial + spice-vdagent ARM64 (UTM tools) or virtio-win guest tools. [reported workflow, Vogtinator gist and Triton blog]
- `qemu-vdagent` options `mouse` (default on) and `clipboard` (default off) are the only backend options; it announces monitors-config caps but does not send resize messages. Dynamic resolution then relies on cocoa's `ui_info` -> virtio-gpu display event -> viogpudo/vgpusrv (chain verified in source, end-to-end behaviour unclear). [verified source]
- `vmnet-shared` instead of `user` needs root or the vmnet entitlement. [unclear]
- `-cpu host,sme=off`: SME property is registered for HVF CPUs in v11.1.2; whether Windows needs SME hidden on M4 is unknown. [verified property; need unclear]

---

## 7. Known Windows 11 ARM issues on M4-series hosts (2025/2026)

- macOS 15.2 Hypervisor.framework exposes SME on M4, which made QEMU HVF fail to start ("cannot disable sme"); UTM/QEMU patch "hvf: arm: disable SME feature" (Feb 2025); UTM 4.6.1 fixed the M4 SME error; upstream 11.x now models SME2 state. UTM's fork still masks SME (`host_isar.id_aa64pfr1 &= ~R_ID_AA64PFR1_SME_MASK`, comment: "on the M4 there is SME but not SVE"). [verified UTM fork source; reported issue] https://patchew.org/QEMU/20250224165735.36792-1-j@getutm.app , https://gitlab.com/qemu-project/qemu/-/issues/2665 , https://github.com/utmapp/UTM/releases/tag/v4.6.2
- QEMU issue #2893: Windows 11 ARM64 ISO not booting for install on an M4 Mac mini (QEMU 9.x, `-machine virt,highmem=on -cpu host -accel hvf`, "convertprogress failed to find range"), no resolution on page (last edit 2026-09-21). [reported] https://gitlab.com/qemu-project/qemu/-/issues/2893
- M4 Macs cannot virtualize macOS guests older than 13.4 (not relevant to Windows). [reported] UTM v4.6.2 notes
- Windows 24H2+ black screen with the virtio display driver (UTM #6332), not M4-specific. [reported]
- TPM Code 10 on HVF with upstream `tpm-tis-device` (macOS 27.2, Oct 2026), not M4-specific. [reported]
- Windows usbncm Code 10 after KB5124008 on Apple silicon VirtualBox (Sep 2026). [reported]
- WSL2 inside Windows ARM on M4 under UTM reported working (Mar 2025, gist comment), consistent with M3+ nested virt support; Microsoft and Parallels list WSL2/VBS/Sandbox as unsupported. [reported] https://gist.github.com/Vogtinator/293c4f90c5e92838f7e72610725905fd

---

## 8. What Parallels-like integration is achievable, and how

| Feature | QEMU path (Windows ARM64 guest) | Status |
|---|---|---|
| Clipboard | spice-vdagent ARM64 (UTM tools) over `virtserialport name=com.redhat.spice.0`; host side SPICE (UTM) or upstream `-chardev qemu-vdagent,clipboard=on` with `-display cocoa` | [verified source] |
| Dynamic resolution | `virtio-gpu-pci`/`virtio-ramfb` + viogpudo + `vgpusrv` resolution service; host sends size (SPICE monitors config in UTM, or cocoa `ui_info`) | [verified source; black-screen issues reported] |
| Shared folders | SPICE WebDAV (`spice-webdavd-arm64` + `org.spice-space.webdav.0` channel + phodav in the client) as in UTM; virtio-fs needs a macOS virtiofsd (not available); alternative: SMB from macOS File Sharing | [verified UTM; virtiofsd reported] |
| 3D / DirectX | UTM Neptune/Triton: `viogpu3d` KMD + Triton UMD + virglrenderer fork + DXMT/D3DMetal; experimental, ARM64 guests only | [reported] |
| Audio | `intel-hda`/`hda-duplex` default in UTM; inbox binding on ARM64 unconfirmed; no virtio-snd driver in virtio-win | [unclear/reported] |
| Time sync, shutdown | qemu-ga (x64 MSI under emulation on ARM64) | [verified] |
| Balloon, RNG, input | Balloon, viorng, vioinput ARM64 drivers | [verified] |
| USB passthrough | `usb-redir` over SPICE (UTM) | [verified source] |
| Coherence-style seamless windows | no open-source equivalent found | [unclear] |

Comparison: Parallels gives DX11.1/GL4.3, vTPM, Secure Boot and Microsoft authorization; Fusion 25H2 gives DX11, clipboard, auto-fit but no Windows shared folders; a QEMU-based app can reach clipboard, resolution, WebDAV sharing, vTPM (with UTM's CRB patch) and Secure Boot today, with 3D only via UTM's unstable stack.

---

## 9. Source list

Primary (read directly):
- UTM source: https://github.com/utmapp/UTM (files listed in 1.4)
- UTM QEMU fork: https://github.com/utmapp/qemu/tree/utm-edition (commits 4653477a1, 156a7df98, 59cc5b96e, 8eb68166a, a172998c2; `hw/display/virtio-ramfb*.c`, `hw/core/sysbus-fdt.c`, `target/arm/hvf/hvf.c`)
- UTM edk2 fork: https://github.com/utmapp/edk2/tree/utm
- UTM guest tools installer: https://github.com/utmapp/spice-nsis (`win-guest-tools.nsis`, `Autounattend.xml`, `Uninstall-VirtioGpu.cmd`, `Makefile`)
- osy KMD fork: https://github.com/osy/kvm-guest-drivers-windows/tree/neptune
- QEMU v11.1.2: https://github.com/qemu/qemu/tree/v11.1.2 (`hw/arm/virt.c`, `hw/arm/virt-acpi-build.c`, `target/arm/hvf/hvf.c`, `accel/hvf/hvf-all.c`, `accel/hvf/entitlements.plist`, `docs/specs/tpm.rst`, `docs/system/devices/usb.rst`, `qemu-options.hx`, `ui/vdagent.c`, `ui/cocoa.m`, `qapi/char.json`, `pc-bios/meson.build`, `roms/edk2-build.config`, `LICENSE`); commits 37863ff, 6f8f256, 46cd2c1, 5f0348b, 5e33de4
- QEMU 11.1.0 announcement: https://www.qemu.org/2026/08/11/qemu-11-1-0/
- edk2: https://github.com/tianocore/edk2/blob/master/ArmVirtPkg/ArmVirtQemuFvMain.fdf.inc , `ArmVirtPkg/ArmVirtQemu.dsc`
- virtio-win: https://github.com/virtio-win/kvm-guest-drivers-windows (`win11_arm64.ddf`, `status.txt`, `README.md`, `LICENSE`), https://github.com/virtio-win/virtio-win-pkg-scripts (`util/filemap.py`, `README.md`, `virtio-win.spec`), https://github.com/virtio-win/virtio-win-guest-tools-installer
- Homebrew: https://github.com/Homebrew/homebrew-core/blob/main/Formula/q/qemu.rb , https://github.com/Homebrew/homebrew-core/blob/main/Formula/s/swtpm.rb
- Microsoft: https://support.microsoft.com/en-us/windows/options-for-using-windows-11-with-mac-computers-with-apple-m1-and-m2-chips-cd15fd62-9b34-4b78-b0bc-121baa3c568c , https://www.microsoft.com/en-us/software-download/windows11arm64 , https://learn.microsoft.com/en-us/windows/arm/iso , https://learn.microsoft.com/windows/whats-new/windows-11-requirements#virtual-machine-support , https://learn.microsoft.com/windows-hardware/customize/desktop/automate-oobe , https://learn.microsoft.com/windows-hardware/drivers/usbcon/supported-usb-classes
- Apple: https://developer.apple.com/documentation/hypervisor/hv_gic_create(_:) , https://developer.apple.com/documentation/updates/hypervisor
- Parallels: https://kb.parallels.com/en/129497 , https://kb.parallels.com/en/115487 , https://kb.parallels.com/en/128867 , https://docs.parallels.com/landing/pdfm-ug/v20-en-us/parallels-desktop-for-mac-20-users-guide/parallels-desktop-preferences-and-virtual-machine-settings/virtual-machine-settings/hardware-settings/cpu-and-memory-settings , https://www.parallels.com/de/products/desktop/microsoft-authorized-solution-windows-11-arm
- Broadcom/VMware: https://knowledge.broadcom.com/external/article/315609/features-of-windows-11-vm-on-vmware-fusi.html , https://knowledge.broadcom.com/external/article/315602/compatibility-considerations-for-arm-gue.html
- UTM docs and blog: https://docs.getutm.app/guides/windows/ , https://docs.getutm.app/guest-support/windows/ , https://docs.getutm.app/settings-qemu/qemu/ , https://blog.getutm.app/2026/introducing-neptune-direct3d-virtualization-for-qemu/ , https://blog.getutm.app/2026/introducing-triton-directx-11-driver-for-qemu/ , https://github.com/utmapp/UTM/releases
- virt-fw-vars: https://www.mankier.com/1/virt-fw-vars ; Debian AAVMF: https://metadata-backend.ftp-master.debian.org/changelogs/main/e/edk2/stable_qemu-efi-aarch64.README.Debian

Secondary:
- https://mustafaakin.dev/blog/windows-on-tart/ ; https://scaleninja.com/docs/macvisor/windows/
- https://linaro.atlassian.net/wiki/spaces/WOAR/pages/28914909194/windows-arm64+VM+using+qemu-system ; https://virtio-win.github.io/Knowledge-Base/Windows-arm64-vm-using-qemu.html ; https://gist.github.com/Vogtinator/293c4f90c5e92838f7e72610725905fd
- https://patchew.org/QEMU/20260327173209.148180-1-mbawa@redhat.com ; https://ratatoskr.run/qemu-devel/2026/03/14436695/t ; https://git.almalinux.org/rpms/qemu-kvm/commit/404985d3a47c6cbacea6e5d2c8a699d0e0710a1d
- https://gitlab.com/qemu-project/qemu/-/issues/830 ; https://github.com/stefanberger/swtpm/issues/493 ; https://github.com/allisonfm85/accessible-virtual-machine/issues/17
- https://gitlab.com/qemu-project/qemu/-/issues/2893 ; https://gitlab.com/qemu-project/qemu/-/issues/2665 ; https://patchew.org/QEMU/20250224165735.36792-1-j@getutm.app ; https://github.com/utmapp/UTM/issues/6332 ; https://gitlab.com/qemu-project/qemu/-/issues/198 ; https://github.com/VirtualBox/virtualbox/issues/877
- https://fosdem.org/2025/events/attachments/fosdem-2025-5100-can-qemu-and-vhost-user-devices-be-used-on-macos-and-bsd-/slides/237342/FOSDEM_20_O6dJsKR.pdf ; https://winfsp.dev/doc/WinFsp-on-ARM64
- https://forum.proxmox.com/threads/virtio-win-releases.164979/ ; https://www.elevenforum.com/t/microsoft-removed-oobe-bypassnro-command-in-latest-windows-11-26h2-builds.46471/latest ; https://pureinfotech.com/microsoft-blocks-windows-11-microsoft-account-bypass/ ; https://pureinfotech.com/bypass-microsoft-account-windows-11-oobe/
- https://next.ink/246929/macos-27-donne-un-coup-de-fouet-a-sa-virtualisation ; https://instagit.com/apple/container/container-nested-virtualization-requirements/ ; https://lwn.net/Articles/1038917
