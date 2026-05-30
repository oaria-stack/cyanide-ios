//
//  doodlelite.m
//  Draw-to-unlock — lock screen doodle canvas, iOS 17 + iOS 18.x compatible.
//
//  iOS 18 compatibility notes
//  --------------------------
//  1. Canvas attachment: on iOS 18 the cover sheet is a subview of
//     coverSheetWindow.rootViewController.view (same as axonlite).
//     A standalone UIWindow at windowLevel 1001 DOES NOT receive touches
//     on iOS 18 because SpringBoard's touch routing changed — the cover
//     sheet's scroll view consumes pan gestures before they reach any
//     overlaid window. We therefore attach as a subview of the cover
//     sheet root view, exactly as axonlite does.
//
//  2. Gesture recognizer: cancelsTouchesInView=NO and delaysTouchesBegan=NO
//     are mandatory on iOS 18 or the underlying scroll view steals touches
//     before our pan GR sees them.
//
//  3. Stroke sampling: we cannot install a compiled IMP remotely, so we use
//     a CADisplayLink on our (Cyanide app) side that polls
//     -translationInView: on the remote pan GR via RemoteCall every ~16ms
//     and appends the points to an NSMutableData in the remote NSUserDefaults.
//     On gesture end (state == UIGestureRecognizerStateEnded == 3) we read
//     the buffer back, run the $1 Unistroke match, and attempt unlock.
//
//  4. Unlock chain: see dl_attempt_unlock for the full iOS 17 + 18.x cascade.
//

#import "doodlelite.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

#define DL_CANVAS_WIDTH_FRAC    0.72
#define DL_CANVAS_HEIGHT_FRAC   0.28
#define DL_CANVAS_CENTER_Y_FRAC 0.54
#define DL_STROKE_WIDTH         4.0
#define DL_MATCH_THRESHOLD      0.25
#define DL_RESAMPLE_N           32
#define DL_MAX_POINTS           512
#define DL_SETTLE_US            30000
#define DL_CANVAS_TAG           0xD00D1E01
#define DL_SHAPE_LAYER_TAG      0xD00D1E02

static const char *kDLStrokeKey   = "doodleliteStrokePoints";
static const char *kDLTemplateKey = "doodleliteTemplatePoints";
static const char *kDLRecordKey   = "doodleliteRecordNext";
static const char *kDLAssocCanvas = "doodleliteCanvas";
static const char *kDLAssocPanGR  = "doodlelitePanGR";
static const char *kDLAssocParent = "doodleliteParentView";

// ---------------------------------------------------------------------------
// Geometry helpers (same pattern as axonlite)
// ---------------------------------------------------------------------------

typedef struct { double x, y, w, h; } DLRect;
typedef struct { double x, y; }       DLPoint;

static bool dl_send_rect(uint64_t obj, const char *sel, double x, double y, double w, double h)
{
    if (!r_is_objc_ptr(obj)) return false;
    DLRect r = {x, y, w, h};
    r_msg2_main_raw(obj, sel, &r, sizeof(r), NULL, 0, NULL, 0, NULL, 0);
    usleep(DL_SETTLE_US);
    return true;
}

static bool dl_send_double(uint64_t obj, const char *sel, double v)
{
    if (!r_is_objc_ptr(obj)) return false;
    r_msg2_main_raw(obj, sel, &v, sizeof(v), NULL, 0, NULL, 0, NULL, 0);
    usleep(DL_SETTLE_US);
    return true;
}

static uint64_t dl_alloc_init_view(const char *cls, double x, double y, double w, double h)
{
    uint64_t c = r_class(cls);
    uint64_t a = r_is_objc_ptr(c) ? r_msg2_main(c, "alloc", 0, 0, 0, 0) : 0;
    uint64_t v = r_is_objc_ptr(a) ? r_msg2_main(a, "init", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(v)) dl_send_rect(v, "setFrame:", x, y, w, h);
    return v;
}

static uint64_t dl_color_rgba(double r, double g, double b, double a)
{
    uint64_t cls = r_class("UIColor");
    if (!r_is_objc_ptr(cls)) return 0;
    return r_msg2_main_raw(cls, "colorWithRed:green:blue:alpha:",
                            &r, sizeof(r), &g, sizeof(g),
                            &b, sizeof(b), &a, sizeof(a));
}

static uint64_t dl_color_white_alpha(double white, double alpha)
{
    uint64_t cls = r_class("UIColor");
    if (!r_is_objc_ptr(cls)) return 0;
    return r_msg2_main_raw(cls, "colorWithWhite:alpha:",
                            &white, sizeof(white),
                            &alpha, sizeof(alpha),
                            NULL, 0, NULL, 0);
}

// ---------------------------------------------------------------------------
// Screen dimensions (read on our side — matches remote process)
// ---------------------------------------------------------------------------

