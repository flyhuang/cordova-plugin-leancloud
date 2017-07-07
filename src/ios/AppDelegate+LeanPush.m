#import "AppDelegate+LeanPush.h"
#import "CDVLeanPush.h"
#import <AVOSCloud/AVOSCloud.h>
#import <objc/runtime.h>
#import <UserNotifications/UserNotifications.h>

@implementation AppDelegate (CDVLean)

void swizzleMethod(Class c, SEL originalSelector)
{
    NSString *original = NSStringFromSelector(originalSelector);

    SEL swizzledSelector = NSSelectorFromString([@"swizzled_" stringByAppendingString:original]);
    SEL noopSelector = NSSelectorFromString([@"noop_" stringByAppendingString:original]);

    Method originalMethod, swizzledMethod, noop;
    originalMethod = class_getInstanceMethod(c, originalSelector);
    swizzledMethod = class_getInstanceMethod(c, swizzledSelector);
    noop = class_getInstanceMethod(c, noopSelector);

    BOOL didAddMethod = class_addMethod(c,
                    originalSelector,
                    method_getImplementation(swizzledMethod),
                    method_getTypeEncoding(swizzledMethod));

    if (didAddMethod)
    {
        class_replaceMethod(c,
                            swizzledSelector,
                            method_getImplementation(noop),
                            method_getTypeEncoding(originalMethod));
    }
    else
    {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [self class];

        swizzleMethod(cls, @selector(application:didFinishLaunchingWithOptions:));
        swizzleMethod(cls, @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:));
        swizzleMethod(cls, @selector(application:didFailToRegisterForRemoteNotificationsWithError:));
        swizzleMethod(cls, @selector(application:didReceiveRemoteNotification:));
        swizzleMethod(cls, @selector(applicationDidBecomeActive:));
    });
}

- (BOOL)swizzled_application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
    // Original application is exchanged with swizzled_application
    // So, when calling swizzled_application, we are actually calling the original application method
    // similar with subclass calling super method. Neat!
    BOOL ret = [self swizzled_application:application didFinishLaunchingWithOptions:launchOptions];

    if (ret) {
        // 注册APNS
        [self registerForRemoteNotification];
        // 初始化leancloud
        [self initLeanCloud];
        // analysis
        if (application.applicationState != UIApplicationStateBackground) {
            // Track an app open here if we launch with a push, unless
            // "content_available" was used to trigger a background push (introduced
            // in iOS 7). In that case, we skip tracking here to avoid double
            // counting the app-open.
            BOOL preBackgroundPush = ![application respondsToSelector:@selector(backgroundRefreshStatus)];
            BOOL oldPushHandlerOnly = ![self respondsToSelector:@selector(application:didReceiveRemoteNotification:fetchCompletionHandler:)];
            BOOL noPushPayload = ![launchOptions objectForKey:UIApplicationLaunchOptionsRemoteNotificationKey];
            if (preBackgroundPush || oldPushHandlerOnly || noPushPayload) {
                [AVAnalytics trackAppOpenedWithLaunchOptions:launchOptions];
            }
        }
    }

    NSDictionary *localNotif = [launchOptions objectForKey:@"UIApplicationLaunchOptionsRemoteNotificationKey"];

    if (localNotif)
    {
        CDVLeanPush *pushHandler = [self.viewController getCommandInstance:@"LeanPush"];
        [pushHandler sendJson:localNotif statusIs: @""];
    }

    return ret;
}

- (void) initLeanCloud {
    NSString *appId = [self.viewController.settings objectForKey:PROP_KEY_LEANCLOUD_APP_ID];
    NSString *appKey = [self.viewController.settings objectForKey:PROP_KEY_LEANCLOUD_APP_KEY];
    if (appId && appKey) {
        [AVOSCloud setApplicationId:appId clientKey:appKey];
    } else {
        NSLog(@"LeanCloud app ID/key not specified");
    }
}

/**
 * 初始化UNUserNotificationCenter
 */
