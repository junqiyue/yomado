#import "WorkspacePreview.h"
#import "VDVirtualDisplay.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ApplicationServices/ApplicationServices.h>

static NSString *const YMPreviewEnabledKey = @"YMWorkspacePreviewEnabled";
static NSString *const YMPreviewPiPFrameKey = @"YMWorkspacePreviewPiPFrame";
static const CGFloat YMTabWidth = 14, YMTabHeight = 54, YMTabGap = 6;
static const CGFloat YMCardWidth = 232, YMCardHeight = 130.5, YMCardGap = 12, YMDockPad = 14;

static BOOL YMReduceMotion(void) { return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion; }
static void YMAnimate(NSTimeInterval duration, void (^changes)(void), void (^_Nullable done)(void)) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = YMReduceMotion() ? 0 : duration;
        context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.9 :0.25 :1];
        context.allowsImplicitAnimation = YES;
        changes();
    } completionHandler:done];
}
static void YMSetContents(CALayer *layer, id contents) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.contents = contents;
    [CATransaction commit];
}


// Where a display's picture actually sits inside an aspect-fit layer.
static CGRect YMAspectFitRect(CGSize content, CGRect bounds) {
    if (content.width <= 0 || content.height <= 0 || bounds.size.width <= 0 || bounds.size.height <= 0) return bounds;
    CGFloat scale = MIN(bounds.size.width / content.width, bounds.size.height / content.height);
    CGSize size = CGSizeMake(content.width * scale, content.height * scale);
    return CGRectMake(CGRectGetMidX(bounds) - size.width / 2, CGRectGetMidY(bounds) - size.height / 2, size.width, size.height);
}
static void YMAddRipple(CALayer *host, CGPoint at, CGFloat radius) {
    if (!host) return;
    CAShapeLayer *ring = [CAShapeLayer layer];
    CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(-radius, -radius, radius * 2, radius * 2), NULL);
    ring.path = path;
    CGPathRelease(path);
    ring.position = at;
    ring.fillColor = [NSColor colorWithSRGBRed:0.898 green:0.282 blue:0.302 alpha:0.22].CGColor;
    ring.strokeColor = [NSColor colorWithSRGBRed:0.898 green:0.282 blue:0.302 alpha:1].CGColor;
    ring.lineWidth = MAX(2.5, radius / 4);
    ring.shadowColor = NSColor.whiteColor.CGColor;
    ring.shadowOpacity = 0.9;
    ring.shadowRadius = 1.5;
    ring.shadowOffset = CGSizeZero;
    [host addSublayer:ring];
    CAShapeLayer *dot = [CAShapeLayer layer];
    CGFloat dr = MAX(3, radius / 3.5);
    CGPathRef dotPath = CGPathCreateWithEllipseInRect(CGRectMake(-dr, -dr, dr * 2, dr * 2), NULL);
    dot.path = dotPath;
    CGPathRelease(dotPath);
    dot.position = at;
    dot.fillColor = [NSColor colorWithSRGBRed:0.898 green:0.282 blue:0.302 alpha:1].CGColor;
    dot.strokeColor = NSColor.whiteColor.CGColor;
    dot.lineWidth = MAX(1, dr / 3);
    [host addSublayer:dot];
    CABasicAnimation *dotFade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    dotFade.fromValue = @1; dotFade.toValue = @0; dotFade.beginTime = CACurrentMediaTime() + 0.8; dotFade.duration = 0.5;
    dotFade.fillMode = kCAFillModeBackwards; dotFade.removedOnCompletion = NO;
    dot.opacity = 0;
    [dot addAnimation:dotFade forKey:@"fade"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [dot removeFromSuperlayer]; });
    CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.9 :0.25 :1];
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    grow.fromValue = @(YMReduceMotion() ? 1.0 : 0.35);
    grow.toValue = @(YMReduceMotion() ? 1.0 : 1.5);
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1;
    fade.toValue = @0;
    fade.beginTime = 0.6;
    fade.duration = 0.6;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[grow, fade];
    group.duration = 1.2;
    group.timingFunction = ease;
    group.fillMode = kCAFillModeForwards;
    group.removedOnCompletion = NO;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ [ring removeFromSuperlayer]; }];
    [ring addAnimation:group forKey:@"ripple"];
    [CATransaction commit];
}

#pragma mark - Capture source (one ScreenCaptureKit stream per virtual display)

@interface YMPreviewSource : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic) CGDirectDisplayID displayID;
@property(nonatomic) SCStream *stream;
@property(nonatomic) SCDisplay *display;
@property(nonatomic) BOOL live;
@property(nonatomic) NSHashTable<CALayer *> *layers;
@property(nonatomic, nullable) id latest;
@property(nonatomic) dispatch_queue_t queue;
@end

