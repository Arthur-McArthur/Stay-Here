// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arthur-McArthur
#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "SHDockNavigation.h"
#include <dlfcn.h>
#include <signal.h>
#include <math.h>

// These private APIs are resolved at runtime. No system Spaces preferences, app bindings,
// application bundles, or system files are changed by this helper.
typedef CFTypeRef (*SHCreateASN)(CFAllocatorRef, pid_t);
typedef CFTypeRef (*SHCopyAppItem)(int32_t, CFTypeRef, CFTypeRef);
typedef OSStatus (*SHSetAppItem)(int32_t, CFTypeRef, CFStringRef, CFTypeRef, CFDictionaryRef *);
typedef int (*SHConnection)(void);
typedef uint64_t (*SHActiveSpace)(int);
typedef CFArrayRef (*SHManagedSpaces)(int);
typedef CGError (*SHAssignSpace)(int, pid_t, uint64_t);

static double SHNow(void) { return NSProcessInfo.processInfo.systemUptime; }
static NSImage *SHMenuBarIcon(void) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [NSColor.blackColor set];
        NSBezierPath *screen = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1.25, 4.0, 13.5, 10.0) xRadius:1.6 yRadius:1.6];
        screen.lineWidth = 1.3;
        [screen stroke];
        [[NSBezierPath bezierPathWithRect:NSMakeRect(7.35, 1.5, 1.3, 2.5)] fill];
        NSBezierPath *base = [NSBezierPath bezierPath];
        [base moveToPoint:NSMakePoint(4.5, 1.5)];
        [base lineToPoint:NSMakePoint(11.5, 1.5)];
        base.lineWidth = 1.3;
        base.lineCapStyle = NSLineCapStyleRound;
        [base stroke];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(5.7, 11.0, 4.6, 1.3) xRadius:0.4 yRadius:0.4] fill];
        NSBezierPath *pin = [NSBezierPath bezierPath];
        [pin moveToPoint:NSMakePoint(6.8, 11.1)];
        [pin lineToPoint:NSMakePoint(9.2, 11.1)];
        [pin lineToPoint:NSMakePoint(9.2, 9.0)];
        [pin lineToPoint:NSMakePoint(10.3, 7.8)];
        [pin lineToPoint:NSMakePoint(5.7, 7.8)];
        [pin lineToPoint:NSMakePoint(6.8, 9.0)];
        [pin closePath];
        [pin fill];
        [[NSBezierPath bezierPathWithRect:NSMakeRect(7.45, 5.8, 1.1, 2.0)] fill];
        return YES;
    }];
    image.template = YES;
    image.accessibilityDescription = @"Stay Here — pinned desktop";
    return image;
}
static void SHLog(NSString *event, NSDictionary *fields) {
    NSMutableDictionary *record = [fields mutableCopy] ?: [NSMutableDictionary dictionary];
    record[@"event"] = event;
    record[@"time"] = @(SHNow());
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    if (data) { fwrite(data.bytes, 1, data.length, stdout); putchar('\n'); fflush(stdout); }
}
static BOOL SHIsTrue(id value) {
    return value && value != NSNull.null && CFEqual((__bridge CFTypeRef)value, kCFBooleanTrue);
}

@interface SHAPI : NSObject {
@public
    SHCreateASN createASN;
    SHCopyAppItem copyAppItem;
    SHSetAppItem setAppItem;
    SHActiveSpace activeSpace;
    SHManagedSpaces managedSpaces;
    SHAssignSpace assignSpace;
    int connection;
    CFStringRef persistenceKey;
    CFStringRef readyKey;
}
- (nullable instancetype)initWithError:(NSString **)error;
@end

@implementation SHAPI
- (instancetype)initWithError:(NSString **)error {
    self = [super init];
    if (!self) return nil;
    void *ls = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!ls || !sky) { if (error) *error = @"A required macOS framework is unavailable."; return nil; }