- (void)registerForRemoteNotification {
    // iOS10 兼容
    if ([[UIDevice currentDevice].systemVersion floatValue] >= 10.0) {
        // 使用 UNUserNotificationCenter 来管理通知
        UNUserNotificationCenter *uncenter = [UNUserNotificationCenter currentNotificationCenter];
        // 监听回调事件
        [uncenter setDelegate:self];
        //iOS10 使用以下方法注册，才能得到授权
        [uncenter requestAuthorizationWithOptions:(UNAuthorizationOptionAlert+UNAuthorizationOptionBadge+UNAuthorizationOptionSound)
                                completionHandler:^(BOOL granted, NSError * _Nullable error) {
                                    [[UIApplication sharedApplication] registerForRemoteNotifications];
                                    //TODO:授权状态改变
                                    NSLog(@"%@" , granted ? @"授权成功" : @"授权失败");
                                }];
        // 获取当前的通知授权状态, UNNotificationSettings
        [uncenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
            NSLog(@"%s\nline:%@\n-----\n%@\n\n", __func__, @(__LINE__), settings);
            /*
             UNAuthorizationStatusNotDetermined : 没有做出选择
             UNAuthorizationStatusDenied : 用户未授权
             UNAuthorizationStatusAuthorized ：用户已授权
             */
            if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
                NSLog(@"未选择");
            } else if (settings.authorizationStatus == UNAuthorizationStatusDenied) {
                NSLog(@"未授权");
            } else if (settings.authorizationStatus == UNAuthorizationStatusAuthorized) {
                NSLog(@"已授权");
            }
        }];
    }
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if ([[UIDevice currentDevice].systemVersion floatValue] >= 8.0) {
        UIUserNotificationType types = UIUserNotificationTypeAlert |
        UIUserNotificationTypeBadge |
        UIUserNotificationTypeSound;
        UIUserNotificationSettings *settings = [UIUserNotificationSettings settingsForTypes:types categories:nil];

        [[UIApplication sharedApplication] registerUserNotificationSettings:settings];
        [[UIApplication sharedApplication] registerForRemoteNotifications];
    } else {
        UIRemoteNotificationType types = UIRemoteNotificationTypeBadge |
        UIRemoteNotificationTypeAlert |
        UIRemoteNotificationTypeSound;
        [[UIApplication sharedApplication] registerForRemoteNotificationTypes:types];
    }
    #pragma clang diagnostic pop
}

- (BOOL)noop_application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
    return YES;
}

- (void)swizzled_applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    int num=application.applicationIconBadgeNumber;
    if(num!=0){
        AVInstallation *currentInstallation = [AVInstallation currentInstallation];
        [currentInstallation setBadge:0];
        [currentInstallation saveEventually];
        application.applicationIconBadgeNumber=0;
    }
}

- (void)noop_applicationDidBecomeActive:(UIApplication *)application
{}


- (void)swizzled_application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    [self swizzled_application:application didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];

    NSLog(@"didRegister");
    AVInstallation *currentInstallation = [AVInstallation currentInstallation];
    [currentInstallation setDeviceTokenFromData:deviceToken];
    [currentInstallation setBadge:0];
    [currentInstallation saveInBackground];
    NSString *certificateName = [self.viewController.settings objectForKey:PROP_KEY_LEANCLOUD_PUSH_CERTIFICATE];
    if (certificateName) {
        [currentInstallation setDeviceProfile:certificateName];
    }
}

- (void)noop_application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{}


-(void)swizzled_application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
    [self swizzled_application:application didFailToRegisterForRemoteNotificationsWithError:error];

    [AVAnalytics event:@"Failed enable push notification" label:[error description]];
    NSLog(@"error=%@",[error description]);
}

-(void)noop_application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{}


-(void)swizzled_application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
{
    [self swizzled_application:application didReceiveRemoteNotification:userInfo];
    CDVLeanPush *pushHandler = [self.viewController getCommandInstance:@"LeanPush"];

    if (application.applicationState == UIApplicationStateActive) {
        // foreground
        [pushHandler sendJson:userInfo statusIs:@"foreground"];
    } else {
        // The application was just brought from the background to the foreground,
        // so we consider the app as having been "opened by a push notification."
        [pushHandler sendJson:userInfo statusIs:@"background"];
        [AVAnalytics trackAppOpenedWithRemoteNotificationPayload:userInfo];
    }

    int num = application.applicationIconBadgeNumber;
    if(num!=0){
        AVInstallation *currentInstallation = [AVInstallation currentInstallation];
        [currentInstallation setBadge:0];
        [currentInstallation saveEventually];
        application.applicationIconBadgeNumber=0;
    }
}

-(void)noop_application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
{}

@end