@implementation YMPreviewSource
+ (SCStreamConfiguration *)configurationForDisplay:(SCDisplay *)display live:(BOOL)live {
    SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
    double aspect = display.height > 0 ? (double)display.width / (double)display.height : 16.0 / 9.0;
    // Thumbnails stay small and slow; the picture-in-picture panel gets the
    // display's native pixels at 30 fps.
    size_t width = live ? MIN((size_t)display.width * 2, (size_t)3840) : 480;
    configuration.width = width;
    configuration.height = (size_t)llround((double)width / aspect);
    configuration.minimumFrameInterval = live ? CMTimeMake(1, 30) : CMTimeMake(1, 2);
    configuration.queueDepth = 3;
    configuration.showsCursor = YES;
    configuration.pixelFormat = kCVPixelFormatType_32BGRA;
    return configuration;
}
- (instancetype)initWithDisplay:(SCDisplay *)display {
    if ((self = [super init])) {
        _display = display;
        _displayID = display.displayID;
        _layers = [NSHashTable weakObjectsHashTable];
        _queue = dispatch_queue_create("dev.chekusu.yomado.preview", DISPATCH_QUEUE_SERIAL);
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        _stream = [[SCStream alloc] initWithFilter:filter configuration:[YMPreviewSource configurationForDisplay:display live:NO] delegate:self];
        NSError *error = nil;
        if (![_stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_queue error:&error]) return nil;
        [_stream startCaptureWithCompletionHandler:^(NSError *startError) { (void)startError; }];
    }
    return self;
}
- (void)attachLayer:(CALayer *)layer {
    [self.layers addObject:layer];
    if (self.latest) YMSetContents(layer, self.latest);
}
- (void)detachLayer:(CALayer *)layer {
    [self.layers removeObject:layer];
}
- (void)setLive:(BOOL)live {
    if (_live == live) return;
    _live = live;
    [self.stream updateConfiguration:[YMPreviewSource configurationForDisplay:self.display live:live] completionHandler:^(NSError *error) { (void)error; }];
}
- (void)stop {
    [self.stream stopCaptureWithCompletionHandler:^(NSError *error) { (void)error; }];
    for (CALayer *layer in self.layers) YMSetContents(layer, nil);
    [self.layers removeAllObjects];
    self.latest = nil;
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
        NSNumber *status = info[SCStreamFrameInfoStatus];
        if (status && status.integerValue != SCFrameStatusComplete) return;
    }
    CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    IOSurfaceRef surface = pixels ? CVPixelBufferGetIOSurface(pixels) : NULL;
    if (!surface) return;
    id contents = (__bridge id)surface;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.latest = contents;
        for (CALayer *layer in self.layers) YMSetContents(layer, contents);
    });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream; (void)error;
}
@end

#pragma mark - Panels and views

@interface YMPreviewPanel : NSPanel
@end
@implementation YMPreviewPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static void YMConfigureFloatingPanel(NSPanel *panel) {
    panel.level = NSFloatingWindowLevel;
    panel.floatingPanel = YES;
    panel.hidesOnDeactivate = NO;
    panel.becomesKeyOnlyIfNeeded = YES;
    panel.releasedWhenClosed = NO;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary
        | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    panel.animationBehavior = NSWindowAnimationBehaviorNone;
}

// A click target that never activates yomado.
@interface YMPreviewHitView : NSView
@property(nonatomic, copy, nullable) void (^onClick)(void);
@property(nonatomic, copy, nullable) void (^onDoubleClick)(void);
@end
@implementation YMPreviewHitView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return self.onClick == nil; }
- (void)mouseUp:(NSEvent *)event {
    if (event.clickCount == 2 && self.onDoubleClick) self.onDoubleClick();
    else if (event.clickCount == 1 && self.onClick) self.onClick();
}
@end

// Collapsed tab: a sliver of the live picture with a status dot.
@interface YMPreviewTab : YMPreviewHitView
@property(nonatomic) CALayer *picture;
@end
@implementation YMPreviewTab
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 5;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.92].CGColor;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.18].CGColor;
        _picture = [CALayer layer];
        _picture.contentsGravity = kCAGravityResizeAspectFill;
        _picture.frame = self.layer.bounds;
        _picture.opacity = 0.85;
        [self.layer addSublayer:_picture];
    }
    return self;
}
- (void)layout { [super layout]; self.picture.frame = self.layer.bounds; }
@end

