#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <time.h>
// #include <Foundation/Foundation.h>

typedef void (*MenuActionCallback)(const char *action, const char *params);
typedef void (*MenuActionResponse)(const char *route, const char *data);

static MenuActionCallback gCallback = NULL;
static MenuActionResponse gResponse = NULL;
static NSStatusItem *gStatusItem = NULL;
static NSPopover *gPopover = NULL;

@interface PopoverVC : NSViewController
@property(nonatomic, strong) NSDatePicker *clockInTime;
@property(nonatomic, strong) NSDatePicker *clockOutTime;
@property(nonatomic, strong) NSDateFormatter *clockFormatter;
@end

static PopoverVC *gPopoverVC = NULL;

@implementation PopoverVC
- (void)loadView {
    // View
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 300)];

    // title
    NSTextField *title = [NSTextField labelWithString:@"Shifty"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.alignment = NSTextAlignmentCenter;
    [view addSubview:title];

    // shiftDuration
    NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
    timeFormatter.dateFormat = @"hh:mm";

    NSDatePicker *shiftDuration = [[NSDatePicker alloc] init];
    shiftDuration.translatesAutoresizingMaskIntoConstraints = NO;
    shiftDuration.datePickerStyle = NSDatePickerStyleTextField;
    shiftDuration.datePickerElements = NSDatePickerElementFlagHourMinute;
    shiftDuration.locale = [NSLocale localeWithLocaleIdentifier:@"en_GB"];
    shiftDuration.dateValue = [timeFormatter dateFromString:@"8:00"];
    [view addSubview:shiftDuration];

    // clockInLabel
    NSTextField *clockInLabel = [NSTextField labelWithString:@"Clock In"];
    clockInLabel.translatesAutoresizingMaskIntoConstraints = NO;
    clockInLabel.alignment = NSTextAlignmentCenter;
    [view addSubview:clockInLabel];

    // clockInTime
    NSDatePicker *clockInTime = [[NSDatePicker alloc] init];
    // [[NSDatePicker alloc] initWithFrame:NSMakeRect(10, 40, 180, 24)];
    clockInTime.translatesAutoresizingMaskIntoConstraints = NO;
    clockInTime.datePickerStyle = NSDatePickerStyleTextField;
    clockInTime.datePickerElements = NSDatePickerElementFlagHourMinute;
    clockInTime.dateValue = [NSDate date];
    [view addSubview:clockInTime];
    self.clockInTime = clockInTime;

    // clockInSetNow
    NSButton *clockInSetNow = [NSButton buttonWithTitle:@"Now"
                                                 target:self
                                                 action:@selector(didSetNow:)];
    clockInSetNow.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:clockInSetNow];

    // clockInBtn
    NSButton *clockInBtn = [NSButton buttonWithTitle:@"Clock In"
                                              target:self
                                              action:@selector(didClockIn:)];
    clockInBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:clockInBtn];

    // clockOutTime
    NSDatePicker *clockOutTime = [[NSDatePicker alloc] init];
    clockOutTime.translatesAutoresizingMaskIntoConstraints = NO;
    clockOutTime.datePickerStyle = NSDatePickerStyleTextField;
    clockOutTime.datePickerElements = NSDatePickerElementFlagHourMinute;
    [view addSubview:clockOutTime];
    self.clockOutTime = clockOutTime;

    // quitBtn
    NSButton *quitBtn = [NSButton buttonWithTitle:@"Quit"
                                           target:NSApp
                                           action:@selector(terminate:)];
    quitBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:quitBtn];

    // Constraints
    [NSLayoutConstraint activateConstraints:@[
        // title
        [title.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:view.topAnchor constant:8],

        // shiftDuration
        [shiftDuration.topAnchor constraintEqualToAnchor:title.bottomAnchor
                                                constant:12],
        [shiftDuration.centerXAnchor
            constraintEqualToAnchor:view.centerXAnchor],
        [shiftDuration.widthAnchor constraintEqualToConstant:80],

        // clockInLabel
        [clockInLabel.topAnchor
            constraintEqualToAnchor:shiftDuration.bottomAnchor
                           constant:4],
        [clockInLabel.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],

        // clockInTime
        [clockInTime.topAnchor constraintEqualToAnchor:clockInLabel.bottomAnchor
                                              constant:4],
        [clockInTime.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [clockInTime.widthAnchor constraintEqualToConstant:80],

        // clockInSetNow
        [clockInSetNow.topAnchor constraintEqualToAnchor:clockInTime.topAnchor],
        [clockInSetNow.leadingAnchor
            constraintEqualToAnchor:clockInTime.trailingAnchor
                           constant:4],
        [clockInSetNow.heightAnchor
            constraintEqualToAnchor:clockInTime.heightAnchor],

        // clockIn
        [clockInBtn.topAnchor constraintEqualToAnchor:clockInTime.bottomAnchor
                                             constant:4],
        [clockInBtn.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [clockInBtn.widthAnchor constraintEqualToConstant:80],

        // clockOutTime
        [clockOutTime.topAnchor constraintEqualToAnchor:clockInBtn.bottomAnchor
                                               constant:4],
        [clockOutTime.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],

        // quitBtn
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
- (void)didSetNow:(id)sender {
    self.clockInTime.dateValue = [NSDate date];
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

    // clockFormatter
    NSTimeZone *gmt = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
    NSDateFormatter *clockFormatter = [[NSDateFormatter alloc] init];
    clockFormatter.dateFormat = @"hh:mm a";
    clockFormatter.timeZone = gmt;
    gPopoverVC.clockFormatter = clockFormatter;
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
      if ([r isEqualToString:@"startup_ack"] || [r isEqualToString:@"clock_in_ack"]) {
          NSTimeInterval ts = (NSTimeInterval)[d longLongValue];
          NSDate *clockOut = [NSDate dateWithTimeIntervalSince1970:ts];
          gPopoverVC.clockOutTime.dateValue = clockOut;
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
    NSDate *date = [NSDate date];
    NSTimeInterval ts = [date timeIntervalSince1970];

    NSString *action = [NSString stringWithFormat:@"startup"];
    NSString *params =
        [NSString stringWithFormat:@"%@|%ld|%d|%d", tz, (long)ts, 8, 0];
    callback([action UTF8String], [params UTF8String]);

    [NSApplication sharedApplication];
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [NSApp setDelegate:delegate];
    [NSApp run];
}
