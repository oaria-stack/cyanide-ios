//
//  iconshapeslite.m
//  Custom icon shape masking via RemoteCall bridge.
//
//  Strategy
//  ========
//  1. Walk all SBIconViews (same traversal as atrialite / snowboardlite).
//  2. For each SBIconView, find the iconImageView and its CALayer.
//  3. Also find the icon's background view layer (_backgroundView or
//     _iconBackgroundView or similar — the layer that shows the app's
//     coloured background behind the icon glyph on iOS 18 masked icons).
//  4. Build a UIBezierPath for the requested shape sized to the icon
//     image view's bounds (always 60×60 pts on standard density, but we
//     read the actual frame so it works with atrialite's scale changes).
//  5. Allocate a CAShapeLayer in the remote process, set its path to the
//     UIBezierPath's CGPath, and assign it as the layer's .mask.
//     CALayer.mask clips all rendering including subviews and shadows.
//  6. Also set cornerRadius=0 and masksToBounds=YES on both layers so
//     the squircle that iOS applies by default doesn't fight the mask.
//
//  Reset
//  =====
//  Set layer.mask = nil and restore the original cornerRadius (27.0 for
//  the icon image view layer, 0 for the outer SBIconView layer).
//  Stock squircle is rendered by SpringBoard's own CALayer properties,
//  not a mask, so removing our mask restores the squircle automatically.
//
//  Path construction
//  =================
//  All paths are built on our (Cyanide app) side as UIBezierPath objects,
//  then the CGPath (a CFTypeRef / pointer) is transferred to the remote
//  process by:
//    a) Serialising the path to NSData via -bezierPathByReversingPath /
//       CGPathCreateCopyByDashingPath... — NOT feasible cross-process.
//    b) Building the path in the REMOTE process using
//       UIBezierPath factory methods available via r_msg2_main.
//       This is the approach we use.
//
//  Remote UIBezierPath calls
//  -------------------------
//  All geometry arguments are CGFloat (double on arm64) passed via
//  r_msg2_main_raw. The CGPath returned by -CGPath is a CGPathRef
//  (pointer) usable as the CAShapeLayer path argument directly.
//

#import "iconshapeslite.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <stdio.h>
#import <string.h>
#import <math.h>
#import <unistd.h>

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

#define ISL_SETTLE_US       25000
#define ISL_MAX_DEPTH       9
#define ISL_MAX_WINDOWS     24
#define ISL_STAR_POINTS     5
#define ISL_CORNER_RADIUS_STOCK  27.0   // stock iOS icon image layer cornerRadius

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

typedef struct { double x, y, w, h; } ISLRect;
typedef struct { double x, y; }       ISLPoint;

static bool isl_send_rect(uint64_t obj, const char *sel, double x, double y, double w, double h)
{
    if (!r_is_objc_ptr(obj)) return false;
    ISLRect r = {x, y, w, h};
    r_msg2_main_raw(obj, sel, &r, sizeof(r), NULL, 0, NULL, 0, NULL, 0);
    return true;
}

static bool isl_send_double(uint64_t obj, const char *sel, double v)
{
    if (!r_is_objc_ptr(obj)) return false;
    r_msg2_main_raw(obj, sel, &v, sizeof(v), NULL, 0, NULL, 0, NULL, 0);
    return true;
}

static bool isl_send_point(uint64_t obj, const char *sel, double x, double y)
{
    if (!r_is_objc_ptr(obj)) return false;
    ISLPoint p = {x, y};
    r_msg2_main_raw(obj, sel, &p, sizeof(p), NULL, 0, NULL, 0, NULL, 0);
    return true;
}

