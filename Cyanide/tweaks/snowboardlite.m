//
//  snowboardlite.m
//  RemoteCall-only SnowBoard-style icon treatment.
//

#import "snowboardlite.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

static uint64_t gSnowboardLiteWhiteColor = 0;
static uint64_t gSnowboardLiteUIImageClass = 0;
static int gSnowboardLiteThemedThisPass = 0;

static NSString *sbl_local_icon_path_for_bundle(const char *bundleID)
{
    if (!bundleID || !bundleID[0]) return nil;
    NSBundle *bundle = [NSBundle mainBundle];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *name = [NSString stringWithUTF8String:bundleID];
    NSString *file = [name stringByAppendingPathExtension:@"png"];

    NSArray<NSString *> *directPaths = @[
        [[[bundle resourcePath] stringByAppendingPathComponent:@"SnowBoardLiteTheme"] stringByAppendingPathComponent:file],
        [@"/var/mobile/Library/Cyanide/SnowBoardLiteTheme" stringByAppendingPathComponent:file],
    ];
    for (NSString *path in directPaths) {
        if ([fm fileExistsAtPath:path]) return path;
    }

    NSString *bundledInFolder = [bundle pathForResource:name ofType:@"png" inDirectory:@"SnowBoardLiteTheme"];
    if (bundledInFolder.length && [fm fileExistsAtPath:bundledInFolder]) return bundledInFolder;

    NSString *bundledFlat = [bundle pathForResource:name ofType:@"png"];
    if (bundledFlat.length && [fm fileExistsAtPath:bundledFlat]) return bundledFlat;

    return nil;
}

static bool sbl_object_class_name(uint64_t obj, char *out, size_t outLen)
{
    if (!r_is_objc_ptr(obj) || !out || outLen == 0) return false;
    out[0] = '\0';

    uint64_t cls = r_dlsym_call(R_TIMEOUT, "object_getClass", obj, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(cls)) return false;
    uint64_t name = r_dlsym_call(R_TIMEOUT, "class_getName", cls, 0, 0, 0, 0, 0, 0, 0);
    if (!name) return false;

    uint64_t heapName = r_dlsym_call(R_TIMEOUT, "strdup", name, 0, 0, 0, 0, 0, 0, 0);
    if (!heapName) return false;
    bool ok = remote_read(heapName, out, outLen - 1);
    r_free(heapName);
    if (ok) out[outLen - 1] = '\0';
    return ok && out[0] != '\0';
}

static bool sbl_class_contains(uint64_t obj, const char *needle)
{
    char cls[128];
    return sbl_object_class_name(obj, cls, sizeof(cls)) && strstr(cls, needle) != NULL;
}

static bool sbl_read_nsstring(uint64_t str, char *out, size_t outLen)
{
    if (!r_is_objc_ptr(str) || !out || outLen == 0) return false;
    memset(out, 0, outLen);

    uint64_t buf = r_dlsym_call(R_TIMEOUT, "malloc", outLen, 0, 0, 0, 0, 0, 0, 0);
    if (!buf) return false;
    r_dlsym_call(R_TIMEOUT, "memset", buf, 0, outLen, 0, 0, 0, 0, 0);

    bool copied = false;
    if (r_responds(str, "getCString:maxLength:encoding:")) {
        uint64_t ok = r_msg2(str, "getCString:maxLength:encoding:", buf, outLen, 4, 0);
        if ((ok & 0xff) && remote_read(buf, out, outLen - 1)) {
            out[outLen - 1] = '\0';
            copied = out[0] != '\0';
        }
    }

    r_free(buf);
    return copied;
}

static uint64_t sbl_white_cgcolor(void)
{
    if (r_is_objc_ptr(gSnowboardLiteWhiteColor)) return gSnowboardLiteWhiteColor;
    uint64_t colorClass = r_class("UIColor");
    if (!r_is_objc_ptr(colorClass)) return 0;
    uint64_t color = r_msg2_main(colorClass, "whiteColor", 0, 0, 0, 0);
    if (!r_is_objc_ptr(color)) return 0;
    gSnowboardLiteWhiteColor = r_msg2_main(color, "CGColor", 0, 0, 0, 0);
    return gSnowboardLiteWhiteColor;
}