// Expanded card: live thumbnail with the display name on a soft gradient.
@interface YMPreviewCard : YMPreviewHitView
@property(nonatomic) CALayer *picture;
@property(nonatomic) CAGradientLayer *shade;
@property(nonatomic) NSTextField *label;
@end
@implementation YMPreviewCard
- (instancetype)initWithFrame:(NSRect)frame name:(NSString *)name {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 10;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.22].CGColor;
        _picture = [CALayer layer];
        _picture.contentsGravity = kCAGravityResizeAspect;
        [self.layer addSublayer:_picture];
        _shade = [CAGradientLayer layer];
        _shade.colors = @[(id)[NSColor colorWithWhite:0 alpha:0.55].CGColor, (id)[NSColor colorWithWhite:0 alpha:0].CGColor];
        _shade.startPoint = CGPointMake(0.5, 0);
        _shade.endPoint = CGPointMake(0.5, 1);
        [self.layer addSublayer:_shade];
        _label = [NSTextField labelWithString:name];
        _label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        _label.textColor = NSColor.whiteColor;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_label];
        self.toolTip = [NSString stringWithFormat:@"查看 %@", name];
    }
    return self;
}
- (void)layout {
    [super layout];
    self.picture.frame = self.layer.bounds;
    self.shade.frame = CGRectMake(0, 0, self.bounds.size.width, 34);
    self.label.frame = NSMakeRect(10, 7, self.bounds.size.width - 20, 16);
}
@end

// Dock content: tracks hover to expand and collapse.
@interface YMPreviewDockView : NSView
@property(nonatomic, copy, nullable) void (^onHover)(BOOL inside);
@end
@implementation YMPreviewDockView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; if (self.onHover) self.onHover(YES); }
- (void)mouseExited:(NSEvent *)event { (void)event; if (self.onHover) self.onHover(NO); }
@end

// Picture-in-picture content: live picture, controls fade in on hover.
@interface YMPiPView : YMPreviewHitView
@property(nonatomic) CALayer *picture;
@property(nonatomic) NSView *bar;
@property(nonatomic) NSTextField *title;
@property(nonatomic) NSButton *closeButton;
@property(nonatomic) NSButton *takeoverButton;
@property(nonatomic) BOOL takeover;
@property(nonatomic, copy, nullable) void (^onForward)(NSEvent *event, NSPoint point);
@end
@implementation YMPiPView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        _picture = [CALayer layer];
        _picture.contentsGravity = kCAGravityResizeAspect;
        [self.layer addSublayer:_picture];
        _bar = [[NSView alloc] init];
        _bar.wantsLayer = YES;
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.colors = @[(id)[NSColor colorWithWhite:0 alpha:0].CGColor, (id)[NSColor colorWithWhite:0 alpha:0.5].CGColor];
        _bar.layer = gradient;
        _bar.alphaValue = 0;
        [self addSubview:_bar];
        _title = [NSTextField labelWithString:@""];
        _title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        _title.textColor = NSColor.whiteColor;
        [_bar addSubview:_title];
        NSImage *close = [NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:@"收起预览"];
        _closeButton = [NSButton buttonWithImage:close target:nil action:nil];
        _closeButton.bordered = NO;
        _closeButton.contentTintColor = [NSColor colorWithWhite:1 alpha:0.9];
        _closeButton.toolTip = @"收起预览";
        [_bar addSubview:_closeButton];
        _takeoverButton = [NSButton buttonWithTitle:@"接管" target:nil action:nil];
        _takeoverButton.bezelStyle = NSBezelStyleInline;
        _takeoverButton.controlSize = NSControlSizeSmall;
        _takeoverButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        _takeoverButton.toolTip = @"在这个画面里直接操作虚拟屏;Agent 会暂停";
        [_bar addSubview:_takeoverButton];
    }
    return self;
}
- (void)setTakeover:(BOOL)takeover {
    _takeover = takeover;
    self.layer.borderWidth = takeover ? 3 : 0;
    self.layer.borderColor = NSColor.controlAccentColor.CGColor;
    self.takeoverButton.title = takeover ? @"交还" : @"接管";
    self.takeoverButton.toolTip = takeover ? @"交还给 Agent" : @"在这个画面里直接操作虚拟屏;Agent 会暂停";
    self.bar.alphaValue = takeover ? 1 : self.bar.alphaValue;
    [self needsLayout];
}
- (BOOL)mouseDownCanMoveWindow { return !self.takeover; }
- (BOOL)forwardIfTakingOver:(NSEvent *)event {
    if (!self.takeover || !self.onForward) return NO;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSView *hit = [self hitTest:[self.superview convertPoint:event.locationInWindow fromView:nil]];
    if ([hit isKindOfClass:NSButton.class]) return NO;
    self.onForward(event, point);
    return YES;
}
- (void)mouseDown:(NSEvent *)event { if (![self forwardIfTakingOver:event]) [super mouseDown:event]; }
- (void)mouseDragged:(NSEvent *)event { if (![self forwardIfTakingOver:event]) [super mouseDragged:event]; }
- (void)mouseUp:(NSEvent *)event { if (![self forwardIfTakingOver:event]) [super mouseUp:event]; }
- (void)rightMouseDown:(NSEvent *)event { if (![self forwardIfTakingOver:event]) [super rightMouseDown:event]; }
- (void)rightMouseUp:(NSEvent *)event { if (![self forwardIfTakingOver:event]) [super rightMouseUp:event]; }
- (void)scrollWheel:(NSEvent *)event { if (![self forwardIfTakingOver:event]) [super scrollWheel:event]; }
- (void)layout {
    [super layout];
    self.picture.frame = self.layer.bounds;
    CGFloat height = 40;
    self.bar.frame = NSMakeRect(0, self.bounds.size.height - height, self.bounds.size.width, height);
    self.title.frame = NSMakeRect(14, 12, self.bounds.size.width - 130, 16);
    self.closeButton.frame = NSMakeRect(self.bounds.size.width - 34, 10, 20, 20);
    self.takeoverButton.frame = NSMakeRect(self.bounds.size.width - 92, 9, 52, 22);
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; YMAnimate(0.18, ^{ self.bar.animator.alphaValue = 1; }, nil); }
- (void)mouseExited:(NSEvent *)event { (void)event; if (!self.takeover) YMAnimate(0.25, ^{ self.bar.animator.alphaValue = 0; }, nil); }
@end