static double dl_screen_w(void) { return UIScreen.mainScreen.bounds.size.width  ?: 390.0; }
static double dl_screen_h(void) { return UIScreen.mainScreen.bounds.size.height ?: 844.0; }

// ---------------------------------------------------------------------------
// Find the cover sheet window & root view (iOS 17 + 18 compatible)
// ---------------------------------------------------------------------------
// On iOS 17: rootViewController class ~= "SBCoverSheetPrimarySlidingViewController"
// On iOS 18: rootViewController class ~= "SBDashBoardViewController" or
//             the window itself is identified by windowLevel ~= 10
// We match any window whose rootViewController class name contains
// "CoverSheet", "DashBoard", or "SBDash".

static bool dl_class_name(uint64_t obj, char *out, size_t len)
{
    if (!r_is_objc_ptr(obj) || !out) return false;
    uint64_t cls  = r_dlsym_call(R_TIMEOUT, "object_getClass", obj, 0,0,0,0,0,0,0);
    uint64_t name = r_dlsym_call(R_TIMEOUT, "class_getName", cls, 0,0,0,0,0,0,0);
    if (!cls || !name) return false;
    uint64_t dup = r_dlsym_call(R_TIMEOUT, "strdup", name, 0,0,0,0,0,0,0);
    if (!dup) return false;
    bool ok = remote_read(dup, out, len - 1);
    r_free(dup);
    if (ok) out[len - 1] = '\0';
    return ok && out[0];
}

static bool dl_is_coversheet_root(uint64_t vc)
{
    if (!r_is_objc_ptr(vc)) return false;
    char cls[128];
    if (!dl_class_name(vc, cls, sizeof(cls))) return false;
    return strstr(cls, "CoverSheet") || strstr(cls, "DashBoard") ||
           strstr(cls, "SBDash")     || strstr(cls, "CSCoverSheet");
}

static uint64_t dl_find_coversheet_root_view(void)
{
    uint64_t appCls = r_class("UIApplication");
    uint64_t app = r_is_objc_ptr(appCls) ?
        r_msg2_main(appCls, "sharedApplication", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(app)) return 0;

    uint64_t wins = r_msg2_main(app, "windows", 0, 0, 0, 0);
    uint64_t cnt  = r_is_objc_ptr(wins) ? r_msg2_main(wins, "count", 0, 0, 0, 0) : 0;
    if (cnt > 60) cnt = 60;

    for (uint64_t i = 0; i < cnt; i++) {
        uint64_t win = r_msg2_main(wins, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(win)) continue;
        uint64_t rootVC = r_msg2_main(win, "rootViewController", 0, 0, 0, 0);
        if (!dl_is_coversheet_root(rootVC)) {
            // Also try presented VC
            uint64_t pres = r_is_objc_ptr(rootVC) ?
                r_msg2_main(rootVC, "presentedViewController", 0, 0, 0, 0) : 0;
            if (!dl_is_coversheet_root(pres)) continue;
            rootVC = pres;
        }
        uint64_t rootView = r_msg2_main(rootVC, "view", 0, 0, 0, 0);
        if (r_is_objc_ptr(rootView)) {
            char cls[128];
            dl_class_name(rootVC, cls, sizeof(cls));
            printf("[DL] cover sheet rootView=0x%llx via VC %s\n", rootView, cls);
            return rootView;
        }
    }

    printf("[DL] cover sheet root view not found in %llu windows\n", cnt);
    return 0;
}

// ---------------------------------------------------------------------------
// NSUserDefaults point buffer
// ---------------------------------------------------------------------------

static int dl_read_points(const char *key, DLPoint *out, int maxPts)
{
    uint64_t defsCls = r_class("NSUserDefaults");
    uint64_t defs = r_is_objc_ptr(defsCls) ?
        r_msg2_main(defsCls, "standardUserDefaults", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(defs)) return 0;

    uint64_t k = r_nsstr_retained(key);
    if (!r_is_objc_ptr(k)) return 0;
    uint64_t data = r_msg2_main(defs, "dataForKey:", k, 0, 0, 0);
    r_msg2(k, "release", 0, 0, 0, 0);
    if (!r_is_objc_ptr(data)) return 0;

    uint64_t len = r_msg2_main(data, "length", 0, 0, 0, 0);
    if (len < 4 || len > (uint64_t)(4 + maxPts * 16)) return 0;

    uint64_t bytes = r_msg2_main(data, "bytes", 0, 0, 0, 0);
    if (!bytes) return 0;

    uint8_t buf[4 + DL_MAX_POINTS * 16];
    if (!remote_read(bytes, buf, (size_t)len)) return 0;

    int32_t count;
    memcpy(&count, buf, 4);
    if (count <= 0 || count > maxPts) return 0;
    memcpy(out, buf + 4, (size_t)count * sizeof(DLPoint));
    return count;
}

