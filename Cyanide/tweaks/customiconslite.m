//
//  customiconslite.m
//  Custom icons for Apple apps and Control Center modules via RemoteCall.
//
//  Architecture
//  ============
//  Two targets:
//
//  1. Home screen Apple app icons (Settings, Phone, Safari, etc.)
//     Uses the identical path as snowboardlite:
//       SBIconController -> iconManager -> rootFolderController -> walk SBIconViews
//     For each SBIconView, read the bundle ID from its SBIcon object and
//     look up a matching PNG in the CustomIconsLite bundle folder.
//     Sets the image via -setImage: on the iconImageView and via
//     -setIconImage: / -_setIconImage: on the SBIconView itself.
//     Also saves the original UIImage pointer so reset can restore it.
//
//  2. Control Center module icons
//     CCUIControlCenterViewController (iOS 17) or
//     CSCombinedViewController (iOS 18) holds module VCs.
//     Walk: sharedInstance -> _moduleInstanceViewControllers (NSArray)
//       -> each CCUIModuleInstanceViewController
//         -> view -> walk UIImageView subviews (depth 4)
//     Replace UIImage on first sizeable UIImageView found.
//     Module identifier read from -moduleIdentifier or _moduleIdentifier ivar.
//     PNG lookup: "CustomIconsLite/<fullIdentifier>.png" then
//                 "CustomIconsLite/<shortName>.png" (last path component).
//
//  Image lookup paths (in order):
//    1. <MainBundle>/CustomIconsLite/<id>.png
//    2. /var/mobile/Library/Cyanide/CustomIconsLite/<id>.png
//    3. <MainBundle>/CustomIconsLite/<shortName>.png  (CC modules only)
//
//  Reset:
//    Store {imageView ptr -> original UIImage ptr} in a static table.
//    On reset, call -setImage: with the original pointer on each saved view.
//

#import "customiconslite.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

#define CIL_SETTLE_US    20000
#define CIL_MAX_SAVES    128
#define CIL_MAX_DEPTH    5
#define CIL_MAX_WINDOWS  24

static const char *kCILBundleFolder   = "CustomIconsLite";
static const char *kCILUserFolder     = "/var/mobile/Library/Cyanide/CustomIconsLite";

// Well-known Apple bundle IDs we target on the home screen
static const char *kCILAppleBundleIDs[] = {
    "com.apple.Preferences",
    "com.apple.mobilephone",
    "com.apple.mobilesafari",
    "com.apple.mobilemail",
    "com.apple.mobilecal",
    "com.apple.camera",
    "com.apple.mobilenotes",
    "com.apple.reminders",
    "com.apple.maps",
    "com.apple.Music",
    "com.apple.tv",
    "com.apple.news",
    "com.apple.mobilegarageband",
    "com.apple.facetime",
    "com.apple.MobileAddressBook",
    "com.apple.DocumentsApp",
    "com.apple.Fitness",
    "com.apple.Health",
    "com.apple.Home",
    "com.apple.tips",
    "com.apple.weather",
    "com.apple.stocks",
    "com.apple.wallet",
    "com.apple.shortcuts",
    "com.apple.measure",
    "com.apple.compass",
    "com.apple.calculator",
    "com.apple.clock",
    "com.apple.MobileStore",
    "com.apple.AppStore",
    "com.apple.podcasts",
    "com.apple.iBooks",
    "com.apple.translate",
    "com.apple.magnifier",
    "com.apple.VoiceMemos",
    "com.apple.mobileme.fmf1",
    "com.apple.findmy",
    NULL
};

// Well-known CC module short names
static const char *kCILCCShortNames[] = {
    "Brightness", "Volume", "WiFi", "Bluetooth", "Flashlight",
    "DoNotDisturb", "Rotation", "AirplaneMode", "FocusUI",
    "LowPowerMode", "NFC", "Timer", "StopWatch", "Calculator",
    "Camera", "Notes", "Mute", "AudioRoute", NULL
};

// ---------------------------------------------------------------------------
// Save table for reset
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t imageView;   // remote UIImageView* or SBIconImageView*
    uint64_t origImage;   // original UIImage*
    bool     active;
} CILSave;

static CILSave g_saves[CIL_MAX_SAVES];
static int     g_save_count = 0;

