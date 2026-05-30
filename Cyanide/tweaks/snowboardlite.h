//
//  snowboardlite.h
//  RemoteCall-only icon styling pass.
//

#ifndef snowboardlite_h
#define snowboardlite_h

#import <stdbool.h>

bool snowboardlite_apply_in_session(void);
bool snowboardlite_stop_in_session(void);
void snowboardlite_forget_remote_state(void);

#endif /* snowboardlite_h */