#pragma mark - Controller

@interface YMWorkspacePreview ()
@property(nonatomic, readwrite) BOOL enabled;
@property(nonatomic) NSArray<NSDictionary *> *displays;
@property(nonatomic) NSMutableDictionary<NSNumber *, YMPreviewSource *> *sources;
@property(nonatomic, nullable) YMPreviewPanel *dock;
@property(nonatomic, nullable) YMPreviewDockView *dockView;
@property(nonatomic) NSMutableArray<YMPreviewTab *> *tabs;
@property(nonatomic) NSMutableArray<YMPreviewCard *> *cards;
@property(nonatomic) BOOL expanded;
@property(nonatomic) BOOL fetching;
@property(nonatomic) NSUInteger retries;
@property(nonatomic, nullable) YMPreviewPanel *pip;
@property(nonatomic, nullable) YMPiPView *pipView;
@property(nonatomic, nullable) NSNumber *pipDisplayID;
@property(nonatomic) BOOL permissionMissing;
@property(nonatomic, readwrite, nullable) NSNumber *takeoverDisplayID;
@property(nonatomic, nullable) NSRunningApplication *takeoverPreviousApp;
@property(nonatomic, nullable) id takeoverPreviousWindow;
@end

@implementation YMWorkspacePreview
- (instancetype)init {
    if ((self = [super init])) {
        _enabled = [NSUserDefaults.standardUserDefaults boolForKey:YMPreviewEnabledKey];
        _displays = @[];
        _sources = [NSMutableDictionary dictionary];
        _tabs = [NSMutableArray array];
        _cards = [NSMutableArray array];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screensChanged:)
            name:NSApplicationDidChangeScreenParametersNotification object:nil];
    }
    return self;
}
- (void)invalidate {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self teardown];
}
- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:YMPreviewEnabledKey];
    if (enabled && !CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();
    [self reconcile];
}
- (void)updateDisplays:(NSArray<NSDictionary *> *)displays {
    if ([displays isEqualToArray:self.displays]) return;
    self.displays = [displays copy];
    self.retries = 0;
    [self reconcile];
}
- (void)screensChanged:(NSNotification *)note {
    (void)note;
    [self layoutDockAnimated:NO];
}

- (void)teardown {
    for (YMPreviewSource *source in self.sources.allValues) [source stop];
    [self.sources removeAllObjects];
    [self closePiP];
    [self.dock orderOut:nil];
    self.dock = nil;
    self.dockView = nil;
    [self.tabs removeAllObjects];
    [self.cards removeAllObjects];
    self.expanded = NO;
}

- (void)reconcile {
    if (!self.enabled || !self.displays.count) { [self teardown]; return; }
    NSMutableSet *wanted = [NSMutableSet set];
    for (NSDictionary *display in self.displays) [wanted addObject:display[@"displayID"]];
    for (NSNumber *ident in self.sources.allKeys) {
        if ([wanted containsObject:ident]) continue;
        [self.sources[ident] stop];
        [self.sources removeObjectForKey:ident];
    }
    if (self.pipDisplayID && ![wanted containsObject:self.pipDisplayID]) [self closePiP];
    self.permissionMissing = !CGPreflightScreenCaptureAccess();
    [self rebuildDock];
    if (!self.permissionMissing) [self startMissingSources];
}

