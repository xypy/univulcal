# Monicon

Monicon is an iPadOS 16 TrollStore capture-card viewer. Version 1.0.0 retains the Hagibis `1de1:f104` USB video path that displayed live Windows video on an M1 iPad Pro running iPadOS 16.3 in version 0.1.9. The 1.0.0 change adds the final app name and icon; long-duration frame rate and audio sync have not been measured.

The app bundle ID is `com.xypy.monicon`. It installs beside the earlier `com.xypy.uvcdiagnostic` test app, so the working diagnostic app remains available until the new build is verified on device.

## Scope

This project intentionally does not ship an iOS 17 public/App Store build. The only target is iPadOS 16 on TrollStore-compatible devices, packaged as a TIPA file.

## Architecture

- Direct UVC backend is the target path: libusb/libuvc enumerates the capture card and receives UVC frames.
- MJPEG/YUYV/H.264 frames are decoded in-process using libjpeg-turbo, Metal shaders, or VideoToolbox as appropriate.
- Capture-card audio is routed to the iPad speaker/headphones only; the iPad microphone is not used.
- The video viewport uses aspect-fit, so black bars are preferred over cropping.
- Resolution and frame-rate selection are exposed in the UI.
- MetalFX is optional and only applies to the custom Metal texture path.

## iPadOS 16 / TrollStore

Apple's public iOS APIs do not provide a general-purpose raw USB host API for arbitrary UVC devices on iPadOS 16. libuvc itself does not grant USB permissions; it is built on top of libusb. The direct backend therefore requires a TrollStore/private-entitlement/device-specific path and is not intended for App Store distribution.

The build runs without an Apple developer account, then ad-hoc signs the app with `Monicon/MoniconUSB.entitlements` before creating a TIPA for TrollStore. The device still needs the private USB host path supported by its jailbreak/TrollStore environment.

## Build

GitHub Actions builds `Monicon-1.0.0.tipa` for iPadOS 16. Download the Actions artifact ZIP, extract the inner TIPA, and install it with TrollStore. The prebuilt iOS libraries and headers from LiveView commit `ebc3beccfab807b4921d1b4dff0dc84a3c23fd02` are included under `Thirdparties/`, so the build does not fetch mutable dependencies.

Project sources are under `Monicon/`. The app icon source is `Monicon/Assets.xcassets/AppIcon.appiconset/Monicon-1024.png`. The release packaging workflow is `.github/workflows/build.yml`.

Use a powered USB-C hub and a UVC class-compliant HDMI capture card.
