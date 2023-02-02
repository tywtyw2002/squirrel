#import <Cocoa/Cocoa.h>
#import <rime_api.h>

@interface OptionNode : NSObject

@property(nonatomic, strong) NSString *option;
@property(nonatomic, readwrite) BOOL mode;
@property(nonatomic, readwrite) BOOL auto_reset;

@end

typedef NSMutableDictionary<NSNumber *, NSString *> SessionMap;
typedef NSMutableDictionary<NSString *, OptionNode *> AppOptions;

@interface SquirrelStatusManager : NSObject
// @property (nonatomic, readonly) RimeSessionId _last_session;
// @property (nonatomic, readonly) NSMutableDictionary<NSString*, BOOL>
// global_status;
// @property (nonatomic, readonly) BOOL global_ascii_status;

// sessions
// @property (nonatomic, readonly) NSMutableDictionary<RimeSessionId, NSString*>
// session_map;

// session
- (void)new_session:(RimeSessionId)s BundleName:(NSString *)bundle_name;
- (void)delete_session:(RimeSessionId)s;

// per app config
- (void)load_app_options;
- (AppOptions *)get_app_option:(NSString *)bundle_name;

// event handler
- (void)system_event_handler:(RimeSessionId)s
                  OptionName:(const char *)option
                 OptionValue:(BOOL)value;
- (void)user_event_handler:(RimeSessionId)s
                OptionName:(const char *)option
               OptionValue:(BOOL)value;

- (void)update_rime_status:(RimeSessionId)s;
- (void)init_rime_status:(RimeSessionId)s;
@end