- (void)startMissingSources {
    BOOL missing = NO;
    for (NSDictionary *display in self.displays) if (!self.sources[display[@"displayID"]]) missing = YES;
    if (!missing || self.fetching) return;
    self.fetching = YES;
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
        completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.fetching = NO;
            if (!self.enabled) return;
            if (!content || error) {
                self.permissionMissing = !CGPreflightScreenCaptureAccess();
                [self rebuildDock];
                return;
            }
            BOOL stillMissing = NO;
            for (NSDictionary *display in self.displays) {
                NSNumber *ident = display[@"displayID"];
                if (self.sources[ident]) continue;
                SCDisplay *match = nil;
                for (SCDisplay *candidate in content.displays) if (candidate.displayID == ident.unsignedIntValue) match = candidate;
                YMPreviewSource *source = match ? [[YMPreviewSource alloc] initWithDisplay:match] : nil;
                if (source) self.sources[ident] = source; else stillMissing = YES;
            }
            [self bindLayers];
            // A display that was just created can take a moment to reach ScreenCaptureKit.
            if (stillMissing && self.retries < 10) {
                self.retries += 1;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self startMissingSources]; });
            }
        });
    }];
}

- (void)bindLayers {
    for (NSUInteger index = 0; index < self.displays.count && index < self.cards.count; index++) {
        YMPreviewSource *source = self.sources[self.displays[index][@"displayID"]];
        if (!source) continue;
        [source attachLayer:self.cards[index].picture];
        if (index < self.tabs.count) [source attachLayer:self.tabs[index].picture];
    }
    if (self.pipDisplayID && self.sources[self.pipDisplayID]) {
        [self.sources[self.pipDisplayID] attachLayer:self.pipView.picture];
        self.sources[self.pipDisplayID].live = YES;
    }
}

#pragma mark Dock

- (NSScreen *)dockScreen {
    // The rightmost physical screen; virtual displays are never used for the dock.
    NSScreen *best = nil;
    for (NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID ident = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if ([VDVirtualDisplay isVirtualDisplay:ident]) continue;
        if (!best || NSMaxX(screen.frame) > NSMaxX(best.frame)) best = screen;
    }
    return best ?: NSScreen.mainScreen;
}

- (NSUInteger)itemCount { return self.permissionMissing ? 1 : self.displays.count; }

- (NSRect)dockFrameExpanded:(BOOL)expanded {
    NSRect visible = [self dockScreen].visibleFrame;
    CGFloat count = (CGFloat)MAX((NSUInteger)1, [self itemCount]);
    CGFloat width = expanded ? YMCardWidth + YMDockPad * 2 : YMTabWidth;
    CGFloat height = expanded ? count * YMCardHeight + (count - 1) * YMCardGap + YMDockPad * 2
                              : count * YMTabHeight + (count - 1) * YMTabGap;
    return NSMakeRect(NSMaxX(visible) - width, NSMidY(visible) - height / 2, width, height);
}