static void cil_save(uint64_t imageView, uint64_t origImage)
{
    if (g_save_count >= CIL_MAX_SAVES) return;
    // Don't double-save the same view
    for (int i = 0; i < g_save_count; i++) {
        if (g_saves[i].imageView == imageView) return;
    }
    g_saves[g_save_count++] = (CILSave){ imageView, origImage, true };
}

// ---------------------------------------------------------------------------
// Image path lookup
// ---------------------------------------------------------------------------

static NSString *cil_png_path(const char *identifier)
{
    if (!identifier || !identifier[0]) return nil;
    NSString *ident  = @(identifier);
    NSString *file   = [ident stringByAppendingPathExtension:@"png"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSBundle *bundle  = NSBundle.mainBundle;

    // 1. Main bundle CustomIconsLite folder
    NSString *p1 = [[bundle.resourcePath
                     stringByAppendingPathComponent:@(kCILBundleFolder)]
                     stringByAppendingPathComponent:file];
    if ([fm fileExistsAtPath:p1]) return p1;

    // 2. User folder
    NSString *p2 = [@(kCILUserFolder) stringByAppendingPathComponent:file];
    if ([fm fileExistsAtPath:p2]) return p2;

    // 3. Bundle pathForResource
    NSString *p3 = [bundle pathForResource:ident ofType:@"png"
                               inDirectory:@(kCILBundleFolder)];
    if (p3.length && [fm fileExistsAtPath:p3]) return p3;

    return nil;
}

// Lookup PNG in a subfolder of CustomIconsLite/
static NSString *cil_png_path_in_dir(const char *subdir, const char *name)
{
    if (!subdir || !name || !name[0]) return nil;
    NSString *file   = [@(name) stringByAppendingPathExtension:@"png"];
    NSString *folder = [@(kCILBundleFolder) stringByAppendingPathComponent:@(subdir)];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSBundle *bundle  = NSBundle.mainBundle;

    // 1. Main bundle CustomIconsLite/<subdir>/
    NSString *p1 = [[bundle.resourcePath
                     stringByAppendingPathComponent:folder]
                     stringByAppendingPathComponent:file];
    if ([fm fileExistsAtPath:p1]) return p1;

    // 2. User folder /var/mobile/Library/Cyanide/CustomIconsLite/<subdir>/
    NSString *p2 = [[@(kCILUserFolder) stringByAppendingPathComponent:@(subdir)]
                    stringByAppendingPathComponent:file];
    if ([fm fileExistsAtPath:p2]) return p2;

    // 3. Flat in main CustomIconsLite/ (no subdir)
    return cil_png_path(name);
}

// For CC modules: also try the last component as a short name
static NSString *cil_cc_png_path(const char *moduleIdentifier)
{
    NSString *p = cil_png_path(moduleIdentifier);
    if (p) return p;

    // Try short name (last path component without extension)
    NSString *ident = @(moduleIdentifier);
    NSString *shortName = [[ident componentsSeparatedByString:@"."] lastObject];
    // Strip common suffixes
    for (NSString *suffix in @[@"Module", @"Control", @"Controller"]) {
        if ([shortName hasSuffix:suffix])
            shortName = [shortName substringToIndex:shortName.length - suffix.length];
    }
    return cil_png_path(shortName.UTF8String);
}

// ---------------------------------------------------------------------------
// Load UIImage in remote process from a local path
// ---------------------------------------------------------------------------

static uint64_t cil_load_remote_image(NSString *localPath)
{
    if (!localPath.length) return 0;
    uint64_t cls = r_class("UIImage");
    if (!r_is_objc_ptr(cls)) return 0;
    uint64_t remotePath = r_nsstr_retained(localPath.UTF8String);
    if (!r_is_objc_ptr(remotePath)) return 0;
    uint64_t img = r_msg2_main(cls, "imageWithContentsOfFile:", remotePath, 0, 0, 0);
    r_msg2(remotePath, "release", 0, 0, 0, 0);
    return r_is_objc_ptr(img) ? img : 0;
}

// ---------------------------------------------------------------------------
// Class name helpers
// ---------------------------------------------------------------------------

static bool cil_class_contains(uint64_t obj, const char *needle)
{
    if (!r_is_objc_ptr(obj) || !needle) return false;
    uint64_t cls  = r_dlsym_call(R_TIMEOUT, "object_getClass", obj, 0,0,0,0,0,0,0);
    uint64_t name = r_dlsym_call(R_TIMEOUT, "class_getName",   cls, 0,0,0,0,0,0,0);
    if (!name) return false;
    uint64_t dup  = r_dlsym_call(R_TIMEOUT, "strdup", name, 0,0,0,0,0,0,0);
    if (!dup) return false;
    char buf[128]; buf[0]='\0';
    remote_read(dup, buf, sizeof(buf)-1);
    r_free(dup);
    buf[sizeof(buf)-1]='\0';
    return strstr(buf, needle) != NULL;
}

static bool cil_read_nsstring(uint64_t str, char *out, size_t outLen)
{
    if (!r_is_objc_ptr(str) || !out || !outLen) return false;
    memset(out, 0, outLen);
    uint64_t buf = r_dlsym_call(R_TIMEOUT, "malloc", outLen, 0,0,0,0,0,0,0);
    if (!buf) return false;
    r_dlsym_call(R_TIMEOUT, "memset", buf, 0, outLen, 0,0,0,0,0);
    bool ok = false;
    if (r_responds(str, "getCString:maxLength:encoding:")) {
        uint64_t res = r_msg2(str, "getCString:maxLength:encoding:", buf, outLen, 4, 0);
        if ((res & 0xff) && remote_read(buf, out, outLen-1)) {
            out[outLen-1]='\0'; ok = out[0]!='\0';
        }
    }
    r_free(buf);
    return ok;
}

// ---------------------------------------------------------------------------
// Home screen icon replacement
// ---------------------------------------------------------------------------

static bool cil_is_target_bundle(const char *bundleID)
{
    for (int i = 0; kCILAppleBundleIDs[i]; i++) {
        if (strcmp(bundleID, kCILAppleBundleIDs[i]) == 0) return true;
    }
    // Also accept any com.apple.* bundle that has a PNG in the folder
    if (strncmp(bundleID, "com.apple.", 10) == 0) {
        return cil_png_path(bundleID) != nil;
    }
    return false;
}

static bool cil_apply_to_sb_icon_view(uint64_t view, bool reset)
{
    if (!r_is_objc_ptr(view)) return false;

    // Get the SBIcon / bundle ID
    uint64_t icon = 0;
    if (r_responds_main(view, "icon"))
        icon = r_msg2_main(view, "icon", 0,0,0,0);
    if (!r_is_objc_ptr(icon))
        icon = r_ivar_value(view, "_icon");
    if (!r_is_objc_ptr(icon)) return false;

    char bundleID[192]; bundleID[0]='\0';
    const char *bundleSelectors[] = {
        "applicationBundleID", "applicationBundleIdentifier",
        "bundleIdentifier",    "displayIdentifier",
        "leafIdentifier",      NULL
    };
    for (int i=0; bundleSelectors[i]; i++) {
        if (!r_responds_main(icon, bundleSelectors[i])) continue;
        uint64_t val = r_msg2_main(icon, bundleSelectors[i], 0,0,0,0);
        if (cil_read_nsstring(val, bundleID, sizeof(bundleID))) break;
    }
    if (!bundleID[0]) return false;
    if (!cil_is_target_bundle(bundleID)) return false;

    // Find the iconImageView
    uint64_t imageView = 0;
    const char *imgSels[] = {
        "iconImageView","_iconImageView","currentImageView","contentsImageView",NULL
    };
    for (int i=0; imgSels[i]; i++) {
        if (!r_responds_main(view, imgSels[i])) continue;
        imageView = r_msg2_main(view, imgSels[i], 0,0,0,0);
        if (r_is_objc_ptr(imageView)) break;
    }
    if (!r_is_objc_ptr(imageView))
        imageView = r_ivar_value(view, "_iconImageView");
    if (!r_is_objc_ptr(imageView)) return false;

    if (reset) {
        // Find saved original and restore
        for (int i=0; i<g_save_count; i++) {
            if (g_saves[i].imageView == imageView && g_saves[i].active) {
                if (r_responds_main(imageView, "setImage:"))
                    r_msg2_main(imageView, "setImage:", g_saves[i].origImage, 0,0,0);
                g_saves[i].active = false;
                printf("[CIL] reset %s\n", bundleID);
                return true;
            }
        }
        return false;
    }

    // Save original image
    uint64_t origImage = 0;
    if (r_responds_main(imageView, "image"))
        origImage = r_msg2_main(imageView, "image", 0,0,0,0);
    cil_save(imageView, origImage);

    // Load and apply custom image
    NSString *path = cil_png_path(bundleID);
    if (!path) return false;
    uint64_t img = cil_load_remote_image(path);
    if (!r_is_objc_ptr(img)) return false;

    bool applied = false;
    if (r_responds_main(imageView, "setImage:")) {
        r_msg2_main(imageView, "setImage:", img, 0,0,0);
        applied = true;
    }
    // Also try the SBIconView-level setters
    if (r_responds_main(view, "setIconImage:")) {
        r_msg2_main(view, "setIconImage:", img, 0,0,0);
        applied = true;
    }
    if (r_responds_main(view, "_setIconImage:")) {
        r_msg2_main(view, "_setIconImage:", img, 0,0,0);
        applied = true;
    }

    if (applied) printf("[CIL] themed %s\n", bundleID);
    return applied;
}

// ---------------------------------------------------------------------------
// Walk home screen view tree
// ---------------------------------------------------------------------------

static int cil_walk_home(uint64_t view, int depth, bool reset)
{
    if (!r_is_objc_ptr(view) || depth > CIL_MAX_DEPTH) return 0;
    int touched = 0;

    if (cil_class_contains(view, "SBIconView") &&
        !cil_class_contains(view, "SBIconImageView")) {
        if (cil_apply_to_sb_icon_view(view, reset)) touched++;
        return touched; // don't recurse inside SBIconView
    }

    if (!r_responds_main(view, "subviews")) return touched;
    uint64_t subs = r_msg2_main(view, "subviews", 0,0,0,0);
    uint64_t cnt  = r_is_objc_ptr(subs) ? r_msg2(subs, "count", 0,0,0,0) : 0;
    if (cnt > 96) cnt = 96;
    for (uint64_t i=0; i<cnt; i++) {
        uint64_t child = r_msg2(subs, "objectAtIndex:", i, 0,0,0);
        touched += cil_walk_home(child, depth+1, reset);
    }
    return touched;
}

static int cil_apply_home_screen(bool reset)
{
    int touched = 0;
    uint64_t cls = r_class("SBIconController");
    uint64_t ic  = r_is_objc_ptr(cls) ? r_msg2_main(cls,"sharedInstance",0,0,0,0) : 0;
    uint64_t im  = r_is_objc_ptr(ic) && r_responds_main(ic,"iconManager") ?
                   r_msg2_main(ic,"iconManager",0,0,0,0) : 0;
    uint64_t rf  = r_is_objc_ptr(im) && r_responds_main(im,"rootFolderController") ?
                   r_msg2_main(im,"rootFolderController",0,0,0,0) : 0;
    if (r_is_objc_ptr(rf) && r_responds_main(rf,"view"))
        touched += cil_walk_home(r_msg2_main(rf,"view",0,0,0,0), 0, reset);
    if (r_is_objc_ptr(im) && r_responds_main(im,"dockListView"))
        touched += cil_walk_home(r_msg2_main(im,"dockListView",0,0,0,0), 0, reset);

    // Also walk all windows to catch App Library etc.
    uint64_t appCls = r_class("UIApplication");
    uint64_t app    = r_is_objc_ptr(appCls) ? r_msg2_main(appCls,"sharedApplication",0,0,0,0) : 0;
    uint64_t wins   = r_is_objc_ptr(app) ? r_msg2_main(app,"windows",0,0,0,0) : 0;
    uint64_t wcnt   = r_is_objc_ptr(wins) ? r_msg2(wins,"count",0,0,0,0) : 0;
    if (wcnt > CIL_MAX_WINDOWS) wcnt = CIL_MAX_WINDOWS;
    for (uint64_t i=0; i<wcnt; i++) {
        uint64_t w = r_msg2(wins,"objectAtIndex:",i,0,0,0);
        touched += cil_walk_home(w, 0, reset);
    }
    return touched;
}

// ---------------------------------------------------------------------------
// Control Center module icon replacement
// ---------------------------------------------------------------------------

// Find the CC view controller (iOS 17: CCUIControlCenterViewController,
// iOS 18: may be embedded in CSCombinedViewController)
static uint64_t cil_cc_view_controller(void)
{
    const char *ccClsNames[] = {
        "CCUIControlCenterViewController",
        "SBControlCenterController",
        "CCRootViewController",
        NULL
    };
    for (int i=0; ccClsNames[i]; i++) {
        uint64_t cls = r_class(ccClsNames[i]);
        if (!r_is_objc_ptr(cls)) continue;
        const char *singletonSels[] = {"sharedInstance","sharedController",NULL};
        for (int j=0; singletonSels[j]; j++) {
            if (!r_responds_main(cls, singletonSels[j])) continue;
            uint64_t vc = r_msg2_main(cls, singletonSels[j], 0,0,0,0);
            if (r_is_objc_ptr(vc)) {
                printf("[CIL] CC VC: %s\n", ccClsNames[i]);
                return vc;
            }
        }
    }
    return 0;
}

// Read module identifier from a CC module VC
static bool cil_module_identifier(uint64_t moduleVC, char *out, size_t outLen)
{
    if (!r_is_objc_ptr(moduleVC) || !out || !outLen) return false;
    out[0]='\0';
    const char *sels[] = {
        "moduleIdentifier","_moduleIdentifier",
        "bundleIdentifier","identifier",NULL
    };
    for (int i=0; sels[i]; i++) {
        uint64_t val = 0;
        if (r_responds_main(moduleVC, sels[i]))
            val = r_msg2_main(moduleVC, sels[i], 0,0,0,0);
        else
            val = r_ivar_value(moduleVC, sels[i]);
        if (cil_read_nsstring(val, out, outLen) && out[0]) return true;
    }
    return false;
}

// Walk a view subtree looking for a UIImageView with a non-nil image
// (skipping tiny views like 1pt decorators)
static uint64_t cil_find_image_view(uint64_t view, int depth)
{
    if (!r_is_objc_ptr(view) || depth > 4) return 0;

    if (cil_class_contains(view, "UIImageView")) {
        // Check it has an image and is a reasonable size
        if (r_responds_main(view, "image")) {
            uint64_t img = r_msg2_main(view, "image", 0,0,0,0);
            if (r_is_objc_ptr(img)) return view;
        }
    }

    if (!r_responds_main(view, "subviews")) return 0;
    uint64_t subs = r_msg2_main(view, "subviews", 0,0,0,0);
    uint64_t cnt  = r_is_objc_ptr(subs) ? r_msg2(subs,"count",0,0,0,0) : 0;
    if (cnt > 24) cnt = 24;
    for (uint64_t i=0; i<cnt; i++) {
        uint64_t child = r_msg2(subs,"objectAtIndex:",i,0,0,0);
        uint64_t found = cil_find_image_view(child, depth+1);
        if (found) return found;
    }
    return 0;
}

static int cil_apply_cc_modules(bool reset)
{
    int touched = 0;
    uint64_t ccVC = cil_cc_view_controller();
    if (!r_is_objc_ptr(ccVC)) {
        printf("[CIL] CC VC not found\n");
        return 0;
    }

    // Get module instance VCs array
    uint64_t modules = 0;
    const char *modSels[] = {
        "_moduleInstanceViewControllers",
        "moduleInstanceViewControllers",
        "_moduleViewControllers",
        "moduleViewControllers",
        NULL
    };
    for (int i=0; modSels[i]; i++) {
        if (r_responds_main(ccVC, modSels[i])) {
            modules = r_msg2_main(ccVC, modSels[i], 0,0,0,0);
            if (r_is_objc_ptr(modules)) break;
        }
        modules = r_ivar_value(ccVC, modSels[i]);
        if (r_is_objc_ptr(modules)) break;
    }

    if (!r_is_objc_ptr(modules)) {
        printf("[CIL] CC modules array not found\n");
        return 0;
    }

    uint64_t cnt = r_msg2(modules,"count",0,0,0,0);
    if (cnt > 32) cnt = 32;
    printf("[CIL] CC modules count=%llu\n", cnt);

    for (uint64_t i=0; i<cnt; i++) {
        uint64_t moduleVC = r_msg2(modules,"objectAtIndex:",i,0,0,0);
        if (!r_is_objc_ptr(moduleVC)) continue;

        char modID[256]; modID[0]='\0';
        cil_module_identifier(moduleVC, modID, sizeof(modID));
        if (!modID[0]) continue;

        NSString *path = reset ? nil : cil_cc_png_path(modID);

        // Force-load the view
        if (r_responds_main(moduleVC,"loadViewIfNeeded"))
            r_msg2_main(moduleVC,"loadViewIfNeeded",0,0,0,0);
        usleep(CIL_SETTLE_US);

        uint64_t view = r_responds_main(moduleVC,"view") ?
            r_msg2_main(moduleVC,"view",0,0,0,0) : 0;
        if (!r_is_objc_ptr(view)) continue;

        uint64_t imageView = cil_find_image_view(view, 0);
        if (!r_is_objc_ptr(imageView)) continue;

        if (reset) {
            for (int s=0; s<g_save_count; s++) {
                if (g_saves[s].imageView == imageView && g_saves[s].active) {
                    r_msg2_main(imageView,"setImage:",g_saves[s].origImage,0,0,0);
                    g_saves[s].active = false;
                    printf("[CIL] CC reset %s\n", modID);
                    touched++;
                    break;
                }
            }
        } else {
            if (!path) continue;

            uint64_t origImage = r_responds_main(imageView,"image") ?
                r_msg2_main(imageView,"image",0,0,0,0) : 0;
            cil_save(imageView, origImage);

            uint64_t img = cil_load_remote_image(path);
            if (!r_is_objc_ptr(img)) continue;

            r_msg2_main(imageView,"setImage:",img,0,0,0);
            // Also try -setSymbolImage: for SF-symbol-backed views
            if (r_responds_main(imageView,"setSymbolImage:"))
                r_msg2_main(imageView,"setSymbolImage:",img,0,0,0);

            printf("[CIL] CC themed %s\n", modID);
            touched++;
        }
        usleep(CIL_SETTLE_US);
    }
    return touched;
}

// ---------------------------------------------------------------------------
// Preferences process — row icon replacement
// ---------------------------------------------------------------------------
// com.apple.Preferences runs as MobilePreferences on iOS.
// Its settings rows are PSTableCell (UITableViewCell subclass) instances
// inside UITableView.  Each cell's -imageView holds the row icon.
// The icon image is a UIImage loaded from the Settings bundle.
// We replace it with a custom PNG loaded into the Preferences process
// via a separate RemoteCallSession.
//
// PNG lookup: CustomIconsLite/prefs/<specifierKey>.png
//             CustomIconsLite/prefs/<cellLabel>.png  (fallback)
// e.g. CustomIconsLite/prefs/WIFI_SETTING_ID.png  or  CustomIconsLite/prefs/Wi-Fi.png
//
// Save table reuses g_saves[] — imageView pointers are in the Preferences
// address space, distinguished from SpringBoard ones by being > 0 and being
// looked up only within a Preferences session.

#define CIL_PREFS_MAX_SAVES  64

typedef struct {
    uint64_t imageView;
    uint64_t origImage;
    bool     active;
} CILPrefsSave;

static CILPrefsSave g_prefs_saves[CIL_PREFS_MAX_SAVES];
static int          g_prefs_save_count = 0;

static void cil_prefs_save(uint64_t iv, uint64_t orig)
{
    if (g_prefs_save_count >= CIL_PREFS_MAX_SAVES) return;
    for (int i=0;i<g_prefs_save_count;i++) if (g_prefs_saves[i].imageView==iv) return;
    g_prefs_saves[g_prefs_save_count++] = (CILPrefsSave){iv, orig, true};
}

// Read a remote NSString via the provided session into a C buffer.
// Uses getCString:maxLength:encoding: (encoding 4 = NSUTF8StringEncoding).
static bool cil_s_read_nsstring(RemoteCallSession *s, uint64_t str,
                                 char *out, size_t outLen)
{
    if (!str || !out || !outLen) return false;
    memset(out, 0, outLen);
    __block uint64_t buf = 0;
    remote_call_with_session(s, ^{ buf = r_dlsym_call(R_TIMEOUT,"malloc",outLen,0,0,0,0,0,0,0); });
    if (!buf) return false;
    remote_call_with_session(s, ^{ r_dlsym_call(R_TIMEOUT,"memset",buf,0,outLen,0,0,0,0,0); });
    __block bool ok = false;
    remote_call_with_session(s, ^{
        if (r_responds(str,"getCString:maxLength:encoding:")) {
            uint64_t res = r_msg2(str,"getCString:maxLength:encoding:",buf,outLen,4,0);
            ok = (res & 0xff) != 0;
        }
    });
    if (ok) {
        [s remoteRead:buf to:out size:outLen-1];
        out[outLen-1]=' ';
        ok = out[0]!=' ';
    }
    remote_call_with_session(s, ^{ r_free(buf); });
    return ok;
}

// Check if an object's class name contains needle, using session s.
static bool cil_s_class_contains(RemoteCallSession *s, uint64_t obj, const char *needle)
{
    if (!obj || !needle) return false;
    __block uint64_t dup = 0;
    remote_call_with_session(s, ^{
        uint64_t cls  = r_dlsym_call(R_TIMEOUT,"object_getClass",obj,0,0,0,0,0,0,0);
        uint64_t name = r_dlsym_call(R_TIMEOUT,"class_getName",cls,0,0,0,0,0,0,0);
        dup = name ? r_dlsym_call(R_TIMEOUT,"strdup",name,0,0,0,0,0,0,0) : 0;
    });
    if (!dup) return false;
    char buf[128]; buf[0]=' ';
    [s remoteRead:dup to:buf size:sizeof(buf)-1];
    remote_call_with_session(s, ^{ r_free(dup); });
    buf[sizeof(buf)-1]=' ';
    return strstr(buf, needle) != NULL;
}

// Load a UIImage in the Preferences process from a local file path.
static uint64_t cil_s_load_image(RemoteCallSession *s, NSString *localPath)
{
    if (!localPath.length) return 0;
    __block uint64_t img = 0;
    remote_call_with_session(s, ^{
        uint64_t cls = r_class("UIImage");
        uint64_t rp  = r_nsstr_retained(localPath.UTF8String);
        if (r_is_objc_ptr(cls) && r_is_objc_ptr(rp)) {
            img = r_msg2_main(cls,"imageWithContentsOfFile:",rp,0,0,0);
            r_msg2(rp,"release",0,0,0,0);
        }
    });
    return img;
}

// Walk a view subtree in the Preferences process and patch all
// UITableViewCell imageViews whose label matches a PNG in CustomIconsLite/prefs/.
static int cil_s_patch_cells(RemoteCallSession *s, uint64_t view, int depth, bool reset)
{
    if (!view || depth > 6) return 0;
    int touched = 0;

    bool isCell = cil_s_class_contains(s, view, "UITableViewCell");
    if (isCell) {
        // Get the cell's imageView
        __block uint64_t imageView = 0;
        remote_call_with_session(s, ^{
            if (r_responds_main(view,"imageView"))
                imageView = r_msg2_main(view,"imageView",0,0,0,0);
        });

        if (imageView) {
            // Get the cell's textLabel text for filename lookup
            __block uint64_t labelStr = 0;
            remote_call_with_session(s, ^{
                uint64_t tl = r_responds_main(view,"textLabel") ?
                    r_msg2_main(view,"textLabel",0,0,0,0) : 0;
                if (r_is_objc_ptr(tl) && r_responds_main(tl,"text"))
                    labelStr = r_msg2_main(tl,"text",0,0,0,0);
            });

            // Also try PSTableCell -title / specifier key
            __block uint64_t specKeyStr = 0;
            remote_call_with_session(s, ^{
                uint64_t spec = 0;
                if (r_responds_main(view,"specifier"))
                    spec = r_msg2_main(view,"specifier",0,0,0,0);
                if (r_is_objc_ptr(spec) && r_responds_main(spec,"key"))
                    specKeyStr = r_msg2_main(spec,"key",0,0,0,0);
            });

            char label[256]={0}, specKey[256]={0};
            cil_s_read_nsstring(s, labelStr,   label,   sizeof(label));
            cil_s_read_nsstring(s, specKeyStr, specKey, sizeof(specKey));

            // Look up PNG by specifier key first, then label
            NSString *path = nil;
            if (specKey[0]) {
                path = cil_png_path_in_dir("prefs", specKey);
            }
            if (!path && label[0]) {
                path = cil_png_path_in_dir("prefs", label);
            }

            if (reset) {
                for (int i=0;i<g_prefs_save_count;i++) {
                    if (g_prefs_saves[i].imageView==imageView && g_prefs_saves[i].active) {
                        uint64_t orig = g_prefs_saves[i].origImage;
                        remote_call_with_session(s, ^{
                            if (r_responds_main(imageView,"setImage:"))
                                r_msg2_main(imageView,"setImage:",orig,0,0,0);
                        });
                        g_prefs_saves[i].active = false;
                        printf("[CIL/prefs] reset cell '%s'
", label);
                        touched++;
                        break;
                    }
                }
            } else if (path) {
                __block uint64_t origImage = 0;
                remote_call_with_session(s, ^{
                    if (r_responds_main(imageView,"image"))
                        origImage = r_msg2_main(imageView,"image",0,0,0,0);
                });
                cil_prefs_save(imageView, origImage);

                uint64_t newImg = cil_s_load_image(s, path);
                if (newImg) {
                    remote_call_with_session(s, ^{
                        if (r_responds_main(imageView,"setImage:"))
                            r_msg2_main(imageView,"setImage:",newImg,0,0,0);
                    });
                    printf("[CIL/prefs] patched '%s' (key='%s')
", label, specKey);
                    touched++;
                }
            }
        }
        // Don't need to recurse deeper into cells for the imageView,
        // but do continue the sibling walk via subviews for other cells.
    }

    // Recurse into subviews
    __block uint64_t subs = 0;
    __block uint64_t cnt  = 0;
    remote_call_with_session(s, ^{
        if (r_responds_main(view,"subviews")) {
            subs = r_msg2_main(view,"subviews",0,0,0,0);
            cnt  = r_is_objc_ptr(subs) ? r_msg2(subs,"count",0,0,0,0) : 0;
            if (cnt > 64) cnt = 64;
        }
    });

    for (uint64_t i=0; i<cnt; i++) {
        __block uint64_t child = 0;
        remote_call_with_session(s, ^{
            child = r_msg2(subs,"objectAtIndex:",i,0,0,0);
        });
        touched += cil_s_patch_cells(s, child, depth+1, reset);
    }
    return touched;
}

static int cil_apply_preferences_process(bool reset)
{
    printf("[CIL/prefs] opening session on MobilePreferences
");

    RemoteCallSession *s = [[RemoteCallSession alloc]
                             initWithProcess:@"MobilePreferences"
                             useMigFilterBypass:YES];
    if (!s || ![s hasLocalState]) {
        printf("[CIL/prefs] Preferences not running or session failed
");
        return 0;
    }

    // Get all windows in Preferences
    __block uint64_t wins = 0;
    __block uint64_t wcnt = 0;
    remote_call_with_session(s, ^{
        uint64_t appCls = r_class("UIApplication");
        uint64_t app = r_is_objc_ptr(appCls) ?
            r_msg2_main(appCls,"sharedApplication",0,0,0,0) : 0;
        wins = r_is_objc_ptr(app) ? r_msg2_main(app,"windows",0,0,0,0) : 0;
        wcnt = r_is_objc_ptr(wins) ? r_msg2(wins,"count",0,0,0,0) : 0;
        if (wcnt > 8) wcnt = 8;
    });

    int touched = 0;
    for (uint64_t i=0; i<wcnt; i++) {
        __block uint64_t win = 0;
        remote_call_with_session(s, ^{
            win = r_msg2(wins,"objectAtIndex:",i,0,0,0);
        });
        touched += cil_s_patch_cells(s, win, 0, reset);
    }

    [s destroyRemoteCall];
    printf("[CIL/prefs] done touched=%d
", touched);
    return touched;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

bool customiconslite_apply_in_session(void)
{
    printf("[CIL] apply\n");
    int home  = cil_apply_home_screen(false);
    usleep(50000);
    int cc    = cil_apply_cc_modules(false);
    usleep(50000);
    int prefs = cil_apply_preferences_process(false);
    printf("[CIL] apply done home=%d cc=%d prefs=%d\n", home, cc, prefs);
    return (home + cc + prefs) > 0;
}

bool customiconslite_reset_in_session(void)
{
    printf("[CIL] reset\n");
    int home  = cil_apply_home_screen(true);
    usleep(50000);
    int cc    = cil_apply_cc_modules(true);
    usleep(50000);
    int prefs = cil_apply_preferences_process(true);
    g_save_count = 0;
    g_prefs_save_count = 0;
    printf("[CIL] reset done home=%d cc=%d prefs=%d\n", home, cc, prefs);
    return (home + cc + prefs) > 0;
}

void customiconslite_forget_remote_state(void)
{
    memset(g_saves,       0, sizeof(g_saves));
    memset(g_prefs_saves, 0, sizeof(g_prefs_saves));
    g_save_count       = 0;
    g_prefs_save_count = 0;
    printf("[CIL] forgot remote state\n");
}