#define SH_LOAD_FUNCTION(field, type, handle, symbol) do { \
    field = (type)dlsym(handle, symbol); \
    if (!field) { if (error) *error = @"Missing macOS function: " @symbol; return nil; } \
} while (0)
    SH_LOAD_FUNCTION(createASN, SHCreateASN, ls, "_LSASNCreateWithPid");
    SH_LOAD_FUNCTION(copyAppItem, SHCopyAppItem, ls, "_LSCopyApplicationInformationItem");
    SH_LOAD_FUNCTION(setAppItem, SHSetAppItem, ls, "_LSSetApplicationInformationItem");
    SH_LOAD_FUNCTION(activeSpace, SHActiveSpace, sky, "SLSGetActiveSpace");
    SH_LOAD_FUNCTION(managedSpaces, SHManagedSpaces, sky, "SLSCopyManagedDisplaySpaces");
    SH_LOAD_FUNCTION(assignSpace, SHAssignSpace, sky, "SLSProcessAssignToSpace");
    SHConnection getConnection;
    SH_LOAD_FUNCTION(getConnection, SHConnection, sky, "SLSMainConnectionID");
#undef SH_LOAD_FUNCTION
    CFStringRef *persistence = dlsym(ls, "_kLSModifierLaunchedForPersistenceKey");
    CFStringRef *ready = dlsym(ls, "_kLSApplicationHasSignalledItIsReadyKey");
    if (!persistence || !*persistence || !ready || !*ready) {
        if (error) *error = @"Required macOS launch metadata is unavailable.";
        return nil;
    }
    persistenceKey = *persistence;
    readyKey = *ready;
    connection = getConnection();
    if (!connection) { if (error) *error = @"Cannot connect to this desktop session."; return nil; }
    return self;
}
@end

@interface SHLaunch : NSObject
@property(nonatomic, strong) NSRunningApplication *application;
@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, copy) NSURL *executableURL;
@property(nonatomic, copy, nullable) NSDate *launchDate;
@property(nonatomic) pid_t pid;
@property(nonatomic, strong) id asn;
@property(nonatomic, strong) id originalPersistence;
@property(nonatomic) BOOL changedPersistence;
@property(nonatomic) uint64_t originSpace;
@property(nonatomic) uint64_t targetSpace;
@property(nonatomic, strong, nullable) NSRunningApplication *priorForeground;
@property(nonatomic, copy, nullable) NSDate *priorForegroundLaunchDate;
@property(nonatomic) double didLaunchAt;
@property(nonatomic) double lastForegroundRestoreAt;
@property(nonatomic) BOOL readyObserved;
@end
@implementation SHLaunch
@end

@interface StayHere : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) SHAPI *api;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, SHLaunch *> *launches;
@property(nonatomic, strong) NSMutableArray *observers;
@property(nonatomic, strong, nullable) NSRunningApplication *lastForeground;
@property(nonatomic, strong, nullable) NSTimer *timer;
@property(nonatomic, strong, nullable) NSStatusItem *statusItem;
@property(nonatomic, strong, nullable) NSMenuItem *enabledItem;
@property(nonatomic, strong) SHDockNavigation *dockNavigation;
@property(nonatomic, strong) NSMenuItem *dockNavigationItem;
@property(nonatomic, strong) NSMutableArray *signalSources;
@property(nonatomic, copy, nullable) NSString *onlyBundle;
@property(nonatomic) BOOL headless;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL stopped;
@property(nonatomic) double duration;
@end

@implementation StayHere
- (instancetype)init {
    self = [super init];
    if (self) {
        _launches = [NSMutableDictionary dictionary];
        _observers = [NSMutableArray array];
        _signalSources = [NSMutableArray array];
        _enabled = YES;
    }
    return self;
}

- (id)readItem:(CFStringRef)key forLaunch:(SHLaunch *)launch {
    CFTypeRef value = self.api->copyAppItem(-2, (__bridge CFTypeRef)launch.asn, key);
    return value ? CFBridgingRelease(value) : NSNull.null;
}

