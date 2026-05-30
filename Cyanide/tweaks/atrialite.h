//
//  atrialite.h
//  RemoteCall-only Atria-style layout preset.
//  Grid: dock 1-12, cols 1-12, rows 1-12.
//  Scale: 20-200 (%), offsetY: -120 to +120 pts.
//

#ifndef atrialite_h
#define atrialite_h

#import <stdbool.h>

bool atrialite_apply_in_session(int dockIcons, int hsCols, int hsRows, bool hideLabels, int iconScalePercent, int iconOffsetY);
bool atrialite_stop_in_session(void);
void atrialite_forget_remote_state(void);

#endif /* atrialite_h */
