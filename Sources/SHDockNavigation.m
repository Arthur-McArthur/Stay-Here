// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arthur-McArthur
#import "SHDockNavigation.h"
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>

typedef int (*SHDockConnection)(void);
typedef uint64_t (*SHDockActiveSpace)(int);
typedef CFArrayRef (*SHDockDisplays)(int);
typedef CFArrayRef (*SHDockWindowSpaces)(int, int, CFArrayRef);
typedef struct { uint32_t high, low; } SHProcessSerialNumber;
typedef OSStatus (*SHProcessForPID)(pid_t, SHProcessSerialNumber *);
typedef CGError (*SHFocusWindow)(SHProcessSerialNumber *, CGWindowID, uint32_t);
typedef AXError (*SHAXWindowID)(AXUIElementRef, CGWindowID *);
typedef int (*SHGetHotkey)(int, uint16_t *, uint16_t *, uint32_t *);
typedef bool (*SHHotkeyEnabled)(int);
typedef int (*SHSetHotkeyEnabled)(int, bool);
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
@property(nonatomic) CGWindowID windowID;
@property(nonatomic, strong) id windowElement;
@property(nonatomic) int desktopHotkey;
@property(nonatomic) double startedAt;
@end
@implementation SHDockIntent
@end

@interface SHDockNavigation () {
    int _connection;
    SHDockActiveSpace _activeSpace;
    SHDockDisplays _displays;
    SHDockWindowSpaces _windowSpaces;
    SHProcessForPID _processForPID;
    SHFocusWindow _focusWindow;
    SHAXWindowID _axWindowID;
    SHGetHotkey _getHotkey;
    SHHotkeyEnabled _hotkeyEnabled;
    SHSetHotkeyEnabled _setHotkeyEnabled;
}
@property(nonatomic, strong) id monitor;
@property(nonatomic, strong) id localMonitor;
@property(nonatomic, strong) SHDockIntent *mouseDown;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *temporaryHotkeys;
@property(nonatomic) NSUInteger hotkeyLease;
@end

