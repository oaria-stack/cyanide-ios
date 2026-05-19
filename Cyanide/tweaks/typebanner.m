//
//  typebanner.m
//

#import "typebanner.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <unistd.h>

#pragma mark - Banner globals (SpringBoard side)

static const uint64_t kTypeBannerOverlayTag = 99431;
static const double kTypeBannerHeight = 36.0;
static const double kTypeBannerCornerRadius = 18.0;
static const double kTypeBannerWinLevel = 999999.0;
static const double kTypeBannerSideMargin = 12.0;
static const double kTypeBannerHorizontalPadding = 14.0;
static const double kTypeBannerIconSize = 20.0;
static const double kTypeBannerIconLabelGap = 8.0;

static uint64_t gTypeBannerWindow = 0;
static uint64_t gTypeBannerLabel = 0;
static uint64_t gTypeBannerFontPtr = 0;

#pragma mark - Banner helpers (SpringBoard side)

typedef struct { double x, y, width, height; } TBRect64;

static bool tb_send_rect_main(uint64_t obj, const char *selName,
                              double x, double y, double w, double h)
{
    if (!r_is_objc_ptr(obj)) return false;
    TBRect64 rect = { x, y, w, h };
    r_msg2_main_raw(obj, selName,
                    &rect, sizeof(rect),
                    NULL, 0,
                    NULL, 0,
                    NULL, 0);
    usleep(20000);
    return true;
}

static bool tb_send_double_main(uint64_t obj, const char *selName, double value)
{
    if (!r_is_objc_ptr(obj)) return false;
    r_msg2_main_raw(obj, selName,
                    &value, sizeof(value),
                    NULL, 0,
                    NULL, 0,
                    NULL, 0);
    usleep(20000);
    return true;
}

static uint64_t tb_remote_nsstring(NSString *s)
{
    const char *utf8 = s.UTF8String;
    if (!utf8) utf8 = "";
    uint64_t buf = r_alloc_str(utf8);
    if (!buf) return 0;

    uint64_t NSString_cls = r_class("NSString");
    if (!r_is_objc_ptr(NSString_cls)) { r_free(buf); return 0; }
    uint64_t alloc = r_msg2(NSString_cls, "alloc", 0, 0, 0, 0);
    uint64_t ns = r_is_objc_ptr(alloc) ? r_msg2(alloc, "initWithUTF8String:", buf, 0, 0, 0) : 0;
    r_free(buf);
    return ns;
}

static double tb_banner_top_y(void)
{
    // Find safe-area top from any UIWindow in SpringBoard so we sit just
    // below the Dynamic Island / notch.
    uint64_t UIApplication = r_class("UIApplication");
    uint64_t app = r_is_objc_ptr(UIApplication)
        ? r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(app)) return 50.0;

    uint64_t keyWin = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    if (!r_is_objc_ptr(keyWin)) {
        uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
        uint64_t count = r_is_objc_ptr(windows) ? r_msg2_main(windows, "count", 0, 0, 0, 0) : 0;
        if (count > 0 && count < 64) keyWin = r_msg2_main(windows, "objectAtIndex:", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(keyWin)) return 50.0;

    struct { double top, left, bottom, right; } insets = {0};
    bool ok = r_msg2_main_struct_ret(keyWin, "safeAreaInsets",
                                     &insets, sizeof(insets),
                                     NULL, 0, NULL, 0, NULL, 0, NULL, 0);
    if (!ok) return 50.0;

    double topY = insets.top;
    if (topY > 47.0) topY += 4.0;  // Dynamic Island offset
    else topY = topY + 4.0;
    if (topY < 8.0) topY = 8.0;
    return topY;
}

