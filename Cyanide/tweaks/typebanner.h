//
//  typebanner.h
//  TypeMillennium port: detect iMessage typing from MobileSMS via RemoteCall,
//  show a Dynamic-Island-style banner in SpringBoard via RemoteCall.
//
//  v1 limitation: detection is MobileSMS-side only (the original BarTypeMessages
//  half), so it requires Messages.app to be running. The system-wide imagent
//  side from BarTypeDaemon is not portable to this env without code injection.
//

#ifndef typebanner_h
#define typebanner_h

#import <stdbool.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>

// SpringBoard-side: show the typing banner with the given display name.
// Must be called inside an init_remote_call("SpringBoard", ...) session.
// Pass nil/empty to render as "Someone is typing…".
bool typebanner_show_in_springboard_session(NSString *displayName);

// SpringBoard-side: fade out and hide the banner. Idempotent.
// Must be called inside an init_remote_call("SpringBoard", ...) session.
bool typebanner_hide_in_springboard_session(void);

// MobileSMS-side: walk the active view hierarchy and return the typing
// display name if any conversation row / open conversation is currently
// showing a typing indicator. Returns nil if nothing is typing.
// Must be called inside an init_remote_call("MobileSMS", ...) session.
NSString *typebanner_poll_in_mobilesms_session(void);

// MobileSMS-side: walk the view hierarchy and log the class name and a
// summary of typing-related selectors for every UITableViewCell-shaped view.
// Use for one-shot diagnostics when the regular poll returns nothing.
// Must be called inside an init_remote_call("MobileSMS", ...) session.
void typebanner_diagnose_in_mobilesms_session(void);
#endif

// One-shot orchestration from Cyanide's process. Tears down any existing
// RemoteCall session, polls MobileSMS, then drives the SpringBoard banner.
// Safe to call from a background queue.
bool typebanner_run_once(void);

// Drop cached remote handles. Call when SpringBoard or MobileSMS may have died.
void typebanner_forget_remote_state(void);

#endif