// ---------------------------------------------------------------------------
// $1 Unistroke match (runs on our side after reading the buffer)
// ---------------------------------------------------------------------------

static void dl_resample(const DLPoint *in, int n, DLPoint *out, int m)
{
    if (n <= 0 || m <= 0) return;
    if (n == 1) { for (int i=0;i<m;i++) out[i]=in[0]; return; }
    double total = 0;
    for (int i=1;i<n;i++) {
        double dx=in[i].x-in[i-1].x, dy=in[i].y-in[i-1].y;
        total += sqrt(dx*dx+dy*dy);
    }
    double interval = total/(m-1), D=0;
    out[0]=in[0];
    int oi=1, i=1;
    while (i<n && oi<m) {
        double dx=in[i].x-in[i-1].x, dy=in[i].y-in[i-1].y;
        double d=sqrt(dx*dx+dy*dy);
        if (D+d >= interval) {
            double t=(interval-D)/d;
            out[oi++]=(DLPoint){in[i-1].x+t*dx, in[i-1].y+t*dy};
            D=0;
        } else { D+=d; i++; }
    }
    while (oi<m) out[oi++]=in[n-1];
}

static void dl_normalise(DLPoint *pts, int n)
{
    double cx=0,cy=0;
    for (int i=0;i<n;i++){cx+=pts[i].x;cy+=pts[i].y;}
    cx/=n; cy/=n;
    for (int i=0;i<n;i++){pts[i].x-=cx;pts[i].y-=cy;}
    double minX=1e9,minY=1e9,maxX=-1e9,maxY=-1e9;
    for (int i=0;i<n;i++){
        if(pts[i].x<minX)minX=pts[i].x; if(pts[i].y<minY)minY=pts[i].y;
        if(pts[i].x>maxX)maxX=pts[i].x; if(pts[i].y>maxY)maxY=pts[i].y;
    }
    double s=fmax(maxX-minX,maxY-minY);
    if(s<1e-6)return;
    for(int i=0;i<n;i++){pts[i].x=(pts[i].x-minX)/s;pts[i].y=(pts[i].y-minY)/s;}
}

static double dl_match_score(const DLPoint *raw, int rn, const DLPoint *tmpl, int tn)
{
    if (rn<4||tn<4) return 1.0;
    DLPoint r[DL_RESAMPLE_N], t[DL_RESAMPLE_N];
    dl_resample(raw, rn, r, DL_RESAMPLE_N);
    dl_resample(tmpl,tn, t, DL_RESAMPLE_N);
    dl_normalise(r,DL_RESAMPLE_N); dl_normalise(t,DL_RESAMPLE_N);
    double sum=0;
    for(int i=0;i<DL_RESAMPLE_N;i++){
        double dx=r[i].x-t[i].x,dy=r[i].y-t[i].y;
        sum+=sqrt(dx*dx+dy*dy);
    }
    return sum/DL_RESAMPLE_N;
}

// ---------------------------------------------------------------------------
// Unlock — full iOS 17 + 18.x cascade
// ---------------------------------------------------------------------------