static uint64_t tb_banner_font(void)
{
    if (r_is_objc_ptr(gTypeBannerFontPtr)) return gTypeBannerFontPtr;

    uint64_t UIFont = r_class("UIFont");
    if (!r_is_objc_ptr(UIFont)) return 0;

    double size = 14.0;
    double weight = 0.30;  // UIFontWeightMedium
    uint64_t font = r_msg2_main_raw(UIFont, "systemFontOfSize:weight:",
                                    &size, sizeof(size),
                                    &weight, sizeof(weight),
                                    NULL, 0,
                                    NULL, 0);
    if (!r_is_objc_ptr(font)) {
        font = r_msg2_main_raw(UIFont, "systemFontOfSize:",
                               &size, sizeof(size),
                               NULL, 0, NULL, 0, NULL, 0);
    }
    if (r_is_objc_ptr(font)) gTypeBannerFontPtr = font;
    return font;
}

static double tb_estimate_label_width(NSString *text)
{
    // Rough estimate: 8pt per char + 10pt slack. Good enough for the banner pill;
    // we don't need precise sizing.
    if (text.length == 0) return 200.0;
    double w = (double)text.length * 8.0 + 10.0;
    if (w < 120.0) w = 120.0;
    if (w > 320.0) w = 320.0;
    return w;
}

static uint64_t tb_find_or_create_window(void)
{
    if (r_is_objc_ptr(gTypeBannerWindow)) return gTypeBannerWindow;

    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) { printf("[TYPEBANNER] UIApplication missing\n"); return 0; }

    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) { printf("[TYPEBANNER] sharedApplication nil\n"); return 0; }

    // Recover any window we created on a previous run via assoc key.
    uint64_t assocKey = r_sel("cyanideTypeBannerOverlayWindow");
    if (!assocKey) return 0;
    uint64_t cachedWin = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                      app, assocKey, 0, 0, 0, 0, 0, 0);
    if (r_is_objc_ptr(cachedWin)) {
        uint64_t cachedLabel = r_msg2_main(cachedWin, "viewWithTag:",
                                           kTypeBannerOverlayTag, 0, 0, 0);
        if (r_is_objc_ptr(cachedLabel)) {
            gTypeBannerWindow = cachedWin;
            gTypeBannerLabel = cachedLabel;
            printf("[TYPEBANNER] recovered cached window=0x%llx label=0x%llx\n",
                   cachedWin, cachedLabel);
            return cachedWin;
        }
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     app, assocKey, 0, 1, 0, 0, 0, 0);
    }

    uint64_t keyWin = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    if (!r_is_objc_ptr(keyWin)) {
        uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
        uint64_t count = r_is_objc_ptr(windows) ? r_msg2_main(windows, "count", 0, 0, 0, 0) : 0;
        if (count > 0 && count < 64) keyWin = r_msg2_main(windows, "objectAtIndex:", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(keyWin)) { printf("[TYPEBANNER] keyWindow nil\n"); return 0; }

    uint64_t scene = r_msg2_main(keyWin, "windowScene", 0, 0, 0, 0);
    if (!r_is_objc_ptr(scene)) { printf("[TYPEBANNER] windowScene nil\n"); return 0; }

    uint64_t UIWindow = r_class("UIWindow");
    if (!r_is_objc_ptr(UIWindow)) { printf("[TYPEBANNER] UIWindow missing\n"); return 0; }

    uint64_t winAlloc = r_msg2_main(UIWindow, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(winAlloc)) return 0;
    uint64_t win = r_msg2_main(winAlloc, "initWithWindowScene:", scene, 0, 0, 0);
    if (!r_is_objc_ptr(win)) return 0;

    // Window: clear background, alert-level, no user interaction so taps
    // pass through everywhere except the banner pill itself (which is just
    // a label — no interaction yet).
    uint64_t UIColor = r_class("UIColor");
    if (r_is_objc_ptr(UIColor)) {
        uint64_t clear = r_msg2_main(UIColor, "clearColor", 0, 0, 0, 0);
        if (r_is_objc_ptr(clear)) r_msg2_main(win, "setBackgroundColor:", clear, 0, 0, 0);
    }
    r_msg2_main(win, "setUserInteractionEnabled:", 0, 0, 0, 0);

    // Label as the banner pill itself.
    uint64_t UILabel = r_class("UILabel");
    if (!r_is_objc_ptr(UILabel)) return 0;
    uint64_t labelAlloc = r_msg2_main(UILabel, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(labelAlloc)) return 0;
    uint64_t label = r_msg2_main(labelAlloc, "init", 0, 0, 0, 0);
    if (!r_is_objc_ptr(label)) return 0;

    r_msg2_main(label, "setTag:", kTypeBannerOverlayTag, 0, 0, 0);
    r_msg2_main(label, "setTextAlignment:", 1, 0, 0, 0);  // NSTextAlignmentCenter
    r_msg2_main(label, "setNumberOfLines:", 1, 0, 0, 0);
    r_msg2_main(label, "setAdjustsFontSizeToFitWidth:", 1, 0, 0, 0);
    if (r_is_objc_ptr(UIColor)) {
        uint64_t black = r_msg2_main(UIColor, "blackColor", 0, 0, 0, 0);
        uint64_t white = r_msg2_main(UIColor, "whiteColor", 0, 0, 0, 0);
        if (r_is_objc_ptr(black)) r_msg2_main(label, "setBackgroundColor:", black, 0, 0, 0);
        if (r_is_objc_ptr(white)) r_msg2_main(label, "setTextColor:", white, 0, 0, 0);
    }
    uint64_t font = tb_banner_font();
    if (r_is_objc_ptr(font)) r_msg2_main(label, "setFont:", font, 0, 0, 0);

    // Rounded pill: setCornerRadius + masksToBounds on the label's layer.
    uint64_t layer = r_msg2_main(label, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        tb_send_double_main(layer, "setCornerRadius:", kTypeBannerCornerRadius);
        r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
    }

    r_msg2_main(win, "addSubview:", label, 0, 0, 0);
    tb_send_double_main(win, "setWindowLevel:", kTypeBannerWinLevel);
    r_msg2_main(win, "setHidden:", 1, 0, 0, 0);  // start hidden, show on demand

    r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                 app, assocKey, win, 1, 0, 0, 0, 0);
    gTypeBannerWindow = win;
    gTypeBannerLabel = label;
    printf("[TYPEBANNER] created window=0x%llx label=0x%llx\n", win, label);
    return win;
}

