// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arthur-McArthur
#import "SHDockNavigation.h"
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <math.h>

typedef int (*SHDockConnection)(void);
typedef uint64_t (*SHDockActiveSpace)(int);
typedef CFArrayRef (*SHDockDisplays)(int);
typedef CFArrayRef (*SHDockWindowSpaces)(int, int, CFArrayRef);
static const int64_t SHNavigationEventTag = 0x5348444f434b;

static void SHDockLog(NSString *event, NSDictionary *fields) {
    NSMutableDictionary *record = [fields mutableCopy] ?: [NSMutableDictionary dictionary];
    record[@"event"] = event;
    record[@"time"] = @(NSProcessInfo.processInfo.systemUptime);
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    if (data) { fwrite(data.bytes, 1, data.length, stdout); putchar('\n'); fflush(stdout); }
}

static id SHAXAttribute(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value = NULL;
    AXUIElementCopyAttributeValue(element, key, &value);
    return CFBridgingRelease(value);
}

@interface SHDockIntent : NSObject
@property(nonatomic, strong) NSRunningApplication *app;
@property(nonatomic, copy) NSDate *launchDate;
@property(nonatomic, copy) NSURL *bundleURL;
@property(nonatomic) CGPoint point;
@property(nonatomic) double timestamp;
@property(nonatomic) uint64_t origin;
@property(nonatomic) uint64_t target;
@property(nonatomic, copy) NSArray<NSNumber *> *spaces;
@end
@implementation SHDockIntent
@end

@interface SHDockNavigation () {
    int _connection;
    SHDockActiveSpace _activeSpace;
    SHDockDisplays _displays;
    SHDockWindowSpaces _windowSpaces;
}
@property(nonatomic, strong) id monitor;
@property(nonatomic, strong) id localMonitor;
@property(nonatomic, strong) SHDockIntent *mouseDown;
@property(nonatomic) NSUInteger generation;
@end

@implementation SHDockNavigation
- (instancetype)init {
    if ((self = [super init])) {
        _enabled = YES;
        void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (sky) {
            SHDockConnection connection = dlsym(sky, "SLSMainConnectionID");
            _activeSpace = dlsym(sky, "SLSGetActiveSpace");
            _displays = dlsym(sky, "SLSCopyManagedDisplaySpaces");
            _windowSpaces = dlsym(sky, "SLSCopySpacesForWindows");
            if (connection) _connection = connection();
        }
    }
    return self;
}
- (BOOL)hasPermission { return AXIsProcessTrusted() && CGPreflightPostEventAccess(); }
- (void)requestPermission {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}
- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    if (!enabled) { self.generation++; self.mouseDown = nil; }
}

// Hit-test one item with a bounded AX timeout; never enumerate the Dock tree.
- (NSURL *)dockAppAtPoint:(CGPoint)point {
    AXUIElementRef system = AXUIElementCreateSystemWide();
    AXUIElementSetMessagingTimeout(system, 0.15);
    AXUIElementRef element = NULL;
    AXError error = AXUIElementCopyElementAtPosition(system, point.x, point.y, &element);
    CFRelease(system);
    if (error != kAXErrorSuccess || !element) return nil;
    NSURL *url = nil;
    for (int depth = 0; depth < 3; depth++) {
        pid_t pid = 0;
        AXUIElementGetPid(element, &pid);
        NSRunningApplication *owner = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        NSString *subrole = SHAXAttribute(element, kAXSubroleAttribute);
        if ([owner.bundleIdentifier isEqualToString:@"com.apple.dock"] && [subrole isEqualToString:@"AXApplicationDockItem"]) {
            id value = SHAXAttribute(element, kAXURLAttribute);
            if ([value isKindOfClass:NSURL.class] && [value isFileURL]) url = [value URLByResolvingSymlinksInPath];
            break;
        }
        id parent = SHAXAttribute(element, kAXParentAttribute);
        if (!parent || CFGetTypeID((__bridge CFTypeRef)parent) != AXUIElementGetTypeID()) break;
        CFRelease(element);
        element = (AXUIElementRef)CFRetain((__bridge CFTypeRef)parent);
    }
    CFRelease(element);
    return url;
}

- (NSArray<NSNumber *> *)orderedSpaces {
    NSArray *displays = CFBridgingRelease(_displays(_connection));
    // Multi-display routing needs separate qualification; don't switch the wrong screen.
    if (displays.count != 1) return nil;
    NSMutableArray *spaces = [NSMutableArray array];
    for (NSDictionary *space in displays.firstObject[@"Spaces"]) {
        NSNumber *sid = space[@"ManagedSpaceID"] ?: space[@"id64"];
        if ([sid isKindOfClass:NSNumber.class]) [spaces addObject:sid];
    }
    return spaces;
}

