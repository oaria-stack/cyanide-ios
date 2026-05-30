SnowBoard Lite theme folder
===========================

Add PNG files here using the app bundle identifier as the filename:

- com.apple.MobileSMS.png
- com.apple.mobilesafari.png
- com.apple.Preferences.png

SnowBoard Lite loads these images at Apply time and swaps matching live
SpringBoard icon image views in memory. The changes are tethered: they reset
after SpringBoard rebuilds its views, respring, reboot, or cleanup.

Advanced: SnowBoard Lite also checks
`/var/mobile/Library/Cyanide/SnowBoardLiteTheme` for the same filenames, which
can be useful for testing on-device without rebuilding the IPA.