bool typebanner_show_in_springboard_session(NSString *displayName)
{
    uint64_t win = tb_find_or_create_window();
    if (!r_is_objc_ptr(win) || !r_is_objc_ptr(gTypeBannerLabel)) {
        printf("[TYPEBANNER] show: no window\n");
        return false;
    }

    NSString *text = nil;
    if (displayName.length == 0) {
        text = @"Someone is typing…";
    } else if ([displayName isEqualToString:@"__SEVERAL_PEOPLE__"]) {
        text = @"Several people are typing…";
    } else {
        text = [NSString stringWithFormat:@" %@ is typing… ", displayName];
    }

    uint64_t ns = tb_remote_nsstring(text);
    if (!r_is_objc_ptr(ns)) { printf("[TYPEBANNER] show: NSString alloc failed\n"); return false; }
    r_msg2_main(gTypeBannerLabel, "setText:", ns, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "CFRelease", ns, 0, 0, 0, 0, 0, 0, 0);

    CGRect screen = UIScreen.mainScreen.bounds;
    double screenW = screen.size.width > 100.0 ? screen.size.width : 390.0;
    double width = tb_estimate_label_width(text);
    if (width > screenW - 2 * kTypeBannerSideMargin) width = screenW - 2 * kTypeBannerSideMargin;
    double x = floor((screenW - width) / 2.0);
    double y = tb_banner_top_y();

    tb_send_rect_main(win, "setFrame:", x, y, width, kTypeBannerHeight);
    tb_send_rect_main(gTypeBannerLabel, "setFrame:", 0, 0, width, kTypeBannerHeight);

    r_msg2_main(win, "setHidden:", 0, 0, 0, 0);
    printf("[TYPEBANNER] show: '%s' frame=(%.1f,%.1f,%.1f,%.1f)\n",
           text.UTF8String, x, y, width, kTypeBannerHeight);
    return true;
}

