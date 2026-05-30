//
//  syscolpatcher.m
//  Live in-process system color patcher via RemoteCall bridge.
//
//  Follows the exact same pattern as darksword_tweaks.m:
//    - r_class / r_msg2_main to walk the ObjC object graph
//    - class_getInstanceVariable + ivar_getOffset to find field offsets
//    - remote_write to poke new float values directly into RAM
//    - remote_read to verify and save originals for reset
//
//  Target path in SpringBoard's address space:
//
//    [_UIAssetManager sharedAssetManager]
//      ._catalog  (CUICatalog*)
//        ._store  (CUICommonAssetStorage* or CUIMutableCommonAssetStorage*)
//          .colorSpecs  (NSDictionary* mapping name -> CUINamedColor)
//            CUINamedColor
//              ._representations  (NSArray* of CUINamedColorRepresentation)
//                CUINamedColorRepresentation
//                  ._color  (UIColor* or struct with float r,g,b,a)
//
//  Because the private class layout changes between iOS versions we try
//  multiple ivar name spellings and fall back to a float-scan of the
//  object's first 256 bytes to find the RGBA run, same approach darksword
//  uses for fields it can't find by name.
//
//  Colors targeted (both light and dark appearances):
//    systemBlueColor, systemTintColor, systemIndigoColor
//
//  Original values are saved so reset can restore exactly.
//

#import "syscolpatcher.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <stdio.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>
#import <math.h>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

#define SCP_SETTLE_US       40000
#define SCP_MAX_SAVES       64
#define SCP_RGBA_EPSILON    0.04f

// UIUserInterfaceStyle (matches UIKit enum)
#define SCP_STYLE_LIGHT  1
#define SCP_STYLE_DARK   2

// ---------------------------------------------------------------------------
// Saved patch record for reset
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t addr;      // address of the float field in remote process
    float    original;  // original value before we patched it
    bool     active;
} SCPSave;

static SCPSave g_saves[SCP_MAX_SAVES];
static int     g_save_count = 0;

static void scp_save(uint64_t addr, float original)
{
    if (g_save_count >= SCP_MAX_SAVES) return;
    g_saves[g_save_count++] = (SCPSave){ addr, original, true };
}

// ---------------------------------------------------------------------------
// Remote float read/write helpers (matching darksword pattern)
// ---------------------------------------------------------------------------

static float scp_read_float(uint64_t addr)
{
    uint32_t bits = (uint32_t)remote_read64(addr) & 0xFFFFFFFF;
    float f;
    memcpy(&f, &bits, 4);
    return f;
}

static bool scp_write_float(uint64_t addr, float value)
{
    uint32_t bits;
    memcpy(&bits, &value, 4);
    uint64_t wide = bits;
    // Read current 8 bytes, replace lower 4, write back
    uint64_t current = remote_read64(addr & ~7ULL);
    uint64_t patched;
    if ((addr & 4) == 0) {
        patched = (current & 0xFFFFFFFF00000000ULL) | wide;
    } else {
        patched = (current & 0x00000000FFFFFFFFULL) | (wide << 32);
    }
    return remote_write(addr & ~7ULL, &patched, sizeof(patched));
}

// Write all four RGBA floats at a 16-byte aligned address
static bool scp_write_rgba(uint64_t addr, SCPColor c)
{
    float rgba[4] = { c.r, c.g, c.b, c.a };
    return remote_write(addr, rgba, sizeof(rgba));
}

static void scp_read_rgba(uint64_t addr, float out[4])
{
    // Read 16 bytes = four floats
    for (int i = 0; i < 4; i++) {
        out[i] = scp_read_float(addr + (uint64_t)(i * 4));
    }
}

// ---------------------------------------------------------------------------
// ivar offset lookup (same as ds_resolve_ivar_target)
// ---------------------------------------------------------------------------

