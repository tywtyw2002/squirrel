#import "SquirrelStatusManager.h"
#import "SquirrelApplicationDelegate.h"
#import "SquirrelConfig.h"
#import <rime_api.h>

extern BOOL _system_ascii_mode_event;

NSString *const SUPPORTED_APP_OPTIONS = @"ascii_mode";

@implementation OptionNode

@synthesize option;
@synthesize mode;
@synthesize auto_reset;

@end

@implementation SquirrelStatusManager {
  RimeSessionId _last_session;
  BOOL global_ascii_status;

  // NSMutableDictionary <RimeSessionId, NSString*> session_map;
  SessionMap *session_map;
  NSMutableDictionary *app_option_map;
  NSArray *support_app_options;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    session_map = [[SessionMap alloc] init];
    app_option_map = [[NSMutableDictionary alloc] init];
    support_app_options =
        [SUPPORTED_APP_OPTIONS componentsSeparatedByString:@","];
  }

  global_ascii_status = false;
  _last_session = 0;
  return self;
}

- (void)new_session:(RimeSessionId)s BundleName:(NSString *)bundle_name {
  // check the bundle with app_options
  AppOptions *app_options = [self get_app_option:bundle_name];
  if (!app_options) {
    return;
  }

  [session_map setObject:bundle_name forKey:[NSNumber numberWithUnsignedLong:s]];
}

- (void)delete_session:(RimeSessionId)s {
  [session_map removeObjectForKey:[NSNumber numberWithUnsignedLong:s]];
}

- (void)load_app_options {
  NSArray *appLists = [NSApp.squirrelAppDelegate.config getAppLists];

  for (NSString *app in appLists) {
    SquirrelAppOptions *appOptions =
        [NSApp.squirrelAppDelegate.config getAppOptions:app];

    AppOptions *p = [[AppOptions alloc] init];

    for (NSString *option in support_app_options) {
      NSNumber *value = [appOptions objectForKey:option];
      if (!value) {
        continue;
      }
      NSNumber *auto_reset = [appOptions
          objectForKey:[NSString stringWithFormat:@"rule_%@_reset", option]];
      OptionNode *node = [[OptionNode alloc] init];
      node.option = option;
      node.mode = [value boolValue];
      node.auto_reset = auto_reset ? [auto_reset boolValue] : true;

      [p setObject:node forKey:option];
    }

    // push appoptions to OptionMap.
    if (p.count > 0) {
      // NSLog(@"App: %@, Options: %@", app, p);
      [app_option_map setObject:p forKey:app];
    }
  }
}

- (AppOptions *)get_app_option:(NSString *)bundle_name {
  AppOptions *app_options = [app_option_map objectForKey:bundle_name];
  return app_options;
}

- (void)system_event_handler:(RimeSessionId)s
                  OptionName:(const char *)option
                 OptionValue:(BOOL)value {
  _system_ascii_mode_event = false;
}

- (void)user_event_handler:(RimeSessionId)s
                OptionName:(const char *)option
               OptionValue:(BOOL)value {
  if (strcmp(option, "ascii_mode")) {
    return;
  }

  NSString *bundle_name = [session_map objectForKey:[NSNumber numberWithUnsignedLong:s]];

  if (!bundle_name) {
    global_ascii_status = value;
    return;
  }

  // AppOptions *app_options = [self get_app_option:bundle_name];

  // OptionNode *node_ascii_mode = [app_options objectForKey:@"ascii_mode"];

  // if (node_ascii_mode) {

  // }
}

- (void)update_rime_status:(RimeSessionId)s {
  // NSLog(@"call update_rime_status, session: %lu, _last: %lu", s, _last_session);
  if (s == _last_session) {
    return;
  }

  _last_session = s;

  NSString *bundle_name = [session_map objectForKey:[NSNumber numberWithUnsignedLong:s]];
  bool current_mode = rime_get_api()->get_option(s, "ascii_mode");
  bool mode = global_ascii_status;
  bool skip = false;

  if (bundle_name) {
    // app with per app options.
    AppOptions *app_options = [self get_app_option:bundle_name];
    OptionNode *node_ascii_mode = [app_options objectForKey:@"ascii_mode"];

    if (node_ascii_mode) {
      if (node_ascii_mode.auto_reset) {
        mode = node_ascii_mode.mode;
      } else {
        skip = true;
      }
    }
  }
  // NSLog(@"app: %@, skip: %d, current_mode: %d, mode: %d", bundle_name, skip, current_mode, mode);
  if (!skip && mode != current_mode) {
    _system_ascii_mode_event = true;
    rime_get_api()->set_option(s, "ascii_mode", mode);
  }
}

- (void)init_rime_status:(RimeSessionId)s {
  NSString *bundle_name = [session_map objectForKey:[NSNumber numberWithUnsignedLong:s]];
  bool mode = global_ascii_status;
  if (bundle_name) {
    AppOptions *app_options = [self get_app_option:bundle_name];
    OptionNode *node_ascii_mode = [app_options objectForKey:@"ascii_mode"];
    if (node_ascii_mode) {
      mode = node_ascii_mode.mode;
    }
  }

  _system_ascii_mode_event = true;
  rime_get_api()->set_option(s, "ascii_mode", mode);
}

@end