bool typebanner_hide_in_springboard_session(void)
{
    if (!r_is_objc_ptr(gTypeBannerWindow)) {
        // Try to recover from associated object before giving up.
        if (!tb_find_or_create_window()) return true;
    }
    if (!r_is_objc_ptr(gTypeBannerWindow)) return true;

    r_msg2_main(gTypeBannerWindow, "setHidden:", 1, 0, 0, 0);
    printf("[TYPEBANNER] hide\n");
    return true;
}

void typebanner_forget_remote_state(void)
{
    gTypeBannerWindow = 0;
    gTypeBannerLabel = 0;
    gTypeBannerFontPtr = 0;
    printf("[TYPEBANNER] forgot remote state\n");
}

#pragma mark - Detection helpers (MobileSMS side)

// Hard cap on remote calls per poll. Each call to a UIKit method through
// RemoteCall costs ~20-100ms with the usleep settle, so 250 nodes is roughly
// 5-25s in the worst case. We log start/end so it's obvious in the log
// whether the function reached the bottom or got capped.
static const int kTbMaxVisits = 250;

typedef struct {
    uint64_t count;
    uint64_t objAt;
    uint64_t subviews;
    uint64_t responds;
    uint64_t show;
    uint64_t conv;
    uint64_t name;
    uint64_t utf8;
} TbPollSels;

static NSString *tb_remote_nsstring_utf8(uint64_t nsStringObj, const TbPollSels *s)
{
    if (!r_is_objc_ptr(nsStringObj) || !s->utf8) return nil;
    uint64_t cstr = r_msg(nsStringObj, s->utf8, 0, 0, 0, 0);
    if (!cstr) return nil;
    char buf[256] = {0};
    if (!remote_read(cstr, buf, sizeof(buf) - 1)) return nil;
    return [NSString stringWithUTF8String:buf];
}

// Walk the view hierarchy under `view`. Returns first display name found,
// or nil. Caller passes a visit budget by pointer; we decrement and bail
// when it hits zero.
static NSString *tb_walk_typing(uint64_t view, int depth, int *visitsLeft,
                                const TbPollSels *s, NSString **found)
{
    if (*visitsLeft <= 0) return nil;
    if (!r_is_objc_ptr(view) || depth > 20) return nil;
    if (*found && (*found).length > 0) return *found;
    (*visitsLeft)--;

    // Cheapest check first: does this view answer -showTypingIndicator?
    uint64_t respShow = r_msg(view, s->responds, s->show, 0, 0, 0);
    if ((respShow & 0xff) != 0) {
        uint64_t isTyping = r_msg(view, s->show, 0, 0, 0, 0);
        if ((isTyping & 0xff) != 0) {
            NSString *name = nil;
            uint64_t respConv = r_msg(view, s->responds, s->conv, 0, 0, 0);
            if ((respConv & 0xff) != 0) {
                uint64_t conv = r_msg(view, s->conv, 0, 0, 0, 0);
                if (r_is_objc_ptr(conv)) {
                    uint64_t respName = r_msg(conv, s->responds, s->name, 0, 0, 0);
                    if ((respName & 0xff) != 0) {
                        uint64_t nm = r_msg(conv, s->name, 0, 0, 0, 0);
                        name = tb_remote_nsstring_utf8(nm, s);
                    }
                }
            }
            *found = name.length > 0 ? name : @"<unknown>";
            printf("[TYPEBANNER] poll: hit at depth=%d visitsLeft=%d name='%s'\n",
                   depth, *visitsLeft, (*found).UTF8String);
            return *found;
        }
    }

    if (*visitsLeft <= 0) return nil;

    uint64_t subs = r_msg(view, s->subviews, 0, 0, 0, 0);
    if (!r_is_objc_ptr(subs)) return nil;
    uint64_t cnt = r_msg(subs, s->count, 0, 0, 0, 0);
    if (cnt == 0 || cnt > 256) return nil;

    for (uint64_t i = 0; i < cnt && *visitsLeft > 0; i++) {
        uint64_t sub = r_msg(subs, s->objAt, i, 0, 0, 0);
        tb_walk_typing(sub, depth + 1, visitsLeft, s, found);
        if (*found && (*found).length > 0) return *found;
    }
    return nil;
}

