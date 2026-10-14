# Feature parity with Parallels Desktop 27: what to build, how, and with which open-source parts

**Target:** a Swift/SwiftUI virtualization app on a MacBook Pro M4 Pro. It runs Linux ARM64 guests on Virtualization.framework (VZ) and Windows 11 ARM64 guests on QEMU with Hypervisor.framework (HVF). There are no x86 guests and no Rosetta.
**Research date:** 2026-10-14
**Companion files in this folder:** `apple-frameworks.md` and `windows-arm-guests.md` (written by another researcher) cover the frameworks and the Windows drivers in more depth.

## How claims are tagged

- **[verified]**: I read the primary source in this session (vendor docs, Apple docs, release notes, or the actual source code or git tags of the repo).
- **[reported]**: the claim comes from a secondary source (press, forum, third-party docs, Hacker News) or from a single user report.
- **[unclear]**: I could not confirm it, sources conflict, or it is general knowledge I did not re-check this session.
- **Recommendation:** my own engineering advice, not a factual claim.

Source IDs such as `[S1]` or `[U6]` point to the numbered source list at the end.

**Limit on this research:** the shared web-search budget ran out near the end. A few items are marked [unclear] because I could not run follow-up searches: GNOME Remote Desktop RAIL support, OrbStack internals, a 2026 open-source Windows-on-ARM Mac app other than UTM, and the Parallels Installation Assistant. Release dates and licenses come from cloning the repositories and reading git tags and LICENSE files directly.

---

## 0. Executive summary

1. **Parallels Desktop 27** (27.0.0, released 2026-08-25) supports Apple silicon only. It adds a Metal-based OpenGL 4.3 driver for Windows and lets guests use SME on M4/M5. It removes Travel mode, Boot Camp, Shared Bluetooth and Intel support. For Windows on ARM, 3D tops out at DirectX 11.1 and OpenGL 4.3. Nested virtualization, WSL2 and VBS are not available for Windows guests [verified, S1, S2, S4].
2. **Quick wins.** Several features take days on VZ or QEMU: clipboard (SPICE agent), dynamic resolution, virtiofs shared folders for Linux, NAT, host-only networking and port forwarding (vmnet on macOS 26), suspend and resume, disk snapshots via APFS clones, rollback mode, unattended installs (cloud-init, Autounattend.xml), a CLI, and start-at-login.
3. **Hard features.**
   - **Coherence for Windows.** No open-source macOS client does RDP RemoteApp (RAIL) today. The Cocoa MacFreeRDP client has no RAIL code. FreeRDP's SDL3 client got beta RAIL in 3.32.0 for X11 and Wayland only [verified, R1, R2]. You would write your own Cocoa RAIL window manager on top of libfreerdp (Apache-2.0) or IronRDP's `ironrdp-rail` codec (MIT/Apache-2.0).
   - **Linux 3D on VZ.** VZ exposes no 3D API for Linux guests [verified, A10].
   - **Windows DirectX.** The UTM team's Neptune/Triton stack is described by its own authors as "very unstable" [verified, U8].
   - **USB passthrough.** On VZ it needs macOS 27 plus a restricted entitlement. On QEMU it needs `com.apple.vm.device-access` or root [verified, A8, B1, B3].
4. **Best reference.** **UTM** (Apache-2.0, plus GPL/LGPL components) solves most of your problems for both backends: SPICE integration (CocoaSpice), guest tools for Windows ARM64, snapshots on VZ (DiskImageKit) and QEMU (QMP/qemu-img), vmnet, AccessoryAccess USB, and `utmctl`. Read its source first [verified, U1, U15].

---

## 1. Feature matrix

Difficulty scale: **S** = days, **M** = 1 to 3 weeks, **L** = 1 to 3 months, **XL** = a quarter or more, or a research project.

| Feature | Parallels behavior | Linux on VZ technique | Windows on QEMU+HVF technique | Building blocks + licenses | Difficulty | Notes |
|---|---|---|---|---|---|---|
| Coherence / seamless windows | Windows apps as Mac windows; tray icons in the menu bar; Windows only; needs Parallels Tools [verified S5] | No VZ support. Forward Wayland windows (waypipe over vsock) to a macOS compositor (Cocoa-Way style) or xpra (X11) | RDP RemoteApp (MS-RDPERP) to the guest, with a custom Cocoa RAIL client | FreeRDP libfreerdp + rail channel (Apache-2.0); IronRDP `ironrdp-rail` (MIT/Apache-2.0); waypipe (GPL-3.0 since 0.10.3); xpra (GPL-2.0+); Cocoa-Way (GPL-3.0) | Win: **L to XL**; Linux: **XL** | No macOS RAIL client exists [verified R1]. RemoteApp needs Windows Pro or Enterprise as the RDP host [verified R9] |
| Clipboard | Text, images and formatted text; files via Cmd-C/V [verified S24] | `VZSpiceAgentPortAttachment` + guest `spice-vdagent` (macOS 13+) [verified A1, A2] | SPICE vdagent over virtio-serial (ARM64 vdagent build in UTM guest tools), or RDP CLIPRDR | spice-vdagent (GPL-3.0+), spice-gtk/CocoaSpice (LGPL-2.1+ / Apache-2.0), QEMU built-in `qemu-vdagent` chardev | **S** | Rich formats and files need your own agent or RDP |
| Drag and drop | Files Mac to Windows; not in Full Screen [verified S27] | Custom vsock agent: copy to shared folder, then simulate a drop in the guest | Same, or RDP file clipboard | Own agent over virtio-vsock or virtio-serial | **L** | No off-the-shelf open-source component found [unclear] |
| Dynamic resolution / Retina | Resolution follows the window; "Best for Retina", "Scaled" modes [verified S8] | `VZVirtualMachineView.automaticallyReconfiguresDisplay` (macOS 14+), used in Apple's GUI Linux sample [verified A1, A11] | spice-vdagent monitors-config, or RDP Display Control | spice-vdagent; FreeRDP disp channel | **S to M** | Retina: map backing scale factor to guest DPI yourself |
| Multi-monitor | "Use All Displays in Full Screen", all or one display, Windows and Linux [verified S26] | `scanouts` is an array; whether VZ supports more than one Linux scanout is [unclear] | virtio-gpu multiple outputs (per-output resolution since QEMU 11.0) or RDP /multimon | QEMU (GPL-2.0), FreeRDP | **M to L** | UTM shows one window per QEMU display [verified U19] |
| Shared folders / profile | Mac folders appear as "Mac" network folders; user folders mirrored as symlinks; Linux uses `/media/psf` via the prl_fsd FUSE daemon (libfuse3) [verified S1, S23] | `VZVirtioFileSystemDeviceConfiguration` + `mount -t virtiofs` [verified U11] | virtio-win `viofs` ARM64 + WinFsp (ARM64 native); or SPICE WebDAV; or RDP drive redirection; or SMB | virtio-win (BSD-3-Clause), WinFsp (GPL-3.0 with FLOSS exception), spice-webdavd | Linux **S**; Windows **M** | VZ virtiofs ignores guest uid/gid changes [reported A23]. virtiofsd is Linux-only, so QEMU on macOS cannot serve virtio-fs out of the box [verified D8] |
| USB passthrough | Prompts Mac or VM on connect and remembers the choice; device allow-list (Business) [verified S14, S15] | macOS 27 `VZUSBPassthroughDevice` + AccessoryAccess; restricted entitlement; user hands over each device in a menu-bar item [verified A7, A8, B1] | usbredir via SPICE, or QEMU `usb-host` (libusb); needs root or `com.apple.vm.device-access` [verified B3, A17] | usbredir (LGPL/GPL), libusb (LGPL), CocoaSpice | **M** (VZ, macOS 27) / **L** (QEMU) | No hardware reset; built-in Apple webcams cannot be captured [verified U9] |
| Audio out / microphone | Output and mic choice per VM [verified S25] | `VZVirtioSoundDeviceConfiguration` with host output sink and input source [verified A14] | QEMU coreaudio is **output only** [verified Q4]; mic via SPICE record channel or RDP `audin` (FreeRDP has a mac backend) [verified R1] | QEMU, spice-gtk, FreeRDP | **S** (VZ) / **M** (QEMU mic) | UTM 5.0.6 fixed SPICE mic quality [verified U6] |
| Camera | "Share Mac camera" [verified S25] | No VZ camera device found [unclear] | RDP camera redirection (RDPECAM); FreeRDP has no macOS camera backend (v4l, gst, android, movie only) [verified R1] | IronRDP has an `ironrdp-rdpecam` crate [verified R6] | **L** | Built-in camera cannot be USB-passed [verified U9] |
| Snapshots | Manual + SmartGuard (every 1 to 48 h, up to 100 kept); merging on delete [verified S16] | Disk: APFS `clonefile`/`cp -c`, or DiskImageKit ASIF overlay layers (macOS 27). Memory state: `saveMachineStateTo` (macOS 14+), often refused for Linux with virtio graphics [verified A3, A7, I7; reported A24] | qcow2 internal snapshots via QMP `snapshot-save` (since QEMU 6.0) or HMP savevm/loadvm [verified Q1, Q2] | QEMU, DiskImageKit (Apple), UTM snapshot backends (Apache-2.0) | **M** | UTM 5.0.6 has a Snapshots tab for both backends [verified U6] |
| Rollback mode | Session changes discarded (Pro) [verified S13] | Ephemeral overlay or throw-away clone | `-snapshot` (writes go to a temp file) [verified Q1] | UTM "Run without saving changes" (AVF, macOS 27) [verified U6]; macosvm `--ephemeral` [verified P11] | **S** | |
| Suspend / resume | Suspend on close; auto-pause when idle [verified S11, S34] | `pause()` + `saveMachineStateTo`/restore (configuration-dependent) | QMP `stop`/`cont`; suspend state as a qcow2 snapshot (UTM uses a default suspend snapshot) [verified U15] | | **S to M** | Tart allows suspend only for macOS VMs ("You can only suspend macOS VMs") [verified P1] |
| Templates, clones, linked clones | Templates (Pro); full clone; linked clone shares the parent disk (Pro) [verified S18, S33] | APFS CoW clone of the bundle; DiskImageKit base + overlay as a true linked clone | qcow2 backing files (`qemu-img create -b`) | Tart clone logic (FSL, study only) | **S** | |
| Encryption | Password-protected VM; vTPM file AES-128, key in System Keychain [verified S31, S32] | No VZ disk-encryption API found [unclear]; use an encrypted disk image or the guest's own LUKS | qcow2 LUKS (AES-256-XTS default) [verified Q1]; BitLocker inside the guest with swtpm vTPM | swtpm (BSD-3-Clause) [verified I8] | **M** | Windows 11 needs TPM 2.0 + Secure Boot [verified I6] |
| Isolation mode | No shared folders, profile, apps, devices, volume sync, or drag and drop [verified S7] | Leave out the virtiofs, SPICE port and USB devices | Same | | **S** | |
| Networking | Shared (NAT), Bridged, Host-only, Disconnect; MAC; Network Conditioner; DHCP v4/v6; port forwarding (Pro) [verified S10, S30] | NAT attachment; bridged needs the restricted `com.apple.vm.networking`; macOS 26 `VZVmnetNetworkDeviceAttachment` adds shared and host modes, custom subnets, DHCP and port forwarding without root [verified A5, A6, A7; reported N2] | libslirp user net + `hostfwd`; QEMU vmnet netdevs need root or the entitlement; socket_vmnet daemon (root) [verified N3, N7, N9] | libslirp (BSD-3/MIT), socket_vmnet (Apache-2.0), gvisor-tap-vsock (Apache-2.0) | **M** | passt is Linux-only [verified N5] |
| prlctl CLI | `prlctl`/`prlsrvctl` (Pro+) [verified S17] | Swift ArgumentParser CLI talking to the app over XPC or AppleScript | Same; QMP passthrough | utmctl (Apache-2.0) as a model [verified U16] | **M** | |
| Vagrant / Packer | Vagrant provider (MIT), Packer plugin (MPL-2.0) [verified S21, S22] | Write a Vagrant provider gem that calls your CLI | Same | vagrant_utm (MIT) as a model [verified P16] | **M** | |
| Guest tools | 13 Parallels Tools features [verified S6]; Linux tools "driverless" via virtio-vsock since 26.1 [reported S37] | Ship a package: spice-vdagent + own agent over vsock | Guest-tools ISO: virtio-win ARM64 drivers + vdagent ARM64 + own agent | spice-nsis (zlib) installer as a model [verified U14] | **L** | |
| Time sync after sleep | Time Synchronization Tool [verified S6] | qemu-ga `guest-set-time` over vsock (vfkit/krunkit `--timesync`) [verified I7] | qemu-ga over virtio-serial | qemu-ga (GPL-2.0) | **S** | Guest clock stops while the host sleeps [verified I7] |
| Graceful shutdown | Shut down / suspend options [verified S11] | `VZVirtualMachine.requestStop()` [verified A12] | QMP `system_powerdown` (ACPI) [verified Q2] | | **S** | |
| 3D graphics | Windows: DX11.1, OpenGL 4.3 (Metal-based in v27); Linux: 3D option [verified S1, S4, S8] | **None available on VZ** (virtio-gpu config has only scanouts) [verified A10]. Alternative: run 3D Linux guests on QEMU or libkrun with Venus + MoltenVK/KosmicKrisp | virtio-gpu viogpudo (2D, ARM64); experimental Triton UMD + Neptune (D3D11) with a DXMT/D3DMetal host [verified U8] | virglrenderer (MIT), ANGLE (BSD-3), MoltenVK (Apache-2.0), KosmicKrisp (Mesa), DXMT (LGPL-2.1) | **XL** | D3DMetal's license prevents bundling [verified U8] |
| Resource auto-tuning | Automatic CPU/RAM (Windows 10+); Standard edition capped at 4 vCPU / 8 GB; Adaptive Hypervisor [verified S9] | Pick vCPU and RAM from host P-core count and RAM; balloon via `targetVirtualMachineMemorySize` [verified A13] | `-smp`, `-m`; virtio-balloon (ARM64 driver exists) [verified D1] | | **S** | vCPU threads always run at high QoS [reported A27] |
| Profiles | Productivity, Games, Design, Dev, Testing [verified S19] | Preset tables in the app | Same | | **S** | |
| Battery / travel mode | Travel mode **removed** in 27 [verified S1]; pause when idle [verified S34] | Pause the VM when there is no foreground use | QMP `stop` | | **S** | |
| Headless | Startup view "Headless" (Pro) [verified S11] | VZ VM without a view; SSH/vsock | `-display none` + RDP/SPICE | | **S** | |
| Start at login | "When the user logs in" [verified S11] | `SMAppService` login item or launch agent (macOS 13+) [verified A19] | Same | | **S** | |
| Windows apps in Dock / Finder | Share Windows apps with Mac, a Dock folder, Dock bounce [verified S12]; Launchpad not documented [verified S12, S38] | n/a | Agent enumerates Start-menu apps; generate stub `.app` bundles that launch RemoteApp | WinApps (AGPL-3.0, Linux) shows the idea [verified R7] | **M** after Coherence | Avoid copying AGPL code |
| Open Mac files in Windows apps | Finder "Open With" and "Change All"; starts the VM in Coherence [verified S29] | n/a | Stub app declares document types; translates the path to the shared path; FreeRDP `/app:program:…,cmd:…` [verified R1] | FreeRDP | **M** | |
| Mac apps from Windows | "Open on Mac", Start-menu "Parallels Shared Applications" [verified S12] | Guest agent RPC: open the host path | Guest agent RPC | Own agent | **M** | |
| Printing / SmartMount / smart cards | Printing tool, SmartMount, smart card sharing [verified S6, S14] | CUPS/IPP over network | RDP printer and smartcard redirection (MacFreeRDP lists them) [reported R4] | FreeRDP | **M** | |
| Nested virtualization | Linux guests only, M3+ and macOS 15+ [verified S9] | `VZGenericPlatformConfiguration.isNestedVirtualizationEnabled` (macOS 15+) [verified A15] | QEMU 11.1: HVF nested virt + vGIC [verified G5] | | **S** (Linux) | Parallels says no nested virt for Windows [verified S4] |
| SME / AI acceleration | SME exposed to guests on M4/M5 [verified S1] | VZ SME exposure [unclear] | QEMU 11.0: SME2 via HVF if the host supports it; disabled when nested virt is on [verified G4, Q5] | QEMU | **S** (config) | Hypervisor SME APIs since macOS 15.2 [verified A18] |
| Toolbox | ~36 small utilities (screen capture, timers, etc.) [verified S35] | Out of scope | | | n/a | Not VM-related |
| DevOps / management API | DevOps service (Go, REST, RBAC), free up to 10 users [verified S28] | Local REST or XPC API (vfkit/krunkit offer `--restful-uri`) [verified I7] | Same | | **M** | |