- (BOOL)matchesIdentity:(SHLaunch *)launch {
    if (launch.application.terminated) return NO;
    NSRunningApplication *current = [NSRunningApplication runningApplicationWithProcessIdentifier:launch.pid];
    if (!current || current.terminated || ![current.bundleIdentifier isEqualToString:launch.bundleID]) return NO;
    if (launch.executableURL && ![current.executableURL isEqual:launch.executableURL]) return NO;
    if (launch.launchDate && current.launchDate && ![launch.launchDate isEqualToDate:current.launchDate]) return NO;
    CFTypeRef currentASN = self.api->createASN(NULL, launch.pid);
    BOOL matches = currentASN && CFEqual(currentASN, (__bridge CFTypeRef)launch.asn);
    if (currentASN) CFRelease(currentASN);
    if (matches && !launch.launchDate && current.launchDate) launch.launchDate = current.launchDate;
    return matches;
}

- (uint64_t)targetSpaceForBundle:(NSString *)bundleID {
    CFPreferencesAppSynchronize(CFSTR("com.apple.spaces"));
    CFPropertyListRef raw = CFPreferencesCopyAppValue(CFSTR("app-bindings"), CFSTR("com.apple.spaces"));
    id bindings = CFBridgingRelease(raw);
    if (![bindings isKindOfClass:NSDictionary.class]) return 0;
    id binding = bindings[bundleID.lowercaseString] ?: bindings[bundleID];
    if (![binding isKindOfClass:NSString.class] || ![NSUUID.alloc initWithUUIDString:binding]) return 0;
    NSString *wanted = [binding lowercaseString];
    CFArrayRef rawDisplays = self.api->managedSpaces(self.api->connection);
    NSArray *displays = CFBridgingRelease(rawDisplays);
    for (id display in displays) {
        if (![display isKindOfClass:NSDictionary.class]) continue;
        for (id space in display[@"Spaces"]) {
            if (![space isKindOfClass:NSDictionary.class] || [space[@"type"] integerValue] != 0) continue;
            id uuid = space[@"uuid"];
            if (![uuid isKindOfClass:NSString.class] || ![[uuid lowercaseString] isEqualToString:wanted]) continue;
            NSNumber *identifier = space[@"ManagedSpaceID"] ?: space[@"id64"];
            return [identifier isKindOfClass:NSNumber.class] ? identifier.unsignedLongLongValue : 0;
        }
    }
    return 0;
}

- (void)releaseLaunch:(SHLaunch *)launch reason:(NSString *)reason {
    if (self.launches[@(launch.pid)] != launch) return;
    if (launch.changedPersistence && [self matchesIdentity:launch]) {
        id current = [self readItem:self.api->persistenceKey forLaunch:launch];
        // An absent original flag is restored as false. Both mean ordinary
        // non-persistence launch behavior; no native app binding is altered.
        if (SHIsTrue(current)) {
            CFTypeRef original = launch.originalPersistence == NSNull.null ? kCFBooleanFalse : (__bridge CFTypeRef)launch.originalPersistence;
            OSStatus status = self.api->setAppItem(-2, (__bridge CFTypeRef)launch.asn, self.api->persistenceKey, original, NULL);
            id after = [self readItem:self.api->persistenceKey forLaunch:launch];
            SHLog(@"restore-launch-flag", @{@"pid": @(launch.pid), @"bundle": launch.bundleID,
                @"status": @(status), @"matchesOriginal": @(CFEqual((__bridge CFTypeRef)after, original))});
        }
    }
    [self.launches removeObjectForKey:@(launch.pid)];
    SHLog(@"release", @{@"pid": @(launch.pid), @"bundle": launch.bundleID, @"reason": reason});
}