NSString *typebanner_poll_in_mobilesms_session(void)
{
    printf("[TYPEBANNER] poll: entry (MobileSMS)\n");

    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) {
        printf("[TYPEBANNER] poll: UIApplication missing\n");
        return nil;
    }
    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) {
        printf("[TYPEBANNER] poll: sharedApplication nil\n");
        return nil;
    }

    TbPollSels sels = {0};
    sels.count    = r_sel("count");
    sels.objAt    = r_sel("objectAtIndex:");
    sels.subviews = r_sel("subviews");
    sels.responds = r_sel("respondsToSelector:");
    sels.show     = r_sel("showTypingIndicator");
    sels.conv     = r_sel("conversation");
    sels.name     = r_sel("name");
    sels.utf8     = r_sel("UTF8String");

    uint64_t selWindows = r_sel("windows");
    uint64_t selRootVC  = r_sel("rootViewController");
    uint64_t selView    = r_sel("view");
    uint64_t selKeyWin  = r_sel("keyWindow");

    // Fast path: keyWindow only. The conversation list / conversation VC the
    // user is currently looking at is rooted in the keyWindow; we don't need
    // to crawl every connectedScene.
    uint64_t keyWin = r_msg(app, selKeyWin, 0, 0, 0, 0);
    if (!r_is_objc_ptr(keyWin)) {
        // Fallback: take the first window of the first scene.
        uint64_t scenes = r_msg2_main(app, "connectedScenes", 0, 0, 0, 0);
        uint64_t allObjs = r_is_objc_ptr(scenes)
            ? r_msg(scenes, r_sel("allObjects"), 0, 0, 0, 0)
            : 0;
        uint64_t sceneCount = r_is_objc_ptr(allObjs)
            ? r_msg(allObjs, sels.count, 0, 0, 0, 0)
            : 0;
        if (sceneCount > 0 && sceneCount < 16) {
            uint64_t scene = r_msg(allObjs, sels.objAt, 0, 0, 0, 0);
            uint64_t windows = r_is_objc_ptr(scene)
                ? r_msg(scene, selWindows, 0, 0, 0, 0)
                : 0;
            uint64_t winCount = r_is_objc_ptr(windows)
                ? r_msg(windows, sels.count, 0, 0, 0, 0)
                : 0;
            if (winCount > 0 && winCount < 32) {
                keyWin = r_msg(windows, sels.objAt, 0, 0, 0, 0);
            }
        }
    }
    if (!r_is_objc_ptr(keyWin)) {
        printf("[TYPEBANNER] poll: no keyWindow / fallback window found\n");
        return nil;
    }

    uint64_t rootVC = r_msg(keyWin, selRootVC, 0, 0, 0, 0);
    if (!r_is_objc_ptr(rootVC)) {
        printf("[TYPEBANNER] poll: rootViewController nil\n");
        return nil;
    }
    uint64_t rootView = r_msg(rootVC, selView, 0, 0, 0, 0);
    if (!r_is_objc_ptr(rootView)) {
        printf("[TYPEBANNER] poll: rootView nil\n");
        return nil;
    }

    NSString *found = nil;
    int visitsLeft = kTbMaxVisits;
    tb_walk_typing(rootView, 0, &visitsLeft, &sels, &found);

    int visited = kTbMaxVisits - visitsLeft;
    if (found.length > 0) {
        printf("[TYPEBANNER] poll: done visited=%d name='%s'\n",
               visited, found.UTF8String);
    } else {
        printf("[TYPEBANNER] poll: done visited=%d no typing detected%s\n",
               visited, visitsLeft <= 0 ? " (HIT VISIT CAP — view tree too deep)" : "");
    }
    return found;
}