static void sbl_set_layer_double(uint64_t layer, const char *selName, double value)
{
    if (!r_is_objc_ptr(layer)) return;
    r_msg2_main_raw(layer, selName,
                    &value, sizeof(value),
                    NULL, 0, NULL, 0, NULL, 0);
}

static void sbl_set_layer_float(uint64_t layer, const char *selName, float value)
{
    if (!r_is_objc_ptr(layer)) return;
    r_msg2_main_raw(layer, selName,
                    &value, sizeof(value),
                    NULL, 0, NULL, 0, NULL, 0);
}

static void sbl_style_icon_view(uint64_t view, bool enabled)
{
    if (!r_is_objc_ptr(view)) return;

    uint64_t layer = r_msg2_main(view, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        sbl_set_layer_double(layer, "setCornerRadius:", enabled ? 18.0 : 0.0);
        sbl_set_layer_double(layer, "setBorderWidth:", enabled ? 1.0 : 0.0);
        sbl_set_layer_float(layer, "setShadowOpacity:", enabled ? 0.22f : 0.0f);
        sbl_set_layer_double(layer, "setShadowRadius:", enabled ? 6.0 : 0.0);
        if (enabled) {
            uint64_t cgColor = sbl_white_cgcolor();
            if (cgColor) r_msg2_main(layer, "setBorderColor:", cgColor, 0, 0, 0);
            if (cgColor) r_msg2_main(layer, "setShadowColor:", cgColor, 0, 0, 0);
        }
    }

    uint64_t iconImageView = 0;
    if (r_responds_main(view, "iconImageView")) {
        iconImageView = r_msg2_main(view, "iconImageView", 0, 0, 0, 0);
    } else if (r_responds_main(view, "_iconImageView")) {
        iconImageView = r_msg2_main(view, "_iconImageView", 0, 0, 0, 0);
    }
    uint64_t imageLayer = r_is_objc_ptr(iconImageView) ? r_msg2_main(iconImageView, "layer", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(imageLayer)) {
        sbl_set_layer_double(imageLayer, "setCornerRadius:", enabled ? 16.0 : 0.0);
        r_msg2_main(imageLayer, "setMasksToBounds:", enabled ? 1 : 0, 0, 0, 0);
    }
}

static uint64_t sbl_icon_object_for_view(uint64_t view)
{
    if (!r_is_objc_ptr(view)) return 0;
    if (r_responds_main(view, "icon")) {
        uint64_t icon = r_msg2_main(view, "icon", 0, 0, 0, 0);
        if (r_is_objc_ptr(icon)) return icon;
    }
    uint64_t ivarIcon = r_ivar_value(view, "_icon");
    return r_is_objc_ptr(ivarIcon) ? ivarIcon : 0;
}

static bool sbl_bundle_id_for_icon(uint64_t icon, char *out, size_t outLen)
{
    if (!r_is_objc_ptr(icon) || !out || outLen == 0) return false;
    out[0] = '\0';

    const char *selectors[] = {
        "applicationBundleID",
        "applicationBundleIdentifier",
        "bundleIdentifier",
        "displayIdentifier",
        "leafIdentifier",
        "uniqueIdentifier",
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        if (!r_responds_main(icon, selectors[i])) continue;
        uint64_t value = r_msg2_main(icon, selectors[i], 0, 0, 0, 0);
        if (sbl_read_nsstring(value, out, outLen) && strchr(out, '.')) return true;
    }
    return false;
}

static uint64_t sbl_image_view_for_icon_view(uint64_t view)
{
    if (!r_is_objc_ptr(view)) return 0;
    const char *selectors[] = {
        "iconImageView",
        "_iconImageView",
        "currentImageView",
        "contentsImageView",
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        if (!r_responds_main(view, selectors[i])) continue;
        uint64_t imageView = r_msg2_main(view, selectors[i], 0, 0, 0, 0);
        if (r_is_objc_ptr(imageView)) return imageView;
    }
    return r_ivar_value(view, "_iconImageView");
}