- (void)restoreForegroundForLaunch:(SHLaunch *)launch {
    if (![self matchesIdentity:launch] || self.api->activeSpace(self.api->connection) != launch.originSpace) return;
    NSRunningApplication *prior = launch.priorForeground;
    if (!prior || prior.terminated || prior.processIdentifier == launch.pid) return;
    NSRunningApplication *currentPrior = [NSRunningApplication runningApplicationWithProcessIdentifier:prior.processIdentifier];
    if (!currentPrior || currentPrior.terminated || ![currentPrior.bundleIdentifier isEqual:prior.bundleIdentifier]) return;
    if (launch.priorForegroundLaunchDate && currentPrior.launchDate && ![launch.priorForegroundLaunchDate isEqualToDate:currentPrior.launchDate]) return;
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != launch.pid) return;
    double now = SHNow();
    if (now - launch.lastForegroundRestoreAt < 0.2) return;
    launch.lastForegroundRestoreAt = now;
    // This requests foreground focus only. No Space-switching API is called.
    BOOL accepted = [prior activateWithOptions:0];
    SHLog(@"restore-foreground", @{@"fromPID": @(launch.pid), @"toPID": @(prior.processIdentifier),
        @"originSpace": @(launch.originSpace), @"accepted": @(accepted)});
}

- (void)launchNotification:(NSNotification *)notification {
    NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
    if (!self.enabled || self.stopped || !app || app.terminated || !app.bundleIdentifier.length || app.processIdentifier == getpid()) return;
    // Plug-in scanners and other background-only children can share their
    // parent's bundle ID. They cannot own foreground focus or desktop windows.
    if (app.activationPolicy == NSApplicationActivationPolicyProhibited) return;
    if (self.onlyBundle && ![app.bundleIdentifier isEqualToString:self.onlyBundle]) return;
    NSNumber *pid = @(app.processIdentifier);
    SHLaunch *launch = self.launches[pid];
    if (launch && ![self matchesIdentity:launch]) { [self releaseLaunch:launch reason:@"identity-changed"]; launch = nil; }
    uint64_t currentSpace = self.api->activeSpace(self.api->connection);
    if (!launch) {
        uint64_t target = [self targetSpaceForBundle:app.bundleIdentifier];
        if (!target || target == currentSpace) return;
        CFTypeRef asn = self.api->createASN(NULL, app.processIdentifier);
        if (!asn) { SHLog(@"guard-unavailable", @{@"bundle": app.bundleIdentifier, @"reason": @"no-launch-identity"}); return; }
        launch = [SHLaunch new];
        launch.application = app;
        launch.pid = app.processIdentifier;
        launch.bundleID = app.bundleIdentifier;
        launch.executableURL = app.executableURL;
        launch.launchDate = app.launchDate;
        launch.asn = CFBridgingRelease(asn);
        launch.originSpace = currentSpace;
        launch.targetSpace = target;
        NSRunningApplication *prior = self.lastForeground;
        if (prior && !prior.terminated && prior.processIdentifier != launch.pid) {
            launch.priorForeground = prior;
            launch.priorForegroundLaunchDate = prior.launchDate;
        }
        launch.originalPersistence = [self readItem:self.api->persistenceKey forLaunch:launch];
        self.launches[pid] = launch;
    }
    if (currentSpace == launch.targetSpace) { [self releaseLaunch:launch reason:@"target-desktop-selected"]; return; }
    if ([notification.name isEqualToString:NSWorkspaceDidLaunchApplicationNotification] && !launch.didLaunchAt) launch.didLaunchAt = SHNow();
    if (![self matchesIdentity:launch]) { [self releaseLaunch:launch reason:@"identity-changed"]; return; }
    OSStatus status = self.api->setAppItem(-2, (__bridge CFTypeRef)launch.asn, self.api->persistenceKey, kCFBooleanTrue, NULL);
    id after = [self readItem:self.api->persistenceKey forLaunch:launch];
    if (!SHIsTrue(launch.originalPersistence) && SHIsTrue(after)) launch.changedPersistence = YES;
    if (status != noErr || !SHIsTrue(after)) {
        SHLog(@"guard-failed", @{@"bundle": launch.bundleID, @"pid": pid, @"step": @"launch-flag", @"status": @(status)});
        [self releaseLaunch:launch reason:@"launch-flag-failed"];
        return;
    }
    CGError assigned = self.api->assignSpace(self.api->connection, launch.pid, launch.targetSpace);
    SHLog(@"guard", @{@"bundle": launch.bundleID, @"pid": pid, @"notification": notification.name,
        @"originSpace": @(launch.originSpace), @"targetSpace": @(launch.targetSpace), @"flagStatus": @(status), @"assignStatus": @(assigned)});
    if (assigned != kCGErrorSuccess) { [self releaseLaunch:launch reason:@"process-assignment-failed"]; return; }
    [self restoreForegroundForLaunch:launch];
}