static uint64_t scp_ivar_offset(uint64_t obj, const char *ivarName)
{
    if (!r_is_objc_ptr(obj) || !ivarName) return 0;
    uint64_t cls = r_dlsym_call(R_TIMEOUT, "object_getClass", obj, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(cls)) return 0;
    uint64_t nameMem = r_alloc_str(ivarName);
    if (!nameMem) return 0;
    uint64_t ivar = r_dlsym_call(100, "class_getInstanceVariable",
                                  cls, nameMem, 0, 0, 0, 0, 0, 0);
    r_free(nameMem);
    if (!ivar) return 0;
    return r_dlsym_call(100, "ivar_getOffset", ivar, 0, 0, 0, 0, 0, 0, 0);
}

static uint64_t scp_ivar_ptr(uint64_t obj, const char *ivarName)
{
    uint64_t off = scp_ivar_offset(obj, ivarName);
    return off ? obj + off : 0;
}

static uint64_t scp_read_ivar_obj(uint64_t obj, const char *ivarName)
{
    uint64_t ptr = scp_ivar_ptr(obj, ivarName);
    if (!ptr) return 0;
    return remote_read64(ptr);
}

// ---------------------------------------------------------------------------
// Class name helper (same pattern as atrialite / snowboardlite)
// ---------------------------------------------------------------------------

static bool scp_class_name(uint64_t obj, char *out, size_t outLen)
{
    if (!r_is_objc_ptr(obj) || !out || outLen == 0) return false;
    out[0] = '\0';
    uint64_t cls = r_dlsym_call(R_TIMEOUT, "object_getClass", obj, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(cls)) return false;
    uint64_t name = r_dlsym_call(R_TIMEOUT, "class_getName", cls, 0, 0, 0, 0, 0, 0, 0);
    if (!name) return false;
    uint64_t heap = r_dlsym_call(R_TIMEOUT, "strdup", name, 0, 0, 0, 0, 0, 0, 0);
    if (!heap) return false;
    bool ok = remote_read(heap, out, outLen - 1);
    r_free(heap);
    if (ok) out[outLen - 1] = '\0';
    return ok && out[0] != '\0';
}

static bool scp_class_contains(uint64_t obj, const char *needle)
{
    char name[128];
    return scp_class_name(obj, name, sizeof(name)) && strstr(name, needle);
}

// ---------------------------------------------------------------------------
// Trait collection helper
// ---------------------------------------------------------------------------

static uint64_t scp_trait_collection(int style)
{
    uint64_t cls = r_class("UITraitCollection");
    if (!r_is_objc_ptr(cls)) return 0;
    return r_msg2_main(cls, "traitCollectionWithUserInterfaceStyle:", (uint64_t)style, 0, 0, 0);
}

// ---------------------------------------------------------------------------
// Scan an object's memory for a float[4] run that looks like RGBA (a~1.0)
// and return its address.  Used as fallback when ivar names are unknown.
// ---------------------------------------------------------------------------

