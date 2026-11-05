#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

#pragma mark - 日志（写到微信沙盒 Documents/GlideProbe）

static NSMutableString *gLog = nil;
static NSLock *gLock = nil;

static NSString *GPOutDir(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    NSString *dir = [docs stringByAppendingPathComponent:@"GlideProbe"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *GPLogPath(void) {
    return [GPOutDir() stringByAppendingPathComponent:@"GlideProbe.log"];
}

static void GPStartLog(void) {
    if (!gLock) gLock = [NSLock new];
    gLog = [NSMutableString string];
}

static void GPFlush(void) {
    if (!gLog) return;
    [gLock lock];
    [gLog writeToFile:GPLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [gLock unlock];
    NSLog(@"[GlideProbe] log written to %@", GPLogPath());
}

#define GPLog(fmt, ...) do { \
    NSString *_line = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    if (gLog) { [gLock lock]; [gLog appendFormat:@"%@\n", _line]; [gLock unlock]; } \
    NSLog(@"[GlideProbe] %@", _line); \
} while (0)

#pragma mark - runtime 工具

static NSArray<NSString *> *GPAllClassNames(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return @[];
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(classes, count);
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:count];
    for (int i = 0; i < count; i++) {
        const char *n = class_getName(classes[i]);
        if (n) [names addObject:[NSString stringWithUTF8String:n]];
    }
    free(classes);
    return names;
}

static NSArray<NSString *> *GPMethodsOfClass(Class cls, BOOL classMethods) {
    NSMutableArray *out = [NSMutableArray array];
    unsigned int n = 0;
    Method *methods = class_copyMethodList(classMethods ? object_getClass(cls) : cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        SEL sel = method_getName(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        [out addObject:[NSString stringWithFormat:@"%c%s  %s",
                        classMethods ? '+' : '-',
                        sel_getName(sel), types ?: ""]];
    }
    free(methods);
    return out;
}

static NSArray<NSString *> *GPPropertiesOfClass(Class cls) {
    NSMutableArray *out = [NSMutableArray array];
    unsigned int n = 0;
    objc_property_t *props = class_copyPropertyList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        [out addObject:[NSString stringWithFormat:@"%s  %s",
                        property_getName(props[i]) ?: "",
                        property_getAttributes(props[i]) ?: ""]];
    }
    free(props);
    return out;
}

static NSArray<NSString *> *GPIvarsOfClass(Class cls) {
    NSMutableArray *out = [NSMutableArray array];
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        [out addObject:[NSString stringWithFormat:@"%s  %s",
                        ivar_getName(ivars[i]) ?: "",
                        ivar_getTypeEncoding(ivars[i]) ?: ""]];
    }
    free(ivars);
    return out;
}

static NSArray<NSString *> *GPClassesMatching(NSArray<NSString *> *keywords) {
    NSMutableArray *matched = [NSMutableArray array];
    for (NSString *name in GPAllClassNames()) {
        for (NSString *kw in keywords) {
            if ([name rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [matched addObject:name]; break;
            }
        }
    }
    return matched;
}

static void GPDumpClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) { GPLog(@"[missing] %@", name); return; }
    GPLog(@"=== %@ (super=%@) ===", name, NSStringFromClass(class_getSuperclass(cls)));
    NSArray *props = GPPropertiesOfClass(cls);
    if (props.count) {
        GPLog(@"  -- properties (%lu) --", (unsigned long)props.count);
        for (NSString *p in props) GPLog(@"    %@", p);
    }
    NSArray *ivars = GPIvarsOfClass(cls);
    if (ivars.count) {
        GPLog(@"  -- ivars (%lu) --", (unsigned long)ivars.count);
        for (NSString *iv in ivars) GPLog(@"    %@", iv);
    }
    NSArray *im = GPMethodsOfClass(cls, NO);
    if (im.count) {
        GPLog(@"  -- instance methods (%lu) --", (unsigned long)im.count);
        for (NSString *m in im) GPLog(@"    %@", m);
    }
    NSArray *cm = GPMethodsOfClass(cls, YES);
    if (cm.count) {
        GPLog(@"  -- class methods (%lu) --", (unsigned long)cm.count);
        for (NSString *m in cm) GPLog(@"    %@", m);
    }
}

