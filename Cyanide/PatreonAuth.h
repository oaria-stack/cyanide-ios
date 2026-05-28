//
//  PatreonAuth.h
//  Cyanide
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main queue whenever linked status, display name, tier title,
// or pledge cents changes. No object/userInfo — observers re-read via the
// helpers below.
extern NSString * const kCyanidePatreonStatusDidChangeNotification;

// Public Patreon URL where users can join the supporter tier. Used by
// Settings to deep-link users who linked their account but aren't pledging
// — they need to actually pledge on patreon.com to unlock supporter
// features.
NSURL *cyanide_patreon_join_url(void);

// YES iff the user has linked a Patreon account at all (regardless of
// current pledge state). Reading is cheap (NSUserDefaults).
BOOL cyanide_patreon_is_linked(void);

// YES iff the linked account is currently an active patron pledging > 0
// cents to the Cyanide campaign. Reads cached value — call
// cyanide_patreon_refresh() to revalidate against the Patreon API.
BOOL cyanide_is_patron(void);

// Display name from /identity (e.g. "Johnny F"), nil if not linked.
NSString * _Nullable cyanide_patreon_display_name(void);

// Highest currently-entitled tier title for the Cyanide campaign, nil if
// none or not linked.
NSString * _Nullable cyanide_patreon_tier_title(void);

// Currently-entitled pledge amount in cents (0 if not pledged or not linked).
NSInteger cyanide_patreon_pledge_cents(void);

// Last successful /identity refresh timestamp, nil if never refreshed.
NSDate * _Nullable cyanide_patreon_last_refresh_date(void);

// Presents the OAuth flow anchored to `presenter`'s window. `completion`
// fires on the main queue once the cached status has been updated (or with
// an error).
void cyanide_patreon_authenticate(UIViewController *presenter,
                                  void (^_Nullable completion)(BOOL success, NSError * _Nullable error));

// Clears tokens and cached status. Posts the status-changed notification.
void cyanide_patreon_sign_out(void);

// Re-fetches /identity if a refresh token is available. No-op if not linked.
// `completion` fires on the main queue. Updates cached status & posts the
// notification only if status actually changed.
void cyanide_patreon_refresh(void (^_Nullable completion)(BOOL success, NSError * _Nullable error));

NS_ASSUME_NONNULL_END
