# CustomIconsLite/prefs/

Place PNG files here named by Settings row label or PSSpecifier key.

## How it works
Cyanide opens a separate RemoteCall session targeting the MobilePreferences
process, walks its visible UITableViewCell instances, and replaces each
cell's imageView image with a matching PNG from this folder.

Because it targets live cells, Settings must be open and the relevant
page visible when you tap Apply. Navigate to the page you want to theme
first, then tap Apply.

## Naming
Name the PNG after the cell's label text or its PSSpecifier key.
Label text is tried if the specifier key lookup misses.

## Common Settings row keys / labels

### Top-level Settings
| Row | Suggested filename |
|---|---|
| Wi-Fi | `Wi-Fi.png` or `WIFI_SETTING_ID.png` |
| Bluetooth | `Bluetooth.png` |
| Cellular | `Cellular.png` |
| Personal Hotspot | `Personal Hotspot.png` |
| Notifications | `Notifications.png` |
| Sounds & Haptics | `Sounds & Haptics.png` |
| Focus | `Focus.png` |
| Screen Time | `Screen Time.png` |
| General | `General.png` |
| Accessibility | `Accessibility.png` |
| Privacy & Security | `Privacy & Security.png` |
| App Store | `App Store.png` |
| Wallet & Apple Pay | `Wallet & Apple Pay.png` |
| Passwords | `Passwords.png` |
| Mail | `Mail.png` |
| Contacts | `Contacts.png` |
| Calendar | `Calendar.png` |
| Notes | `Notes.png` |
| Reminders | `Reminders.png` |
| Freeform | `Freeform.png` |
| Messages | `Messages.png` |
| FaceTime | `FaceTime.png` |
| Safari | `Safari.png` |
| Maps | `Maps.png` |
| Shortcuts | `Shortcuts.png` |
| Health | `Health.png` |
| Siri | `Siri.png` |
| Camera | `Camera.png` |
| Photos | `Photos.png` |
| Game Center | `Game Center.png` |
| TV Provider | `TV Provider.png` |
| VPN | `VPN.png` |

## Icon size
60×60 px (@1x), 120×120 px (@2x), or 180×180 px (@3x). PNG with
rounded corners or transparency is fine — Settings clips to a rounded
rect automatically.

## Runtime drop-in
You can also drop files at runtime (no rebuild needed) to:
/var/mobile/Library/Cyanide/CustomIconsLite/prefs/