- (uint64_t)remoteWindowSpace:(NSRunningApplication *)app origin:(uint64_t)origin ordered:(NSArray *)ordered {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    uint64_t target = 0;
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowOwnerPID] intValue] != app.processIdentifier || [window[(id)kCGWindowLayer] intValue] != 0) continue;
        NSNumber *wid = window[(id)kCGWindowNumber];
        if (!wid) continue;
        NSArray *membership = CFBridgingRelease(_windowSpaces(_connection, 7, (__bridge CFArrayRef)@[wid]));
        if ([membership containsObject:@(origin)]) return 0;
        if (!target) for (NSNumber *sid in membership) {
            if ([ordered containsObject:sid]) { target = sid.unsignedLongLongValue; break; }
        }
    }
    return target;
}

- (SHDockIntent *)intentAtPoint:(CGPoint)point timestamp:(double)timestamp {
    NSURL *url = [self dockAppAtPoint:point];
    if (!url) return nil;
    NSArray *ordered = [self orderedSpaces];
    uint64_t origin = _activeSpace(_connection);
    if (![ordered containsObject:@(origin)]) return nil;
    NSArray *apps = [NSWorkspace.sharedWorkspace.runningApplications sortedArrayUsingComparator:^NSComparisonResult(NSRunningApplication *a, NSRunningApplication *b) {
        return [(a.launchDate ?: NSDate.distantFuture) compare:(b.launchDate ?: NSDate.distantFuture)];
    }];
    for (NSRunningApplication *app in apps) {
        // Capture an existing process before mouse-up can cause a cold launch.
        if (app.terminated || !app.finishedLaunching || app.activationPolicy == NSApplicationActivationPolicyProhibited || !app.launchDate || -app.launchDate.timeIntervalSinceNow < 3) continue;
        if (![[app.bundleURL URLByResolvingSymlinksInPath] isEqual:url]) continue;
        uint64_t target = [self remoteWindowSpace:app origin:origin ordered:ordered];
        if (!target) continue;
        SHDockIntent *intent = [SHDockIntent new];
        intent.app = app; intent.launchDate = app.launchDate; intent.bundleURL = url;
        intent.point = point; intent.timestamp = timestamp;
        intent.origin = origin; intent.target = target; intent.spaces = ordered;
        return intent;
    }
    return nil;
}

- (BOOL)identityMatches:(SHDockIntent *)intent {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:intent.app.processIdentifier];
    return app && !app.terminated && [app.launchDate isEqual:intent.launchDate] && [[app.bundleURL URLByResolvingSymlinksInPath] isEqual:intent.bundleURL];
}

- (BOOL)postStepRight:(BOOL)right {
    CFPreferencesAppSynchronize(CFSTR("com.apple.symbolichotkeys"));
    NSDictionary *hotkeys = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("AppleSymbolicHotKeys"), CFSTR("com.apple.symbolichotkeys")));
    NSDictionary *setting = [hotkeys isKindOfClass:NSDictionary.class] ? hotkeys[right ? @"81" : @"79"] : nil;
    if (setting[@"enabled"] && ![setting[@"enabled"] boolValue]) return NO;
    NSArray *parameters = setting[@"value"][@"parameters"];
    CGKeyCode key = right ? 124 : 123;
    CGEventFlags flags = kCGEventFlagMaskControl | kCGEventFlagMaskSecondaryFn;
    if ([parameters isKindOfClass:NSArray.class] && parameters.count == 3) {
        NSInteger code = [parameters[1] integerValue];
        if (code < 0 || code > 127) return NO;
        key = (CGKeyCode)code;
        flags = [parameters[2] unsignedLongLongValue];
    }
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, key, true);
    if (!down) return NO;
    CGEventSetFlags(down, flags);
    CGEventSetIntegerValueField(down, kCGEventSourceUserData, SHNavigationEventTag);
    CGEventPost(kCGSessionEventTap, down);
    CFRelease(down);
    // Distinct down/up timestamps are needed for reliable symbolic hotkeys.
    // Always release the key, even if a newer user action cancels the route.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        CGEventRef up = CGEventCreateKeyboardEvent(NULL, key, false);
        if (up) {
            CGEventSetFlags(up, flags);
            CGEventSetIntegerValueField(up, kCGEventSourceUserData, SHNavigationEventTag);
            CGEventPost(kCGSessionEventTap, up);
            CFRelease(up);
        }
    });
    return YES;
}