@implementation SHDockNavigation
- (instancetype)init {
    if ((self = [super init])) {
        _enabled = YES;
        _temporaryHotkeys = [NSMutableDictionary dictionary];
        void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (sky) {
            SHDockConnection connection = dlsym(sky, "SLSMainConnectionID");
            _activeSpace = dlsym(sky, "SLSGetActiveSpace");
            _displays = dlsym(sky, "SLSCopyManagedDisplaySpaces");
            _windowSpaces = dlsym(sky, "SLSCopySpacesForWindows");
            _focusWindow = dlsym(sky, "_SLPSSetFrontProcessWithOptions");
            _getHotkey = dlsym(sky, "CGSGetSymbolicHotKeyValue");
            _hotkeyEnabled = dlsym(sky, "CGSIsSymbolicHotKeyEnabled");
            _setHotkeyEnabled = dlsym(sky, "CGSSetSymbolicHotKeyEnabled");
            if (connection) _connection = connection();
        }
        void *services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
        if (services) {
            _processForPID = dlsym(services, "GetProcessForPID");
            _axWindowID = dlsym(services, "_AXUIElementGetWindow");
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
    if (!enabled) { self.generation++; self.mouseDown = nil; [self restoreTemporaryHotkeys]; }
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

- (id)focusedWindowForApp:(NSRunningApplication *)app matching:(CGWindowID)wanted {
    if (!_axWindowID) return nil;
    AXUIElementRef element = AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementSetMessagingTimeout(element, 0.1);
    id focused = SHAXAttribute(element, kAXFocusedWindowAttribute);
    CGWindowID wid = 0;
    if (focused && CFGetTypeID((__bridge CFTypeRef)focused) == AXUIElementGetTypeID()) _axWindowID((__bridge AXUIElementRef)focused, &wid);
    if (wid && (!wanted || wid == wanted)) { CFRelease(element); return focused; }
    // AXWindows can omit windows on other Spaces; prefer AXFocusedWindow.
    NSArray *windows = SHAXAttribute(element, kAXWindowsAttribute);
    CFRelease(element);
    if ([windows isKindOfClass:NSArray.class]) for (id window in windows) {
        if (CFGetTypeID((__bridge CFTypeRef)window) != AXUIElementGetTypeID()) continue;
        wid = 0;
        _axWindowID((__bridge AXUIElementRef)window, &wid);
        if (wid && wid == wanted) return window;
    }
    return nil;
}

- (NSDictionary *)windowForApp:(NSRunningApplication *)app origin:(uint64_t)origin ordered:(NSArray *)ordered preferred:(CGWindowID)preferred {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSDictionary *first = nil, *focused = nil, *current = nil;
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowOwnerPID] intValue] != app.processIdentifier || [window[(id)kCGWindowLayer] intValue] != 0) continue;
        NSNumber *wid = window[(id)kCGWindowNumber];
        if (!wid) continue;
        NSArray *membership = CFBridgingRelease(_windowSpaces(_connection, 7, (__bridge CFArrayRef)@[wid]));
        if ([membership containsObject:@(origin)]) membership = @[@(origin)];
        for (NSNumber *sid in membership) {
            if (![ordered containsObject:sid]) continue;
            NSDictionary *candidate = @{@"window": wid, @"space": sid};
            if (!first) first = candidate;
            if (wid.unsignedIntValue == preferred) focused = candidate;
            if (sid.unsignedLongLongValue == origin && !current) current = candidate;
            break;
        }
    }
    if ([focused[@"space"] unsignedLongLongValue] == origin) return focused;
    return current ?: focused ?: first;
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
        id window = [self focusedWindowForApp:app matching:0];
        CGWindowID preferred = 0;
        if (window && _axWindowID) _axWindowID((__bridge AXUIElementRef)window, &preferred);
        NSDictionary *candidate = [self windowForApp:app origin:origin ordered:ordered preferred:preferred];
        if (!candidate) continue;
        SHDockIntent *intent = [SHDockIntent new];
        intent.app = app; intent.launchDate = app.launchDate; intent.bundleURL = url;
        intent.point = point; intent.timestamp = timestamp;
        intent.origin = origin; intent.target = [candidate[@"space"] unsignedLongLongValue]; intent.spaces = ordered;
        intent.windowID = [candidate[@"window"] unsignedIntValue];
        intent.windowElement = preferred == intent.windowID ? window : nil;
        NSArray *displays = CFBridgingRelease(_displays(_connection));
        int ordinal = 0;
        for (NSDictionary *space in displays.firstObject[@"Spaces"]) {
            if ([space[@"type"] integerValue] != 0) continue;
            ordinal++;
            NSNumber *sid = space[@"ManagedSpaceID"] ?: space[@"id64"];
            if (sid.unsignedLongLongValue == intent.target && ordinal <= 9) intent.desktopHotkey = 117 + ordinal;
        }
        return intent;
    }
    return nil;
}

- (BOOL)identityMatches:(SHDockIntent *)intent {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:intent.app.processIdentifier];
    return app && !app.terminated && [app.launchDate isEqual:intent.launchDate] && [[app.bundleURL URLByResolvingSymlinksInPath] isEqual:intent.bundleURL];
}

- (void)restoreTemporaryHotkeys {
    @synchronized (self) {
        for (NSNumber *identifier in self.temporaryHotkeys.allKeys) {
            if (_setHotkeyEnabled && _setHotkeyEnabled(identifier.intValue, false) == 0) [self.temporaryHotkeys removeObjectForKey:identifier];
        }
    }
}