static uint64_t sbl_load_theme_image_for_bundle(const char *bundleID)
{
    NSString *path = sbl_local_icon_path_for_bundle(bundleID);
    if (!path.length) return 0;
    if (!gSnowboardLiteUIImageClass) gSnowboardLiteUIImageClass = r_class("UIImage");
    if (!r_is_objc_ptr(gSnowboardLiteUIImageClass)) return 0;

    uint64_t remotePath = r_nsstr_retained(path.UTF8String);
    if (!r_is_objc_ptr(remotePath)) return 0;
    uint64_t image = r_msg2_main(gSnowboardLiteUIImageClass, "imageWithContentsOfFile:", remotePath, 0, 0, 0);
    r_msg2(remotePath, "release", 0, 0, 0, 0);
    return r_is_objc_ptr(image) ? image : 0;
}

static bool sbl_apply_theme_image_to_icon_view(uint64_t view)
{
    char bundleID[192];
    uint64_t icon = sbl_icon_object_for_view(view);
    if (!sbl_bundle_id_for_icon(icon, bundleID, sizeof(bundleID))) return false;

    uint64_t image = sbl_load_theme_image_for_bundle(bundleID);
    if (!r_is_objc_ptr(image)) return false;

    bool applied = false;
    uint64_t imageView = sbl_image_view_for_icon_view(view);
    if (r_is_objc_ptr(imageView) && r_responds_main(imageView, "setImage:")) {
        r_msg2_main(imageView, "setImage:", image, 0, 0, 0);
        applied = true;
    }

    if (r_responds_main(view, "setIconImage:")) {
        r_msg2_main(view, "setIconImage:", image, 0, 0, 0);
        applied = true;
    }
    if (r_responds_main(view, "_setIconImage:")) {
        r_msg2_main(view, "_setIconImage:", image, 0, 0, 0);
        applied = true;
    }

    if (applied) {
        gSnowboardLiteThemedThisPass++;
        printf("[SNOWBOARDLITE] themed %s\n", bundleID);
    }
    return applied;
}

static int sbl_walk_view_tree(uint64_t view, int depth, bool enabled)
{
    if (!r_is_objc_ptr(view) || depth > 8) return 0;

    int touched = 0;
    bool isIconView = sbl_class_contains(view, "SBIconView");
    bool isImageView = sbl_class_contains(view, "SBIconImageView");
    if (isIconView && !isImageView) {
        bool themed = enabled ? sbl_apply_theme_image_to_icon_view(view) : false;
        if (!enabled || themed) sbl_style_icon_view(view, enabled);
        touched++;
    }

    if (!r_responds_main(view, "subviews")) return touched;
    uint64_t subviews = r_msg2_main(view, "subviews", 0, 0, 0, 0);
    if (!r_is_objc_ptr(subviews) || !r_responds(subviews, "count")) return touched;

    uint64_t count = r_msg2(subviews, "count", 0, 0, 0, 0);
    if (count > 96) count = 96;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t child = r_msg2(subviews, "objectAtIndex:", i, 0, 0, 0);
        touched += sbl_walk_view_tree(child, depth + 1, enabled);
    }
    return touched;
}

static int sbl_apply_to_windows(bool enabled)
{
    uint64_t appClass = r_class("UIApplication");
    if (!r_is_objc_ptr(appClass)) return 0;
    uint64_t app = r_msg2_main(appClass, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return 0;
    uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
    if (!r_is_objc_ptr(windows) || !r_responds(windows, "count")) return 0;

    int touched = 0;
    uint64_t count = r_msg2(windows, "count", 0, 0, 0, 0);
    if (count > 24) count = 24;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t window = r_msg2(windows, "objectAtIndex:", i, 0, 0, 0);
        touched += sbl_walk_view_tree(window, 0, enabled);
    }
    return touched;
}