- (void)waitForStep:(SHDockIntent *)intent generation:(NSUInteger)generation from:(uint64_t)from next:(uint64_t)next deadline:(double)deadline {
    if (!self.enabled || self.generation != generation || ![self identityMatches:intent]) return;
    uint64_t current = _activeSpace(_connection);
    if (current == next) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self advance:intent generation:generation expected:next];
        });
    } else if (current == from && NSProcessInfo.processInfo.systemUptime < deadline) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self waitForStep:intent generation:generation from:from next:next deadline:deadline];
        });
    } else {
        self.generation++;
        SHDockLog(@"dock-navigation-cancelled", @{@"reason": current == from ? @"shortcut-timeout" : @"desktop-changed"});
    }
}

- (void)advance:(SHDockIntent *)intent generation:(NSUInteger)generation expected:(uint64_t)expected {
    if (!self.enabled || self.generation != generation || ![self hasPermission] || ![self identityMatches:intent]) return;
    uint64_t current = _activeSpace(_connection);
    if (current != expected || ![[self orderedSpaces] isEqual:intent.spaces]) return;
    if (current == intent.target) {
        [intent.app activateWithOptions:0];
        SHDockLog(@"dock-navigation-complete", @{@"pid": @(intent.app.processIdentifier), @"targetSpace": @(intent.target)});
        return;
    }
    NSUInteger source = [intent.spaces indexOfObject:@(current)], target = [intent.spaces indexOfObject:@(intent.target)];
    if (source == NSNotFound || target == NSNotFound) return;
    BOOL right = target > source;
    uint64_t next = [intent.spaces[right ? source + 1 : source - 1] unsignedLongLongValue];
    if (![self postStepRight:right]) { SHDockLog(@"dock-navigation-cancelled", @{@"reason": @"desktop-shortcut-disabled"}); return; }
    [self waitForStep:intent generation:generation from:current next:next deadline:NSProcessInfo.processInfo.systemUptime + 1.5];
}

- (void)handleMouseEvent:(NSEvent *)event {
    if (CGEventGetIntegerValueField(event.CGEvent, kCGEventSourceUserData) == SHNavigationEventTag) return;
    if (event.type != NSEventTypeLeftMouseUp) {
        if (self.mouseDown) SHDockLog(@"dock-input-cancelled", @{});
        self.generation++; self.mouseDown = nil;
    }
    if (event.type != NSEventTypeLeftMouseDown && event.type != NSEventTypeLeftMouseUp) return;
    if (!self.enabled || ![self hasPermission]) return;
    NSEventModifierFlags modifiers = event.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand);
    if (modifiers) { self.mouseDown = nil; return; }
    CGPoint point = CGEventGetLocation(event.CGEvent);
    if (event.type == NSEventTypeLeftMouseDown) {
        self.mouseDown = [self intentAtPoint:point timestamp:event.timestamp];
    } else if (event.type == NSEventTypeLeftMouseUp) {
        SHDockIntent *intent = self.mouseDown;
        self.mouseDown = nil;
        if (!intent || event.timestamp - intent.timestamp > 0.6 || hypot(point.x - intent.point.x, point.y - intent.point.y) > 5) return;
        if (![[self dockAppAtPoint:point] isEqual:intent.bundleURL]) return;
        NSUInteger generation = self.generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!self.enabled || self.generation != generation || ![self identityMatches:intent] || self->_activeSpace(self->_connection) != intent.origin) return;
            NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
            if (front.processIdentifier != intent.app.processIdentifier) return;
            if (self.willNavigate) self.willNavigate(intent.app);
            SHDockLog(@"dock-navigation", @{@"pid": @(intent.app.processIdentifier), @"originSpace": @(intent.origin), @"targetSpace": @(intent.target)});
            [self advance:intent generation:generation expected:intent.origin];
        });
    }
}

- (void)start {
    if (self.monitor || !_connection || !_activeSpace || !_displays || !_windowSpaces) return;
    __weak SHDockNavigation *weakSelf = self;
    self.monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown | NSEventMaskKeyDown | NSEventMaskScrollWheel handler:^(NSEvent *event) {
        [weakSelf handleMouseEvent:event];
    }];
    self.localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown | NSEventMaskKeyDown | NSEventMaskScrollWheel handler:^NSEvent *(NSEvent *event) {
        [weakSelf handleMouseEvent:event];
        return event;
    }];
    SHDockLog(@"dock-navigation-armed", @{@"permission": @([self hasPermission]), @"monitor": @(self.monitor != nil)});
}
- (void)stop {
    self.generation++; self.mouseDown = nil;
    if (self.monitor) { [NSEvent removeMonitor:self.monitor]; self.monitor = nil; }
    if (self.localMonitor) { [NSEvent removeMonitor:self.localMonitor]; self.localMonitor = nil; }
}
- (void)dealloc { [self stop]; }
@end
