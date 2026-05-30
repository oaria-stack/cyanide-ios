# CustomIconsLite

Place PNG icon files here named by bundle ID or CC module identifier.

## Home screen Apple apps
File name = bundle ID + .png

| App | Filename |
|---|---|
| Settings | `com.apple.Preferences.png` |
| Phone | `com.apple.mobilephone.png` |
| Safari | `com.apple.mobilesafari.png` |
| Mail | `com.apple.mobilemail.png` |
| Calendar | `com.apple.mobilecal.png` |
| Camera | `com.apple.camera.png` |
| Notes | `com.apple.mobilenotes.png` |
| Maps | `com.apple.maps.png` |
| Music | `com.apple.Music.png` |
| FaceTime | `com.apple.facetime.png` |
| Clock | `com.apple.clock.png` |
| Calculator | `com.apple.calculator.png` |
| Health | `com.apple.Health.png` |
| Wallet | `com.apple.wallet.png` |
| Shortcuts | `com.apple.shortcuts.png` |
| Find My | `com.apple.findmy.png` |

Any other `com.apple.*` app is also supported — just use its bundle ID.

## Control Center modules
File name = full module identifier + .png, or short name + .png

| Module | Full name | Short name |
|---|---|---|
| Brightness | `com.apple.control-center.BrightnessModule.png` | `Brightness.png` |
| Volume | `com.apple.control-center.AudioModule.png` | `Volume.png` |
| Wi-Fi | `com.apple.control-center.WiFiModule.png` | `WiFi.png` |
| Bluetooth | `com.apple.control-center.BluetoothModule.png` | `Bluetooth.png` |
| Flashlight | `com.apple.control-center.FlashlightModule.png` | `Flashlight.png` |
| Do Not Disturb | `com.apple.control-center.DoNotDisturbModule.png` | `DoNotDisturb.png` |
| Rotation Lock | `com.apple.control-center.OrientationLockModule.png` | `Rotation.png` |
| Low Power | `com.apple.control-center.LowPowerMode.png` | `LowPowerMode.png` |
| Airplane Mode | `com.apple.control-center.AirplaneModeModule.png` | `AirplaneMode.png` |

## Icon size
Use 120×120 px (standard @2x) or 180×180 px (@3x). PNG with transparency supported.

## User folder (no rebuild needed)
You can also drop PNGs at runtime into:
`/var/mobile/Library/Cyanide/CustomIconsLite/`
without rebuilding the IPA.