static ISLRect isl_read_frame(uint64_t view)
{
    ISLRect r = {0,0,60,60};
    if (!r_is_objc_ptr(view)) return r;
    // -frame returns CGRect (struct). On arm64 structs ≤ 32 bytes are
    // returned in x0-x3. We call via a raw buffer read of the ivar or
    // via r_msg2_main_raw with an output pointer.
    // Simplest: read the _layer.frame ivar chain or use -bounds.
    // Use UIView -bounds which is always {0,0,w,h}.
    // bounds is returned in x0:x1:x2:x3 (four doubles).
    // do_remote_call_stable only gives us x0 (x).
    // Read it via the layer's bounds ivar instead.
    uint64_t layer = r_msg2_main(view, "layer", 0,0,0,0);
    if (!r_is_objc_ptr(layer)) return r;
    // CALayer _bounds is a CGRect at a known ivar offset.
    // Safer: read -frame.size.width from the view via tag trick.
    // We use the actual UIView.frame ivar name.
    uint64_t cls = r_dlsym_call(R_TIMEOUT,"object_getClass",view,0,0,0,0,0,0,0);
    uint64_t fName = r_alloc_str("_layer");
    if (fName) {
        uint64_t ivar = r_dlsym_call(100,"class_getInstanceVariable",cls,fName,0,0,0,0,0,0);
        r_free(fName);
        if (ivar) {
            // just use the default 60x60 — most icons are this size
            // and we read from the iconImageView which is always square
        }
    }
    // Fallback: read layer.bounds via -bounds message returning CGRect.
    // We can't get all 4 doubles from one call.
    // Use a pre-agreed constant + adjust later: always 60×60.
    return r;
}

// Read actual icon size from the view frame.
// UIView._frame is a CGRect at a stable ivar offset.
// We try the ivar directly, then fall back to a bounds scan on the layer,
// then default to 60.0 (correct for standard @3x icons).
static double isl_icon_size(uint64_t iconImageView)
{
    if (!r_is_objc_ptr(iconImageView)) return 60.0;

    // Try UIView ivar _frame (a CGRect = {x,y,w,h}, 4 doubles = 32 bytes)
    uint64_t cls  = r_dlsym_call(R_TIMEOUT,"object_getClass",iconImageView,0,0,0,0,0,0,0);
    uint64_t fnam = r_alloc_str("_frame");
    if (fnam) {
        uint64_t ivar = r_dlsym_call(100,"class_getInstanceVariable",cls,fnam,0,0,0,0,0,0);
        uint64_t off  = ivar ? r_dlsym_call(100,"ivar_getOffset",ivar,0,0,0,0,0,0,0) : 0;
        r_free(fnam);
        if (off && off < 512) {
            double frame[4] = {0};
            if (remote_read(iconImageView + off, frame, 32)) {
                double w = frame[2], h = frame[3];
                if (w > 20.0 && w < 200.0 && fabs(w - h) < 2.0) {
                    printf("[ISL] icon size from _frame ivar: %.1f\n", w);
                    return w;
                }
            }
        }
    }

    // Layer bounds scan: try known offsets first (arm64 iOS 17: 48, iOS 18: 56)
    // then do a wider scan.
    uint64_t layer = r_msg2_main(iconImageView, "layer", 0,0,0,0);
    if (r_is_objc_ptr(layer)) {
        uint64_t knownOffsets[] = {48, 56, 40, 64, 72, 0};
        for (int ki = 0; knownOffsets[ki]; ki++) {
            double vals[4] = {0};
            if (!remote_read(layer + knownOffsets[ki], vals, 32)) continue;
            if (vals[0] == 0.0 && vals[1] == 0.0 &&
                vals[2] > 20.0 && vals[2] < 200.0 &&
                fabs(vals[2] - vals[3]) < 0.5) {
                printf("[ISL] icon size from layer+%llu: %.1f\n", knownOffsets[ki], vals[2]);
                return vals[2];
            }
        }
        // Wider scan
        for (uint64_t off = 32; off + 32 <= 320; off += 8) {
            double vals[4] = {0};
            if (!remote_read(layer + off, vals, 32)) continue;
            if (vals[0] == 0.0 && vals[1] == 0.0 &&
                vals[2] > 20.0 && vals[2] < 200.0 &&
                fabs(vals[2] - vals[3]) < 0.5) {
                printf("[ISL] icon size from layer scan +%llu: %.1f\n", off, vals[2]);
                return vals[2];
            }
        }
    }

    printf("[ISL] icon size: using default 60.0\n");
    return 60.0;
}