- (BOOL)postDesktopHotkey:(int)identifier {
    // These numbered desktop actions have been qualified on macOS 26.
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 26 || !_getHotkey || !_hotkeyEnabled || !_setHotkeyEnabled || identifier < 118 || identifier > 126) return NO;
    uint16_t character = 0, key = 0;
    uint32_t flags = 0;
    if (_getHotkey(identifier, &character, &key, &flags) != 0 || key > 127) return NO;
    NSNumber *number = @(identifier);
    NSUInteger lease = 0;
    @synchronized (self) {
        BOOL alreadyOwned = self.temporaryHotkeys[number] != nil;
        if (!_hotkeyEnabled(identifier)) {
            if (_setHotkeyEnabled(identifier, true) != 0) return NO;
            alreadyOwned = YES;
        }
        if (alreadyOwned) {
            lease = ++self.hotkeyLease;
            self.temporaryHotkeys[number] = @(lease);
        }
        if (!_hotkeyEnabled(identifier)) { [self restoreTemporaryHotkeys]; return NO; }
    }
    // Restore only a disabled action we temporarily enabled, including when
    // another click supersedes this one. Never replace the user's binding.
    if (lease) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        @synchronized (self) {
            if ([self.temporaryHotkeys[number] unsignedIntegerValue] != lease) return;
            int status = self->_setHotkeyEnabled(identifier, false);
            if (!status) [self.temporaryHotkeys removeObjectForKey:number];
            else SHDockLog(@"dock-hotkey-restore-failed", @{@"status": @(status)});
        }
    });
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, key, true);
    if (!down) { [self restoreTemporaryHotkeys]; return NO; }
    CGEventSetFlags(down, flags);
    CGEventSetIntegerValueField(down, kCGEventSourceUserData, SHNavigationEventTag);
    CGEventPost(kCGHIDEventTap, down);
    CFRelease(down);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        CGEventRef up = CGEventCreateKeyboardEvent(NULL, key, false);
        if (up) {
            CGEventSetFlags(up, flags);
            CGEventSetIntegerValueField(up, kCGEventSourceUserData, SHNavigationEventTag);
            CGEventPost(kCGHIDEventTap, up);
            CFRelease(up);
        }
    });
    return YES;
}

- (BOOL)windowStillExists:(SHDockIntent *)intent {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, intent.windowID));
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowNumber] unsignedIntValue] == intent.windowID && [window[(id)kCGWindowOwnerPID] intValue] == intent.app.processIdentifier) return YES;
    }
    return NO;
}

- (void)bringWindowForward:(SHDockIntent *)intent {
    if (![self identityMatches:intent] || ![self windowStillExists:intent]) return;
    [intent.app unhide];
    [intent.app activateWithOptions:0];
    if (_processForPID && _focusWindow) {
        SHProcessSerialNumber psn = {0};
        if (_processForPID(intent.app.processIdentifier, &psn) == noErr) _focusWindow(&psn, intent.windowID, 0x200);
    }
    if (!intent.windowElement) intent.windowElement = [self focusedWindowForApp:intent.app matching:intent.windowID];
    if (intent.windowElement) {
        AXUIElementRef window = (__bridge AXUIElementRef)intent.windowElement;
        AXUIElementSetMessagingTimeout(window, 0.1);
        AXUIElementSetAttributeValue(window, kAXMainAttribute, kCFBooleanTrue);
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute, kCFBooleanTrue);
        if (AXUIElementPerformAction(window, kAXRaiseAction) == kAXErrorInvalidUIElement) {
            intent.windowElement = [self focusedWindowForApp:intent.app matching:intent.windowID];
            if (intent.windowElement) AXUIElementPerformAction((__bridge AXUIElementRef)intent.windowElement, kAXRaiseAction);
        }
    }
}

- (BOOL)windowIsVisibleInFront:(SHDockIntent *)intent {
    if (intent.app.hidden || NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != intent.app.processIdentifier) return NO;
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    BOOL targetOnScreen = NO;
    pid_t topOwner = 0;
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowNumber] unsignedIntValue] == intent.windowID) targetOnScreen = YES;
        if (topOwner || [window[(id)kCGWindowLayer] intValue] != 0 || [window[(id)kCGWindowAlpha] doubleValue] == 0) continue;
        pid_t owner = [window[(id)kCGWindowOwnerPID] intValue];
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:owner];
        if (app.activationPolicy == NSApplicationActivationPolicyRegular) topOwner = owner;
    }
    return targetOnScreen && topOwner == intent.app.processIdentifier;
}

- (void)verifyWindow:(SHDockIntent *)intent generation:(NSUInteger)generation retry:(BOOL)retry {
    if (!self.enabled || self.generation != generation || ![self identityMatches:intent] || _activeSpace(_connection) != intent.target) return;
    if ([self windowIsVisibleInFront:intent]) {
        SHDockLog(@"dock-navigation-complete", @{@"pid": @(intent.app.processIdentifier), @"targetSpace": @(intent.target), @"windowVisible": @YES, @"elapsed": @(NSProcessInfo.processInfo.systemUptime - intent.startedAt)});
    } else if (retry) {
        [self bringWindowForward:intent];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self verifyWindow:intent generation:generation retry:NO];
        });
    } else {
        SHDockLog(@"dock-window-not-front", @{@"pid": @(intent.app.processIdentifier), @"targetSpace": @(intent.target)});
    }
}

