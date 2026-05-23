//
//  UpdateChecker.m
//  Cyanide
//

#import "UpdateChecker.h"

static NSString * const kReleasesAPI             = @"https://api.github.com/repos/zeroxjf/cyanide-ios/releases/latest";
static NSString * const kUpdateSkippedVersionKey = @"installer.update.skippedVersion";
static NSString * const kUpdateSnoozeUntilKey    = @"installer.update.snoozeUntil";
static const NSTimeInterval kSnoozeDuration      = 24 * 60 * 60; // 24h

@interface UpdateChecker ()
@property (nonatomic, assign) BOOL didCheckThisLaunch;
@end

@implementation UpdateChecker

+ (instancetype)shared
{
    static UpdateChecker *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[UpdateChecker alloc] init]; });
    return s;
}

- (NSString *)currentVersion
{
    NSString *v = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"];
    return v.length > 0 ? v : @"0";
}

- (NSString *)normalizeTag:(NSString *)tag
{
    if ([tag hasPrefix:@"v"] || [tag hasPrefix:@"V"]) {
        return [tag substringFromIndex:1];
    }
    return tag;
}

static int compare_versions(NSString *a, NSString *b)
{
    NSArray<NSString *> *aParts = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *bParts = [b componentsSeparatedByString:@"."];
    NSUInteger n = MAX(aParts.count, bParts.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger ai = (i < aParts.count) ? [aParts[i] integerValue] : 0;
        NSInteger bi = (i < bParts.count) ? [bParts[i] integerValue] : 0;
        if (ai < bi) return -1;
        if (ai > bi) return 1;
    }
    return 0;
}

- (void)checkForUpdatesIfNeededFrom:(UIViewController *)presenter
{
    if (self.didCheckThisLaunch) return;
    self.didCheckThisLaunch = YES;
    if (!presenter) return;

    printf("[UPDATE] checking latest release (current=%s)\n",
           self.currentVersion.UTF8String);

    NSURL *url = [NSURL URLWithString:kReleasesAPI];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:10.0];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error)
    {
        if (error || !data) {
            printf("[UPDATE] check failed: %s\n",
                   error ? error.localizedDescription.UTF8String : "no data");
            return;
        }
        NSError *jsonErr = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr || ![obj isKindOfClass:NSDictionary.class]) {
            printf("[UPDATE] release JSON parse failed\n");
            return;
        }
        NSDictionary *release = obj;
        NSString *tag     = release[@"tag_name"];
        NSString *htmlURL = release[@"html_url"];
        id bodyObj        = release[@"body"];
        NSString *body    = [bodyObj isKindOfClass:NSString.class] ? (NSString *)bodyObj : nil;
        if (![tag isKindOfClass:NSString.class] || ![htmlURL isKindOfClass:NSString.class]) return;

        __strong typeof(weakSelf) self_ = weakSelf;
        if (!self_) return;

        NSString *latest  = [self_ normalizeTag:tag];
        NSString *current = [self_ currentVersion];
        if (compare_versions(latest, current) <= 0) {
            printf("[UPDATE] already on latest (current=%s latest=%s)\n",
                   current.UTF8String, latest.UTF8String);
            return;
        }

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *skipped = [d stringForKey:kUpdateSkippedVersionKey];
        if (skipped && [skipped isEqualToString:latest]) {
            printf("[UPDATE] version %s skipped by user; not prompting\n", latest.UTF8String);
            return;
        }
        NSDate *snoozeUntil = [d objectForKey:kUpdateSnoozeUntilKey];
        if ([snoozeUntil isKindOfClass:NSDate.class] && [snoozeUntil compare:[NSDate date]] == NSOrderedDescending) {
            printf("[UPDATE] snoozed until %s; not prompting\n", snoozeUntil.description.UTF8String);
            return;
        }

        printf("[UPDATE] new release available: %s (current %s)\n",
               latest.UTF8String, current.UTF8String);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self_ presentUpdateAlertFrom:presenter
                                   latest:latest
                                  current:current
                                      url:htmlURL
                                    notes:body];
        });
    }];
    [task resume];
}