// ---------------------------------------------------------------------------
// Class name helper (matching atrialite pattern)
// ---------------------------------------------------------------------------

static bool isl_class_contains(uint64_t obj, const char *needle)
{
    if (!r_is_objc_ptr(obj) || !needle) return false;
    uint64_t cls  = r_dlsym_call(R_TIMEOUT,"object_getClass",obj,0,0,0,0,0,0,0);
    uint64_t name = r_dlsym_call(R_TIMEOUT,"class_getName",cls,0,0,0,0,0,0,0);
    if (!cls || !name) return false;
    uint64_t dup  = r_dlsym_call(R_TIMEOUT,"strdup",name,0,0,0,0,0,0,0);
    if (!dup) return false;
    char buf[128]; buf[0]='\0';
    remote_read(dup, buf, sizeof(buf)-1);
    r_free(dup);
    buf[sizeof(buf)-1]='\0';
    return strstr(buf, needle) != NULL;
}

// ---------------------------------------------------------------------------
// Remote UIBezierPath shape builders
// Each returns the CGPath pointer (remote) or 0 on failure.
// All sizes are in points. The path fills a sz×sz square origin (0,0).
// ---------------------------------------------------------------------------

static uint64_t isl_bezier_class(void)
{
    return r_class("UIBezierPath");
}

static uint64_t isl_path_circle(double sz)
{
    uint64_t cls = isl_bezier_class();
    if (!r_is_objc_ptr(cls)) return 0;
    ISLRect oval = {0, 0, sz, sz};
    uint64_t path = r_msg2_main_raw(cls, "bezierPathWithOvalInRect:",
                                    &oval, sizeof(oval),
                                    NULL,0, NULL,0, NULL,0);
    if (!r_is_objc_ptr(path)) return 0;
    return r_msg2_main(path, "CGPath", 0,0,0,0);
}

static uint64_t isl_path_square(double sz)
{
    uint64_t cls = isl_bezier_class();
    if (!r_is_objc_ptr(cls)) return 0;
    ISLRect rect = {0,0,sz,sz};
    uint64_t path = r_msg2_main_raw(cls, "bezierPathWithRect:",
                                    &rect, sizeof(rect),
                                    NULL,0, NULL,0, NULL,0);
    if (!r_is_objc_ptr(path)) return 0;
    return r_msg2_main(path, "CGPath", 0,0,0,0);
}

static uint64_t isl_path_rounded_square(double sz, double radius)
{
    uint64_t cls = isl_bezier_class();
    if (!r_is_objc_ptr(cls)) return 0;
    ISLRect rect = {0,0,sz,sz};
    // bezierPathWithRoundedRect:cornerRadius:
    uint64_t path = r_msg2_main_raw(cls, "bezierPathWithRoundedRect:cornerRadius:",
                                    &rect, sizeof(rect),
                                    &radius, sizeof(radius),
                                    NULL,0, NULL,0);
    if (!r_is_objc_ptr(path)) return 0;
    return r_msg2_main(path, "CGPath", 0,0,0,0);
}

// Squircle via continuousCorners (iOS 13+ CALayer cornerCurve).
// We approximate with a large-radius rounded rect which is visually
// indistinguishable. The stock mask uses cornerCurve=continuous on the
// layer, so for reset we just set mask=nil and cornerCurve back.
static uint64_t isl_path_squircle(double sz)
{
    // Squircle approximation: cornerRadius = sz * 0.2275 (matches stock iOS)
    return isl_path_rounded_square(sz, sz * 0.2275);
}