#pragma mark - Diagnostic dump (MobileSMS side)

// Walk the keyWindow's view tree and log every view whose class name contains
// "Cell", "Conversation", or "Typing". For each, log the class name plus
// whether it responds to a set of candidate typing-indicator selectors. This
// is for one-shot discovery: if the live poll finds nothing, the user can run
// this to see what the actual classes/selectors are on this iOS build.
static void tb_diag_walk(uint64_t view, int depth, int *visitsLeft,
                         uint64_t selSubviews, uint64_t selCount,
                         uint64_t selObjAt, uint64_t selClass,
                         uint64_t selResponds, uint64_t selUTF8,
                         uint64_t *typingSels, const char *const *typingNames,
                         int typingSelCount,
                         uint64_t fnNSStringFromClass)
{
    if (*visitsLeft <= 0) return;
    if (!r_is_objc_ptr(view) || depth > 25) return;
    (*visitsLeft)--;

    uint64_t cls = r_dlsym_call(R_TIMEOUT, "object_getClass",
                                view, 0, 0, 0, 0, 0, 0, 0);
    if (r_is_objc_ptr(cls)) {
        uint64_t clsName = r_dlsym_call(R_TIMEOUT, "class_getName",
                                        cls, 0, 0, 0, 0, 0, 0, 0);
        char clsBuf[128] = {0};
        if (clsName && remote_read(clsName, clsBuf, sizeof(clsBuf) - 1)) {
            BOOL interesting =
                strstr(clsBuf, "Cell") != NULL ||
                strstr(clsBuf, "Conversation") != NULL ||
                strstr(clsBuf, "Typing") != NULL ||
                strstr(clsBuf, "CKChat") != NULL;
            if (interesting) {
                // Build a comma-separated list of which candidate sels this
                // view responds to.
                char respBuf[256] = {0};
                size_t off = 0;
                for (int i = 0; i < typingSelCount; i++) {
                    uint64_t r = r_msg(view, selResponds, typingSels[i], 0, 0, 0);
                    if ((r & 0xff) == 0) continue;
                    int written = snprintf(respBuf + off, sizeof(respBuf) - off,
                                           "%s%s", off ? "," : "", typingNames[i]);
                    if (written <= 0 || (size_t)written >= sizeof(respBuf) - off) break;
                    off += (size_t)written;
                }
                printf("[TYPEBANNER] diag d=%d cls=%s sels=[%s]\n",
                       depth, clsBuf, respBuf);
            }
        }
    }

    if (*visitsLeft <= 0) return;
    uint64_t subs = r_msg(view, selSubviews, 0, 0, 0, 0);
    if (!r_is_objc_ptr(subs)) return;
    uint64_t cnt = r_msg(subs, selCount, 0, 0, 0, 0);
    if (cnt == 0 || cnt > 256) return;
    for (uint64_t i = 0; i < cnt && *visitsLeft > 0; i++) {
        uint64_t sub = r_msg(subs, selObjAt, i, 0, 0, 0);
        tb_diag_walk(sub, depth + 1, visitsLeft,
                     selSubviews, selCount, selObjAt,
                     selClass, selResponds, selUTF8,
                     typingSels, typingNames, typingSelCount,
                     fnNSStringFromClass);
    }
}