---

## 2. Parallels Desktop 27 feature inventory (Apple silicon, ARM guests)

### 2.1 Release facts

- Release dates from the official KB: 27.0.0 (58628) on 2026-08-25, 27.0.1 on 2026-09-01, 27.0.2 on 2026-09-17, 27.0.3 on 2026-10-07 [verified, S1]. The blog announcement is dated 2026-08-21 [verified, S2].
- **Apple silicon only.** Intel Macs stay on v26 [verified, S1, S2].
- **New in 27.0.0** [verified, S1]:
  - Metal-based OpenGL driver for Windows, raising OpenGL from 4.1 to 4.3; Parallels claims up to 2.6x on M3 and newer.
  - SME use for Windows and Linux VMs on M4/M5.
  - Support for Ubuntu 26.04, Fedora 44, Debian 13.6 and Kali 2026.2.
  - Parallels Tools can be updated from the command line in headless Ubuntu Arm.
  - The Linux shared-folder daemon `prl_fsd` moved from libfuse2 to libfuse3.
  - Enterprise edition is certified ARM SystemReady SR 3.1 (VE band).
  - The blog also mentions a DevOps management interface and SSO improvements [verified, S2].
- **Removed in 27** [verified, S1]:
  - Installing on macOS Ventura
  - Intel support
  - Boot Camp
  - **Travel mode**
  - Classic Outlook badges
  - The Security preferences tab (Enterprise admins control it remotely)
  - **Shared Bluetooth** (use a USB dongle instead)
- **Windows on ARM limits** [verified, S4]:
  - DirectX 11.1 and OpenGL 4.3
  - No nested virtualization, WSL2 or VBS (WSL1 works as a workaround)
- **Price:** about $185/year for the subscription tier the article cites [reported, S3].

### 2.2 One-line inventory