static uint64_t scp_scan_rgba_in_obj(uint64_t obj, float knownR, float knownG, float knownB)
{
    if (!r_is_objc_ptr(obj)) return 0;
    for (uint64_t off = 8; off + 16 <= 256; off += 4) {
        float f[4];
        scp_read_rgba(obj + off, f);
        if (fabsf(f[0] - knownR) < SCP_RGBA_EPSILON &&
            fabsf(f[1] - knownG) < SCP_RGBA_EPSILON &&
            fabsf(f[2] - knownB) < SCP_RGBA_EPSILON &&
            fabsf(f[3] - 1.0f)   < SCP_RGBA_EPSILON) {
            return obj + off;
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Patch a single UIColor object's in-memory RGBA
// ---------------------------------------------------------------------------

// Try to find and patch the float[4] RGBA in a resolved UIColor or
// CUINamedColorRepresentation object.
// knownR/G/B are the expected stock values so we can verify we found the
// right spot and save the originals.
static bool scp_patch_color_obj(uint64_t colorObj, SCPColor replacement,
                                 float knownR, float knownG, float knownB,
                                 const char *tag)
{
    if (!r_is_objc_ptr(colorObj)) return false;

    // Try known ivar names for the RGBA backing store across iOS versions
    const char *ivarCandidates[] = {
        "_red", "_green", "_blue", "_alpha",   // UIDeviceRGBColor (iOS 13-16)
        "red",  "green",  "blue",  "alpha",
        NULL
    };

    // First try structured ivar access: look for _red ivar
    uint64_t redAddr = 0;
    for (int i = 0; ivarCandidates[i]; i += 4) {
        uint64_t ra = scp_ivar_ptr(colorObj, ivarCandidates[i]);
        if (!ra) continue;
        float rv = scp_read_float(ra);
        if (fabsf(rv - knownR) < SCP_RGBA_EPSILON) {
            redAddr = ra;
            printf("[SCP] %s: found via ivar '%s' @ 0x%llx val=%.3f\n",
                   tag, ivarCandidates[i], ra, rv);
            break;
        }
    }

    // Fallback: scan the object memory for the RGBA float run
    if (!redAddr) {
        uint64_t scanAddr = scp_scan_rgba_in_obj(colorObj, knownR, knownG, knownB);
        if (scanAddr) {
            redAddr = scanAddr;
            printf("[SCP] %s: found via scan @ 0x%llx\n", tag, scanAddr);
        }
    }

    if (!redAddr) {
        printf("[SCP] %s: could not locate RGBA fields in obj 0x%llx\n", tag, colorObj);
        return false;
    }

    // Save original values
    float orig[4];
    scp_read_rgba(redAddr, orig);
    printf("[SCP] %s: original (%.3f,%.3f,%.3f,%.3f) -> patching (%.3f,%.3f,%.3f,%.3f)\n",
           tag, orig[0], orig[1], orig[2], orig[3],
           replacement.r, replacement.g, replacement.b, replacement.a);

    for (int i = 0; i < 4; i++) {
        scp_save(redAddr + (uint64_t)(i * 4), orig[i]);
    }

    return scp_write_rgba(redAddr, replacement);
}

// ---------------------------------------------------------------------------
// Walk _UIAssetManager -> CUICatalog to find a named color's rendition
// ---------------------------------------------------------------------------

// Try to get the shared asset manager
static uint64_t scp_asset_manager(void)
{
    // _UIAssetManager is the SpringBoard-side catalog holder
    uint64_t cls = r_class("_UIAssetManager");
    if (r_is_objc_ptr(cls) && r_responds_main(cls, "sharedAssetManager")) {
        uint64_t mgr = r_msg2_main(cls, "sharedAssetManager", 0, 0, 0, 0);
        if (r_is_objc_ptr(mgr)) {
            printf("[SCP] got _UIAssetManager sharedAssetManager\n");
            return mgr;
        }
    }
    // Fallback: some iOS versions expose it differently
    cls = r_class("UIAssetManager");
    if (r_is_objc_ptr(cls) && r_responds_main(cls, "sharedAssetManager")) {
        uint64_t mgr = r_msg2_main(cls, "sharedAssetManager", 0, 0, 0, 0);
        if (r_is_objc_ptr(mgr)) {
            printf("[SCP] got UIAssetManager sharedAssetManager\n");
            return mgr;
        }
    }
    printf("[SCP] asset manager not found\n");
    return 0;
}

// Try ivar names for the CUICatalog inside _UIAssetManager
static uint64_t scp_catalog(uint64_t assetMgr)
{
    const char *ivarNames[] = { "_catalog", "catalog", "_assetCatalog", NULL };
    for (int i = 0; ivarNames[i]; i++) {
        uint64_t val = scp_read_ivar_obj(assetMgr, ivarNames[i]);
        if (r_is_objc_ptr(val)) {
            printf("[SCP] catalog via ivar '%s' = 0x%llx\n", ivarNames[i], val);
            return val;
        }
    }
    // Also try message
    if (r_responds_main(assetMgr, "catalog")) {
        uint64_t val = r_msg2_main(assetMgr, "catalog", 0, 0, 0, 0);
        if (r_is_objc_ptr(val)) {
            printf("[SCP] catalog via -catalog msg = 0x%llx\n", val);
            return val;
        }
    }
    printf("[SCP] catalog not found in assetMgr 0x%llx\n", assetMgr);
    return 0;
}

// Get the named color object from the catalog by color name key
static uint64_t scp_named_color(uint64_t catalog, const char *name)
{
    if (!r_is_objc_ptr(catalog) || !name) return 0;

    // CUICatalog -namedColorWithName: or -colorForName: or -colorWithName:
    const char *selectors[] = {
        "namedColorWithName:",
        "colorForName:",
        "colorWithName:",
        "_namedColorWithName:",
        NULL
    };
    uint64_t nsName = r_nsstr_retained(name);
    if (!r_is_objc_ptr(nsName)) return 0;

    uint64_t result = 0;
    for (int i = 0; selectors[i]; i++) {
        if (!r_responds_main(catalog, selectors[i])) continue;
        result = r_msg2_main(catalog, selectors[i], nsName, 0, 0, 0);
        if (r_is_objc_ptr(result)) {
            printf("[SCP] namedColor '%s' via -%s = 0x%llx\n", name, selectors[i], result);
            break;
        }
    }

    r_msg2(nsName, "release", 0, 0, 0, 0);
    return result;
}

// ---------------------------------------------------------------------------
// Main patch function for one named color
// ---------------------------------------------------------------------------

static bool scp_patch_named_color(const char *uiColorSelector,
                                   const char *catalogName,
                                   SCPColor light, SCPColor dark,
                                   float stockLightR, float stockLightG, float stockLightB,
                                   float stockDarkR,  float stockDarkG,  float stockDarkB)
{
    printf("[SCP] patching '%s'\n", uiColorSelector);

    uint64_t uiColorCls = r_class("UIColor");
    if (!r_is_objc_ptr(uiColorCls)) return false;

    // Get the UIColor singleton
    if (!r_responds_main(uiColorCls, uiColorSelector)) {
        printf("[SCP]   UIColor does not respond to +%s\n", uiColorSelector);
        return false;
    }
    uint64_t colorObj = r_msg2_main(uiColorCls, uiColorSelector, 0, 0, 0, 0);
    if (!r_is_objc_ptr(colorObj)) {
        printf("[SCP]   +%s returned nil\n", uiColorSelector);
        return false;
    }
    usleep(SCP_SETTLE_US);

    // Resolve to concrete color for each appearance
    uint64_t tcLight = scp_trait_collection(SCP_STYLE_LIGHT);
    uint64_t tcDark  = scp_trait_collection(SCP_STYLE_DARK);
    usleep(SCP_SETTLE_US);

    uint64_t resolvedLight = 0, resolvedDark = 0;
    if (r_responds_main(colorObj, "resolvedColorWithTraitCollection:")) {
        resolvedLight = r_msg2_main(colorObj, "resolvedColorWithTraitCollection:", tcLight, 0, 0, 0);
        usleep(SCP_SETTLE_US);
        resolvedDark  = r_msg2_main(colorObj, "resolvedColorWithTraitCollection:", tcDark,  0, 0, 0);
        usleep(SCP_SETTLE_US);
    }

    // If resolution gives back same pointer (static color) or nil, use the object itself
    if (!r_is_objc_ptr(resolvedLight)) resolvedLight = colorObj;
    if (!r_is_objc_ptr(resolvedDark))  resolvedDark  = colorObj;

    printf("[SCP]   light=0x%llx dark=0x%llx\n", resolvedLight, resolvedDark);

    char clsName[128];
    scp_class_name(resolvedLight, clsName, sizeof(clsName));
    printf("[SCP]   light class: %s\n", clsName);

    bool okLight = scp_patch_color_obj(resolvedLight, light,
                                        stockLightR, stockLightG, stockLightB,
                                        "light");
    usleep(SCP_SETTLE_US);

    bool okDark = (resolvedDark == resolvedLight)
        ? true // same object patched above; dark shares the same struct
        : scp_patch_color_obj(resolvedDark, dark,
                               stockDarkR, stockDarkG, stockDarkB,
                               "dark");
    usleep(SCP_SETTLE_US);

    // Also try via CUICatalog for the cases where the resolved color does
    // not expose RGBA ivars directly (iOS 17+ CUINamedColor path)
    if (!okLight || !okDark) {
        printf("[SCP]   direct patch %s, trying CUICatalog path\n",
               (!okLight && !okDark) ? "failed" : "partial");

        uint64_t assetMgr = scp_asset_manager();
        usleep(SCP_SETTLE_US);
        uint64_t catalog  = r_is_objc_ptr(assetMgr) ? scp_catalog(assetMgr) : 0;
        usleep(SCP_SETTLE_US);

        if (r_is_objc_ptr(catalog)) {
            uint64_t namedColor = scp_named_color(catalog, catalogName);
            usleep(SCP_SETTLE_US);

            if (r_is_objc_ptr(namedColor)) {
                // CUINamedColor holds an array of representations
                // Try _representations ivar -> NSArray -> CUINamedColorRepresentation
                uint64_t repsIvar = scp_ivar_ptr(namedColor, "_representations");
                uint64_t reps = repsIvar ? remote_read64(repsIvar) : 0;

                if (!r_is_objc_ptr(reps) && r_responds_main(namedColor, "representations")) {
                    reps = r_msg2_main(namedColor, "representations", 0, 0, 0, 0);
                }

                if (r_is_objc_ptr(reps) && r_responds(reps, "count")) {
                    uint64_t count = r_msg2(reps, "count", 0, 0, 0, 0);
                    if (count > 8) count = 8;
                    printf("[SCP]   CUINamedColor reps count=%llu\n", count);

                    for (uint64_t i = 0; i < count; i++) {
                        uint64_t rep = r_msg2(reps, "objectAtIndex:", i, 0, 0, 0);
                        if (!r_is_objc_ptr(rep)) continue;

                        // Each representation has a _color ivar (UIColor*)
                        uint64_t repColorIvar = scp_ivar_ptr(rep, "_color");
                        uint64_t repColor = repColorIvar ? remote_read64(repColorIvar) : 0;
                        if (!r_is_objc_ptr(repColor)) {
                            if (r_responds_main(rep, "color"))
                                repColor = r_msg2_main(rep, "color", 0, 0, 0, 0);
                        }

                        char repCls[128];
                        scp_class_name(rep, repCls, sizeof(repCls));
                        printf("[SCP]   rep[%llu] class=%s repColor=0x%llx\n",
                               i, repCls, repColor);

                        if (!r_is_objc_ptr(repColor)) continue;

                        // Determine appearance of this rep
                        // _userInterfaceStyle ivar: 1=light 2=dark 0=any
                        uint64_t styleAddr = scp_ivar_ptr(rep, "_userInterfaceStyle");
                        int style = styleAddr ? (int)(remote_read64(styleAddr) & 0xFF) : 0;
                        bool isDark = (style == SCP_STYLE_DARK);
                        SCPColor col = isDark ? dark : light;
                        float expectR = isDark ? stockDarkR : stockLightR;
                        float expectG = isDark ? stockDarkG : stockLightG;
                        float expectB = isDark ? stockDarkB : stockLightB;

                        char repTag[32];
                        snprintf(repTag, sizeof(repTag), "rep[%llu]%s", i, isDark ? "-dark" : "-light");
                        bool ok = scp_patch_color_obj(repColor, col,
                                                       expectR, expectG, expectB, repTag);
                        if (ok) { okLight = true; okDark = true; }
                        usleep(SCP_SETTLE_US);
                    }
                } else {
                    // Fallback: scan namedColor itself for RGBA
                    bool ok = scp_patch_color_obj(namedColor, light,
                                                   stockLightR, stockLightG, stockLightB,
                                                   "namedColor-scan");
                    if (ok) okLight = true;
                }
            }
        }
    }

    // Flush UIColor resolved-color cache.
    // iOS 17: _clearCaches on UIColor class.
    // iOS 18: _clearCaches was removed; instead invalidate via
    //         UIColorTransformEnvironment or just post a trait-change
    //         notification by toggling overrideUserInterfaceStyle.
    if (r_is_objc_ptr(uiColorCls)) {
        if (r_responds_main(uiColorCls, "_clearCaches")) {
            r_msg2_main(uiColorCls, "_clearCaches", 0, 0, 0, 0);
        }
        // iOS 18 fallback: hit the shared asset manager's cache invalidation
        uint64_t amCls = r_class("_UIAssetManager");
        if (!r_is_objc_ptr(amCls)) amCls = r_class("UIAssetManager");
        if (r_is_objc_ptr(amCls)) {
            uint64_t am = r_msg2_main(amCls, "sharedAssetManager", 0, 0, 0, 0);
            if (r_is_objc_ptr(am) && r_responds_main(am, "invalidateAllCaches")) {
                r_msg2_main(am, "invalidateAllCaches", 0, 0, 0, 0);
            }
            if (r_is_objc_ptr(am) && r_responds_main(am, "_invalidateCachedColors")) {
                r_msg2_main(am, "_invalidateCachedColors", 0, 0, 0, 0);
            }
        }
        usleep(SCP_SETTLE_US);
    }

    printf("[SCP]   '%s' light=%s dark=%s\n", uiColorSelector,
           okLight ? "ok" : "warn", okDark ? "ok" : "warn");
    return okLight || okDark;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

bool syscolpatcher_apply_in_session(SCPColor light, SCPColor dark)
{
    printf("[SCP] apply light(%.3f,%.3f,%.3f,%.3f) dark(%.3f,%.3f,%.3f,%.3f)\n",
           light.r, light.g, light.b, light.a,
           dark.r,  dark.g,  dark.b,  dark.a);

    bool ok = false;

    // systemBlueColor: stock light ~(0.00, 0.478, 1.00, 1.0)
    //                  stock dark  ~(0.04, 0.518, 1.00, 1.0)
    ok |= scp_patch_named_color("systemBlueColor", "systemBlue",
                                  light, dark,
                                  0.000f, 0.478f, 1.000f,
                                  0.039f, 0.518f, 1.000f);
    usleep(SCP_SETTLE_US);

    // systemTintColor (same slot on most iOS versions)
    ok |= scp_patch_named_color("systemTintColor", "systemTint",
                                  light, dark,
                                  0.000f, 0.478f, 1.000f,
                                  0.039f, 0.518f, 1.000f);
    usleep(SCP_SETTLE_US);

    // systemIndigoColor: stock light ~(0.345, 0.337, 0.839, 1.0)
    //                    stock dark  ~(0.369, 0.361, 0.902, 1.0)
    // Only patch indigo if caller wants a noticeably different tint
    if (fabsf(light.b - 1.0f) > 0.1f || fabsf(light.r - 0.0f) > 0.1f) {
        ok |= scp_patch_named_color("systemIndigoColor", "systemIndigo",
                                      light, dark,
                                      0.345f, 0.337f, 0.839f,
                                      0.369f, 0.361f, 0.902f);
        usleep(SCP_SETTLE_US);
    }

    printf("[SCP] apply done ok=%d saves=%d\n", (int)ok, g_save_count);
    return ok;
}

bool syscolpatcher_reset_in_session(void)
{
    printf("[SCP] reset: restoring %d saved floats\n", g_save_count);
    int restored = 0;
    for (int i = 0; i < g_save_count; i++) {
        if (!g_saves[i].active) continue;
        if (scp_write_float(g_saves[i].addr, g_saves[i].original)) {
            restored++;
            g_saves[i].active = false;
        }
    }
    g_save_count = 0;

    // Flush cache
    uint64_t uiColorCls = r_class("UIColor");
    if (r_is_objc_ptr(uiColorCls) && r_responds_main(uiColorCls, "_clearCaches")) {
        r_msg2_main(uiColorCls, "_clearCaches", 0, 0, 0, 0);
    }

    printf("[SCP] reset done restored=%d\n", restored);
    return restored > 0;
}

void syscolpatcher_forget_remote_state(void)
{
    memset(g_saves, 0, sizeof(g_saves));
    g_save_count = 0;
    printf("[SCP] forgot remote state\n");
}