// Diamond: rotated square
static uint64_t isl_path_diamond(double sz)
{
    uint64_t cls = isl_bezier_class();
    if (!r_is_objc_ptr(cls)) return 0;
    uint64_t path = r_msg2_main(cls, "bezierPath", 0,0,0,0);
    if (!r_is_objc_ptr(path)) return 0;
    double half = sz/2.0;
    // top -> right -> bottom -> left -> close
    ISLPoint top   = {half, 0};
    ISLPoint right = {sz,   half};
    ISLPoint bot   = {half, sz};
    ISLPoint left  = {0,    half};
    r_msg2_main_raw(path, "moveToPoint:",    &top,   sizeof(top),   NULL,0,NULL,0,NULL,0);
    r_msg2_main_raw(path, "addLineToPoint:", &right, sizeof(right), NULL,0,NULL,0,NULL,0);
    r_msg2_main_raw(path, "addLineToPoint:", &bot,   sizeof(bot),   NULL,0,NULL,0,NULL,0);
    r_msg2_main_raw(path, "addLineToPoint:", &left,  sizeof(left),  NULL,0,NULL,0,NULL,0);
    r_msg2_main(path, "closePath", 0,0,0,0);
    return r_msg2_main(path, "CGPath", 0,0,0,0);
}

// 5-point star
static uint64_t isl_path_star(double sz)
{
    uint64_t cls = isl_bezier_class();
    if (!r_is_objc_ptr(cls)) return 0;
    uint64_t path = r_msg2_main(cls, "bezierPath", 0,0,0,0);
    if (!r_is_objc_ptr(path)) return 0;

    double cx = sz/2.0, cy = sz/2.0;
    double outerR = sz/2.0 * 0.96;
    double innerR = outerR * 0.40;
    int n = ISL_STAR_POINTS;
    bool first = true;

    for (int i = 0; i < n*2; i++) {
        double angle = M_PI * i / n - M_PI_2;
        double r = (i % 2 == 0) ? outerR : innerR;
        ISLPoint pt = {cx + r * cos(angle), cy + r * sin(angle)};
        if (first) {
            r_msg2_main_raw(path, "moveToPoint:",    &pt, sizeof(pt), NULL,0,NULL,0,NULL,0);
            first = false;
        } else {
            r_msg2_main_raw(path, "addLineToPoint:", &pt, sizeof(pt), NULL,0,NULL,0,NULL,0);
        }
    }
    r_msg2_main(path, "closePath", 0,0,0,0);
    return r_msg2_main(path, "CGPath", 0,0,0,0);
}

// Shield (rounded top, pointed bottom)
static uint64_t isl_path_shield(double sz)
{
    uint64_t cls = isl_bezier_class();
    if (!r_is_objc_ptr(cls)) return 0;
    uint64_t path = r_msg2_main(cls, "bezierPath", 0,0,0,0);
    if (!r_is_objc_ptr(path)) return 0;

    double r = sz * 0.25;
    double w = sz, h = sz;
    // Build shield as a polygon: rounded top via large corner rect, pointed bottom.
    // Use bezierPathWithRoundedRect: for the rounded top half, then extend
    // with line segments to a bottom point.
    // Simpler: 8-point polygon approximating a shield.
    double bevel = sz * 0.15;
    // top-left bevel -> top-right bevel (top edge)
    // top-right bevel -> right side -> bottom-right -> bottom point -> bottom-left -> left side -> top-left
    ISLPoint pts[] = {
        {bevel,      0},       // top-left after bevel
        {sz - bevel, 0},       // top-right before bevel
        {sz,         bevel},   // top-right corner
        {sz,         sz*0.62}, // right side bottom
        {sz/2.0,     sz},      // bottom point
        {0,          sz*0.62}, // left side bottom
        {0,          bevel},   // top-left corner
    };
    r_msg2_main_raw(path, "moveToPoint:", &pts[0], sizeof(pts[0]), NULL,0,NULL,0,NULL,0);
    for (int pi = 1; pi < 7; pi++)
        r_msg2_main_raw(path, "addLineToPoint:", &pts[pi], sizeof(pts[pi]), NULL,0,NULL,0,NULL,0);
    r_msg2_main(path, "closePath", 0,0,0,0);
    return r_msg2_main(path, "CGPath", 0,0,0,0);
}

