//
//  iconshapeslite.h
//  Custom icon shape masking via CAShapeLayer masks applied to SBIconView
//  image layers in the live SpringBoard process.
//
//  Shapes: squircle (stock), circle, square, rounded-square,
//          diamond, star (5-point), shield, teardrop.
//
//  All patching is in-session. Call iconshapeslite_reset_in_session() to
//  restore stock squircle masks before respringing.
//

#ifndef iconshapeslite_h
#define iconshapeslite_h

#import <stdbool.h>

typedef enum : int {
    ISLShapeSquircle     = 0,   // stock iOS continuous-corner squircle
    ISLShapeCircle       = 1,
    ISLShapeSquare       = 2,
    ISLShapeRoundedSquare= 3,   // standard rounded rect (non-continuous)
    ISLShapeDiamond      = 4,
    ISLShapeStar         = 5,
    ISLShapeShield       = 6,
    ISLShapeTeardrop     = 7,
} ISLShape;

// Apply shape to all currently loaded SBIconViews.
// cornerRadiusPct: only used for ISLShapeRoundedSquare (0–50, percent of icon size).
bool iconshapeslite_apply_in_session(ISLShape shape, int cornerRadiusPct);

// Restore stock squircle masks.
bool iconshapeslite_reset_in_session(void);

// Forget cached remote state (call after destroy_remote_call).
void iconshapeslite_forget_remote_state(void);

#endif /* iconshapeslite_h */