- (void)rebuildDock {
    if (!self.dock) {
        YMPreviewPanel *panel = [[YMPreviewPanel alloc] initWithContentRect:[self dockFrameExpanded:NO]
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        YMConfigureFloatingPanel(panel);
        panel.opaque = NO;
        panel.backgroundColor = NSColor.clearColor;
        panel.hasShadow = NO;
        YMPreviewDockView *view = [[YMPreviewDockView alloc] initWithFrame:NSZeroRect];
        view.wantsLayer = YES;
        __weak YMWorkspacePreview *weakSelf = self;
        view.onHover = ^(BOOL inside) { [weakSelf hoverChanged:inside]; };
        panel.contentView = view;
        self.dock = panel;
        self.dockView = view;
    }
    for (NSView *view in [(NSArray<NSView *> *)self.tabs arrayByAddingObjectsFromArray:(NSArray<NSView *> *)self.cards]) [view removeFromSuperview];
    for (YMPreviewSource *source in self.sources.allValues) [source.layers removeAllObjects];
    [self.tabs removeAllObjects];
    [self.cards removeAllObjects];
    __weak YMWorkspacePreview *weakSelf = self;
    if (self.permissionMissing) {
        YMPreviewTab *tab = [[YMPreviewTab alloc] initWithFrame:NSZeroRect];
        tab.layer.backgroundColor = NSColor.systemOrangeColor.CGColor;
        tab.onClick = ^{ [weakSelf requestPermission]; };
        YMPreviewCard *card = [[YMPreviewCard alloc] initWithFrame:NSZeroRect name:@"需要「屏幕录制」权限才能预览 · 点此授权"];
        card.layer.backgroundColor = [NSColor colorWithWhite:0.16 alpha:0.95].CGColor;
        card.label.lineBreakMode = NSLineBreakByWordWrapping;
        card.onClick = ^{ [weakSelf requestPermission]; };
        [self.tabs addObject:tab];
        [self.cards addObject:card];
    } else {
        for (NSDictionary *display in self.displays) {
            NSNumber *ident = display[@"displayID"];
            YMPreviewTab *tab = [[YMPreviewTab alloc] initWithFrame:NSZeroRect];
            tab.toolTip = display[@"name"];
            tab.onClick = ^{ [weakSelf openPiPForDisplayID:ident]; };
            YMPreviewCard *card = [[YMPreviewCard alloc] initWithFrame:NSZeroRect name:display[@"name"] ?: @""];
            card.onClick = ^{ [weakSelf openPiPForDisplayID:ident]; };
            [self.tabs addObject:tab];
            [self.cards addObject:card];
        }
    }
    for (NSView *view in [(NSArray<NSView *> *)self.tabs arrayByAddingObjectsFromArray:(NSArray<NSView *> *)self.cards]) [self.dockView addSubview:view];
    [self bindLayers];
    [self layoutDockAnimated:NO];
    [self.dock orderFrontRegardless];
}

- (void)layoutSubviewsExpanded:(BOOL)expanded inSize:(NSSize)size {
    CGFloat y = size.height - (expanded ? YMDockPad : 0);
    for (NSUInteger index = 0; index < self.cards.count; index++) {
        if (expanded) {
            y -= YMCardHeight;
            self.cards[index].frame = NSMakeRect(YMDockPad, y, YMCardWidth, YMCardHeight);
            y -= YMCardGap;
        } else {
            y -= YMTabHeight;
            self.tabs[index].frame = NSMakeRect(0, y, YMTabWidth, YMTabHeight);
            y -= YMTabGap;
        }
    }
}

- (void)layoutDockAnimated:(BOOL)animated {
    if (!self.dock) return;
    BOOL expanded = self.expanded;
    NSRect frame = [self dockFrameExpanded:expanded];
    [self layoutSubviewsExpanded:expanded inSize:frame.size];
    void (^changes)(void) = ^{
        [self.dock.animator setFrame:frame display:YES];
        for (YMPreviewTab *tab in self.tabs) tab.animator.alphaValue = expanded ? 0 : 1;
        for (YMPreviewCard *card in self.cards) card.animator.alphaValue = expanded ? 1 : 0;
    };
    if (animated) YMAnimate(0.24, changes, nil);
    else {
        [self.dock setFrame:frame display:YES];
        for (YMPreviewTab *tab in self.tabs) tab.alphaValue = expanded ? 0 : 1;
        for (YMPreviewCard *card in self.cards) card.alphaValue = expanded ? 1 : 0;
    }
}

- (void)hoverChanged:(BOOL)inside {
    if (inside) {
        if (self.expanded) return;
        self.expanded = YES;
        [self layoutDockAnimated:YES];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.dock || NSPointInRect(NSEvent.mouseLocation, self.dock.frame)) return;
        [self collapseDock];
    });
}
- (void)collapseDock {
    if (!self.expanded) return;
    self.expanded = NO;
    [self layoutDockAnimated:YES];
}

- (void)requestPermission {
    CGRequestScreenCaptureAccess();
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}

#pragma mark Agent action marks

- (void)markPoint:(CGPoint)point {
    if (!self.enabled) return;
    for (NSUInteger index = 0; index < self.displays.count; index++) {
        NSNumber *ident = self.displays[index][@"displayID"];
        CGRect bounds = CGDisplayBounds(ident.unsignedIntValue);
        if (!CGRectContainsPoint(bounds, point)) continue;
        // Normalized position, origin bottom-left to match AppKit layers.
        CGFloat nx = (point.x - bounds.origin.x) / bounds.size.width;
        CGFloat ny = 1 - (point.y - bounds.origin.y) / bounds.size.height;
        NSMutableArray<CALayer *> *hosts = [NSMutableArray array];
        if (index < self.cards.count) [hosts addObject:self.cards[index].picture];
        if ([self.pipDisplayID isEqual:ident] && self.pip.visible) [hosts addObject:self.pipView.picture];
        for (CALayer *host in hosts) {
            CGRect fit = YMAspectFitRect(bounds.size, host.bounds);
            CGPoint at = CGPointMake(CGRectGetMinX(fit) + nx * fit.size.width, CGRectGetMinY(fit) + ny * fit.size.height);
            YMAddRipple(host, at, MAX(7, fit.size.width / 60));
        }
        return;
    }
}

#pragma mark Takeover