- (void)checkForUpdatesManuallyFrom:(UIViewController *)presenter
{
    if (!presenter) return;

    printf("[UPDATE] manual check requested (current=%s)\n",
           self.currentVersion.UTF8String);

    UIAlertController *checking = [UIAlertController
        alertControllerWithTitle:@"Checking for Updates…"
                         message:@"\n\n"
                  preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spin =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spin.translatesAutoresizingMaskIntoConstraints = NO;
    [spin startAnimating];
    [checking.view addSubview:spin];
    [NSLayoutConstraint activateConstraints:@[
        [spin.centerXAnchor constraintEqualToAnchor:checking.view.centerXAnchor],
        [spin.bottomAnchor  constraintEqualToAnchor:checking.view.bottomAnchor constant:-20],
    ]];

    UIViewController *top = presenter;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:checking animated:YES completion:nil];

    NSURL *url = [NSURL URLWithString:kReleasesAPI];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:10.0];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error)
    {
        __strong typeof(weakSelf) self_ = weakSelf;
        NSString *current = self_ ? [self_ currentVersion] : @"unknown";

        NSString *failureReason = nil;
        NSString *latest = nil;
        NSString *htmlURL = nil;
        NSString *notes = nil;

        if (error || !data) {
            failureReason = error ? error.localizedDescription : @"No response from GitHub.";
        } else {
            NSError *jsonErr = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (jsonErr || ![obj isKindOfClass:NSDictionary.class]) {
                failureReason = @"Could not parse the release feed.";
            } else {
                NSDictionary *release = obj;
                id tagObj  = release[@"tag_name"];
                id urlObj  = release[@"html_url"];
                id bodyObj = release[@"body"];
                if (![tagObj isKindOfClass:NSString.class] || ![urlObj isKindOfClass:NSString.class]) {
                    failureReason = @"Release feed was missing fields.";
                } else {
                    latest  = self_ ? [self_ normalizeTag:tagObj] : tagObj;
                    htmlURL = urlObj;
                    notes   = [bodyObj isKindOfClass:NSString.class] ? bodyObj : nil;
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [checking dismissViewControllerAnimated:YES completion:^{
                if (failureReason) {
                    printf("[UPDATE] manual check failed: %s\n", failureReason.UTF8String);
                    UIAlertController *ac = [UIAlertController
                        alertControllerWithTitle:@"Check Failed"
                                         message:[NSString stringWithFormat:
                                                  @"Couldn't reach GitHub.\n\n%@", failureReason]
                                  preferredStyle:UIAlertControllerStyleAlert];
                    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
                    UIViewController *top2 = presenter;
                    while (top2.presentedViewController) top2 = top2.presentedViewController;
                    [top2 presentViewController:ac animated:YES completion:nil];
                    return;
                }

                if (compare_versions(latest, current) <= 0) {
                    printf("[UPDATE] manual check: up to date (current=%s latest=%s)\n",
                           current.UTF8String, latest.UTF8String);
                    UIAlertController *ac = [UIAlertController
                        alertControllerWithTitle:@"Up to Date"
                                         message:[NSString stringWithFormat:
                                                  @"You're on the latest release.\n\nInstalled: %@\nLatest: %@",
                                                  current, latest]
                                  preferredStyle:UIAlertControllerStyleAlert];
                    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
                    UIViewController *top2 = presenter;
                    while (top2.presentedViewController) top2 = top2.presentedViewController;
                    [top2 presentViewController:ac animated:YES completion:nil];
                    return;
                }

                printf("[UPDATE] manual check: update available %s (current %s)\n",
                       latest.UTF8String, current.UTF8String);
                if (self_) {
                    [self_ presentUpdateAlertFrom:presenter
                                           latest:latest
                                          current:current
                                              url:htmlURL
                                            notes:notes];
                }
            }];
        });
    }];
    [task resume];
}

- (void)presentUpdateAlertFrom:(UIViewController *)presenter
                        latest:(NSString *)latest
                       current:(NSString *)current
                           url:(NSString *)urlString
                         notes:(NSString *)notes
{
    UIViewController *top = presenter;
    while (top.presentedViewController) top = top.presentedViewController;

    NSMutableString *message = [NSMutableString string];
    [message appendFormat:@"A new release of Cyanide is available.\n\nLatest: %@\nInstalled: %@",
                          latest, current];

    NSString *trimmed = [notes stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > 0) {
        // UIAlertController plain-text view doesn't render markdown; strip the
        // few markers that show up in our release notes so the body reads
        // clean, then cap length so the alert stays scannable.
        NSMutableString *clean = [trimmed mutableCopy];
        [clean replaceOccurrencesOfString:@"\r\n" withString:@"\n"
                                  options:0 range:NSMakeRange(0, clean.length)];
        [clean replaceOccurrencesOfString:@"**"   withString:@""
                                  options:0 range:NSMakeRange(0, clean.length)];
        [clean replaceOccurrencesOfString:@"`"    withString:@""
                                  options:0 range:NSMakeRange(0, clean.length)];
        NSString *body = clean;
        const NSUInteger kMaxNotesChars = 800;
        if (body.length > kMaxNotesChars) {
            body = [[body substringToIndex:kMaxNotesChars - 1] stringByAppendingString:@"…"];
        }
        [message appendFormat:@"\n\nWhat's new:\n%@", body];
    } else {
        [message appendString:@"\n\nUpdates ship as sideloadable IPAs on GitHub Releases."];
    }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Update Available"
                                                                message:message
                                                         preferredStyle:UIAlertControllerStyleAlert];

    [ac addAction:[UIAlertAction actionWithTitle:@"View Release"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *_) {
        NSURL *u = [NSURL URLWithString:urlString];
        if (!u) return;
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"Remind Me Later"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *_) {
        NSDate *until = [[NSDate date] dateByAddingTimeInterval:kSnoozeDuration];
        [[NSUserDefaults standardUserDefaults] setObject:until forKey:kUpdateSnoozeUntilKey];
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"Skip This Version"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *_) {
        [[NSUserDefaults standardUserDefaults] setObject:latest forKey:kUpdateSkippedVersionKey];
    }]];

    [top presentViewController:ac animated:YES completion:nil];
}

@end