- (void)activationNotification:(NSNotification *)notification {
    NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
    if (!app || app.terminated || app.processIdentifier == getpid()) return;
    SHLaunch *launch = self.launches[@(app.processIdentifier)];
    if (launch) {
        if (self.api->activeSpace(self.api->connection) == launch.targetSpace) [self releaseLaunch:launch reason:@"target-desktop-selected"];
        else [self restoreForegroundForLaunch:launch];
        return;
    }
    self.lastForeground = app;
    uint64_t current = self.api->activeSpace(self.api->connection);
    for (SHLaunch *pending in self.launches.allValues) {
        if (current == pending.originSpace) {
            pending.priorForeground = app;
            pending.priorForegroundLaunchDate = app.launchDate;
        }
    }
}

- (void)tick {
    [self updateDockNavigationMenu];
    uint64_t current = self.api->activeSpace(self.api->connection);
    for (SHLaunch *launch in self.launches.allValues) {
        if (![self matchesIdentity:launch]) { [self releaseLaunch:launch reason:@"application-ended"]; continue; }
        if (current == launch.targetSpace) { [self releaseLaunch:launch reason:@"target-desktop-selected"]; continue; }
        BOOL ready = SHIsTrue([self readItem:self.api->readyKey forLaunch:launch]);
        if (ready && !launch.readyObserved) { launch.readyObserved = YES; SHLog(@"ready", @{@"pid": @(launch.pid), @"bundle": launch.bundleID}); }
        // The notification may be missed if it was coalesced, but a confirmed
        // finished application gives a conservative starting point for grace.
        if (!launch.didLaunchAt && ready && launch.application.finishedLaunching) launch.didLaunchAt = SHNow();
        if (ready && launch.didLaunchAt && SHNow() - launch.didLaunchAt >= 2.0) {
            [self restoreForegroundForLaunch:launch];
            [self releaseLaunch:launch reason:@"startup-complete"];
        }
    }
}