// The person drives the virtual display from the picture-in-picture panel.
// Each mouse event is replayed at the matching point on the virtual display
// and the pointer is put straight back over the panel, so the person keeps
// their place. Clicking there activates the target app, so the physical
// keyboard types into it directly. Handing back restores the app and window
// that had focus before.
- (void)toggleTakeover:(id)sender {
    (void)sender;
    if (self.takeoverDisplayID) [self endTakeover]; else [self beginTakeover];
}
- (void)beginTakeover {
    if (!self.pipDisplayID || !AXIsProcessTrusted()) return;
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    self.takeoverPreviousApp = front;
    self.takeoverPreviousWindow = nil;
    if (front) {
        AXUIElementRef app = AXUIElementCreateApplication(front.processIdentifier);
        CFTypeRef window = NULL;
        if (app && AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &window) == kAXErrorSuccess && window)
            self.takeoverPreviousWindow = CFBridgingRelease(window);
        if (app) CFRelease(app);
    }
    self.takeoverDisplayID = self.pipDisplayID;
    self.pipView.takeover = YES;
    self.pipView.title.stringValue = [NSString stringWithFormat:@"你在操作 %@ · Agent 已暂停", [self nameForDisplayID:self.pipDisplayID]];
}
- (void)endTakeover {
    if (!self.takeoverDisplayID) return;
    self.takeoverDisplayID = nil;
    self.pipView.takeover = NO;
    if (self.pipDisplayID) self.pipView.title.stringValue = [self nameForDisplayID:self.pipDisplayID];
    NSRunningApplication *previous = self.takeoverPreviousApp;
    if (previous && !previous.terminated) {
        AXUIElementRef app = AXUIElementCreateApplication(previous.processIdentifier);
        if (self.takeoverPreviousWindow) AXUIElementPerformAction((__bridge AXUIElementRef)self.takeoverPreviousWindow, kAXRaiseAction);
        if (app) { AXUIElementSetAttributeValue(app, kAXFrontmostAttribute, kCFBooleanTrue); CFRelease(app); }
    }
    self.takeoverPreviousApp = nil;
    self.takeoverPreviousWindow = nil;
}
- (void)forwardEvent:(NSEvent *)event atViewPoint:(NSPoint)point {
    if (!self.takeoverDisplayID) return;
    CGRect bounds = CGDisplayBounds(self.takeoverDisplayID.unsignedIntValue);
    CGRect fit = YMAspectFitRect(bounds.size, self.pipView.picture.bounds);
    CGFloat nx = (point.x - fit.origin.x) / fit.size.width;
    CGFloat ny = 1 - (point.y - fit.origin.y) / fit.size.height;
    if (nx < 0 || nx > 1 || ny < 0 || ny > 1) return;
    CGPoint target = CGPointMake(bounds.origin.x + nx * bounds.size.width, bounds.origin.y + ny * bounds.size.height);
    CGEventRef now = CGEventCreate(NULL);
    CGPoint back = now ? CGEventGetLocation(now) : CGPointZero;
    if (now) CFRelease(now);
    CGEventRef replay = NULL;
    switch (event.type) {
        case NSEventTypeLeftMouseDown: replay = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, target, kCGMouseButtonLeft); break;
        case NSEventTypeLeftMouseUp: replay = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, target, kCGMouseButtonLeft); break;
        case NSEventTypeLeftMouseDragged: replay = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDragged, target, kCGMouseButtonLeft); break;
        case NSEventTypeRightMouseDown: replay = CGEventCreateMouseEvent(NULL, kCGEventRightMouseDown, target, kCGMouseButtonRight); break;
        case NSEventTypeRightMouseUp: replay = CGEventCreateMouseEvent(NULL, kCGEventRightMouseUp, target, kCGMouseButtonRight); break;
        case NSEventTypeScrollWheel: {
            double scale = event.hasPreciseScrollingDeltas ? 1 : 10;
            replay = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2,
                (int32_t)llround(event.scrollingDeltaY * scale), (int32_t)llround(event.scrollingDeltaX * scale), 0);
            break;
        }
        default: break;
    }
    if (!replay) return;
    if (event.type != NSEventTypeScrollWheel) CGEventSetIntegerValueField(replay, kCGMouseEventClickState, event.clickCount);
    CGWarpMouseCursorPosition(target);
    CGEventSetLocation(replay, target);
    CGEventPost(kCGHIDEventTap, replay);
    CFRelease(replay);
    CGWarpMouseCursorPosition(back);
    CGAssociateMouseAndMouseCursorPosition(true);
    if (event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeRightMouseDown) [self markPoint:target];
}

#pragma mark Picture in picture

- (NSString *)nameForDisplayID:(NSNumber *)ident {
    for (NSDictionary *display in self.displays) if ([display[@"displayID"] isEqual:ident]) return display[@"name"] ?: @"";
    return @"";
}

