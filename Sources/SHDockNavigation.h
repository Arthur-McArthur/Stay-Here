// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arthur-McArthur
#import <AppKit/AppKit.h>

@interface SHDockNavigation : NSObject
@property(nonatomic) BOOL enabled;
@property(nonatomic, copy) void (^willNavigate)(NSRunningApplication *app);
- (void)start;
- (void)stop;
- (BOOL)hasPermission;
- (void)requestPermission;
@end