void typebanner_diagnose_in_mobilesms_session(void)
{
    printf("[TYPEBANNER] diag: entry (MobileSMS)\n");

    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) { printf("[TYPEBANNER] diag: UIApplication missing\n"); return; }
    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) { printf("[TYPEBANNER] diag: app nil\n"); return; }

    uint64_t selCount = r_sel("count");
    uint64_t selObjAt = r_sel("objectAtIndex:");
    uint64_t selSubviews = r_sel("subviews");
    uint64_t selResponds = r_sel("respondsToSelector:");
    uint64_t selKeyWin = r_sel("keyWindow");
    uint64_t selRootVC = r_sel("rootViewController");
    uint64_t selView = r_sel("view");
    uint64_t selClass = r_sel("class");
    uint64_t selUTF8 = r_sel("UTF8String");

    // Candidate selectors a "typing" cell or VC might respond to. We log
    // every match so we can see what the cell actually exposes.
    const char *typingNames[] = {
        "showTypingIndicator",
        "isShowingTypingIndicator",
        "showsTypingIndicator",
        "setShowTypingIndicator:",
        "setShowsTypingIndicator:",
        "typingIndicatorVisible",
        "isTypingIndicatorVisible",
        "setTypingIndicatorVisible:",
        "typingHandle",
        "isTyping",
        "conversation",
    };
    int typingSelCount = (int)(sizeof(typingNames) / sizeof(typingNames[0]));
    uint64_t typingSels[16] = {0};
    for (int i = 0; i < typingSelCount; i++) {
        typingSels[i] = r_sel(typingNames[i]);
    }

    uint64_t keyWin = r_msg(app, selKeyWin, 0, 0, 0, 0);
    if (!r_is_objc_ptr(keyWin)) { printf("[TYPEBANNER] diag: keyWindow nil\n"); return; }
    uint64_t rootVC = r_msg(keyWin, selRootVC, 0, 0, 0, 0);
    if (!r_is_objc_ptr(rootVC)) { printf("[TYPEBANNER] diag: rootVC nil\n"); return; }
    uint64_t rootView = r_msg(rootVC, selView, 0, 0, 0, 0);
    if (!r_is_objc_ptr(rootView)) { printf("[TYPEBANNER] diag: rootView nil\n"); return; }

    int visitsLeft = 600;
    tb_diag_walk(rootView, 0, &visitsLeft,
                 selSubviews, selCount, selObjAt,
                 selClass, selResponds, selUTF8,
                 typingSels, typingNames, typingSelCount,
                 0);
    int visited = 600 - visitsLeft;
    printf("[TYPEBANNER] diag: done visited=%d\n", visited);
}

#pragma mark - One-shot orchestrator

static NSString *gTypeBannerLastName = nil;

bool typebanner_run_once(void)
{
    // Phase 1: poll MobileSMS for typing state.
    NSString *currentName = nil;
    bool mobileSMSRunning = false;
    if (init_remote_call("MobileSMS", false) == 0) {
        mobileSMSRunning = true;
        @try {
            currentName = typebanner_poll_in_mobilesms_session();
        } @catch (NSException *e) {
            printf("[TYPEBANNER] MobileSMS poll exception: %s\n", e.reason.UTF8String);
        }
        destroy_remote_call();
    } else {
        printf("[TYPEBANNER] MobileSMS not running or unreachable\n");
    }

    // Phase 2: update SpringBoard banner if state changed.
    BOOL stateChanged = (currentName.length > 0) !=
                        (gTypeBannerLastName.length > 0);
    if (!stateChanged && currentName.length > 0 && gTypeBannerLastName.length > 0) {
        stateChanged = ![currentName isEqualToString:gTypeBannerLastName];
    }

    if (!stateChanged && !mobileSMSRunning && gTypeBannerLastName.length > 0) {
        // Messages app died → drop banner.
        stateChanged = YES;
        currentName = nil;
    }

    if (!stateChanged) return true;

    if (init_remote_call("SpringBoard", false) != 0) {
        printf("[TYPEBANNER] SpringBoard not reachable\n");
        return false;
    }
    bool ok = false;
    @try {
        if (currentName.length > 0) {
            ok = typebanner_show_in_springboard_session(currentName);
        } else {
            ok = typebanner_hide_in_springboard_session();
        }
    } @catch (NSException *e) {
        printf("[TYPEBANNER] SpringBoard update exception: %s\n", e.reason.UTF8String);
    }
    destroy_remote_call();

    gTypeBannerLastName = currentName ? [currentName copy] : nil;
    return ok;
}