- (NSRect)defaultPiPFrame {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:YMPreviewPiPFrameKey];
    NSRect frame = saved.length ? NSRectFromString(saved) : NSZeroRect;
    for (NSScreen *screen in NSScreen.screens)
        if (frame.size.width >= 240 && NSContainsRect(screen.visibleFrame, frame)) return frame;
    NSRect visible = [self dockScreen].visibleFrame;
    CGFloat width = 640, height = 360;
    return NSMakeRect(NSMaxX(visible) - width - YMTabWidth - 24, NSMinY(visible) + 24, width, height);
}

- (void)openPiPForDisplayID:(NSNumber *)ident {
    [self collapseDock];
    if (self.pipDisplayID && ![self.pipDisplayID isEqual:ident]) {
        [self endTakeover];
        YMPreviewSource *previous = self.sources[self.pipDisplayID];
        [previous detachLayer:self.pipView.picture];
        previous.live = NO;
    }
    if (!self.pip) {
        YMPreviewPanel *panel = [[YMPreviewPanel alloc] initWithContentRect:[self defaultPiPFrame]
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView | NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        YMConfigureFloatingPanel(panel);
        panel.titleVisibility = NSWindowTitleHidden;
        panel.titlebarAppearsTransparent = YES;
        for (NSWindowButton button = NSWindowCloseButton; button <= NSWindowZoomButton; button++)
            [panel standardWindowButton:button].hidden = YES;
        panel.movableByWindowBackground = YES;
        panel.contentAspectRatio = NSMakeSize(16, 9);
        panel.minSize = NSMakeSize(320, 180);
        panel.backgroundColor = NSColor.blackColor;
        YMPiPView *view = [[YMPiPView alloc] initWithFrame:NSZeroRect];
        __weak YMWorkspacePreview *weakSelf = self;
        view.onDoubleClick = ^{ [weakSelf togglePiPSize]; };
        view.closeButton.target = self;
        view.closeButton.action = @selector(closePiPFromButton:);
        view.takeoverButton.target = self;
        view.takeoverButton.action = @selector(toggleTakeover:);
        view.onForward = ^(NSEvent *event, NSPoint point) { [weakSelf forwardEvent:event atViewPoint:point]; };
        panel.contentView = view;
        self.pip = panel;
        self.pipView = view;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(pipFrameChanged:) name:NSWindowDidEndLiveResizeNotification object:panel];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(pipFrameChanged:) name:NSWindowDidMoveNotification object:panel];
    }
    self.pipDisplayID = ident;
    self.pipView.title.stringValue = [self nameForDisplayID:ident];
    YMSetContents(self.pipView.picture, nil);
    YMPreviewSource *source = self.sources[ident];
    if (source) { [source attachLayer:self.pipView.picture]; source.live = YES; }
    if (!self.pip.visible) {
        self.pip.alphaValue = 0;
        [self.pip orderFrontRegardless];
        YMAnimate(0.2, ^{ self.pip.animator.alphaValue = 1; }, nil);
    }
}

- (void)pipFrameChanged:(NSNotification *)note {
    (void)note;
    if (self.pip) [NSUserDefaults.standardUserDefaults setObject:NSStringFromRect(self.pip.frame) forKey:YMPreviewPiPFrameKey];
}

- (void)togglePiPSize {
    NSRect frame = self.pip.frame;
    NSRect visible = (self.pip.screen ?: [self dockScreen]).visibleFrame;
    BOOL large = frame.size.width >= 1000;
    CGFloat width = large ? 640 : MIN(1280, visible.size.width - 48);
    CGFloat height = width * 9 / 16;
    NSRect next = NSMakeRect(NSMaxX(frame) - width, NSMinY(frame), width, height);
    next.origin.x = MAX(NSMinX(visible) + 12, MIN(next.origin.x, NSMaxX(visible) - width - 12));
    next.origin.y = MAX(NSMinY(visible) + 12, MIN(next.origin.y, NSMaxY(visible) - height - 12));
    YMAnimate(0.25, ^{ [self.pip.animator setFrame:next display:YES]; }, nil);
}

- (void)closePiPFromButton:(id)sender { (void)sender; [self closePiP]; }

- (void)closePiP {
    if (!self.pip) return;
    [self endTakeover];
    if (self.pipDisplayID) {
        YMPreviewSource *source = self.sources[self.pipDisplayID];
        [source detachLayer:self.pipView.picture];
        source.live = NO;
    }
    self.pipDisplayID = nil;
    YMPreviewPanel *panel = self.pip;
    YMAnimate(0.18, ^{ panel.animator.alphaValue = 0; }, ^{ [panel orderOut:nil]; });
}
@end