- (void)waitForDesktop:(SHDockIntent *)intent generation:(NSUInteger)generation deadline:(double)deadline {
    if (!self.enabled || self.generation != generation || ![self hasPermission] || ![self identityMatches:intent]) return;
    uint64_t current = _activeSpace(_connection);
    if (current == intent.target) {
        [self bringWindowForward:intent];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self verifyWindow:intent generation:generation retry:YES];
        });
    } else if (current == intent.origin && NSProcessInfo.processInfo.systemUptime < deadline && [[self orderedSpaces] isEqual:intent.spaces]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self waitForDesktop:intent generation:generation deadline:deadline];
        });
    } else {
        self.generation++;
        SHDockLog(@"dock-navigation-cancelled", @{@"reason": current == intent.origin ? @"desktop-timeout" : @"desktop-changed"});
    }
}

- (void)navigate:(SHDockIntent *)intent generation:(NSUInteger)generation {
    intent.startedAt = NSProcessInfo.processInfo.systemUptime;
    // Raise before switching so the window is already in front on arrival.
    [self bringWindowForward:intent];
    uint64_t current = _activeSpace(_connection);
    if (current == intent.target) {
        [self waitForDesktop:intent generation:generation deadline:intent.startedAt + 1];
    } else if (current == intent.origin && [self postDesktopHotkey:intent.desktopHotkey]) {
        [self waitForDesktop:intent generation:generation deadline:intent.startedAt + 1.5];
    } else {
        SHDockLog(@"dock-navigation-cancelled", @{@"reason": @"direct-desktop-unavailable"});
    }
}

- (void)handleMouseEvent:(NSEvent *)event {
    if (CGEventGetIntegerValueField(event.CGEvent, kCGEventSourceUserData) == SHNavigationEventTag) return;
    if (event.type == NSEventTypeLeftMouseDragged) {
        CGPoint point = CGEventGetLocation(event.CGEvent);
        if (self.mouseDown && hypot(point.x - self.mouseDown.point.x, point.y - self.mouseDown.point.y) > 5) {
            self.generation++; self.mouseDown = nil;
        }
        return;
    }
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
        // AppKit delivers global copies asynchronously. The Dock may have
        // hidden or rearranged its tiles after processing mouse-up already;
        // trust the verified press target and drag/identity checks instead.
        NSUInteger generation = self.generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!self.enabled || self.generation != generation || ![self identityMatches:intent]) return;
            uint64_t current = self->_activeSpace(self->_connection);
            if (current != intent.origin && current != intent.target) return;
            if (self.willNavigate) self.willNavigate(intent.app);
            SHDockLog(@"dock-navigation", @{@"pid": @(intent.app.processIdentifier), @"originSpace": @(intent.origin), @"targetSpace": @(intent.target)});
            [self navigate:intent generation:generation];
        });
    }
}

- (void)start {
    if (self.monitor || !_connection || !_activeSpace || !_displays || !_windowSpaces) return;
    __weak SHDockNavigation *weakSelf = self;
    self.monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown | NSEventMaskKeyDown | NSEventMaskScrollWheel handler:^(NSEvent *event) {
        [weakSelf handleMouseEvent:event];
    }];
    self.localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown | NSEventMaskKeyDown | NSEventMaskScrollWheel handler:^NSEvent *(NSEvent *event) {
        [weakSelf handleMouseEvent:event];
        return event;
    }];
    SHDockLog(@"dock-navigation-armed", @{@"permission": @([self hasPermission]), @"monitor": @(self.monitor != nil)});
}
- (void)stop {
    self.generation++; self.mouseDown = nil;
    [self restoreTemporaryHotkeys];
    if (self.monitor) { [NSEvent removeMonitor:self.monitor]; self.monitor = nil; }
    if (self.localMonitor) { [NSEvent removeMonitor:self.localMonitor]; self.localMonitor = nil; }
}
- (void)dealloc { [self stop]; }
@end