static bool dl_attempt_unlock(void)
{
    printf("[DL] attempting unlock\n");

    // iOS 17: SBCoverSheetPresentationManager _handleBiometricEvent:
    uint64_t sbcpCls = r_class("SBCoverSheetPresentationManager");
    uint64_t sbcpMgr = r_is_objc_ptr(sbcpCls) ?
        r_msg2_main(sbcpCls, "sharedInstance", 0,0,0,0) : 0;
    if (r_is_objc_ptr(sbcpMgr) && r_responds_main(sbcpMgr, "_handleBiometricEvent:")) {
        r_msg2_main(sbcpMgr, "_handleBiometricEvent:", 0,0,0,0);
        printf("[DL] unlock via _handleBiometricEvent:\n");
        return true;
    }

    // iOS 18.0–18.3: CSAuthenticationCoordinator
    const char *csAuthSels[] = {
        "performBiometricAuthentication",
        "attemptUnlockWithBiometrics",
        "beginAuthentication",
        NULL
    };
    uint64_t csAuthCls = r_class("CSAuthenticationCoordinator");
    uint64_t csAuth = 0;
    if (r_is_objc_ptr(csAuthCls)) {
        csAuth = r_msg2_main(csAuthCls, "sharedCoordinator", 0,0,0,0);
        if (!r_is_objc_ptr(csAuth))
            csAuth = r_msg2_main(csAuthCls, "sharedInstance", 0,0,0,0);
    }
    if (r_is_objc_ptr(csAuth)) {
        for (int i = 0; csAuthSels[i]; i++) {
            if (r_responds_main(csAuth, csAuthSels[i])) {
                r_msg2_main(csAuth, csAuthSels[i], 0,0,0,0);
                printf("[DL] unlock via CSAuthenticationCoordinator.%s\n", csAuthSels[i]);
                return true;
            }
        }
    }

    // iOS 18.4+: SBDashBoardViewController dismissLockScreenAnimated:
    uint64_t dbCls = r_class("SBDashBoardViewController");
    uint64_t db = r_is_objc_ptr(dbCls) ?
        r_msg2_main(dbCls, "sharedInstance", 0,0,0,0) : 0;
    if (!r_is_objc_ptr(db) && r_is_objc_ptr(sbcpMgr) &&
        r_responds_main(sbcpMgr, "dashBoardViewController")) {
        db = r_msg2_main(sbcpMgr, "dashBoardViewController", 0,0,0,0);
    }
    if (r_is_objc_ptr(db)) {
        if (r_responds_main(db, "dismissLockScreenAnimated:")) {
            r_msg2_main(db, "dismissLockScreenAnimated:", 1,0,0,0);
            printf("[DL] unlock via SBDashBoardViewController.dismissLockScreenAnimated:\n");
            return true;
        }
        if (r_responds_main(db, "_handleBiometricEvent:")) {
            r_msg2_main(db, "_handleBiometricEvent:", 0,0,0,0);
            printf("[DL] unlock via SBDashBoardViewController._handleBiometricEvent:\n");
            return true;
        }
    }

    // iOS 18 all: CSPasscodeEntryController (renamed from SBUIPasscodeEntryController)
    const char *peCls[] = {"CSPasscodeEntryController","SBUIPasscodeEntryController",NULL};
    for (int i=0; peCls[i]; i++) {
        uint64_t cls = r_class(peCls[i]);
        if (!r_is_objc_ptr(cls)) continue;
        uint64_t pe = r_msg2_main(cls, "sharedInstance", 0,0,0,0);
        if (!r_is_objc_ptr(pe)) continue;
        if (r_responds_main(pe, "dismissWithAnimation:")) {
            r_msg2_main(pe, "dismissWithAnimation:", 1,0,0,0);
            printf("[DL] unlock via %s.dismissWithAnimation:\n", peCls[i]);
            return true;
        }
        if (r_responds_main(pe, "dismiss")) {
            r_msg2_main(pe, "dismiss", 0,0,0,0);
            printf("[DL] unlock via %s.dismiss\n", peCls[i]);
            return true;
        }
    }

    // Fallback: setCoverSheetPresented:animated:
    if (r_is_objc_ptr(sbcpMgr) &&
        r_responds_main(sbcpMgr, "setCoverSheetPresented:animated:")) {
        r_msg2_main(sbcpMgr, "setCoverSheetPresented:animated:", 0,1,0,0);
        printf("[DL] unlock via setCoverSheetPresented:NO animated:YES\n");
        return true;
    }

    printf("[DL] unlock: no viable method found\n");
    return false;
}

// ---------------------------------------------------------------------------
// CADisplayLink polling — runs on the Cyanide app side
// ---------------------------------------------------------------------------
// Every frame we read the pan GR state + translation from the remote process
// and accumulate points. On state == Ended we run the match.

static uint64_t g_panGR       = 0;
static uint64_t g_canvasView  = 0;
static uint64_t g_shapeLayer  = 0;
static uint64_t g_badgeLabel  = 0;
static uint64_t g_parentView  = 0;

static DLPoint  g_strokeBuf[DL_MAX_POINTS];
static int      g_strokeCount = 0;
static bool     g_recording   = false;  // recording a new template
static bool     g_tracking    = false;  // actively tracking a stroke

static CADisplayLink *g_displayLink = nil;

// ---------------------------------------------------------------------------
// DLTickTarget — lightweight NSObject subclass used as CADisplayLink target
// ---------------------------------------------------------------------------
@interface DLTickTarget : NSObject
+ (instancetype)shared;
- (void)tick:(CADisplayLink *)link;
@end

@implementation DLTickTarget
+ (instancetype)shared {
    static DLTickTarget *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [DLTickTarget new]; });
    return s;
}
- (void)tick:(CADisplayLink *)link { dl_tick(link); }
@end

// UIGestureRecognizerState values
#define GR_STATE_BEGAN    1
#define GR_STATE_CHANGED  2
#define GR_STATE_ENDED    3
#define GR_STATE_CANCELLED 4
#define GR_STATE_FAILED   5

// Read pan GR state (int) via ivar _state
static int dl_pan_state(void)
{
    if (!r_is_objc_ptr(g_panGR)) return -1;
    // _state ivar
    uint64_t stateAddr = 0;
    uint64_t cls = r_dlsym_call(R_TIMEOUT,"object_getClass",g_panGR,0,0,0,0,0,0,0);
    uint64_t nameMem = r_alloc_str("_state");
    if (nameMem) {
        uint64_t ivar = r_dlsym_call(100,"class_getInstanceVariable",cls,nameMem,0,0,0,0,0,0);
        uint64_t off  = ivar ? r_dlsym_call(100,"ivar_getOffset",ivar,0,0,0,0,0,0,0) : 0;
        if (off) stateAddr = g_panGR + off;
        r_free(nameMem);
    }
    if (!stateAddr) return -1;
    return (int)(remote_read64(stateAddr) & 0xFF);
}