// Teardrop (circle with pointed bottom-right)
static uint64_t isl_path_teardrop(double sz)
{
    uint64_t cls = isl_bezier_class();
    if (!r_is_objc_ptr(cls)) return 0;
    // bezierPathWithRoundedRect:byRoundingCorners:cornerRadii: — iOS 7+
    // Round all corners except bottom-right
    ISLRect rect = {0, 0, sz, sz};
    // UIRectCornerTopLeft|TopRight|BottomLeft = 1|2|8 = 11
    uint64_t corners = 11;
    // cornerRadii is a CGSize (2 doubles), NOT a CGRect
    typedef struct { double w; double h; } ISLSize;
    ISLSize radii = {sz * 0.45, sz * 0.45};
    uint64_t path = r_msg2_main_raw(cls,
        "bezierPathWithRoundedRect:byRoundingCorners:cornerRadii:",
        &rect,    sizeof(rect),
        &corners, sizeof(corners),
        &radii,   sizeof(radii),
        NULL, 0);
    if (!r_is_objc_ptr(path)) {
        // Fallback: use a circle
        return isl_path_circle(sz);
    }
    return r_msg2_main(path, "CGPath", 0,0,0,0);
}

// ---------------------------------------------------------------------------
// Build path for the requested shape
// ---------------------------------------------------------------------------

static uint64_t isl_make_path(ISLShape shape, double sz, int cornerRadiusPct)
{
    switch (shape) {
        case ISLShapeCircle:
            return isl_path_circle(sz);
        case ISLShapeSquare:
            return isl_path_square(sz);
        case ISLShapeRoundedSquare: {
            double r = sz * ((double)cornerRadiusPct / 100.0);
            if (r < 0)    r = 0;
            if (r > sz/2) r = sz/2;
            return isl_path_rounded_square(sz, r);
        }
        case ISLShapeDiamond:
            return isl_path_diamond(sz);
        case ISLShapeStar:
            return isl_path_star(sz);
        case ISLShapeShield:
            return isl_path_shield(sz);
        case ISLShapeTeardrop:
            return isl_path_teardrop(sz);
        case ISLShapeSquircle:
        default:
            return 0; // 0 = reset to nil mask (stock squircle via layer)
    }
}

// ---------------------------------------------------------------------------
// Apply mask + layer settings to a single icon image layer
// ---------------------------------------------------------------------------