#pragma mark - Hook（只读打印调用参数）

static void GPHookSelector(Class cls, SEL sel, NSString *tag) {
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        GPLog(@"[hook-miss] %@ -[%@ %@]", tag, NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }
    IMP origIMP = method_getImplementation(m);
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
    NSInteger nargs = sig ? sig.numberOfArguments : 2;

    IMP newIMP = imp_implementationWithBlock(^(id _self, ...) {
        va_list ap; va_start(ap, _self);
        NSMutableString *args = [NSMutableString string];
        for (NSInteger i = 2; i < nargs; i++) {
            @try {
                id v = va_arg(ap, id);
                [args appendFormat:@" arg%ld=%@", (long)i - 2, v];
            } @catch (NSException *e) {
                [args appendFormat:@" arg%ld=<non-object>", (long)i - 2];
                break;
            }
        }
        va_end(ap);
        GPLog(@"[hook] %@ -[%@ %@]%@", tag, NSStringFromClass(cls), NSStringFromSelector(sel), args);
        typedef id (*Fn)(id, SEL, ...);
        return ((Fn)origIMP)(_self, sel);
    });
    method_setImplementation(m, newIMP);
}

static void GPInstallHooks(void) {
    GPLog(@"\n########## 安装 Hook ##########");
    for (NSString *cn in GPClassesMatching(@[@"Menu", @"LongPress", @"ContextMenu"])) {
        Class cls = NSClassFromString(cn); unsigned int n = 0;
        Method *ms = class_copyMethodList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *sn = NSStringFromSelector(method_getName(ms[i]));
            if ([sn rangeOfString:@"menu" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [sn rangeOfString:@"select" options:NSCaseInsensitiveSearch].location != NSNotFound)
                GPHookSelector(cls, method_getName(ms[i]), @"menu");
        }
        free(ms);
    }
    for (NSString *cn in GPClassesMatching(@[@"InputView", @"InputBar", @"ChatInput"])) {
        Class cls = NSClassFromString(cn); unsigned int n = 0;
        Method *ms = class_copyMethodList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *sn = NSStringFromSelector(method_getName(ms[i]));
            if ([sn rangeOfString:@"send" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [sn rangeOfString:@"text" options:NSCaseInsensitiveSearch].location != NSNotFound)
                GPHookSelector(cls, method_getName(ms[i]), @"input");
        }
        free(ms);
    }
    for (NSString *cn in GPClassesMatching(@[@"MessageMgr", @"MsgMgr"])) {
        Class cls = NSClassFromString(cn);
        GPHookSelector(cls, NSSelectorFromString(@"AsyncOnAddMsg:MsgWrap:"), @"msg");
        GPHookSelector(cls, NSSelectorFromString(@"onAddMsg:MsgWrap:"), @"msg");
    }
}

#pragma mark - 探测任务

static void GPProbeRuntimeOverview(void) {
    GPLog(@"\n########## 运行时概览 ##########");
    NSArray *all = GPAllClassNames();
    GPLog(@"已加载类总数: %lu", (unsigned long)all.count);
    NSArray *wx = GPClassesMatching(@[@"MM", @"WC", @"WX", @"WeChat", @"Tencent"]);
    GPLog(@"疑似微信类数量: %lu", (unsigned long)wx.count);
    NSUInteger lim = MIN(wx.count, (NSUInteger)200);
    for (NSUInteger i = 0; i < lim; i++) GPLog(@"  %@", wx[i]);
    if (wx.count > lim) GPLog(@"  ... 其余 %lu 个省略", (unsigned long)(wx.count - lim));
}