// Read CGPoint translation via -translationInView:nil
static DLPoint dl_pan_translation(void)
{
    DLPoint p = {0,0};
    if (!r_is_objc_ptr(g_panGR) || !r_is_objc_ptr(g_canvasView)) return p;
    // translationInView: returns CGPoint (two doubles on arm64) in x0/x1
    // We call it via do_remote_call_stable and read from a stack buffer
    // by passing nil (0) as the view argument
    uint64_t sel = r_sel("translationInView:");
    if (!sel) return p;
    // translationInView: returns CGPoint struct — on arm64 this is returned
    // in x0:x1 (two 64-bit float regs). do_remote_call_stable returns x0.
    // We need to call via objc_msgSend_stret or read from a pre-allocated
    // CGPoint output buffer in the remote process.
    uint64_t buf = r_alloc(16);
    if (!buf) return p;
    // Use -translationInView: with our canvas view
    do_remote_call_stable(R_TIMEOUT, "objc_msgSend",
                          g_panGR, sel, g_canvasView, 0,0,0,0,0);
    // The return value is a CGPoint: on arm64, x0=x, x1=y for struct returns
    // of 2 doubles. However do_remote_call_stable only returns x0.
    // Alternative: read from the translation via a CGPoint* out-param using
    // -getTranslation:inView: if available, or read the ivar directly.
    // Read _translation ivar from the pan GR object
    uint64_t txCls = r_dlsym_call(R_TIMEOUT,"object_getClass",g_panGR,0,0,0,0,0,0,0);
    uint64_t txName = r_alloc_str("_translation");
    double tx=0, ty=0;
    if (txName) {
        uint64_t txIvar = r_dlsym_call(100,"class_getInstanceVariable",txCls,txName,0,0,0,0,0,0);
        uint64_t txOff  = txIvar ? r_dlsym_call(100,"ivar_getOffset",txIvar,0,0,0,0,0,0,0) : 0;
        if (txOff) {
            remote_read(g_panGR + txOff, &tx, 8);
            remote_read(g_panGR + txOff + 8, &ty, 8);
        }
        r_free(txName);
    }
    r_free(buf);
    p.x = tx; p.y = ty;
    return p;
}

// Save current stroke as template into NSUserDefaults
static void dl_save_template(void)
{
    if (g_strokeCount < 4) return;
    uint64_t defsCls = r_class("NSUserDefaults");
    uint64_t defs = r_is_objc_ptr(defsCls) ?
        r_msg2_main(defsCls, "standardUserDefaults", 0,0,0,0) : 0;
    if (!r_is_objc_ptr(defs)) return;

    size_t dataLen = 4 + (size_t)g_strokeCount * sizeof(DLPoint);
    uint8_t *buf = (uint8_t *)malloc(dataLen);
    if (!buf) return;
    int32_t cnt = g_strokeCount;
    memcpy(buf, &cnt, 4);
    memcpy(buf + 4, g_strokeBuf, (size_t)g_strokeCount * sizeof(DLPoint));

    uint64_t nsData = r_alloc(dataLen);
    if (nsData) {
        remote_write(nsData, buf, dataLen);
        uint64_t dataCls = r_class("NSData");
        uint64_t dataObj = r_is_objc_ptr(dataCls) ?
            r_msg2_main(dataCls, "dataWithBytesNoCopy:length:freeWhenDone:",
                        nsData, (uint64_t)dataLen, 0, 0) : 0;
        if (r_is_objc_ptr(dataObj)) {
            uint64_t k = r_nsstr_retained(kDLTemplateKey);
            if (r_is_objc_ptr(k)) {
                r_msg2_main(defs, "setObject:forKey:", dataObj, k, 0, 0);
                r_msg2_main(defs, "synchronize", 0,0,0,0);
                r_msg2(k, "release", 0,0,0,0);
                printf("[DL] template saved (%d pts)\n", g_strokeCount);
            }
        }
    }
    free(buf);
}

// Clear the CAShapeLayer path
static void dl_clear_stroke_path(void)
{
    if (!r_is_objc_ptr(g_shapeLayer)) return;
    uint64_t cgPathCls = r_class("UIBezierPath");
    if (!r_is_objc_ptr(cgPathCls)) return;
    uint64_t empty = r_msg2_main(cgPathCls, "bezierPath", 0,0,0,0);
    if (r_is_objc_ptr(empty)) {
        uint64_t cgp = r_msg2_main(empty, "CGPath", 0,0,0,0);
        if (cgp) r_msg2_main(g_shapeLayer, "setPath:", cgp, 0,0,0);
    }
}