- (void)toggleEnabled:(id)sender {
    self.enabled = !self.enabled;
    self.dockNavigation.enabled = self.enabled && ![NSUserDefaults.standardUserDefaults boolForKey:@"DockNavigationDisabled"];
    self.enabledItem.state = self.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (!self.enabled) for (SHLaunch *launch in self.launches.allValues) [self releaseLaunch:launch reason:@"disabled"];
    SHLog(@"enabled", @{@"value": @(self.enabled)});
}
- (void)updateDockNavigationMenu {
    BOOL permission = [self.dockNavigation hasPermission];
    self.dockNavigationItem.title = permission ? @"One-click Dock switching" : @"Enable one-click Dock switching…";
    self.dockNavigationItem.state = permission && self.dockNavigation.enabled ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)toggleDockNavigation:(id)sender {
    if (![self.dockNavigation hasPermission]) { [self.dockNavigation requestPermission]; return; }
    BOOL disabled = ![NSUserDefaults.standardUserDefaults boolForKey:@"DockNavigationDisabled"];
    [NSUserDefaults.standardUserDefaults setBool:disabled forKey:@"DockNavigationDisabled"];
    self.dockNavigation.enabled = self.enabled && !disabled;
    [self updateDockNavigationMenu];
}
- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.lastForeground = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
    __weak StayHere *weakSelf = self;
    self.dockNavigation = [SHDockNavigation new];
    self.dockNavigation.enabled = ![NSUserDefaults.standardUserDefaults boolForKey:@"DockNavigationDisabled"];
    self.dockNavigation.willNavigate = ^(NSRunningApplication *app) {
        SHLaunch *launch = weakSelf.launches[@(app.processIdentifier)];
        if (launch) [weakSelf releaseLaunch:launch reason:@"explicit-dock-click"];
    };
    [self.dockNavigation start];
    for (NSNotificationName name in @[NSWorkspaceWillLaunchApplicationNotification, NSWorkspaceDidLaunchApplicationNotification]) {
        [self.observers addObject:[center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { [weakSelf launchNotification:n]; }]];
    }
    [self.observers addObject:[center addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { [weakSelf activationNotification:n]; }]];
    [self.observers addObject:[center addObserverForName:NSWorkspaceDidTerminateApplicationNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSRunningApplication *app = n.userInfo[NSWorkspaceApplicationKey];
        SHLaunch *launch = weakSelf.launches[@(app.processIdentifier)];
        if (launch) [weakSelf releaseLaunch:launch reason:@"application-ended"];
    }]];
    [self.observers addObject:[center addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { [weakSelf tick]; }]];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
    if (!self.headless) {
        self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
        self.statusItem.button.image = SHMenuBarIcon();
        self.statusItem.button.imagePosition = NSImageOnly;
        self.statusItem.button.title = @"";
        self.statusItem.button.accessibilityLabel = @"Stay Here";
        self.statusItem.button.toolTip = @"Keep the active desktop when assigned apps launch";
        NSMenu *menu = [NSMenu new];
        self.enabledItem = [[NSMenuItem alloc] initWithTitle:@"Keep this desktop when apps open" action:@selector(toggleEnabled:) keyEquivalent:@""];
        self.enabledItem.target = self;
        self.enabledItem.state = NSControlStateValueOn;
        [menu addItem:self.enabledItem];
        self.dockNavigationItem = [[NSMenuItem alloc] initWithTitle:@"One-click Dock switching" action:@selector(toggleDockNavigation:) keyEquivalent:@""];
        self.dockNavigationItem.target = self;
        [menu addItem:self.dockNavigationItem];
        [self updateDockNavigationMenu];
        [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Stay Here" action:@selector(quit:) keyEquivalent:@""];
        quit.target = self;
        [menu addItem:quit];
        self.statusItem.menu = menu;
    }
    for (NSNumber *number in @[@(SIGTERM), @(SIGINT)]) {
        int signo = number.intValue;
        signal(signo, SIG_IGN);
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signo, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(source, ^{ [NSApp terminate:nil]; });
        dispatch_resume(source);
        [self.signalSources addObject:source];
    }
    if (self.duration > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    SHLog(@"armed", @{@"enabled": @(self.enabled), @"headless": @(self.headless), @"onlyBundle": self.onlyBundle ?: NSNull.null});
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (!self.stopped) {
        self.stopped = YES;
        [self.dockNavigation stop];
        [self.timer invalidate];
        NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
        for (id observer in self.observers) [center removeObserver:observer];
        [self.observers removeAllObjects];
        for (SHLaunch *launch in self.launches.allValues) [self releaseLaunch:launch reason:@"helper-exit"];
        for (dispatch_source_t source in self.signalSources) dispatch_source_cancel(source);
        [self.signalSources removeAllObjects];
        if (self.statusItem) [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];
        SHLog(@"stopped", @{});
    }
    return NSTerminateNow;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        StayHere *delegate = [StayHere new];
        for (int i = 1; i < argc; i++) {
            NSString *argument = @(argv[i]);
            if ([argument isEqualToString:@"--headless"]) delegate.headless = YES;
            else if ([argument isEqualToString:@"--only-bundle"] && i + 1 < argc) delegate.onlyBundle = @(argv[++i]);
            else if ([argument isEqualToString:@"--duration"] && i + 1 < argc) {
                char *end = NULL;
                delegate.duration = strtod(argv[++i], &end);
                if (!end || *end || !isfinite(delegate.duration) || delegate.duration <= 0) { fprintf(stderr, "Invalid duration.\n"); return 2; }
            } else { fprintf(stderr, "Usage: %s [--headless] [--duration SECONDS] [--only-bundle BUNDLE_ID]\n", argv[0]); return 2; }
        }
        NSString *error = nil;
        delegate.api = [[SHAPI alloc] initWithError:&error];
        if (!delegate.api) { fprintf(stderr, "Stay Here: %s\n", error.UTF8String); return 2; }
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
