#import <AppKit/AppKit.h>
#include <Foundation/Foundation.h>

typedef void (*MenuActionCallback)(const char *action);

static MenuActionCallback gCallback = NULL;
static NSStatusItem *gStatusItem = NULL;
static NSPopover *gPopover = NULL;

@interface PopoverVC : NSViewController
@end

@implementation PopoverVC
- (void)loadView {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 500)];

    NSTextField *clockInLabel = [NSTextField labelWithString:@"Clock In"];
    clockInLabel.frame = NSMakeRect(0, 40, 200, 40);
    clockInLabel.alignment = NSTextAlignmentCenter;
    [view addSubview:clockInLabel];

    NSDatePicker *clockInTime =
        [[NSDatePicker alloc] initWithFrame:NSMakeRect(10, 40, 180, 24)];
    clockInTime.datePickerStyle = NSDatePickerStyleTextField;
    clockInTime.datePickerElements = NSDatePickerElementFlagHourMinute;
    clockInTime.dateValue = [NSDate date];
    [view addSubview:clockInTime];

    NSButton *quit = [NSButton buttonWithTitle:@"Quit"
                                        target:NSApp
                                        action:@selector(terminate:)];
    quit.frame = NSMakeRect(60, 8, 80, 28);
    [view addSubview:quit];

    self.view = view;
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSPopoverDelegate>
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    NSStatusBar *bar = [NSStatusBar systemStatusBar];
    gStatusItem = [bar statusItemWithLength:NSVariableStatusItemLength];

    NSButton *btn = gStatusItem.button;
    btn.title = @"😎";
    btn.action = @selector(togglePopover:);
    btn.target = self;

    gPopover = [[NSPopover alloc] init];
    gPopover.contentViewController = [[PopoverVC alloc] init];
    gPopover.contentSize = NSMakeSize(200, 500);
    gPopover.behavior = NSPopoverBehaviorTransient;
    gPopover.delegate = self;
}

- (void)togglePopover:(id)sender {
    if (gPopover.isShown) {
        [gPopover close];
    } else {
        [gPopover showRelativeToRect:gStatusItem.button.bounds
                              ofView:gStatusItem.button
                       preferredEdge:NSRectEdgeMaxY];
    }
}
@end

void runMenuBarApp(MenuActionCallback callback) {
    gCallback = callback;
    [NSApplication sharedApplication];
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [NSApp setDelegate:delegate];
    [NSApp run];
}