static void GPRunProbe(void) {
    GPStartLog();
    GPLog(@"GlideProbe start, pid=%d bundle=%@", getpid(), [[NSBundle mainBundle] bundleIdentifier]);
    GPLog(@"log path=%@", GPLogPath());

    GPProbeRuntimeOverview();

    GPLog(@"\n########## 消息相关类 ##########");
    for (NSString *n in GPClassesMatching(@[@"CMessage", @"MessageWrap", @"MsgWrap", @"MessageMgr",
                                            @"MsgMgr", @"MessageCell", @"MessageView", @"MsgView"]))
        GPDumpClass(n);

    GPLog(@"\n########## 联系人与会话类 ##########");
    for (NSString *n in GPClassesMatching(@[@"Contact", @"Session", @"ChatContact",
                                            @"Friend", @"Conversation"]))
        GPDumpClass(n);

    GPLog(@"\n########## 长按消息菜单 ##########");
    for (NSString *n in GPClassesMatching(@[@"Menu", @"MenuItem", @"UIMenu",
                                            @"LongPress", @"ContextMenu"]))
        GPDumpClass(n);

    GPLog(@"\n########## 消息输入框 ##########");
    for (NSString *n in GPClassesMatching(@[@"InputView", @"InputBar", @"InputTool",
                                            @"TextView", @"Keyboard", @"ChatInput"]))
        GPDumpClass(n);

    GPLog(@"\n########## 聊天记录读取相关 ##########");
    for (NSString *n in GPClassesMatching(@[@"MessageDB", @"MMDB", @"WCDB", @"Database",
                                            @"ChatLog", @"History", @"MessageStorage"]))
        GPDumpClass(n);

    GPInstallHooks();
    GPFlush();
}

#pragma mark - 悬浮按钮 + 系统分享面板

@interface GPFloatingButton : UIButton @end
@implementation GPFloatingButton
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.gestureRecognizers.count == 0) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(onPan:)];
        [self addGestureRecognizer:pan];
    }
}
- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.superview];
}
@end

static UIWindow *gOverlayWindow = nil;

static UIViewController *GPTopViewController(void) {
    UIViewController *top = gOverlayWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

static void GPShowShareSheet(void) {
    GPFlush();
    if (![[NSFileManager defaultManager] fileExistsAtPath:GPLogPath()]) {
        NSLog(@"[GlideProbe] log not found: %@", GPLogPath());
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:GPLogPath()];
    UIActivityViewController *vc = [[UIActivityViewController alloc]
                                    initWithActivityItems:@[url] applicationActivities:nil];
    UIViewController *root = GPTopViewController();
    if (vc.popoverPresentationController) {
        vc.popoverPresentationController.sourceView = root.view;
        vc.popoverPresentationController.sourceRect =
            CGRectMake(root.view.bounds.size.width / 2,
                       root.view.bounds.size.height / 2, 1, 1);
        vc.popoverPresentationController.permittedArrowDirections = 0;
    }
    [root presentViewController:vc animated:YES completion:nil];
}

static void GPInstallFloatingButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s; break;
            }
        }
        if (!scene) {
            // 场景还没就绪，1 秒后重试
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ GPInstallFloatingButton(); });
            return;
        }

        gOverlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
        gOverlayWindow.windowLevel = UIWindowLevelAlert + 100;
        gOverlayWindow.backgroundColor = [UIColor clearColor];
        gOverlayWindow.rootViewController = [UIViewController new];

        GPFloatingButton *btn = [GPFloatingButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, 0, 54, 54);
        btn.center = CGPointMake(scene.coordinateSpace.bounds.size.width - 44, 140);
        btn.layer.cornerRadius = 27;
        btn.backgroundColor = [UIColor colorWithRed:0.10 green:0.50 blue:1.0 alpha:0.85];
        [btn setTitle:@"GP" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.layer.shadowColor = [UIColor blackColor].CGColor;
        btn.layer.shadowOpacity = 0.4;
        btn.layer.shadowRadius = 4;
        btn.layer.shadowOffset = CGSizeMake(0, 2);

        [btn addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull a) {
            GPShowShareSheet();
        }] forControlEvents:UIControlEventTouchUpInside];

        [gOverlayWindow.rootViewController.view addSubview:btn];
        gOverlayWindow.hidden = NO;
    });
}

#pragma mark - 入口

__attribute__((constructor))
static void GlideProbeInit(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                GPRunProbe();
                GPInstallFloatingButton();
            });
        });
    }];
}