// Show badge (✓ or ✗) then hide after delay
static void dl_show_badge(bool ok)
{
    if (!r_is_objc_ptr(g_badgeLabel)) return;
    uint64_t txt = r_nsstr_retained(ok ? "✓" : "✗");
    if (!r_is_objc_ptr(txt)) return;
    r_msg2_main(g_badgeLabel, "setText:", txt, 0,0,0);
    r_msg2(txt, "release", 0,0,0,0);

    uint64_t col = ok ? dl_color_rgba(0.2,0.9,0.4,1.0) : dl_color_rgba(1.0,0.3,0.3,1.0);
    if (r_is_objc_ptr(col)) r_msg2_main(g_badgeLabel, "setTextColor:", col, 0,0,0);
    r_msg2_main(g_badgeLabel, "setHidden:", 0,0,0,0);

    // Hide after 0.8s on main thread via performSelector:withObject:afterDelay:
    uint64_t trueNum = r_msg2_main(r_class("NSNumber"), "numberWithBool:", 1, 0,0,0);
    if (r_is_objc_ptr(trueNum)) {
        double delay = 0.8;
        r_msg2_main_raw(g_badgeLabel, "performSelector:withObject:afterDelay:",
                        (void*)r_sel("setHidden:"), sizeof(uint64_t),
                        &trueNum, sizeof(trueNum),
                        &delay, sizeof(delay),
                        NULL, 0);
    }
}

// Main display link tick
static void dl_tick(CADisplayLink *link)
{
    if (!r_is_objc_ptr(g_panGR)) return;

    int state = dl_pan_state();
    if (state < 0) return;

    if (state == GR_STATE_BEGAN) {
        g_strokeCount = 0;
        g_tracking = true;
        dl_clear_stroke_path();
        printf("[DL] stroke began\n");
    }

    if ((state == GR_STATE_BEGAN || state == GR_STATE_CHANGED) && g_tracking) {
        DLPoint pt = dl_pan_translation();
        if (g_strokeCount < DL_MAX_POINTS) {
            // Only append if moved enough (avoid duplicate points)
            bool append = (g_strokeCount == 0);
            if (!append) {
                DLPoint last = g_strokeBuf[g_strokeCount-1];
                double dx = pt.x - last.x, dy = pt.y - last.y;
                append = (dx*dx + dy*dy) > 4.0;
            }
            if (append) g_strokeBuf[g_strokeCount++] = pt;
        }
    }

    if ((state == GR_STATE_ENDED || state == GR_STATE_CANCELLED) && g_tracking) {
        g_tracking = false;
        printf("[DL] stroke ended pts=%d\n", g_strokeCount);

        // Check record-next flag in local defaults
        bool recordNext = [[NSUserDefaults standardUserDefaults]
                           boolForKey:@(kDLRecordKey)];

        if (recordNext) {
            dl_save_template();
            [[NSUserDefaults standardUserDefaults]
             removeObjectForKey:@(kDLRecordKey)];
            [[NSUserDefaults standardUserDefaults] synchronize];
            dl_show_badge(true);
            printf("[DL] gesture recorded\n");
            return;
        }

        // Load template and match
        DLPoint tmpl[DL_MAX_POINTS];
        int tn = dl_read_points(kDLTemplateKey, tmpl, DL_MAX_POINTS);

        if (tn < 4) {
            printf("[DL] no template stored yet\n");
            dl_show_badge(false);
            return;
        }

        double score = dl_match_score(g_strokeBuf, g_strokeCount, tmpl, tn);
        printf("[DL] match score=%.3f threshold=%.3f\n", score, DL_MATCH_THRESHOLD);

        if (score <= DL_MATCH_THRESHOLD) {
            dl_show_badge(true);
            dl_attempt_unlock();
        } else {
            dl_show_badge(false);
        }

        g_strokeCount = 0;
    }
}

// ---------------------------------------------------------------------------
// Canvas construction
// ---------------------------------------------------------------------------

