#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
// #include <Foundation/Foundation.h>

typedef void (*MenuActionCallback)(const char *action, const char *params);
typedef void (*MenuActionResponse)(const char *route, const char *data);

static MenuActionCallback gCallback = NULL;
static MenuActionResponse gResponse = NULL;
static NSStatusItem *gStatusItem = NULL;
static NSPopover *gPopover = NULL;

@interface PopoverVC : NSViewController
@property(nonatomic, strong) NSDatePicker *clockInTime;
@property(nonatomic, strong) NSTextField *clockInLabel2;
@end

static PopoverVC *gPopoverVC = NULL;

@implementation PopoverVC
- (void)loadView {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 500)];

    NSTextField *title = [NSTextField labelWithString:@"Shifty"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.alignment = NSTextAlignmentCenter;
    [view addSubview:title];

    NSTextField *clockInLabel = [NSTextField labelWithString:@"Clock In"];
    clockInLabel.translatesAutoresizingMaskIntoConstraints = NO;
    clockInLabel.alignment = NSTextAlignmentCenter;
    [view addSubview:clockInLabel];

    NSDatePicker *clockInTime =
        [[NSDatePicker alloc] initWithFrame:NSMakeRect(10, 40, 180, 24)];
    clockInTime.translatesAutoresizingMaskIntoConstraints = NO;
    clockInTime.datePickerStyle = NSDatePickerStyleTextField;
    clockInTime.datePickerElements = NSDatePickerElementFlagHourMinute;
    clockInTime.dateValue = [NSDate date];
    [view addSubview:clockInTime];

    NSButton *clockIn = [NSButton buttonWithTitle:@"Clock In"
                                           target:self
                                           action:@selector(didClockIn:)];
    clockIn.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:clockIn];
    self.clockInTime = clockInTime;

    NSTextField *clockInLabel2 = [NSTextField labelWithString:@"Clock In"];
    clockInLabel2.translatesAutoresizingMaskIntoConstraints = NO;
    clockInLabel2.alignment = NSTextAlignmentCenter;
    [view addSubview:clockInLabel2];
    self.clockInLabel2 = clockInLabel2;

    NSButton *quitBtn = [NSButton buttonWithTitle:@"Quit"
                                           target:NSApp
                                           action:@selector(terminate:)];
    quitBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:quitBtn];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:view.topAnchor constant:8],

        [clockInLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor
                                               constant:12],
        [clockInLabel.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],

        [clockInTime.topAnchor constraintEqualToAnchor:clockInLabel.bottomAnchor
                                              constant:4],
        [clockInTime.leadingAnchor constraintEqualToAnchor:view.leadingAnchor
                                                  constant:10],
        [clockInTime.trailingAnchor constraintEqualToAnchor:view.trailingAnchor
                                                   constant:-10],

        [clockIn.topAnchor constraintEqualToAnchor:clockInTime.bottomAnchor
                                          constant:4],
        [clockIn.leadingAnchor constraintEqualToAnchor:view.leadingAnchor
                                              constant:10],
        [clockIn.trailingAnchor constraintEqualToAnchor:view.trailingAnchor
                                               constant:-10],

        [clockInLabel2.topAnchor constraintEqualToAnchor:clockIn.bottomAnchor
                                                constant:12],
        [clockInLabel2.centerXAnchor
            constraintEqualToAnchor:view.centerXAnchor],

        [quitBtn.bottomAnchor constraintEqualToAnchor:view.bottomAnchor
                                             constant:-8],
        [quitBtn.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [quitBtn.widthAnchor constraintEqualToConstant:80],
    ]];
    self.view = view;
}
- (void)didClockIn:(id)sender {
    NSDate *date = self.clockInTime.dateValue;
    NSTimeInterval ts = [date timeIntervalSince1970];

    NSString *action = [NSString stringWithFormat:@"clock_in"];
    NSString *params = [NSString stringWithFormat:@"%ld", (long)ts];
    if (gCallback)
        gCallback([action UTF8String], [params UTF8String]);
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

    gPopoverVC = (PopoverVC *)gPopover.contentViewController;
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

void onMenuResponse(const char *route, const char *data) {
    NSString *r = route ? @(route) : @"";
    NSString *d = data ? @(data) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"onMenuResponse: route=%@ data=%@ popoverVC=%@", r, d, gPopoverVC);
        if ([r isEqualToString:@"clock_in_ack"]) {
            NSLog(@"setting clockInLabel2 to %@", d);
            gPopoverVC.clockInLabel2.stringValue = d;
        }
    });
}

void runMenuBarApp(MenuActionCallback callback,
                   MenuActionResponse **responseOut) {
    gCallback = callback;
    gResponse = onMenuResponse;
    if (responseOut)
        *responseOut = onMenuResponse;

    NSString *tz = [NSTimeZone localTimeZone].name;
    NSString *action = [NSString stringWithFormat:@"timezone"];
    NSString *params = [NSString stringWithFormat:@"%@", tz];
    callback([action UTF8String], [params UTF8String]);

    [NSApplication sharedApplication];
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [NSApp setDelegate:delegate];
    [NSApp run];
}