| # | Feature | What it does | Source |
|---|---|---|---|
| 1 | Coherence | Windows apps run as individual Mac windows without the VM desktop. Tray icons go to the macOS menu bar and windows move between Spaces. Windows only, needs Tools, not in the App Store edition | [verified S5] |
| 2 | Mouse sync | Pointer moves seamlessly between host and VM | [verified S6] |
| 3 | Time sync | Keeps the guest clock matched to the Mac, or at a fixed offset | [verified S6] |
| 4 | Drag and drop | Drag files between macOS and the VM; not in Full Screen | [verified S6, S27] |
| 5 | Clipboard | Shares images and formatted text ("Preserve text formatting"); files via Cmd-C/V | [verified S24] |
| 6 | Dynamic resolution | Guest resolution follows the window size | [verified S6] |
| 7 | Retina modes | "Best for Retina display", "Scaled", "Best for external displays" | [verified S8] |
| 8 | Multi-monitor | "Use All Displays in Full Screen" for Windows and Linux; uses one display or all; layout comes from macOS | [verified S26] |
| 9 | Shared folders | Mac folders appear in Windows as "Mac" network folders; per-folder read-only; Linux mounts at `/media/psf` or `/mnt/psf` | [verified S23] |
| 10 | Shared profile | Mirrors Desktop, Documents, Downloads, etc. as symlinks (v20+); deleted files go to the macOS Trash; Movies, Music and Pictures are off by default since 26.3 | [verified S23] |
| 11 | Windows disks in Finder | Mount VM disks under Finder > Shared while the VM runs | [verified S23] |
| 12 | Shared applications | Windows apps open from Finder; a Dock folder of Windows apps; Dock icons bounce; Mac apps in the Windows Start menu ("Parallels Shared Applications"), "Open on Mac" | [verified S12] |
| 13 | File associations | Mac files open in Windows apps (Open With, Change All) and the reverse; starts or resumes the VM in Coherence | [verified S29] |
| 14 | Shared Internet apps | Chooses which browser (Mac or VM) opens which link type; Windows only | [verified S6] |
| 15 | SmartMount | Volumes connected to the Mac become available in the VM | [verified S6] |
| 16 | Printing | Syncs printers between host and guest | [verified S6] |
| 17 | USB | On connect, asks Mac or VM and can remember the choice; Devices > USB menu; Business edition has an "Allow external devices" list; `prlctl set --device-del usb` | [verified S14, S15] |
| 18 | Smart cards | Mac smart card readers shared with Windows; a CAC reader can be used by both at once | [verified S14, S15] |
| 19 | Sound and camera | Pick output device and microphone; "Share Mac camera with Windows" | [verified S25] |
| 20 | Snapshots | Manual snapshots; SmartGuard automatic snapshots (1 to 48 h interval, up to 100 kept, "Optimize for Time Machine"); Go To / Delete with merge | [verified S16] |
| 21 | Rollback mode | Starts the VM so session changes are discarded (Pro/Business) | [verified S13] |
| 22 | Isolation | Stops sharing of folders, profile, apps, devices and volume, and blocks drag and drop | [verified S7] |
| 23 | Encryption | Password-encrypts the VM (algorithm not stated on the page); vTPM storage encrypted with AES-128, key in the System Keychain | [verified S31, S32] |
| 24 | vTPM / Secure Boot | Added automatically to Windows 11 VMs | [verified S32] |
| 25 | Networking | Shared (NAT), Bridged, Host-only (custom networks), Disconnect; MAC address; Network Conditioner; DHCPv4/v6 servers; port-forwarding rules (Pro) | [verified S10, S30] |
| 26 | CPU and memory | Automatic (Windows 10+) or Manual; Standard edition limited to 4 vCPU / 8 GB, Pro up to 128 GB | [verified S9] |
| 27 | Adaptive Hypervisor | Shifts resources between macOS and the VM depending on the app in focus | [verified S9] |
| 28 | Nested virtualization | Linux guests on M3+ with macOS 15+ (Pro/Business) | [verified S9] |
| 29 | Profiles | Productivity, Games, Design, Software development, Software testing | [verified S19] |
| 30 | Startup and shutdown | Manual, Background, or Custom; start on window open, app start or user login; startup view Coherence / Window / Full Screen / PiP / **Headless (Pro)**; on-close actions; pause after idle | [verified S11, S34] |
| 31 | Picture in Picture | A small always-visible VM window | [verified S36, page exists] |
| 32 | Clone / linked clone / templates | Full clones; linked clones share the parent disk (Pro); templates (Pro) | [verified S18, S33] |
| 33 | Backup | "Backing Up a Virtual Machine" page | [verified S36, page exists] |
| 34 | prlctl / prlsrvctl | VM and app management CLI (Pro/Business/Enterprise) | [verified S17] |
| 35 | Vagrant provider | `vagrant-parallels`, MIT, latest tag 2.4.9 (2026-06-12) | [verified S21, git tags] |
| 36 | Packer plugin | `packer-plugin-parallels`, MPL-2.0, latest tag v1.2.8 (2025-04-22) | [verified S22, git tags] |
| 37 | DevOps service | Go REST API with RBAC for many hosts; free up to 10 users | [verified S28] |
| 38 | AppleScript | "Using Apple Script with the Guest OS" page | [verified S36, page exists] |
| 39 | Parallels Toolbox | About 36 utilities (capture, record, timers, DoNotSleep, etc.); not VM-related | [verified S35] |
| 40 | Tray integration | Windows tray icons in the Mac menu bar | [verified S6] |
| 41 | Linux Tools v26.1+ | "Driverless", using virtio-vsock instead of kernel modules | [reported S37] |
| 42 | SME / AI | Matrix acceleration in guests on M4/M5 | [verified S1] |
| 43 | Metal OpenGL 4.3 driver | Faster OpenGL for Windows guests | [verified S1] |

---

## 3. How to rebuild each feature

### 3.1 Coherence (seamless windows)

#### Windows guests: RDP RemoteApp (RAIL)

- **Protocol.** RemoteApp is specified in [MS-RDPERP], the Remote Programs Virtual Channel Extension [verified, R10]. The client opens the `rail` static virtual channel, and the server sends window orders (create, move, title, icon, visible region). The FreeRDP wiki notes that a packet capture shows the client registering `rail`, `rail_ri` and `rail_wi` [verified, R3].
- **Guest side.**
  - The RDP host must be Windows Pro, Enterprise or Education; Home editions cannot act as RDP hosts [verified, R9].
  - WinApps enables unlisted RemoteApp programs with these registry values: `fDenyTSConnections=0`, `UserAuthentication=1`, `TSAppAllowList\fDisabledAllowList=1`, `Policies\…\Terminal Services\fAllowUnlistedRemotePrograms=1` [verified, R7 `oem/RDPApps.reg`].
  - WinApps documents a mandatory 20-second RemoteApp session-termination delay [verified, R7].
- **FreeRDP state** (Apache-2.0; latest tag 3.32.2 on 2026-10-12) [verified, R1, git tags]:
  - **Cocoa client (`client/Mac`): no RAIL implementation.** Master on 2026-10-14 has only the files CertificateDialog, Clipboard, Keyboard, MRDPCursor, MRDPView, PasswordDialog and mf_client, and no rail code [verified, R1 source inspection].
  - A third-party doc site says MacFreeRDP supports RemoteApp [reported, R4]. The source does not support this, so treat the claim as **wrong or stale**.
  - **SDL3 client:** basic RAIL "beta" since 3.32.0 for X11 and Wayland [verified, R2]. `sdl_rail_platform.cpp` only distinguishes Wayland from non-Wayland, and its non-Wayland path uses X11 helpers (compositor detection, restacking). Whether SDL3 RAIL works on macOS's Cocoa SDL backend is **[unclear]**, and it would at best give generic SDL windows, not native ones.
  - The RAIL channel client (`channels/rail/client/rail_main.c`, `rail_orders.c`) can be reused as a library from your own Cocoa front end [verified, R1 source tree].
  - FreeRDP's `/app` option accepts `program:`, `cmd:`, `file:`, `guid:`, `icon:`, `name:`, `workdir:` and `hidef:` [verified, R1 `client/common/cmdline.h`].
- **IronRDP** (Devolutions, Rust, MIT OR Apache-2.0) [verified, R6]:
  - Includes a crate `ironrdp-rail` v0.1.0, described as a "RAIL static virtual channel wire protocol implementation", which is a codec only.
  - Also includes clipboard, display control, rdpsnd, rdpecam, rdpdr and USB-related crates.
  - Latest tag in the repo: `ironrdp-viewer-v0.1.0`, 2026-07-11 [verified, git tags].
  - Bindings: .NET via Diplomat and WASM. **No Swift bindings** [verified, R6], so you would write a C ABI shim.
- **Reference projects:**
  - WinApps: AGPL-3.0 for most files [verified, R7 LICENSE.md]; Linux only; uses FreeRDP RemoteApp; queries Windows for installed apps and creates shortcuts.
  - WinBoat: MIT, Electron app with a Go guest server; Linux only; tag v0.9.2 on 2026-08-25 [verified, R8, git tags].
  - **Neither supports macOS** [verified, R7, R8].
- **Recommendation.** Build a native Cocoa RAIL client:
  - libfreerdp core plus the rail, cliprdr, disp, rdpsnd, audin and rdpdr channels, all Apache-2.0.
  - Map each RAIL window to an `NSWindow` with no title bar. Composite surface bits from the RDP GFX pipeline into a `CAMetalLayer`, apply the visible-region shape, and map Z-order and focus to `NSWindow` ordering.
  - Connect to the guest over the vmnet host-only network, or a QEMU `hostfwd` port for 3389.
  - Effort: **L to XL**. The hardest parts are window-state fidelity (snap, minimize, modal dialogs) and focus/IME. Parallels itself fixed "dialogs behind other windows" in 27.0.3 [verified, S1].
- **Alternative (XL, research).** Write your own guest compositor-capture agent (per-window capture inside Windows plus an IPC channel to the host). I found no open-source implementation [unclear].

#### Linux guests

- **waypipe** (Wayland forwarding):
  - Rewritten in Rust in 0.10.3 (2025-03-13), and the license changed to **GPLv3** [verified, R12 changelog]. The freedesktop page still says MIT, so treat MIT as the pre-0.10.3 license [reported, R12].
  - `--vsock` transport since 0.9.0 [verified, R12].
- **Cocoa-Way** [verified, R14 repo; reported, R14 HN]:
  - Rust, **GPL-3.0**, v2.0.2 released 2026-07-18.
  - A native macOS Wayland compositor with a Metal renderer. It talks to Linux through a `waypipe-darwin` binary (over SSH, a Unix socket, or Apple container transport).
  - Hacker News commenters were skeptical about code quality and the README's claims.