static uint64_t dl_build_shape_layer(uint64_t canvasView, double cw, double ch)
{
    uint64_t cls = r_class("CAShapeLayer");
    uint64_t alloc = r_is_objc_ptr(cls) ? r_msg2_main(cls, "alloc", 0,0,0,0) : 0;
    uint64_t sl = r_is_objc_ptr(alloc) ? r_msg2_main(alloc, "init", 0,0,0,0) : 0;
    if (!r_is_objc_ptr(sl)) return 0;

    dl_send_rect(sl, "setFrame:", 0,0,cw,ch);
    r_msg2_main(sl, "setTag:", DL_SHAPE_LAYER_TAG, 0,0,0);

    uint64_t white = dl_color_white_alpha(1.0, 1.0);
    uint64_t cgWhite = r_is_objc_ptr(white) ? r_msg2_main(white, "CGColor", 0,0,0,0) : 0;
    if (cgWhite) r_msg2_main(sl, "setStrokeColor:", cgWhite, 0,0,0);

    uint64_t clear = dl_color_rgba(0,0,0,0);
    uint64_t cgClear = r_is_objc_ptr(clear) ? r_msg2_main(clear, "CGColor", 0,0,0,0) : 0;
    if (cgClear) r_msg2_main(sl, "setFillColor:", cgClear, 0,0,0);

    double sw = DL_STROKE_WIDTH;
    r_msg2_main_raw(sl, "setLineWidth:", &sw, sizeof(sw), NULL,0,NULL,0,NULL,0);
    r_msg2_main(sl, "setLineCap:", 1, 0,0,0);   // kCALineCapRound
    r_msg2_main(sl, "setLineJoin:", 1, 0,0,0);  // kCALineJoinRound

    uint64_t layer = r_msg2_main(canvasView, "layer", 0,0,0,0);
    if (r_is_objc_ptr(layer)) r_msg2_main(layer, "addSublayer:", sl, 0,0,0);
    return sl;
}

