//
//  syscolpatcher.h
//  Patches system semantic colors live in SpringBoard's process memory via
//  the RemoteCall bridge, following the same ds_poke_*_ivar pattern used
//  by darksword_tweaks.
//
//  The in-RAM target is the CUINamedColor rendition objects held by the
//  shared CUICatalog (_UIAssetManager) that CoreUI uses to resolve named
//  colors such as systemBlue, label, tint, etc.  We walk:
//
//    _UIAssetManager sharedAssetManager
//      -> CUICatalog
//        -> CUICommonAssetStorage  (internal storage object)
//          -> rendition map keyed by name
//            -> CUINamedColor  (holds float[4] RGBA per appearance)
//
//  All patching is in-session only. Call syscolpatcher_reset_in_session()
//  to restore original values before respringing.
//
//  Color channels are floats in 0.0–1.0.
//

#ifndef syscolpatcher_h
#define syscolpatcher_h

#import <stdbool.h>

typedef struct {
    float r, g, b, a;
} SCPColor;

// Patch named system colors in the live SpringBoard process.
// Walks CUICatalog -> CUINamedColor and writes RGBA floats directly into
// the rendition's backing store for both light and dark appearances.
bool syscolpatcher_apply_in_session(SCPColor light, SCPColor dark);

// Restore all in-session patches to their original values.
bool syscolpatcher_reset_in_session(void);

// Forget cached remote pointers (call after destroy_remote_call).
void syscolpatcher_forget_remote_state(void);

#endif /* syscolpatcher_h */