static bool isl_apply_to_layer(uint64_t layer, uint64_t cgPath, ISLShape shape)
{
    if (!r_is_objc_ptr(layer)) return false;

    if (shape == ISLShapeSquircle) {
        // Reset: remove mask, restore stock cornerRadius + cornerCurve
        r_msg2_main(layer, "setMask:", 0, 0,0,0);
        isl_send_double(layer, "setCornerRadius:", ISL_CORNER_RADIUS_STOCK);
        r_msg2_main(layer, "setMasksToBounds:", 1, 0,0,0);
        // cornerCurve = kCACornerCurveContinuous = @"continuous"
        uint64_t contStr = r_nsstr_retained("continuous");
        if (r_is_objc_ptr(contStr)) {
            if (r_responds_main(layer, "setCornerCurve:"))
                r_msg2_main(layer, "setCornerCurve:", contStr, 0,0,0);
            r_msg2(contStr, "release", 0,0,0,0);
        }
        return true;
    }

    if (!cgPath) return false;

    // Alloc CAShapeLayer for the mask
    uint64_t slCls = r_class("CAShapeLayer");
    uint64_t slAlloc = r_is_objc_ptr(slCls) ? r_msg2_main(slCls, "alloc", 0,0,0,0) : 0;
    uint64_t maskLayer = r_is_objc_ptr(slAlloc) ? r_msg2_main(slAlloc, "init", 0,0,0,0) : 0;
    if (!r_is_objc_ptr(maskLayer)) return false;

    // Set the path
    r_msg2_main(maskLayer, "setPath:", cgPath, 0,0,0);

    // Fill with white (mask uses alpha — white = opaque)
    uint64_t UIColor = r_class("UIColor");
    uint64_t white   = r_is_objc_ptr(UIColor) ?
        r_msg2_main(UIColor, "whiteColor", 0,0,0,0) : 0;
    uint64_t cgWhite = r_is_objc_ptr(white) ?
        r_msg2_main(white, "CGColor", 0,0,0,0) : 0;
    if (cgWhite) r_msg2_main(maskLayer, "setFillColor:", cgWhite, 0,0,0);

    // Apply as mask
    r_msg2_main(layer, "setCornerRadius:", 0, 0,0,0);
    r_msg2_main(layer, "setMask:", maskLayer, 0,0,0);
    r_msg2_main(layer, "setMasksToBounds:", 1, 0,0,0);

    usleep(ISL_SETTLE_US);
    return true;
}

// ---------------------------------------------------------------------------
// Apply to a single SBIconView
// ---------------------------------------------------------------------------

static bool isl_apply_to_icon_view(uint64_t iconView, ISLShape shape, int cornerRadiusPct)
{
    if (!r_is_objc_ptr(iconView)) return false;

    // Find the image view
    uint64_t imageView = 0;
    const char *imgSels[] = {
        "iconImageView", "_iconImageView",
        "currentImageView", "contentsImageView", NULL
    };
    for (int i = 0; imgSels[i]; i++) {
        if (!r_responds_main(iconView, imgSels[i])) continue;
        imageView = r_msg2_main(iconView, imgSels[i], 0,0,0,0);
        if (r_is_objc_ptr(imageView)) break;
    }
    if (!r_is_objc_ptr(imageView))
        imageView = r_ivar_value(iconView, "_iconImageView");

    uint64_t imageLayer = r_is_objc_ptr(imageView) ?
        r_msg2_main(imageView, "layer", 0,0,0,0) : 0;

    if (!r_is_objc_ptr(imageLayer)) {
        // Fallback: use the icon view's own layer
        imageLayer = r_msg2_main(iconView, "layer", 0,0,0,0);
    }
    if (!r_is_objc_ptr(imageLayer)) return false;

    double sz = isl_icon_size(r_is_objc_ptr(imageView) ? imageView : iconView);
    uint64_t cgPath = isl_make_path(shape, sz, cornerRadiusPct);

    bool ok = isl_apply_to_layer(imageLayer, cgPath, shape);
    usleep(ISL_SETTLE_US);

    // Also mask the background view if present
    const char *bgIvars[] = {
        "_backgroundView", "_iconBackgroundView",
        "_backgroundLayer", NULL
    };
    for (int i = 0; bgIvars[i]; i++) {
        uint64_t bgView = r_ivar_value(iconView, bgIvars[i]);
        if (!r_is_objc_ptr(bgView)) continue;
        uint64_t bgLayer = r_msg2_main(bgView, "layer", 0,0,0,0);
        if (r_is_objc_ptr(bgLayer)) {
            // Build a fresh path for the background (same size)
            uint64_t bgPath = isl_make_path(shape, sz, cornerRadiusPct);
            isl_apply_to_layer(bgLayer, bgPath, shape);
            usleep(ISL_SETTLE_US);
        }
        break; // one background is enough
    }

    return ok;
}

// ---------------------------------------------------------------------------
// Walk the view tree — same pattern as atrialite
// ---------------------------------------------------------------------------