static uint64_t dl_build_pan_gr(uint64_t canvasView)
{
    // On iOS 18 we MUST set cancelsTouchesInView=NO and delaysTouchesBegan=NO
    // or the cover sheet scroll view steals touches before our GR fires.
    uint64_t grCls = r_class("UIPanGestureRecognizer");
    if (!r_is_objc_ptr(grCls)) return 0;
    uint64_t alloc = r_msg2_main(grCls, "alloc", 0,0,0,0);
    // Use canvasView itself as target with a noop selector that it won't mind
    // receiving. We don't need the action to do anything — we poll state/translation.
    // Use "self" as both target and a real selector so UIKit accepts it.
    uint64_t sel = r_sel("setNeedsDisplay");
    uint64_t gr = r_is_objc_ptr(alloc) ?
        r_msg2_main(alloc, "initWithTarget:action:", canvasView, sel, 0,0) : 0;
    if (!r_is_objc_ptr(gr)) return 0;

    r_msg2_main(gr, "setCancelsTouchesInView:", 0, 0,0,0);   // iOS 18 critical
    r_msg2_main(gr, "setDelaysTouchesBegan:", 0, 0,0,0);     // iOS 18 critical
    r_msg2_main(gr, "setDelaysTouchesEnded:", 0, 0,0,0);
    r_msg2_main(gr, "setMinimumNumberOfTouches:", 1, 0,0,0);
    r_msg2_main(gr, "setMaximumNumberOfTouches:", 1, 0,0,0);

    r_msg2_main(canvasView, "addGestureRecognizer:", gr, 0,0,0);
    printf("[DL] pan GR installed: 0x%llx\n", gr);
    return gr;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

void doodlelite_forget_remote_state(void)
{
    g_panGR = g_canvasView = g_shapeLayer = g_badgeLabel = g_parentView = 0;
    printf("[DL] forgot remote state\n");
}

bool doodlelite_stop_in_session(void)
{
    if (g_displayLink) {
        [g_displayLink invalidate];
        g_displayLink = nil;
    }
    g_tracking = false;
    g_strokeCount = 0;
    if (r_is_objc_ptr(g_canvasView)) {
        r_msg2_main(g_canvasView, "removeFromSuperview", 0,0,0,0);
    }
    doodlelite_forget_remote_state();
    printf("[DL] stopped\n");
    return true;
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

bool doodlelite_start_in_session(void)
{
    printf("[DL] start_in_session\n");

    // Stop any existing display link
    if (g_displayLink) { [g_displayLink invalidate]; g_displayLink = nil; }

    // Find cover sheet root view — this is where we attach, iOS 17 + 18
    uint64_t parentView = dl_find_coversheet_root_view();
    if (!r_is_objc_ptr(parentView)) {
        printf("[DL] cover sheet not visible yet — try after locking device\n");
        return false;
    }

    double sw = dl_screen_w(), sh = dl_screen_h();
    double cw = sw * DL_CANVAS_WIDTH_FRAC;
    double ch = sh * DL_CANVAS_HEIGHT_FRAC;
    double cx = (sw - cw) / 2.0;
    double cy = sh * DL_CANVAS_CENTER_Y_FRAC - ch / 2.0;
    printf("[DL] canvas frame=(%.0f,%.0f,%.0f,%.0f)\n", cx,cy,cw,ch);

    // Remove any orphaned canvas from a previous session
    while (1) {
        uint64_t old = r_msg2_main(parentView, "viewWithTag:", DL_CANVAS_TAG, 0,0,0);
        if (!r_is_objc_ptr(old)) break;
        r_msg2_main(old, "removeFromSuperview", 0,0,0,0);
    }

    // Build canvas view
    uint64_t canvas = dl_alloc_init_view("UIView", cx, cy, cw, ch);
    if (!r_is_objc_ptr(canvas)) { printf("[DL] canvas alloc failed\n"); return false; }

    r_msg2_main(canvas, "setTag:", DL_CANVAS_TAG, 0,0,0);
    r_msg2_main(canvas, "setUserInteractionEnabled:", 1, 0,0,0);
    r_msg2_main(canvas, "setClipsToBounds:", 1, 0,0,0);

    // Background: semi-transparent dark
    uint64_t bg = dl_color_rgba(0.0, 0.0, 0.0, 0.30);
    if (r_is_objc_ptr(bg)) r_msg2_main(canvas, "setBackgroundColor:", bg, 0,0,0);

    // Rounded corners
    uint64_t layer = r_msg2_main(canvas, "layer", 0,0,0,0);
    if (r_is_objc_ptr(layer)) {
        dl_send_double(layer, "setCornerRadius:", 18.0);
        r_msg2_main(layer, "setMasksToBounds:", 1, 0,0,0);
    }
    usleep(DL_SETTLE_US);

    // Shape layer for strokes
    uint64_t sl = dl_build_shape_layer(canvas, cw, ch);
    usleep(DL_SETTLE_US);

    // Hint label: "Draw to unlock"
    uint64_t hint = dl_alloc_init_view("UILabel", 0, ch-34, cw, 28);
    if (r_is_objc_ptr(hint)) {
        uint64_t white = dl_color_white_alpha(1.0, 0.85);
        if (r_is_objc_ptr(white)) r_msg2_main(hint, "setTextColor:", white, 0,0,0);
        r_msg2_main(hint, "setTextAlignment:", 1, 0,0,0);
        r_msg2_main(hint, "setUserInteractionEnabled:", 0, 0,0,0);
        uint64_t UIFont = r_class("UIFont");
        if (r_is_objc_ptr(UIFont)) {
            double fsz = 13.0;
            uint64_t font = r_msg2_main_raw(UIFont, "systemFontOfSize:",
                                            &fsz, sizeof(fsz), NULL,0,NULL,0,NULL,0);
            if (r_is_objc_ptr(font)) r_msg2_main(hint, "setFont:", font, 0,0,0);
        }
        uint64_t hintStr = r_nsstr_retained("Draw to unlock");
        if (r_is_objc_ptr(hintStr)) {
            r_msg2_main(hint, "setText:", hintStr, 0,0,0);
            r_msg2(hintStr, "release", 0,0,0,0);
        }
        r_msg2_main(canvas, "addSubview:", hint, 0,0,0);
    }
    usleep(DL_SETTLE_US);

    // Badge label (✓ / ✗)
    uint64_t badge = dl_alloc_init_view("UILabel",
                                         (cw-48)/2, (ch-48)/2-16, 48, 48);
    if (r_is_objc_ptr(badge)) {
        r_msg2_main(badge, "setTextAlignment:", 1, 0,0,0);
        r_msg2_main(badge, "setHidden:", 1, 0,0,0);
        r_msg2_main(badge, "setUserInteractionEnabled:", 0, 0,0,0);
        uint64_t UIFont = r_class("UIFont");
        if (r_is_objc_ptr(UIFont)) {
            double fsz = 36.0;
            uint64_t font = r_msg2_main_raw(UIFont, "boldSystemFontOfSize:",
                                            &fsz, sizeof(fsz), NULL,0,NULL,0,NULL,0);
            if (r_is_objc_ptr(font)) r_msg2_main(badge, "setFont:", font, 0,0,0);
        }
        r_msg2_main(canvas, "addSubview:", badge, 0,0,0);
    }
    usleep(DL_SETTLE_US);

    // Pan gesture recognizer — iOS 18 compatible
    uint64_t gr = dl_build_pan_gr(canvas);
    usleep(DL_SETTLE_US);

    // Attach to cover sheet root view
    r_msg2_main(parentView, "addSubview:", canvas, 0,0,0);
    r_msg2_main(parentView, "bringSubviewToFront:", canvas, 0,0,0);
    usleep(DL_SETTLE_US);

    // Store state
    g_canvasView = canvas;
    g_shapeLayer = sl;
    g_badgeLabel = badge;
    g_parentView = parentView;
    g_panGR      = gr;
    g_strokeCount = 0;
    g_tracking = false;

    // Start CADisplayLink on our (Cyanide app) side to poll GR state each frame.
    // DLTickTarget is a simple NSObject subclass defined at file scope whose
    // -tick: method calls dl_tick().
    g_displayLink = [CADisplayLink displayLinkWithTarget:[DLTickTarget shared]
                                                selector:@selector(tick:)];
    g_displayLink.preferredFramesPerSecond = 60;
    [g_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    printf("[DL] installed canvas=0x%llx sl=0x%llx gr=0x%llx parent=0x%llx\n",
           canvas, sl, gr, parentView);
    return true;
}
