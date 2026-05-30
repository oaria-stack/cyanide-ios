//
//  atrialite.m
//  RemoteCall-only Atria-style layout preset.
//

#import "atrialite.h"
#import "sbcustomizer.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"

#import <stdio.h>
#import <string.h>

static const int kAtriaLiteStockDockIcons = 4;
static const int kAtriaLiteStockHomeCols = 4;
static const int kAtriaLiteStockHomeRows = 6;
static const bool kAtriaLiteStockHideLabels = false;

static bool atl_object_class_name(uint64_t obj, char *out, size_t outLen)
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

static bool atl_class_contains(uint64_t obj, const char *needle)
{
    char cls[128];
    return atl_object_class_name(obj, cls, sizeof(cls)) && strstr(cls, needle) != NULL;
}

static uint64_t atl_icon_image_view(uint64_t iconView)
{
    if (!r_is_objc_ptr(iconView)) return 0;
    const char *selectors[] = { "iconImageView", "_iconImageView", "currentImageView", "contentsImageView" };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        if (!r_responds_main(iconView, selectors[i])) continue;
        uint64_t imageView = r_msg2_main(iconView, selectors[i], 0, 0, 0, 0);
        if (r_is_objc_ptr(imageView)) return imageView;
    }
    return r_ivar_value(iconView, "_iconImageView");
}

static void atl_set_view_transform(uint64_t view, double scale, double offsetY)
{
    if (!r_is_objc_ptr(view)) return;
    double transform[6] = { scale, 0.0, 0.0, scale, 0.0, offsetY };
    r_msg2_main_raw(view, "setTransform:",
                    transform, sizeof(transform),
                    NULL, 0, NULL, 0, NULL, 0);
}

static int atl_walk_icon_views(uint64_t view, int depth, double scale, double offsetY)
{
    if (!r_is_objc_ptr(view) || depth > 8) return 0;

    int touched = 0;
    bool isIconView = atl_class_contains(view, "SBIconView");
    bool isImageView = atl_class_contains(view, "SBIconImageView");
    if (isIconView && !isImageView) {
        uint64_t imageView = atl_icon_image_view(view);
        atl_set_view_transform(r_is_objc_ptr(imageView) ? imageView : view, scale, offsetY);
        touched++;
    }

    if (!r_responds_main(view, "subviews")) return touched;
    uint64_t subviews = r_msg2_main(view, "subviews", 0, 0, 0, 0);
    if (!r_is_objc_ptr(subviews) || !r_responds(subviews, "count")) return touched;

    uint64_t count = r_msg2(subviews, "count", 0, 0, 0, 0);
    if (count > 96) count = 96;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t child = r_msg2(subviews, "objectAtIndex:", i, 0, 0, 0);
        touched += atl_walk_icon_views(child, depth + 1, scale, offsetY);
    }
    return touched;
}

static int atl_transform_loaded_icons(int iconScalePercent, int iconOffsetY)
{
    double scale = (double)iconScalePercent / 100.0;
    if (scale < 0.20) scale = 0.20;
    if (scale > 2.00) scale = 2.00;
    double offsetY = (double)iconOffsetY;
    if (offsetY < -120.0) offsetY = -120.0;
    if (offsetY > 120.0) offsetY = 120.0;

    uint64_t cls = r_class("SBIconController");
    uint64_t iconController = r_is_objc_ptr(cls) ? r_msg2_main(cls, "sharedInstance", 0, 0, 0, 0) : 0;
    uint64_t iconManager = r_is_objc_ptr(iconController) && r_responds_main(iconController, "iconManager")
        ? r_msg2_main(iconController, "iconManager", 0, 0, 0, 0)
        : 0;
    uint64_t rootFolder = r_is_objc_ptr(iconManager) && r_responds_main(iconManager, "rootFolderController")
        ? r_msg2_main(iconManager, "rootFolderController", 0, 0, 0, 0)
        : 0;

    int touched = 0;
    if (r_is_objc_ptr(rootFolder) && r_responds_main(rootFolder, "view")) {
        touched += atl_walk_icon_views(r_msg2_main(rootFolder, "view", 0, 0, 0, 0), 0, scale, offsetY);
    }
    if (r_is_objc_ptr(iconManager) && r_responds_main(iconManager, "dockListView")) {
        touched += atl_walk_icon_views(r_msg2_main(iconManager, "dockListView", 0, 0, 0, 0), 0, scale, offsetY);
    }

    uint64_t app = r_msg2_main(r_class("UIApplication"), "sharedApplication", 0, 0, 0, 0);
    uint64_t windows = r_is_objc_ptr(app) ? r_msg2_main(app, "windows", 0, 0, 0, 0) : 0;
    uint64_t count = r_is_objc_ptr(windows) && r_responds(windows, "count") ? r_msg2(windows, "count", 0, 0, 0, 0) : 0;
    if (count > 24) count = 24;
    for (uint64_t i = 0; i < count; i++) {
        touched += atl_walk_icon_views(r_msg2(windows, "objectAtIndex:", i, 0, 0, 0), 0, scale, offsetY);
    }

    printf("[ATRIALITE] icon scale=%d%% offsetY=%d touched=%d\n", iconScalePercent, iconOffsetY, touched);
    return touched;
}

bool atrialite_apply_in_session(int dockIcons, int hsCols, int hsRows, bool hideLabels, int iconScalePercent, int iconOffsetY)
{
    printf("[ATRIALITE] apply dock=%d home=%dx%d hideLabels=%d iconScale=%d%% offsetY=%d\n",
           dockIcons, hsCols, hsRows, hideLabels, iconScalePercent, iconOffsetY);
    bool ok = sbcustomizer_apply_in_session(dockIcons, hsCols, hsRows, hideLabels);
    atl_transform_loaded_icons(iconScalePercent, iconOffsetY);
    return ok;
}

bool atrialite_stop_in_session(void)
{
    printf("[ATRIALITE] restore stock dock=%d home=%dx%d hideLabels=%d\n",
           kAtriaLiteStockDockIcons,
           kAtriaLiteStockHomeCols,
           kAtriaLiteStockHomeRows,
           kAtriaLiteStockHideLabels);
    bool ok = sbcustomizer_apply_in_session(kAtriaLiteStockDockIcons,
                                            kAtriaLiteStockHomeCols,
                                            kAtriaLiteStockHomeRows,
                                            kAtriaLiteStockHideLabels);
    atl_transform_loaded_icons(100, 0);
    return ok;
}

void atrialite_forget_remote_state(void)
{
    printf("[ATRIALITE] forgot remote state\n");
}