- **xpra:** GPL-2.0+, has macOS arm64 clients and a "seamless" mode for X11 apps [verified, R13].
- **Weston RDP-RAIL** (from Microsoft's WSLg fork): **not merged** upstream. MR 1667 is still open and depends on unmerged FreeRDP PRs [verified, R11]. Using it would also need the macOS RAIL client described above.
- **GNOME Remote Desktop RAIL:** [unclear], not verified.
- **Recommendation:** treat seamless Linux windows as a late phase. The most realistic path is waypipe over virtio-vsock (VZ has `VZVirtioSocketDevice`) feeding your own Smithay- or Metal-based compositor. Mind GPL-3.0 if you reuse waypipe or Cocoa-Way code in a closed app.

### 3.2 Clipboard, dynamic resolution, drag and drop

**Linux on VZ**
- Apple's GUI Linux sample adds a `VZVirtioConsoleDeviceConfiguration` with a port named `VZSpiceAgentPortAttachment.spiceAgentPortName` and a `VZSpiceAgentPortAttachment` attachment. This gives copy and paste of **text and images** with guest `spice-vdagent` on macOS 13+ [verified, A1, A2].
- The same sample sets `automaticallyReconfiguresDisplay = true` (macOS 14+) so the Linux display resizes with the window [verified, A1, A11].
- UTM docs: spice-vdagent is required for clipboard on both backends, and for dynamic resolution on QEMU [verified, U11].

**Windows on QEMU**
- UTM guest tools (spice-nsis fork, **zlib** license) install [verified, U14 `win-guest-tools.nsis`, COPYING]:
  - `vdagent.exe` and `vdservice.exe` **ARM64 builds**
  - `vioserial`
  - `spice-webdavd-arm64` MSI
  - `viogpudo` or the experimental `viogpu3d`
- The qemu-ga install function picks the x64 MSI only on AMD64 and otherwise the x86 MSI, so ARM64 guests get the x86 build [verified, U14]. Whether that runs reliably under emulation is [unclear]. Linaro reports the virtio-win guest-tools installer works on arm64 (tested with 0.1.271) [verified, D3].
- QEMU has a built-in `qemu-vdagent` chardev with `mouse` and `clipboard` options [verified, Q3]. Its capability table includes `monitors-config` and `display-config`, but whether the built-in agent drives resolution changes is [unclear]. UTM uses a full SPICE client (CocoaSpice) instead.
- **CocoaSpice** (Apache-2.0) wraps spice-gtk (LGPL-2.1+) and provides [verified, U13, B5]:
  - Metal rendering
  - clipboard
  - USB sharing and enumeration
  - Unix and TCP connections

**Drag and drop**
- Neither SPICE nor VZ gives Parallels-style host-to-guest file drag and drop.
- **Recommendation:** implement drag and drop in your own agent. On drop, stage the file into the shared folder, then tell the guest agent to inject a drop at the cursor (X11/Wayland: XDND or Wayland data-device; Windows: OLE `DoDragDrop` from the agent).
- For Windows over RDP, the clipboard file-transfer channel (CLIPRDR file contents) is an option.

### 3.3 Shared folders

**Linux on VZ**
- `VZVirtioFileSystemDeviceConfiguration` with `mount -t virtiofs share /mnt/x`, or an fstab entry `share <mnt> virtiofs rw,nofail 0 0` [verified, U11].
- **Ownership quirk:** UID/GID changes made in the guest do not persist, and files appear owned by whichever user accesses them [reported, A23].
- Lima uses virtiofs for VZ and 9p for QEMU by default [verified, D6].

**Windows on QEMU**
- **virtio-fs:** upstream virtio-win builds `viofs.sys` and `virtiofs.exe` for Win11 ARM64 (listed in `win11_arm64.ddf`) [verified, D1].
  - The service links WinFsp (`#include "winfsp/winfsp.h"`) [verified, D1].
  - WinFsp runs natively on ARM64 [verified, D2] and is **GPLv3 with a FLOSS linking exception** [verified, D2 License.txt].
- **The host side is the blocker:**
  - QEMU's virtio-fs needs a vhost-user backend (virtiofsd, Rust, Linux-only).
  - QEMU's meson build disables vhost-user by default when the host OS is not Linux [verified, D8 source].
  - A 2024 patch series made vhost-user build on macOS (adding `memory-backend-shm`) and was tested with vhost-user-blk, not virtiofsd [verified, D8]. A FOSDEM 2025 talk still framed macOS support as an open question [verified, D9].
  - **So virtio-fs for Windows guests on a macOS host is not available off the shelf [verified/unclear].**
  - UTM's guest tools install `viofs` **only on non-ARM64** [verified, U14].
- **Working options today:**
  1. **SPICE WebDAV:** spice-webdavd ARM64 MSI is in UTM tools, and the share appears as a network drive [verified, U10, U14]. Performance is modest [unclear].
  2. **SMB:** macOS File Sharing reached over the vmnet host-only network.
  3. **RDP drive redirection** (`\\tsclient\`): comes "for free" if you build Coherence on RDP.
  4. **9p (VirtFS):** QEMU allows VirtFS on Darwin hosts (since 2022) [verified, D7], but Windows has no general 9p client driver for arbitrary virtio-9p devices [unclear]. A KVM Forum talk mentions Windows providing `v9pfs.dll` in a different context (WSL/Hyper-V) [verified, D4].
- **Shared profile (Parallels-style):** create symlinks or Known Folder redirection in the guest for Desktop, Documents and Downloads that point at the share. Parallels does this with symlinks since v20 [verified, S23].

### 3.4 3D acceleration

**Linux on VZ: none**
- `VZVirtioGraphicsDeviceConfiguration` exposes only `scanouts` [verified, A10]. There is no virgl, Venus or Metal path for Linux guests, so the guest renders with software (llvmpipe) [unclear on exact guest behavior].
- macOS 27 adds `VZCustomVirtioDeviceConfiguration`, a user-space virtio device with your own queues, but **it requires a custom guest driver** [verified, A7]. Building a GPU on it would be research-grade (XL) [Recommendation].

**Linux with 3D: switch backend**
- **UTM (QEMU):**
  - v5.0.0 (2026-01-11) added Venus (Vulkan 1.3 on Linux guests with Mesa) and an Apple Core OpenGL backend (OpenGL 4.1) [verified, U4, U2 tags].
  - The release notes recommend MoltenVK over KosmicKrisp, call KosmicKrisp "work in progress", and say Linux desktop rendering on Vulkan "does not work" yet because indirect draws for geometry shaders are missing [verified, U3].
- **libkrun / krunkit** (Apache-2.0):
  - virtio-gpu with Venus and native context.
  - krunkit runs "GPU-enabled (via venus) lightweight VMs on macOS" [verified, G10].
  - Lima's krunkit VM type is "experimental" [verified, G11].
- **KosmicKrisp** (LunarG, in Mesa):
  - Vulkan 1.3 conformant on macOS 15+ (announced 2025-10-30) [verified, G2].
  - **Vulkan 1.4 conformant** (2026-10-03); LunarG calls it production-ready on modern macOS and close to native Metal performance [verified, G1].
  - UTM 5.0.6 bundles it and requires macOS 26 for it [verified, U6].
- **Licenses:** MoltenVK Apache-2.0 [verified, G6], ANGLE BSD-3-Clause [verified, G7], virglrenderer MIT [verified, G8].
- **gfxstream / rutabaga:** QEMU documents host requirements only for Linux hosts [verified, G3]. macOS host status is [unclear].
- **QEMU 11.0** added virtio-gpu native context and per-output resolution [verified, G4].

**Windows on QEMU**
- `viogpudo` (display-only) ships for ARM64 [verified, D1].
- **Neptune** (2026-05-16) [verified, U7]:
  - A Direct3D-over-virtio-gpu protocol inside virglrenderer.
  - At first it ran only on a Linux host with a Linux guest through DXVK.
- **Triton** (2026-07-24) [verified, U8]:
  - A D3D11 user-mode driver for **Windows ARM64** guests, plus a KMD.
  - Pre-built signed drivers live on `osy/kvm-guest-drivers-windows` releases.
  - Host backends on macOS are **DXMT** (LGPL-2.1, CodeWeavers [verified, G9]) or **D3DMetal**. D3DMetal is x86_64-only (runs under Rosetta), and its license prevents bundling.
  - The authors call the drivers "still very unstable".
- **UTM releases:**
  - v5.0.4 (2026-08-01): added the Neptune backend [verified, U5].
  - v5.0.5 (2026-09-01): experimental DirectX 12 via D3DMetal (macOS) and DX11 via DXMT (iOS) [verified, U3].
  - v5.0.6 (tag 2026-09-24): notes the Windows 3D driver "needs an update that hasn't been released yet" [verified, U6].
- **Parallels gap:** Parallels ships DX11.1 and OpenGL 4.3 today [verified, S4]. Matching it is **XL**.

### 3.5 USB passthrough

**VZ, macOS 27+**
- APIs: `VZUSBPassthroughDeviceConfiguration(device: AAUSBAccessory)` and `VZUSBPassthroughDevice`, attached via `VZUSBController.attach(device:)`; devices are discovered through **AccessoryAccess** (`AAUSBAccessoryManager.shared.registerListener`) [verified, A7, A8, A9].
- **Entitlements** [verified, B1]:
  - `com.apple.developer.accessory-access.usb` ("Claim USB Accessory"): restricted; needs a paid account and a provisioning profile.
  - `com.apple.security.device.usb`, which implies the App Sandbox.
  - `com.apple.security.virtualization` (ad-hoc signing works).
- **UX constraint** [verified, B1]:
  - The user hands each device to the app through a "Virtual Machine Accessories" menu-bar item.
  - There is "no API to request this handover", and the choice "doesn't persist across launches".
  - Known bug FB24018643: matching works only with `IOUSBDevice`.
  - Tested with an Ubuntu 26.04 guest.
- UTM 5.0.6 implements this for AVF ("USB passthrough", macOS 27) using `AccessoryAccess` [verified, U6, U15 `UTMAppleUSBManager.swift`].
- Before macOS 27, Apple DTS answered "No" to USB passthrough on VZ [verified, A22].

**QEMU**
- libusb's darwin backend captures devices via `USBDeviceReEnumerate` with the capture mask, which needs **root** or `com.apple.vm.device-access` plus `IOServiceAuthorize()` [verified, B3].
- Apple: `com.apple.vm.device-access` is required for IOUSBHost device capture [verified, A17].
- UTM uses SPICE usbredir through CocoaSpice (`CSUSBDevice`) and holds `com.apple.vm.device-access` in its signed entitlements [verified, U15, U17].
- **Limitations** [verified, U9]:
  - "it is not possible to get a proper hardware reset"
  - built-in Apple webcams cannot be captured
- One user found USB Wi-Fi adapters "basically non-functional" [reported, B4].
- **Licenses:** usbredir GPL-2+/LGPL-2.0+/LGPL-2.1+; spice-gtk LGPL [verified, B5].

### 3.6 Snapshots, rollback, suspend

**VZ**
- `pause()` then `saveMachineStateTo(url:)` (macOS 14+); it fails unless the VM is paused [verified, A3]. Check `validateSaveRestoreSupport()` first [verified, A4].
- **Linux caveat:**
  - One developer got "Unsupported graphics device in configuration" saving a Linux VM with virtio graphics on macOS 14.2 [reported, A24].
  - Tart refuses suspend for non-macOS VMs [verified, P1].
  - UTM probes with `validateSaveRestoreSupport()` and disables state snapshots when it fails [verified, U15].
  - **Expect memory snapshots of GUI Linux on VZ to be unavailable; verify on macOS 27 [unclear].**
- **Disk snapshots:**
  - `clonefile(2)` / `cp -c` gives copy-on-write images [verified, I7].
  - macOS 27 **DiskImageKit** stacks ASIF layers (base, cache, overlay) and attaches them via `VZDiskImageStorageDeviceAttachment(diskImage:)` [verified, A7, A25, A26].
  - UTM 5.0.6 stores each snapshot as an ASIF layer named `<image>.<uuid>.asif`, copies the EFI vars alongside, and copies the saved state if present. Layers can only be changed while the VM is not running [verified, U15 `UTMAppleSnapshotBackend.swift`, `UTMAppleDiskImage.swift`].
  - Older hosts fall back to the private DiskImages2 framework [verified, U15]. Avoid that in an App Store-bound app [Recommendation].

**QEMU**
- `savevm`/`loadvm`/`delvm` need at least one writable non-removable qcow2. The VM state goes in the first qcow2, and each disk stores its own snapshot [verified, Q1].
- QMP `snapshot-save` exists since 6.0 [verified, Q2].
- `-snapshot` makes all disks read-only and sends writes to a temp file, which gives rollback mode [verified, Q1].
- UTM splits this into a **live** backend (QMP, VM running) and a **frozen** backend (qemu-img, VM off) [verified, U15].

**Rollback** maps to an ephemeral overlay (VZ) or `-snapshot` (QEMU). UTM's "Run without saving changes" is available for AVF on macOS 27 [verified, U6].

### 3.7 Guest agents

- **Parallels Tools** = the 13 tools in §2.2 [verified, S6]. On Linux it now uses virtio-vsock and no kernel modules [reported, S37].
- **Open equivalents:**
  - **spice-vdagent** (GPL-3.0+) [verified, B5]: clipboard and resolution.
  - **qemu-ga** (part of QEMU, GPL-2.0 [verified, Q6]): time, exec, file, IP and shutdown commands. `utmctl` exposes file pull/push, exec and ip-address through the guest agent [verified, U16].
  - **Your own agent over virtio-vsock** (`VZVirtioSocketDevice` on VZ; on QEMU, `vhost-vsock` is Linux-host-only [unclear], so use virtio-serial for Windows on QEMU).
- **Models to copy:**
  - Apple `containerization`'s `vminitd`: init plus a gRPC API over vsock [verified, P7].
  - Tart guest agent (gRPC, `tart exec`) [verified, P1].
  - VirtualBuddy `VirtualWormhole`: vsock port 51780, clipboard sync with session tokens and verified file transfers, for macOS guests [verified, P3].
  - Lima `pkg/guestagent` with `timesync` and port-forward sockets [verified, P4 source tree].
- **Time sync:** the guest clock stops during host sleep. vfkit/krunkit `--timesync vsockPort=N` sets it through `qemu-ga --method=vsock-listen` [verified, I7, P9].
- **Graceful shutdown:** VZ `requestStop()` [verified, A12]; QEMU QMP `system_powerdown` [verified, Q2].

### 3.8 Unattended install and auto-configuration

**Linux**
- cloud-init **NoCloud** reads a vfat or iso9660 volume labelled `CIDATA`. Files: `user-data`, `meta-data` (must contain `instance-id`), optional `network-config` and `vendor-data`. Alternatively use `ds=nocloud;s=<uri>/` on the kernel command line [verified, I1].
- vfkit can build the seed ISO itself (`--cloud-init user-data,meta-data`) [verified, I7]. Lima has `pkg/cidata` [verified, P4].
- cloud-init is dual GPLv3 / Apache-2.0 [verified, I9]. You only generate its input files, so its license doesn't affect your app.
- **Ubuntu autoinstall:** `user-data` with an `autoinstall:` block on a seed ISO built with `cloud-localds`. Add `autoinstall` to the kernel command line to skip the confirmation prompt [verified, I2].
- **Fastest path:** boot ARM64 cloud images directly with a NoCloud seed instead of running installers [Recommendation].

**Windows 11 ARM64**
- Official ARM64 ISO: microsoft.com/software-download/windows11arm64 [verified, I5].
- Setup finds `Autounattend.xml` at the root of removable read/write or read-only media [verified, I3].
- Components need `processorArchitecture="arm64"`. UTM's `Autounattend.xml` lists every component twice, once for amd64 and once for arm64 [verified, U14].
- The Arm Learning Path script [verified, I4]:
  1. downloads the ARM64 ISO and patches it to boot without a keypress
  2. downloads the VirtIO drivers
  3. generates `autounattend.xml` and `firstlogin.ps1`
  4. packs them into `unattended.iso`
  5. creates a qcow2 disk
  6. boots QEMU with UEFI (20 to 30 minutes)
- **VM requirements:** TPM 2.0 and Secure Boot, at least 4 GB RAM, at least 2 vCPUs, at least 64 GB disk [verified, I6].
- UTM uses SWTPM and an ARM64 Secure Boot firmware [verified, U18]. swtpm is BSD-3-Clause [verified, I8].

### 3.9 Networking

**VZ**
- **NAT** via `VZNATNetworkDeviceAttachment` needs no special entitlement [unclear on the exact entitlement; Lima vzNAT needs neither root nor sudoers, verified N1].
- **Bridged** (`VZBridgedNetworkDeviceAttachment`) requires `com.apple.vm.networking` [verified, A5]. That entitlement is "restricted to developers of virtualization software" and you must contact Apple to get it [verified, A16].
- **macOS 26+:** `VZVmnetNetworkDeviceAttachment(network:)` with `vmnet_network_create` [verified, A6, A7]:
  - shared and host modes
  - custom subnets
  - DHCP settings
  - TCP/UDP port forwarding
  - networks shareable across processes via XPC serialization
  - a VM can only use a network its own process created (unless shared via serialization)
  - networks are not persisted when the app quits
- Code-Hex/vz's PR says the flow "does not require the `com.apple.vm.networking` entitlement nor root privileges" [reported, N2].
- UTM 5.0.6 offers "Shared Network (VM to VM)" and "Host Only" for AVF on macOS 26, and pins subnets 192.168.96.1/24 and 192.168.160.1/24 for stable addresses [verified, U6, U15].
- A forum thread title reports DHCP reservations and port-forwarding rules being lost when the last interface leaves a `vmnet_network_ref` [reported, A29]. Plan to re-create them.
- **Before macOS 26:** host-only and port forwarding meant `VZFileHandleNetworkDeviceAttachment` plus your own user-space stack [verified, A21].

**QEMU**
- `-netdev user` (libslirp: BSD-3-Clause and MIT [verified, N6]) with `hostfwd=tcp::2222-:22` [verified, N9].
- `vmnet-shared`/`-host`/`-bridged` need root or `com.apple.vm.networking` [verified, N3, N4]. UTM's QEMU launcher holds that entitlement [verified, U17].
- **socket_vmnet** (Apache-2.0, v1.2.2 on 2025-11-19): a root-owned daemon that Lima starts via sudoers [verified, N1, N7].
- **gvisor-tap-vsock** (Apache-2.0): a user-space stack used by podman/Lima (`user-v2`) [verified, N8, N10].
- **passt:** Linux-only [verified, N5].
- **Open question [unclear]:** QEMU's `net/vmnet-*` does not use the macOS 26 `vmnet_network_*` APIs (only `vmnet-host.c` references `vmnet_network_identifier_key`) [verified, source]. So the macOS 26 rootless vmnet path does not apply to QEMU yet without patching.

### 3.10 CLI, scripting and automation

- **utmctl** (Swift ArgumentParser) drives UTM.app through **ScriptingBridge/AppleScript** (`UTM.sdef`) [verified, U16]. Commands:
  - `list`, `status`, `start`, `suspend`, `stop`
  - `attach` (serial)
  - `file pull/push`, `exec`, `ip-address`
  - `clone`, `delete`
  - `usb list/connect/disconnect`
  - `snapshot list/create/restore/overwrite/rename/delete/scan/discard-state`
- **Tart CLI:** clone, create, delete, exec, export, get, import, ip, list, login, logout, prune, pull, push, rename, run, set, stop, suspend. Each VM runs in its own `tart run` process, and `suspend` sends it SIGUSR1 [verified, P1].
- **vfkit / krunkit:** `--restful-uri` (tcp or unix) for a REST control API [verified, I7, P9].
- **Lima:** `limactl` with YAML templates [verified, P4].
- **Vagrant:** `vagrant_utm` 0.2.0, MIT, released 2026-10-14 [verified, P16]. Parallels' provider is MIT [verified, S21].
- **System hooks:** App Intents (macOS 13+) for Shortcuts, Spotlight and Siri [verified, A20]. `SMAppService` for login items, agents and daemons (macOS 13+) [verified, A19].
- **Recommendation:** one VM-runner helper process per VM (as UTM and Tart do), a control XPC service, the CLI talking XPC (not AppleScript, for speed), and AppleScript/App Intents as thin wrappers.

### 3.11 Resource tuning on the M4 Pro

- **M4 Pro variants:** 12-core (8P + 4E) [verified, P19 notebookcheck] or 14-core (10P + 4E), up to 64 GB [verified, P19 MacRumors].
- vCPU threads are scheduled like P-cores, "invariably run at high QoS", and the guest cannot request E-cores [reported, A27, older macOS]. VM cores are "primarily Performance cores" [reported, A28].
- **Parallels:**
  - Automatic sizing for Windows 10+
  - Standard edition capped at 4 vCPU / 8 GB
  - Adaptive Hypervisor shifts resources toward the app in focus
  - Pause after idle saves CPU and battery
  [verified, S9, S34]
- The Arm Learning Path defaults to half the host's RAM and half its cores, with minimums of 2 GB and 2 cores [verified, I4].
- **VZ memory:** balloon adjustable at runtime via `targetVirtualMachineMemorySize` [verified, A13].
- **SME:** Hypervisor SME state APIs since macOS 15.2 [verified, A18]. QEMU 11.0 exposes SME2 via HVF, and the code clears SME when nested virt is enabled [verified, G4, Q5]. On M4 this lets you match Parallels' "AI acceleration" claim for QEMU guests. VZ exposure is [unclear].
- **Recommendation** for defaults on a 12-core / 24 to 48 GB M4 Pro:

  | Guest | vCPUs | RAM | Disk |
  |---|---|---|---|
  | Windows 11 | 4 to 6 (never more than P-cores minus 2) | 8 GB | 64 GB+ |
  | Linux desktop | 4 | 4 to 8 GB | |
  | Linux server | 2 | 2 GB | |

  Auto-pause after N minutes with no foreground window. Battery mode: cap vCPUs at 2 to 4 and pause idle VMs (Parallels removed Travel mode [verified, S1]).

---

## 4. Open-source reference implementations

Release dates are the latest tag dates read with `git for-each-ref` on 2026-10-14 [verified unless noted].

| Project | URL | License | Language | Backend | Latest release | Worth studying |
|---|---|---|---|---|---|---|
| **UTM** | github.com/utmapp/UTM | Apache-2.0, with (L)GPL components such as QEMU and gstreamer [verified U1] | Swift + ObjC | QEMU+HVF **and** VZ | v5.0.6 beta (2026-09-24); v4.7.5 stable "Latest" (2026-01-03) [verified U2] | `Services/` (snapshot backends, AccessoryAccess USB, vmnet manager, ASIF images, SWTPM), `QEMULauncher`/`QEMUHelper` process split and entitlements, `utmctl`, `Scripting/UTM.sdef`, guest tools (spice-nsis), CocoaSpice |
| **CocoaSpice** | github.com/utmapp/CocoaSpice | Apache-2.0 [verified U13] | Swift/ObjC over spice-gtk (LGPL) | SPICE client | (no tags checked) | Metal SPICE display, clipboard, USB redirection |
| **VirtualBuddy** | github.com/insidegui/VirtualBuddy | BSD-2-Clause [verified P3] | Swift | VZ | 2.2 (2026-10-13) | VirtualWormhole vsock channel and clipboard protocol; guest app; macOS-guest focus, Linux "some distros" |
| **Tart** | github.com/cirruslabs/tart (README now points to **github.com/openai/tart**) | **FSL-1.1-ALv2** (relicensed 2026-06-05, commit 5ad172e). Copyright OpenAI. Any "Competing Use" is prohibited; each version converts to Apache-2.0 two years after release [verified P1] | Swift | VZ | 2.41.0 (2026-10-13) | APFS CoW clone + space reclaim, OCI push/pull, gRPC guest agent, suspend rules. **Study only; do not copy into a competing product** |
| Cirrus Labs note | cirruslabs.org | | | | | Joined OpenAI (announced 2026-04-07); promised a "more permissive license" and stopped charging fees [verified P2]. The June relicense to FSL with an Apache future license appears to be that step [unclear] |
| **Lima** | github.com/lima-vm/lima | Apache-2.0 [verified] | Go | QEMU, VZ (default on macOS since v1.0), krunkit (experimental) [verified G11] | v2.2.1 (2026-10-03); v2.3.0-beta.1 | `pkg/cidata`, `pkg/guestagent` (timesync), `pkg/portfwd`, `pkg/networks` (socket_vmnet/sudoers), mounts. CNCF incubating [verified P4] |
| **Code-Hex/vz** | github.com/Code-Hex/vz | MIT [verified] | Go + ObjC | VZ bindings | v3.8.0 (2026-09-29) | `vmnet/` package (macOS 26 APIs, XPC sharing), wiki of Linux-on-VZ knowledge |
| **apple/container** | github.com/apple/container | Apache-2.0 [verified] | Swift | VZ (one lightweight VM per container) | 1.5.0 (2026-09-28) | Needs macOS 26 [verified P6]; vmnet networking per container |
| **apple/containerization** | github.com/apple/containerization | Apache-2.0 [verified] | Swift | VZ (macOS); cloud-hypervisor on Linux | 0.51.0 (2026-10-13) | `vminitd` gRPC over vsock, ext4 builder, optimized kernel config, Rosetta [verified P7] |
| **libkrun** | github.com/containers/libkrun | Apache-2.0 [verified] | Rust | Own VMM on HVF | v1.19.6 (2026-09-29) | virtio-gpu Venus/native context, virtio-fs, vsock TSI networking [verified G10] |
| **krunkit** | github.com/containers/krunkit | Apache-2.0 [verified] | Rust | libkrun/HVF | v1.3.2 (2026-07-03) | GPU (Venus) Linux VMs on macOS 14+; vfkit-compatible CLI, `--timesync`, REST API [verified P9] |
| **vfkit** (Red Hat / CRC) | github.com/crc-org/vfkit | Apache-2.0 [verified] | Go | VZ | v0.6.4 (2026-07-07) | `doc/usage.md` device catalogue, cloud-init ISO generation, timesync, REST API [verified I7] |
| podman machine | docs.podman.io | Apache-2.0 [unclear] | Go | `applehv` provider [verified P17]; libkrun provider [unclear] | n/a | Provider abstraction |
| **macosvm** | github.com/s-u/macosvm | GPL-2.0 or GPL-3.0 [verified] | ObjC | VZ | 0.2-3 (2026-06-22) | `--ephemeral`, `cp -c` CoW clones [verified P11] |
| **Quickemu** | github.com/quickemu-project/quickemu | MIT [verified] | Bash | QEMU (HVF on macOS hosts) [verified source] | 4.9.9 (2026-02-10) | SPICE clipboard, 9p and Samba sharing, OS download recipes [verified P12] |
| **socket_vmnet** | github.com/lima-vm/socket_vmnet | Apache-2.0 [verified] | C | vmnet daemon | v1.2.2 (2025-11-19) | Root daemon model, if QEMU needs vmnet without the entitlement |
| **FreeRDP** | github.com/FreeRDP/FreeRDP | Apache-2.0 [verified R1] | C | RDP client | 3.32.2 (2026-10-12) | rail/cliprdr/disp/rdpdr/audin channels; SDL3 RAIL (beta) |
| **IronRDP** | github.com/Devolutions/IronRDP | MIT OR Apache-2.0 [verified R6] | Rust | RDP client/server | ironrdp-viewer v0.1.0 (2026-07-11) | `ironrdp-rail` codec, rdpecam, cliprdr |
| **WinApps** | github.com/winapps-org/winapps | AGPL-3.0 (mostly) [verified R7] | Bash | KVM/Docker on Linux | no tags | RemoteApp registry setup, app discovery. **Do not copy code** |
| **WinBoat** | github.com/TibixDev/winboat | MIT [verified R8] | TypeScript (Electron) + Go guest server | Docker/Podman KVM on Linux | v0.9.2 (2026-08-25) | Go guest server for app lists and icons |
| **Cocoa-Way** | github.com/J-x-Z/cocoa-way | GPL-3.0 [verified R14] | Rust | Wayland compositor on macOS | 2.0.2 (2026-07-18) | Proof of concept for seamless Linux windows |
| **Veertu Anka** | veertu.com | Commercial | n/a | macOS VMs; backend [unclear] | brew cask 3.9.3.219 [verified P13] | CI-focused; macOS guests |
| **OrbStack** | orbstack.dev | Free for personal use; Pro $8 per user per month for commercial use [verified P14]; open-source status not stated [unclear] | Swift app [verified] | [unclear] | n/a | UX benchmark for Linux machines and VirtioFS |
| **Viable / Liviable** | eclecticlight.co | Freeware by Howard Oakley [reported P15]; source availability [unclear] | n/a | VZ | n/a | Liviable runs Linux VMs [reported P15] |
| Apple sample "Running GUI Linux in a VM on a Mac" | developer.apple.com | Apple sample code license [unclear] | Swift | VZ | macOS 13+ [verified A1] | Minimal correct device set: EFI, virtio-blk, NAT, virtio-gpu, audio in/out, USB keyboard and pointer, SPICE clipboard, auto-resize |
| vagrant_utm | rubygems.org/gems/vagrant_utm | MIT [verified P16] | Ruby | UTM | 0.2.0 (2026-10-14) | Template for your Vagrant provider |

**Newer Windows-on-ARM-for-Mac open-source projects (2025/2026):** apart from UTM's Neptune and Triton work, I did not find a dedicated new open-source app before the search budget ran out [unclear]. One article says VMware Fusion became free for personal and commercial use in late 2024 [reported, P18].

---

## 5. Licensing and entitlement checklist

**Licenses**
- **QEMU is GPL-2.0** [verified, Q6]. Ship it as a separate executable (as UTM does with `QEMULauncher`) and publish the source of the exact QEMU you ship. Your Swift app can stay under any license if it only talks to QEMU over QMP and SPICE sockets [Recommendation; consult counsel].
- **spice-gtk and usbredir are LGPL** [verified, B5]. Link them dynamically and allow relinking.
- **Guest-side GPL components:** spice-vdagent (GPL-3.0+) and WinFsp (GPL-3.0 with FLOSS exception). Redistributing them in a guest-tools ISO means you must offer their source.
  - WinFsp's exception covers FLOSS software that links to it. virtio-win's `virtiofs.exe` is BSD-licensed, so it qualifies [verified, D1, D2].
  - Whether a closed-source agent of yours may link WinFsp is [unclear], so avoid linking it directly.
- **virtio-win drivers:** BSD-3-Clause style [verified, D1]. **spice-nsis** installer: zlib [verified, U14].
- **Do not reuse code from:** Tart (FSL "Competing Use"), WinApps (AGPL), Cocoa-Way and waypipe (GPL-3.0), unless your app is GPL-compatible.
- **D3DMetal** cannot be bundled [verified, U8]. **DXMT** is LGPL-2.1 [verified, G9].

**Entitlements**
- `com.apple.security.virtualization`: VZ; works with ad-hoc signing [verified, B1].
- `com.apple.security.hypervisor` (plus `allow-jit`) for the QEMU process [verified, U17].
- `com.apple.vm.networking`: restricted; needed for bridged VZ networking and QEMU vmnet [verified, A5, A16, U17].
- `com.apple.vm.device-access`: USB capture for QEMU [verified, A17, B3].
- `com.apple.developer.accessory-access.usb`: restricted; VZ USB on macOS 27 [verified, B1].

---

## 6. Suggested phased roadmap

**Phase 1 (4 to 6 weeks): Linux on VZ, "Parallels Lite"**
- Device set from Apple's GUI Linux sample [verified, A1].
- `automaticallyReconfiguresDisplay`, SPICE clipboard, and virtiofs shares with a "Mirror home folders" preset.
- NAT, plus vmnet shared and host-only with port forwarding on macOS 26.
- Cloud-image install with a NoCloud seed ISO; ISO install as a fallback.
- Pause, resume and graceful stop; `clonefile` clones and templates; rollback via an ephemeral clone.
- Login item via `SMAppService`; headless mode.
- `yourctl` CLI over XPC.
- Small vsock agent: IP report, time sync after wake, shutdown hooks.

**Phase 2 (6 to 10 weeks): Windows 11 ARM on QEMU+HVF**
- Separate QEMU process (sandboxed, `com.apple.security.hypervisor`), EDK2 with Secure Boot, swtpm.
- Generated `Autounattend.xml` (arm64 components) plus a virtio-win ARM64 driver ISO.
- Display via CocoaSpice (Apache-2.0) or your own SPICE client; vdagent ARM64 for clipboard and resolution.
- Shares via SPICE WebDAV or SMB.
- libslirp user networking with `hostfwd`; request `com.apple.vm.networking` from Apple early.
- QMP snapshots (live and frozen), `-snapshot` rollback, qcow2 backing-file linked clones.
- Turn on SME2 (QEMU 11.0+).

**Phase 3 (8 to 12 weeks): integration parity**
- Snapshot manager with scheduled "SmartGuard" equivalent.
- On macOS 27: DiskImageKit layered snapshots for VZ, and USB passthrough via AccessoryAccess (needs the restricted entitlement).
- QEMU USB via usbredir (needs `com.apple.vm.device-access`).
- Mic for Windows through SPICE record; isolation mode; auto-tuning presets; Vagrant provider and Packer plugin.

**Phase 4 (3 to 6 months): Coherence for Windows**
- Native Cocoa RAIL client on libfreerdp (rail + cliprdr + rdpdr + audin + disp).
- Guest agent enumerates Start-menu apps and icons and generates stub `.app` bundles in `~/Applications/<VM> Apps` (Dock, Launchpad, Spotlight).
- Document-type declarations for "Open With".
- RDP drive redirection replaces WebDAV for Coherence sessions.

**Phase 5 (research): graphics and seamless Linux**
- Optional "Linux with 3D" profile on QEMU or libkrun with Venus plus KosmicKrisp or MoltenVK.
- Track UTM Triton/Neptune for Windows D3D11.
- Prototype waypipe over vsock with a Metal compositor.

---

## 7. Open questions to check on a real M4 Pro running macOS 27

1. Does `validateSaveRestoreSupport()` pass for a Linux VZ VM with `VZVirtioGraphicsDeviceConfiguration` on macOS 27? Prior reports say no [reported, A24].
2. Does VZ accept more than one Linux scanout (multi-monitor)? [unclear]
3. Do `vmnet_network_*` APIs work in a sandboxed app without `com.apple.vm.networking`? Reported yes [reported, N2]. Does port forwarding survive VM restarts? [reported issue, A29]
4. Does FreeRDP's SDL3 RAIL path work on the macOS SDL backend at all? [unclear]
5. Does qemu-ga (x86 build) work in Windows ARM64 guests, or should you ship the virtio-win ARM64 guest agent? [unclear]
6. Does VZ expose SME to Linux guests on M4? [unclear]

---

## 8. Sources

### Parallels
- S1 Parallels Desktop 27 release notes (KB 131168): https://kb.parallels.com/131168/
- S2 Parallels blog "Parallels Desktop 27": https://www.parallels.com/blogs/parallels-desktop-27/
- S3 MacTrast on PD 27: https://www.mactrast.com/2026/08/parallels-desktop-27-update-now-apple-silicon-only-offers-faster-graphics-and-ai-acceleration-thanks-to-new-metal-based-graphics-driver/
- S4 Limitations of Windows 11 on Apple silicon (KB 129497): https://kb.parallels.com/en/129497
- S5 Coherence ("Merging Windows and macOS"): https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-26-users-guide/use-windows-on-your-mac/setting-how-windows-works-with-macos/merging-windows-and-macos.md
- S6 Parallels Tools overview (PD27 UG): https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/advanced-topics/installing-and-updating-parallels-tools/parallels-tools-overview.md
- S7 Isolating Windows from Mac: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/use-windows-on-your-mac/protecting-your-data/isolating-windows-from-mac.md
- S8 Graphics settings: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/parallels-desktop-preferences-and-virtual-machine-settings/virtual-machine-settings/hardware-settings/graphics-settings.md
- S9 CPU & Memory settings: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/parallels-desktop-preferences-and-virtual-machine-settings/virtual-machine-settings/hardware-settings/cpu-and-memory-settings.md
- S10 Network settings: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/parallels-desktop-preferences-and-virtual-machine-settings/virtual-machine-settings/hardware-settings/network-settings.md
- S11 Startup and shutdown settings: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/use-windows-on-your-mac/getting-started/shutdown-and-suspend-windows/startup-and-shutdown-settings.md
- S12 Sharing applications: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/use-windows-on-your-mac/setting-how-windows-works-with-macos/sharing-items-between-macos-and-windows/sharing-applications.md
- S13 Rollback mode: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/use-windows-on-your-mac/protecting-your-data/working-in-windows-without-saving-changes.md
- S14 USB & Bluetooth settings: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/parallels-desktop-preferences-and-virtual-machine-settings/virtual-machine-settings/hardware-settings/usb-and-bluetooth-settings.md
- S15 Connecting external devices: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/use-windows-on-your-mac/connecting-external-devices.md
- S16 Snapshots: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/advanced-topics/working-with-virtual-machines/saving-snapshots-of-a-virtual-machine.md
- S17 Developer's Guide CLI: https://docs.parallels.com/parallels-desktop-developers-guide/command-line-interface-utility
- S18 Cloning: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/advanced-topics/working-with-virtual-machines/cloning-a-virtual-machine.md
- S19 Profiles: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/use-windows-on-your-mac/optimizing-performance/optimizing-virtual-machines-for-specific-tasks.md
- S20 Parallels Tools for Linux: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/advanced-topics/installing-and-updating-parallels-tools/parallels-tools-for-linux.md
- S21 vagrant-parallels: https://github.com/Parallels/vagrant-parallels
- S22 packer-plugin-parallels: https://github.com/Parallels/packer-plugin-parallels
- S23 Sharing files and folders: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/use-windows-on-your-mac/setting-how-windows-works-with-macos/sharing-items-between-macos-and-windows/sharing-files-and-folders.md
- S24 Copy and paste: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/use-windows-on-your-mac/setting-how-windows-works-with-macos/sharing-items-between-macos-and-windows/copying-and-pasting-between-macos-and-windows.md
- S25 Sound & Camera: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/parallels-desktop-preferences-and-virtual-machine-settings/virtual-machine-settings/hardware-settings/sound-and-camera-settings.md
- S26 Full screen on multiple monitors (KB 122901): https://kb.parallels.com/en/122901
- S27 Drag and drop (KB 6910): https://kb.parallels.com/en/6910
- S28 DevOps Service: https://docs.parallels.com/landing/parallels-desktop-developers-guide/devops-service
- S29 Open files in preferred app: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/use-windows-on-your-mac/setting-how-windows-works-with-macos/sharing-items-between-macos-and-windows/setting-files-to-open-in-your-preferred-application.md
- S30 Shared network settings: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/advanced-topics/shared-network-settings.md
- S31 Encrypting Windows: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/use-windows-on-your-mac/protecting-your-data/encrypting-windows-to-protect-it-from-unauthorized-use.md
- S32 Virtual TPM (KB 122702): https://kb.parallels.com/en/122702
- S33 VM templates: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/advanced-topics/working-with-virtual-machines/creating-and-using-virtual-machine-templates.md
- S34 Pause when no apps open: https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-27-users-guide/use-windows-on-your-mac/optimizing-performance/pausing-windows-when-no-applications-are-open.md
- S35 Toolbox tools list (KB 124364): https://kb.parallels.com/124364/
- S36 Parallels docs index: https://docs.parallels.com/llms.txt
- S37 OMG! Ubuntu on Parallels Tools for Linux 26.1 (virtio-vsock): https://omgubuntu.co.uk/2025/10/parallels-desktop-tools-linux-virtio-sock-update
- S38 KB 114124 (Windows apps in Dock): https://www.kb.parallels.com/en/114124

### Apple
- A1 Running GUI Linux in a VM on a Mac: https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac
- A2 VZSpiceAgentPortAttachment: https://developer.apple.com/documentation/virtualization/vzspiceagentportattachment
- A3 saveMachineStateTo: https://developer.apple.com/documentation/virtualization/vzvirtualmachine/savemachinestateto(url:completionhandler:)
- A4 validateSaveRestoreSupport: https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration/validatesaverestoresupport()
- A5 VZBridgedNetworkDeviceAttachment: https://developer.apple.com/documentation/virtualization/vzbridgednetworkdeviceattachment
- A6 VZVmnetNetworkDeviceAttachment init(network:): https://developer.apple.com/documentation/virtualization/vzvmnetnetworkdeviceattachment/init(network:)
- A7 WWDC26 session 224 "Expand the capabilities of your Virtualization app": https://developer.apple.com/videos/play/wwdc2026/224/
- A8 VZUSBPassthroughDevice: https://developer.apple.com/documentation/virtualization/vzusbpassthroughdevice
- A9 VZUSBPassthroughDeviceConfiguration: https://developer.apple.com/documentation/virtualization/vzusbpassthroughdeviceconfiguration
- A10 VZVirtioGraphicsDeviceConfiguration: https://developer.apple.com/documentation/virtualization/vzvirtiographicsdeviceconfiguration
- A11 automaticallyReconfiguresDisplay: https://developer.apple.com/documentation/virtualization/vzvirtualmachineview/automaticallyreconfiguresdisplay
- A12 requestStop(): https://developer.apple.com/documentation/virtualization/vzvirtualmachine/requeststop()
- A13 targetVirtualMachineMemorySize: https://developer.apple.com/documentation/virtualization/vzvirtiotraditionalmemoryballoondevice/targetvirtualmachinememorysize
- A14 VZHostAudioInputStreamSource: https://developer.apple.com/documentation/virtualization/vzhostaudioinputstreamsource
- A15 isNestedVirtualizationEnabled: https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration/isnestedvirtualizationenabled
- A16 com.apple.vm.networking: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.vm.networking
- A17 com.apple.vm.device-access: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.vm.device-access
- A18 hv_vcpu_get_sme_state: https://developer.apple.com/documentation/hypervisor/hv_vcpu_get_sme_state(_:_:)
- A19 SMAppService: https://developer.apple.com/documentation/servicemanagement/smappservice
- A20 App Intents: https://developer.apple.com/documentation/appintents
- A21 Forum: host-only and port forwarding in VZ: https://developer.apple.com/forums/thread/783894
- A22 Forum: USB passthrough answer "No": https://developer.apple.com/forums/thread/825379
- A23 Forum: shared directories do not honor uid/gid: https://developer.apple.com/forums/thread/779419
- A24 Forum: Linux save state "Unsupported graphics device": https://developer.apple.com/forums/thread/745168
- A25 Eclectic Light, virtualisation in Golden Gate: https://eclecticlight.co/2026/06/12/macos-virtualisation-is-leaping-forward-in-golden-gate/
- A26 Bitrise on WWDC26 Virtualization: https://bitrise.io/blog/post/wwdc26-the-virtualization-framework-updates-that-matter-for-large-mac-fleets
- A27 Eclectic Light, virtual cores on Apple silicon: https://eclecticlight.co/2023/10/23/how-does-macos-manage-virtual-cores-on-apple-silicon
- A28 Eclectic Light, "Virtualisation on Apple silicon Macs is different": https://eclecticlight.co/2026/04/29/virtualisation-on-apple-silicon-macs-is-different/
- A29 Forum thread title (vmnet_network_ref loses DHCP reservations and port forwarding), search result only: https://developer.apple.com/forums/thread/847642

### UTM
- U1 UTM repo: https://github.com/utmapp/UTM
- U2 UTM releases: https://github.com/utmapp/UTM/releases/
- U3 UTM v5.0.5: https://github.com/utmapp/UTM/releases/tag/v5.0.5
- U4 UTM v5.0.0: https://github.com/utmapp/UTM/releases/tag/v5.0.0
- U5 UTM v5.0.4: https://github.com/utmapp/UTM/releases/tag/v5.0.4
- U6 UTM v5.0.6 notes: https://newreleases.io/project/github/utmapp/UTM/release/v5.0.6
- U7 Neptune blog: https://blog.getutm.app/2026/introducing-neptune-direct3d-virtualization-for-qemu/
- U8 Triton blog: https://blog.getutm.app/2026/introducing-triton-directx-11-driver-for-qemu/
- U9 UTM USB docs: https://docs.getutm.app/guest-support/sharing/usb/
- U10 UTM Windows guest docs: https://docs.getutm.app/guest-support/windows/
- U11 UTM Linux guest docs: https://docs.getutm.app/guest-support/linux/
- U12 UTM dynamic resolution: https://docs.getutm.app/guest-support/dynamic-resolution/
- U13 CocoaSpice: https://github.com/utmapp/CocoaSpice
- U14 UTM guest tools installer (spice-nsis; files win-guest-tools.nsis, Autounattend.xml, COPYING inspected): https://github.com/utmapp/spice-nsis
- U15 UTM Services source (UTMAppleSnapshotBackend.swift, UTMQemuSnapshotBackend.swift, UTMAppleDiskImage.swift, UTMAppleUSBManager.swift, UTMAppleVmnetNetworkManager.swift, UTMAppleVirtualMachine.swift; main on 2026-10-14): https://github.com/utmapp/UTM/tree/main/Services
- U16 utmctl source: https://github.com/utmapp/UTM/blob/main/utmctl/UTMCtl.swift
- U17 UTM entitlements (Platform/macOS/macOS.entitlements, QEMULauncher/QEMULauncher.entitlements, QEMUHelper/QEMUHelper.entitlements): https://github.com/utmapp/UTM
- U18 UTM 4.3 TPM/Secure Boot: https://docs.getutm.app/updates/v4.3/ and https://github.com/utmapp/UTM/discussions/5503
- U19 UTM v4.0.1 (multiple displays for QEMU): https://github.com/utmapp/UTM/releases/tag/v4.0.1

### RDP and seamless windows
- R1 FreeRDP repo (Apache-2.0; source of client/Mac, client/SDL/SDL3, channels/rail, channels/rdpecam, client/common/cmdline.h inspected on master 2026-10-14): https://github.com/FreeRDP/FreeRDP
- R2 FreeRDP releases (3.32.0/3.32.1 notes): https://github.com/FreeRDP/FreeRDP/releases
- R3 FreeRDP wiki RemoteApp: https://github.com/FreeRDP/FreeRDP/wiki/RemoteApp
- R4 Third-party MacFreeRDP doc (claims RemoteApp; contradicted by source): https://mintlify.wiki/freerdp/freerdp/clients/mac
- R5 Third-party FreeRDP clients overview: https://mintlify.wiki/freerdp/freerdp/clients/overview
- R6 IronRDP: https://github.com/Devolutions/IronRDP
- R7 WinApps: https://github.com/winapps-org/winapps
- R8 WinBoat: https://github.com/TibixDev/winboat
- R9 Microsoft Learn, Enable Remote Desktop (Home cannot host): https://learn.microsoft.com/windows-server/remote/remote-desktop-services/remotepc/remote-desktop-allow-access
- R10 [MS-RDPERP]: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdperp/83275957-2d0e-4c52-88d1-1b4c998c6bec
- R11 Weston MR 1667 (RDP-RAIL rebase): https://gitlab.freedesktop.org/wayland/weston/-/merge_requests/1667
- R12 waypipe changelog (openSUSE) and repo: https://src.opensuse.org/pool/waypipe/raw/branch/factory/waypipe.changes ; https://gitlab.freedesktop.org/mstoeckl/waypipe
- R13 xpra: https://github.com/Xpra-org/xpra
- R14 Cocoa-Way and HN discussion: https://github.com/J-x-Z/cocoa-way ; https://hn.svelte.dev/item/47553185
- R15 VirtualBox seamless windows: https://docs.oracle.com/en/virtualization/virtualbox/6.0/user/seamlesswindows.html
- R16 Microsoft weston-mirror: https://github.com/microsoft/weston-mirror

### Drivers and file sharing
- D1 virtio-win drivers (LICENSE, win11_arm64.ddf, viofs/svc/virtiofs.cpp inspected): https://github.com/virtio-win/kvm-guest-drivers-windows
- D2 WinFsp on ARM64 and license: https://winfsp.dev/doc/WinFsp-on-ARM64 ; https://github.com/winfsp/winfsp
- D3 Linaro, windows-arm64 VM using qemu-system: https://linaro.atlassian.net/wiki/spaces/WOAR/pages/28914909194/windows-arm64+VM+using+qemu-system
- D4 KVM Forum 2024, QEMU support for Windows on Arm: https://kvm-forum.qemu.org/2024/Qemu_support_for_Windows_on_Arm_GgKlLjf.pdf
- D5 Proxmox Windows VirtIO drivers: https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers
- D6 Lima mounts: https://lima-vm.io/docs/config/mount/
- D7 QEMU commit "9p: darwin: meson: Allow VirtFS on Darwin": https://qemu.googlesource.com/qemu/+/0fb1e19d78536e23b650ca72decdc29c98f2dcc1%5E%21/
- D8 vhost-user on any POSIX (patch series) + QEMU meson.build on master: https://patchew.org/QEMU/20240404122330.92710-1-sgarzare@redhat.com/ ; https://github.com/qemu/qemu/blob/master/meson.build
- D9 FOSDEM 2025 vhost-user on macOS/BSD: https://fosdem.org/schedule/event/fosdem-2025-5100-can-qemu-and-vhost-user-devices-be-used-on-macos-and-bsd-

### Graphics
- G1 Phoronix, KosmicKrisp Vulkan 1.4 conformant: https://www.phoronix.com/news/KosmicKrisp-Vulkan-1.4-2026
- G2 LunarG, KosmicKrisp Vulkan 1.3 conformance: https://www.lunarg.com/lunarg-achieves-vulkan-1-3-conformance-with-kosmickrisp-on-apple-silicon/
- G3 QEMU virtio-gpu docs: https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html
- G4 QEMU 11.0.0 release: https://www.qemu.org/2026/04/22/qemu-11-0-0/
- G5 QEMU 11.1.0 release: https://www.qemu.org/2026/08/11/qemu-11-1-0/
- G6 MoltenVK: https://github.com/KhronosGroup/MoltenVK
- G7 ANGLE: https://github.com/google/angle
- G8 virglrenderer (UTM fork COPYING, MIT): https://github.com/utmapp/virglrenderer
- G9 DXMT: https://github.com/3Shain/dxmt
- G10 libkrun: https://github.com/containers/libkrun
- G11 Lima krunkit VM type: https://lima-vm.io/docs/config/vmtype/krunkit/

### USB
- B1 usb-macos-vm (VZUSBPassthroughDevice example): https://github.com/beriberikix/usb-macos-vm
- B2 Kestilo USB issue: https://codeberg.org/brechanbech/Kestilo/issues/1
- B3 libusb "darwin: add authorization for device capture": https://flutter.googlesource.com/third_party/libusb/+/6a902c3b207a017cd699ac8bb6659abf32eb0c99
- B4 QEMU issue 2178 (USB passthrough on Apple silicon unusable): https://gitlab.com/qemu-project/qemu/-/issues/2178
- B5 Guix package licenses for usbredir, spice-gtk, spice-vdagent, virglrenderer: https://git.cbaines.net/guix/plain/gnu/packages/spice.scm?h=ruby-2.5

### Networking
- N1 Lima VMNet networks: https://lima-vm.io/docs/config/network/vmnet/
- N2 Code-Hex/vz PR 205 (macOS 26 vmnet): https://github.com/Code-Hex/vz/pull/205
- N3 QEMU issue 1364 (vmnet without sudo): https://gitlab.com/qemu-project/qemu/-/issues/1364
- N4 arcbox-vmnet requirements: https://docs.rs/crate/arcbox-vmnet/0.6.4
- N5 passt: https://passt.top/passt/about/
- N6 libslirp copyright (Debian): https://metadata.ftp-master.debian.org/changelogs/main/libs/libslirp/oldstable_copyright
- N7 socket_vmnet: https://github.com/lima-vm/socket_vmnet
- N8 gvisor-tap-vsock: https://github.com/containers/gvisor-tap-vsock
- N9 QEMU `hostfwd` (qemu-options.hx on master): https://github.com/qemu/qemu/blob/master/qemu-options.hx
- N10 Lima network docs: https://lima-vm.io/docs/config/network/

### QEMU internals
- Q1 QEMU disk images (snapshots, -snapshot, LUKS): https://www.qemu.org/docs/master/system/images.html
- Q2 QEMU QMP reference (snapshot-save since 6.0 in qapi/migration.json; system_powerdown): https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html ; https://github.com/qemu/qemu/blob/master/qapi/migration.json
- Q3 QEMU qemu-vdagent chardev (qapi/char.json, ui/vdagent.c): https://github.com/qemu/qemu/blob/master/qapi/char.json
- Q4 QEMU coreaudio backend, output only (audio/coreaudio.m, master 2026-10-13): https://github.com/qemu/qemu/blob/master/audio/coreaudio.m
- Q5 QEMU HVF SME2 handling (target/arm/hvf/hvf.c): https://github.com/qemu/qemu/blob/master/target/arm/hvf/hvf.c
- Q6 QEMU LICENSE (GPL-2.0): https://github.com/qemu/qemu/blob/master/LICENSE

### Installation
- I1 cloud-init NoCloud: https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html
- I2 Ubuntu autoinstall quick start: https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/autoinstall-quickstart.html
- I3 Windows Setup Automation Overview: https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-setup-automation-overview?view=windows-11
- I4 Arm Learning Path, Windows 11 VM automation: https://learn.arm.com/learning-paths/laptops-and-desktops/win11-vm-automation/vm-creation-3/
- I5 Windows 11 Arm ISO overview: https://learn.microsoft.com/windows/arm/iso
- I6 Windows 11 VM requirements: https://learn.microsoft.com/windows/whats-new/windows-11-requirements#virtual-machine-support
- I7 vfkit usage docs: https://github.com/crc-org/vfkit/blob/main/doc/usage.md
- I8 swtpm: https://github.com/stefanberger/swtpm
- I9 cloud-init repo (licenses): https://github.com/canonical/cloud-init

### Reference projects
- P1 Tart (LICENSE FSL-1.1-ALv2, Sources/tart/Commands inspected): https://github.com/cirruslabs/tart (moved to https://github.com/openai/tart)
- P2 Cirrus Labs joins OpenAI: https://cirruslabs.org/
- P3 VirtualBuddy (VirtualWormhole README inspected): https://github.com/insidegui/VirtualBuddy
- P4 Lima: https://github.com/lima-vm/lima
- P5 Code-Hex/vz: https://github.com/Code-Hex/vz
- P6 apple/container: https://github.com/apple/container
- P7 apple/containerization: https://github.com/apple/containerization
- P8 libkrun: https://github.com/containers/libkrun
- P9 krunkit (docs/usage.md): https://github.com/containers/krunkit
- P10 vfkit: https://github.com/crc-org/vfkit
- P11 macosvm: https://github.com/s-u/macosvm
- P12 Quickemu: https://github.com/quickemu-project/quickemu
- P13 Anka Homebrew cask: https://formulae.brew.sh/cask/anka-virtualization
- P14 OrbStack pricing: https://orbstack.dev/pricing
- P15 Viable / Liviable: https://eclecticlight.co/2022/07/14/introducing-viable-to-virtualise-macos-on-apple-silicon-macs/ ; https://taoofmac.com/space/apps/viable
- P16 vagrant_utm gem: https://rubygems.org/gems/vagrant_utm
- P17 podman machine init: https://docs.podman.io/en/latest/markdown/podman-machine-init.1.html
- P18 "Running Windows 11 on a Mac in 2026": https://programminginsider.com/running-windows-11-on-a-mac-in-2026-your-real-options/
- P19 M4 Pro specs: https://macrumors.com/2024/10/29/apple-announces-m4-pro-chip ; https://www.notebookcheck.com/Apple-M4-Pro-12-cores-Prozessor-Benchmarks-und-Specs.922298.0.html
