//
//  doodlelite.h
//  Draw-to-unlock: installs a canvas UIWindow on the SpringBoard lock screen
//  via the RemoteCall bridge.  The user draws a shape; if it matches the
//  stored gesture (by shape similarity score) the lock is dismissed.
//
//  All state is in-session only.
//

#ifndef doodlelite_h
#define doodlelite_h

#import <stdbool.h>
#import <stdint.h>

// Install / refresh the doodle canvas on the lock screen.
// Call once after a session starts; the canvas persists until
// doodlelite_stop_in_session() is called.
bool doodlelite_start_in_session(void);

// Remove the canvas window from SpringBoard.
bool doodlelite_stop_in_session(void);

// Forget cached remote pointers (call after destroy_remote_call).
void doodlelite_forget_remote_state(void);

#endif /* doodlelite_h */