static int isl_walk(uint64_t view, int depth, ISLShape shape, int crPct)
{
    if (!r_is_objc_ptr(view) || depth > ISL_MAX_DEPTH) return 0;
    int touched = 0;

    if (isl_class_contains(view, "SBIconView") &&
        !isl_class_contains(view, "SBIconImageView")) {
        isl_apply_to_icon_view(view, shape, crPct);
        touched++;
        // Don't recurse into SBIconView children to avoid double-masking
        return touched;
    }

    if (!r_responds_main(view, "subviews")) return touched;
    uint64_t subs = r_msg2_main(view, "subviews", 0,0,0,0);
    uint64_t cnt  = (r_is_objc_ptr(subs) && r_responds(subs,"count")) ?
        r_msg2(subs, "count", 0,0,0,0) : 0;
    if (cnt > 96) cnt = 96;
    for (uint64_t i = 0; i < cnt; i++) {
        uint64_t child = r_msg2(subs, "objectAtIndex:", i, 0,0,0);
        touched += isl_walk(child, depth+1, shape, crPct);
    }
    return touched;
}

static int isl_apply_all(ISLShape shape, int crPct)
{
    int touched = 0;

    // Via SBIconController (home screen + dock)
    uint64_t cls = r_class("SBIconController");
    uint64_t ic  = r_is_objc_ptr(cls) ?
        r_msg2_main(cls, "sharedInstance", 0,0,0,0) : 0;
    uint64_t im  = r_is_objc_ptr(ic) && r_responds_main(ic, "iconManager") ?
        r_msg2_main(ic, "iconManager", 0,0,0,0) : 0;
    uint64_t rf  = r_is_objc_ptr(im) && r_responds_main(im, "rootFolderController") ?
        r_msg2_main(im, "rootFolderController", 0,0,0,0) : 0;

    if (r_is_objc_ptr(rf) && r_responds_main(rf, "view"))
        touched += isl_walk(r_msg2_main(rf, "view", 0,0,0,0), 0, shape, crPct);
    if (r_is_objc_ptr(im) && r_responds_main(im, "dockListView"))
        touched += isl_walk(r_msg2_main(im, "dockListView", 0,0,0,0), 0, shape, crPct);

    // Via UIApplication.windows (catches today view, search, etc.)
    uint64_t appCls = r_class("UIApplication");
    uint64_t app    = r_is_objc_ptr(appCls) ?
        r_msg2_main(appCls, "sharedApplication", 0,0,0,0) : 0;
    uint64_t wins   = r_is_objc_ptr(app) ?
        r_msg2_main(app, "windows", 0,0,0,0) : 0;
    uint64_t wcnt   = (r_is_objc_ptr(wins) && r_responds(wins,"count")) ?
        r_msg2(wins, "count", 0,0,0,0) : 0;
    if (wcnt > (uint64_t)ISL_MAX_WINDOWS) wcnt = ISL_MAX_WINDOWS;
    for (uint64_t i = 0; i < wcnt; i++) {
        uint64_t w = r_msg2(wins, "objectAtIndex:", i, 0,0,0);
        touched += isl_walk(w, 0, shape, crPct);
    }

    printf("[ISL] applied shape=%d crPct=%d touched=%d\n",
           (int)shape, crPct, touched);
    return touched;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

bool iconshapeslite_apply_in_session(ISLShape shape, int cornerRadiusPct)
{
    printf("[ISL] apply shape=%d cornerRadiusPct=%d\n", (int)shape, cornerRadiusPct);
    int touched = isl_apply_all(shape, cornerRadiusPct);
    return touched > 0;
}

bool iconshapeslite_reset_in_session(void)
{
    printf("[ISL] reset to squircle\n");
    int touched = isl_apply_all(ISLShapeSquircle, 0);
    return touched > 0;
}

void iconshapeslite_forget_remote_state(void)
{
    printf("[ISL] forgot remote state\n");
}
