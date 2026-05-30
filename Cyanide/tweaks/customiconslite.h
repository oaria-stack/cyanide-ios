//
//  customiconslite.h
//  Custom icon images for first-party Apple apps and Control Center modules,
//  applied live in SpringBoard via the RemoteCall bridge.
//
//  Home screen icons:
//    PNG files placed in the app bundle under CustomIconsLite/ named by
//    bundle ID, e.g. "com.apple.Preferences.png", "com.apple.mobilephone.png".
//    Also checked at /var/mobile/Library/Cyanide/CustomIconsLite/<bundleID>.png.
//
//  Control Center module icons:
//    CCUIModuleInstanceViewController views are walked; the first UIImageView
//    found in each module is replaced. PNGs named by module identifier, e.g.
//    "com.apple.control-center.BrightnessModule.png".
//    Also accepts short names: "Brightness.png", "WiFi.png", "Flashlight.png".
//
//  All patching is in-session only.
//

#ifndef customiconslite_h
#define customiconslite_h

#import <stdbool.h>

// Apply custom icons to all loaded Apple app icons and CC modules.
bool customiconslite_apply_in_session(void);

// Remove custom icons and restore originals.
bool customiconslite_reset_in_session(void);

// Forget cached remote state.
void customiconslite_forget_remote_state(void);

#endif /* customiconslite_h */