static int sbl_apply_to_icon_controller(bool enabled)
{
    uint64_t cls = r_class("SBIconController");
    if (!r_is_objc_ptr(cls)) return 0;
    uint64_t iconController = r_msg2_main(cls, "sharedInstance", 0, 0, 0, 0);
    if (!r_is_objc_ptr(iconController)) return 0;

    int touched = 0;
    uint64_t iconManager = r_responds_main(iconController, "iconManager")
        ? r_msg2_main(iconController, "iconManager", 0, 0, 0, 0)
        : 0;
    uint64_t rootFolder = r_is_objc_ptr(iconManager) && r_responds_main(iconManager, "rootFolderController")
        ? r_msg2_main(iconManager, "rootFolderController", 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(rootFolder) && r_responds_main(rootFolder, "view")) {
        uint64_t rootView = r_msg2_main(rootFolder, "view", 0, 0, 0, 0);
        touched += sbl_walk_view_tree(rootView, 0, enabled);
    }
    if (r_is_objc_ptr(iconManager) && r_responds_main(iconManager, "dockListView")) {
        uint64_t dock = r_msg2_main(iconManager, "dockListView", 0, 0, 0, 0);
        touched += sbl_walk_view_tree(dock, 0, enabled);
    }
    return touched;
}

static bool sbl_open_app_library_briefly(void)
{
    uint64_t cls = r_class("SBIconController");
    if (!r_is_objc_ptr(cls)) return false;
    uint64_t iconController = r_msg2_main(cls, "sharedInstance", 0, 0, 0, 0);
    if (!r_is_objc_ptr(iconController)) return false;

    const char *selectors[] = {
        "showAppLibraryAnimated:",
        "_showAppLibraryAnimated:",
        "revealAppLibraryAnimated:",
        "_revealAppLibraryAnimated:",
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        if (!r_responds_main(iconController, selectors[i])) continue;
        printf("[SNOWBOARDLITE] opening App Library via %s\n", selectors[i]);
        r_msg2_main(iconController, selectors[i], 1, 0, 0, 0);
        usleep(800000);
        return true;
    }
    return false;
}

static void sbl_leave_app_library(void)
{
    uint64_t cls = r_class("SBIconController");
    uint64_t iconController = r_is_objc_ptr(cls) ? r_msg2_main(cls, "sharedInstance", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(iconController)) return;

    if (r_responds_main(iconController, "scrollToIconListAtIndex:animated:")) {
        r_msg2_main(iconController, "scrollToIconListAtIndex:animated:", 0, 1, 0, 0);
        return;
    }

    uint64_t iconManager = r_responds_main(iconController, "iconManager")
        ? r_msg2_main(iconController, "iconManager", 0, 0, 0, 0)
        : 0;
    uint64_t rootFolder = r_is_objc_ptr(iconManager) && r_responds_main(iconManager, "rootFolderController")
        ? r_msg2_main(iconManager, "rootFolderController", 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(rootFolder) && r_responds_main(rootFolder, "scrollToIconListAtIndex:animated:")) {
        r_msg2_main(rootFolder, "scrollToIconListAtIndex:animated:", 0, 1, 0, 0);
        return;
    }

    uint64_t uiCls = r_class("SBUIController");
    uint64_t ui = r_is_objc_ptr(uiCls) ? r_msg2_main(uiCls, "sharedInstance", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(ui) && r_responds_main(ui, "clickedMenuButton")) {
        r_msg2_main(ui, "clickedMenuButton", 0, 0, 0, 0);
    }
}

bool snowboardlite_apply_in_session(void)
{
    uint32_t oldSettleUS = r_settle_us(2000);
    gSnowboardLiteThemedThisPass = 0;
    bool openedAppLibrary = sbl_open_app_library_briefly();
    int touched = sbl_apply_to_icon_controller(true);
    touched += sbl_apply_to_windows(true);
    if (openedAppLibrary) sbl_leave_app_library();
    printf("[SNOWBOARDLITE] apply touched=%d themed=%d\n", touched, gSnowboardLiteThemedThisPass);
    r_settle_us(oldSettleUS);
    return gSnowboardLiteThemedThisPass > 0;
}

bool snowboardlite_stop_in_session(void)
{
    uint32_t oldSettleUS = r_settle_us(1000);
    int touched = sbl_apply_to_icon_controller(false);
    touched += sbl_apply_to_windows(false);
    printf("[SNOWBOARDLITE] stop touched=%d\n", touched);
    r_settle_us(oldSettleUS);
    return true;
}

void snowboardlite_forget_remote_state(void)
{
    gSnowboardLiteWhiteColor = 0;
    gSnowboardLiteUIImageClass = 0;
    printf("[SNOWBOARDLITE] forgot remote state\n");
}
