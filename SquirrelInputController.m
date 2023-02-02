#import "SquirrelInputController.h"

#import "SquirrelApplicationDelegate.h"
#import "SquirrelConfig.h"
#import "SquirrelPanel.h"
#import "macos_keycode.h"
#import <rime_api.h>
#import <rime/key_table.h>

@interface SquirrelInputController (Private)
- (void)createSession;
- (void)destroySession;
- (void)rimeConsumeCommittedText;
- (void)updateStyleOptions;
- (void)rimeUpdate;
- (void)updateAppOptions;
- (void)UpdateAsciiStatus;
@end

const int N_KEY_ROLL_OVER = 50;
static NSString *kFullWidthSpace = @"　";

extern BOOL _global_ascii_mode = false;
extern BOOL _system_ascii_mode_event = false;
RimeSessionId _last_session = 0;


@implementation SquirrelInputController {
  id _currentClient;
  NSString *_preeditString;
  NSRange _selRange;
  NSUInteger _caretPos;
  NSArray<NSString *> *_candidates;
  NSEventModifierFlags _lastModifier;
  NSEventType _lastEventType;
  RimeSessionId _session;
  NSString *_schemaId;
  BOOL _inlinePreedit;
  BOOL _inlineCandidate;
  BOOL _showingSwitcherMenu;
  // for chord-typing
  int _chordKeyCodes[N_KEY_ROLL_OVER];
  int _chordModifiers[N_KEY_ROLL_OVER];
  NSUInteger _chordKeyCount;
  NSTimer *_chordTimer;
  NSTimeInterval _chordDuration;
  NSString *_currentApp;

  //ascii hack
  BOOL _ascii_mode;
  BOOL _app_ascii_setting;
}

/*!
   @method
   @abstract   Receive incoming event
   @discussion This method receives key events from the client application.
 */
- (BOOL)handleEvent:(NSEvent *)event
             client:(id)sender {
  // Return YES to indicate the the key input was received and dealt with.
  // Key processing will not continue in that case.  In other words the
  // system will not deliver a key down event to the application.
  // Returning NO means the original key down will be passed on to the client.

  _currentClient = sender;

  NSEventModifierFlags modifiers = event.modifierFlags;

  BOOL handled = NO;

  @autoreleasepool {
    if (!_session || !rime_get_api()->find_session(_session)) {
      [self createSession];
      if (!_session) {
        return NO;
      }
    }

    NSString *app = [_currentClient bundleIdentifier];
    // NSLog(@"self: %@", self);
    // NSLog(@"cur_app: %@, app: %@, session: %lu", _currentApp, app, _session);

    if (![_currentApp isEqualToString:app]) {
      // NSLog(@"Update -> cur_app: %@, app: %@", _currentApp, app);
      _currentApp = [app copy];
      [self updateAppOptions];
    }

    switch (event.type) {
      case NSEventTypeFlagsChanged: {
        if (_lastModifier == modifiers) {
          handled = YES;
          break;
        }
        //NSLog(@"FLAGSCHANGED client: %@, modifiers: 0x%lx", sender, modifiers);
        int rime_modifiers = osx_modifiers_to_rime_modifiers(modifiers);
        int rime_keycode = 0;
        // For flags-changed event, keyCode is available since macOS 10.15 (#715)
        BOOL keyCodeAvailable = NO;
        if (@available(macOS 10.15, *)) {
          keyCodeAvailable = YES;
          rime_keycode = osx_keycode_to_rime_keycode(event.keyCode, 0, 0, 0);
          //NSLog(@"keyCode: %d", event.keyCode);
        }
        int release_mask = 0;
        NSUInteger changes = _lastModifier ^ modifiers;
        if (changes & NSEventModifierFlagCapsLock) {
          if (!keyCodeAvailable) {
            rime_keycode = XK_Caps_Lock;
          }
          // NOTE: rime assumes XK_Caps_Lock to be sent before modifier changes,
          // while NSFlagsChanged event has the flag changed already.
          // so it is necessary to revert kLockMask.
          rime_modifiers ^= kLockMask;
          [self processKey:rime_keycode modifiers:rime_modifiers];
        }
        if (changes & NSEventModifierFlagShift) {
          if (!keyCodeAvailable) {
            rime_keycode = XK_Shift_L;
          }
          release_mask = modifiers & NSEventModifierFlagShift ? 0 : kReleaseMask;
          [self processKey:rime_keycode modifiers:(rime_modifiers | release_mask)];
        }
        if (changes & NSEventModifierFlagControl) {
          if (!keyCodeAvailable) {
            rime_keycode = XK_Control_L;
          }
          release_mask = modifiers & NSEventModifierFlagControl ? 0 : kReleaseMask;
          [self processKey:rime_keycode modifiers:(rime_modifiers | release_mask)];
        }
        if (changes & NSEventModifierFlagOption) {
          if (!keyCodeAvailable) {
            rime_keycode = XK_Alt_L;
          }
          release_mask = modifiers & NSEventModifierFlagOption ? 0 : kReleaseMask;
          [self processKey:rime_keycode modifiers:(rime_modifiers | release_mask)];
        }
        if (changes & NSEventModifierFlagCommand) {
          if (!keyCodeAvailable) {
            rime_keycode = XK_Super_L;
          }
          release_mask = modifiers & NSEventModifierFlagCommand ? 0 : kReleaseMask;
          [self processKey:rime_keycode modifiers:(rime_modifiers | release_mask)];
          // do not update UI when using Command key
          break;
        }
        [self rimeUpdate];
      } break;
      case NSEventTypeKeyDown: {
        // ignore Command+X hotkeys.
        if (modifiers & NSEventModifierFlagCommand) {
          break;
        }

        [self UpdateAsciiStatus];

        ushort keyCode = event.keyCode;
        NSString *keyChars = ((modifiers & NSEventModifierFlagShift) && !(modifiers & NSEventModifierFlagControl) &&
                              !(modifiers & NSEventModifierFlagOption)) ? event.characters : event.charactersIgnoringModifiers;
        //NSLog(@"KEYDOWN client: %@, modifiers: 0x%lx, keyCode: %d, keyChars: [%@]",
        //      sender, modifiers, keyCode, keyChars);

        // translate osx keyevents to rime keyevents
        int rime_keycode = osx_keycode_to_rime_keycode(keyCode, [keyChars characterAtIndex:0],
                                                       modifiers & NSEventModifierFlagShift,
                                                       modifiers & NSEventModifierFlagCapsLock);
        if (rime_keycode) {
          int rime_modifiers = osx_modifiers_to_rime_modifiers(modifiers);
          handled = [self processKey:rime_keycode modifiers:rime_modifiers];
          [self rimeUpdate];
        }
      } break;
      default:
        break;
    }
  }

  _lastModifier = modifiers;
  _lastEventType = event.type;

  return handled;
}

- (BOOL)processKey:(int)rime_keycode 
         modifiers:(int)rime_modifiers {
  // with linear candidate list, arrow keys may behave differently.
  Bool is_linear = NSApp.squirrelAppDelegate.panel.linear;
  if (is_linear != rime_get_api()->get_option(_session, "_linear")) {
    rime_get_api()->set_option(_session, "_linear", is_linear);
  }
  // with vertical text, arrow keys may behave differently.
  Bool is_vertical = NSApp.squirrelAppDelegate.panel.vertical;
  if (is_vertical != rime_get_api()->get_option(_session, "_vertical")) {
    rime_get_api()->set_option(_session, "_vertical", is_vertical);
  }

  BOOL handled = (BOOL)rime_get_api()->process_key(_session, rime_keycode, rime_modifiers);
  //NSLog(@"rime_keycode: 0x%x, rime_modifiers: 0x%x, handled = %d", rime_keycode, rime_modifiers, handled);

  // TODO add special key event postprocessing here

  if (!handled) {
    BOOL isVimBackInCommandMode = rime_keycode == XK_Escape ||
      ((rime_modifiers & kControlMask) && (rime_keycode == XK_c ||
                                           rime_keycode == XK_C ||
                                           rime_keycode == XK_bracketleft));
    if (isVimBackInCommandMode &&
        rime_get_api()->get_option(_session, "vim_mode") &&
        !rime_get_api()->get_option(_session, "ascii_mode")) {
      _system_ascii_mode_event = true;
      rime_get_api()->set_option(_session, "ascii_mode", True);
      // NSLog(@"turned Chinese mode off in vim-like editor's command mode");
    }
  }

  // Simulate key-ups for every interesting key-down for chord-typing.
  if (handled) {
    BOOL is_chording_key =
      (rime_keycode >= XK_space && rime_keycode <= XK_asciitilde) ||
      rime_keycode == XK_Control_L || rime_keycode == XK_Control_R ||
      rime_keycode == XK_Alt_L || rime_keycode == XK_Alt_R ||
      rime_keycode == XK_Shift_L || rime_keycode == XK_Shift_R;
    if (is_chording_key &&
        rime_get_api()->get_option(_session, "_chord_typing")) {
      [self updateChord:rime_keycode modifiers:rime_modifiers];
    } else if ((rime_modifiers & kReleaseMask) == 0) {
      // non-chording key pressed
      [self clearChord];
    }
  }

  return handled;
}

- (void)perform:(rimeAction)action
        onIndex:(rimeIndex)index {
  //NSLog(@"perform action: %u on index: %lu", action, (unsigned long)index);
  bool handled = false;
  if (index >= '!' && index <= '~' && (action == kSELECT || action == kHILITE)) {
    handled = rime_get_api()->process_key(_session, (int)index, action == kHILITE ? kAltMask : 0);
  } else if (index >= 0xff08 && index <= 0xffff && action == kSELECT) {
    handled = rime_get_api()->process_key(_session, (int)index, 0);
  } else if (index >= 0 && index < 10) {
    switch (action) {
      case kSELECT:
        handled = rime_get_api()->select_candidate_on_current_page(_session, (size_t)index);
        break;
      case kHILITE:
        handled = rime_get_api()->hilite_candidate_on_current_page(_session, (size_t)index);
        break;
      case kDELETE:
        handled = rime_get_api()->delete_candidate_on_current_page(_session, (size_t)index);
        break;
    }
  }
  if (handled) {
    [self rimeUpdate];
  }
}

- (void)onChordTimer:(NSTimer *)timer {
  // chord release triggered by timer
  NSUInteger processed_keys = 0;
  if (_chordKeyCount && _session) {
    // simulate key-ups
    for (NSUInteger i = 0; i < _chordKeyCount; ++i) {
      if (rime_get_api()->process_key(_session, _chordKeyCodes[i],
                                      (_chordModifiers[i] | kReleaseMask))) {
        ++processed_keys;
      }
    }
  }
  [self clearChord];
  if (processed_keys > 0) {
    [self rimeUpdate];
  }
}

- (void)updateChord:(int)keycode
          modifiers:(int)modifiers {
  //NSLog(@"update chord: {%s} << %x", _chord, keycode);
  for (NSUInteger i = 0; i < _chordKeyCount; ++i) {
    if (_chordKeyCodes[i] == keycode) {
      return;
    }
  }
  if (_chordKeyCount >= N_KEY_ROLL_OVER) {
    // you are cheating. only one human typist (fingers <= 10) is supported.
    return;
  }
  _chordKeyCodes[_chordKeyCount] = keycode;
  _chordModifiers[_chordKeyCount] = modifiers;
  ++_chordKeyCount;
  // reset timer
  if (_chordTimer && _chordTimer.valid) {
    [_chordTimer invalidate];
  }
  _chordDuration = 0.1;
  NSNumber *duration = [NSApp.squirrelAppDelegate.config 
                        getOptionalDouble:@"chord_duration"];
  if (duration && duration.doubleValue > 0) {
    _chordDuration = duration.doubleValue;
  }
  _chordTimer = [NSTimer scheduledTimerWithTimeInterval:_chordDuration
                                                 target:self
                                               selector:@selector(onChordTimer:)
                                               userInfo:nil
                                                repeats:NO];
}

- (void)clearChord {
  _chordKeyCount = 0;
  if (_chordTimer) {
    if (_chordTimer.valid) {
      [_chordTimer invalidate];
    }
    _chordTimer = nil;
  }
}

- (NSUInteger)recognizedEvents:(id)sender {
  //NSLog(@"recognizedEvents:");
  return NSEventMaskKeyDown | NSEventMaskFlagsChanged;
}

- (void)activateServer:(id)sender {
  //NSLog(@"activateServer:");
  NSString *keyboardLayout = [NSApp.squirrelAppDelegate.config 
                              getString:@"keyboard_layout"];
  if ([keyboardLayout isEqualToString:@"last"] ||
      [keyboardLayout isEqualToString:@""]) {
    keyboardLayout = nil;
  } else if ([keyboardLayout isEqualToString:@"default"]) {
    keyboardLayout = @"com.apple.keylayout.ABC";
  } else if (![keyboardLayout hasPrefix:@"com.apple.keylayout."]) {
    keyboardLayout = [@"com.apple.keylayout."
                      stringByAppendingString:keyboardLayout];
  }
  if (keyboardLayout) {
    [sender overrideKeyboardWithKeyboardNamed:keyboardLayout];
  }
  _preeditString = @"";
}

- (instancetype)initWithServer:(IMKServer *)server
                      delegate:(id)delegate
                        client:(id)inputClient {
  //NSLog(@"initWithServer:delegate:client:");
  if (self = [super initWithServer:server delegate:delegate
                            client:inputClient]) {
    _currentClient = inputClient;
    [self createSession];
    _preeditString = [[NSString alloc] init];
  }
  return self;
}

- (void)deactivateServer:(id)sender {
  //NSLog(@"deactivateServer:");
  [NSApp.squirrelAppDelegate.panel hide];
  [self commitComposition:sender];
}

/*!
   @method
   @abstract   Called when a user action was taken that ends an input session.
   Typically triggered by the user selecting a new input method
   or keyboard layout.
   @discussion When this method is called your controller should send the
   current input buffer to the client via a call to
   insertText:replacementRange:.  Additionally, this is the time
   to clean up if that is necessary.
 */

- (void)commitComposition:(id)sender {
  //NSLog(@"commitComposition:");
  // commit raw input
  if (_session) {
    const char *raw_input = rime_get_api()->get_input(_session);
    if (raw_input) {
      [self commitString:@(raw_input)];
      rime_get_api()->clear_composition(_session);
    }
  }
}

// a piece of comment from SunPinyin's macos wrapper says:
// > though we specified the showPrefPanel: in SunPinyinApplicationDelegate as the
// > action receiver, the IMKInputController will actually receive the event.
// so here we deliver messages to our responsible SquirrelApplicationDelegate
- (void)deploy:(id)sender {
  [NSApp.squirrelAppDelegate deploy:sender];
}

- (void)syncUserData:(id)sender {
  [NSApp.squirrelAppDelegate syncUserData:sender];
}

- (void)configure:(id)sender {
  [NSApp.squirrelAppDelegate configure:sender];
}

- (void)checkForUpdates:(id)sender {
  [NSApp.squirrelAppDelegate.updater performSelector:@selector(checkForUpdates:)
                                          withObject:sender];
}

- (void)openWiki:(id)sender {
  [NSApp.squirrelAppDelegate openWiki:sender];
}

- (NSMenu *)menu {
  return NSApp.squirrelAppDelegate.menu;
}

- (NSArray *)candidates:(id)sender {
  return _candidates;
}

- (void)dealloc {
  [self destroySession];
  _preeditString = nil;
}

- (void)commitString:(NSString *)string {
  //NSLog(@"commitString:");
  [_currentClient insertText:string
            replacementRange:NSMakeRange(NSNotFound, 0)];

  _preeditString = @"";

  [NSApp.squirrelAppDelegate.panel hide];
}

- (void)showPreeditString:(NSString *)preedit
                 selRange:(NSRange)range
                 caretPos:(NSUInteger)pos {
  //NSLog(@"showPreeditString: '%@'", preedit);

  if ([_preeditString isEqualToString:preedit] &&
      NSEqualRanges(_selRange, range) && _caretPos == pos) {
    return;
  }

  _preeditString = preedit;
  _selRange = range;
  _caretPos = pos;

  //NSLog(@"selRange.location = %ld, selRange.length = %ld; caretPos = %ld",
  //      range.location, range.length, pos);
  NSDictionary *attrs;
  NSMutableAttributedString *attrString = [[NSMutableAttributedString alloc] initWithString:preedit];
  if (range.location > 0) {
    NSRange convertedRange = NSMakeRange(0, range.location);
    attrs = [self markForStyle:kTSMHiliteConvertedText atRange:convertedRange];
    [attrString setAttributes:attrs range:convertedRange];
  }
  {
    NSRange remainingRange = NSMakeRange(range.location, preedit.length - range.location);
    attrs = [self markForStyle:kTSMHiliteSelectedRawText atRange:remainingRange];
    [attrString setAttributes:attrs range:remainingRange];
  }
  [_currentClient setMarkedText:attrString
                 selectionRange:NSMakeRange(pos, 0)
               replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
}

- (void)showPanelWithPreedit:(NSString *)preedit
                    selRange:(NSRange)selRange
                    caretPos:(NSUInteger)caretPos
                  candidates:(NSArray<NSString *> *)candidates
                    comments:(NSArray<NSString *> *)comments
                 highlighted:(NSUInteger)index
                     pageNum:(NSUInteger)pageNum
                    lastPage:(BOOL)lastPage {
  //NSLog(@"showPanelWithPreedit:...:");
  _candidates = candidates;
  SquirrelPanel *panel = NSApp.squirrelAppDelegate.panel;
  NSRect inputPos;
  [_currentClient attributesForCharacterIndex:0 lineHeightRectangle:&inputPos];
  if (NSEqualRects(inputPos, NSZeroRect) && _preeditString.length == 0) {
    // activate inline session, in e.g. table cells, by fake inputs
    [_currentClient setMarkedText:@" " 
                   selectionRange:NSMakeRange(0, 0)
                 replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
    [_currentClient attributesForCharacterIndex:0 
                            lineHeightRectangle:&inputPos];
    [_currentClient setMarkedText:_preeditString 
                   selectionRange:NSMakeRange(0, 0)
                 replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
  }
  if (@available(macOS 14.0, *)) {  // avoid overlapping with cursor effects view
    if (_lastModifier & NSEventModifierFlagCapsLock) {
      NSRect screenRect = NSScreen.mainScreen.frame;
      if (NSIntersectsRect(inputPos, screenRect)) {
        screenRect = NSScreen.mainScreen.visibleFrame;
        if (NSWidth(inputPos) > NSHeight(inputPos)) {
          NSRect capslockAccessory = NSMakeRect(NSMinX(inputPos) - 30, NSMinY(inputPos), 27, NSHeight(inputPos));
          if (NSMinX(capslockAccessory) < NSMinX(screenRect))
            capslockAccessory.origin.x = NSMinX(screenRect);
          if (NSMaxX(capslockAccessory) > NSMaxX(screenRect))
            capslockAccessory.origin.x = NSMaxX(screenRect) - NSWidth(capslockAccessory);
          inputPos = NSUnionRect(inputPos, capslockAccessory);
        } else {
          NSRect capslockAccessory = NSMakeRect(NSMinX(inputPos), NSMinY(inputPos) - 26, NSWidth(inputPos), 23);
          if (NSMinY(capslockAccessory) < NSMinY(screenRect))
            capslockAccessory.origin.y = NSMaxY(screenRect) + 3;
          if (NSMaxY(capslockAccessory) > NSMaxY(screenRect))
            capslockAccessory.origin.y = NSMaxY(screenRect) - NSHeight(capslockAccessory);
          inputPos = NSUnionRect(inputPos, capslockAccessory);
        }
      }
    }
  }
  panel.position = inputPos;
  panel.inputController = self;
  [panel showPreedit:preedit
            selRange:selRange
            caretPos:caretPos
          candidates:candidates
            comments:comments
         highlighted:index
             pageNum:pageNum
            lastPage:lastPage];
}

@end // SquirrelController


// implementation of private interface
@implementation SquirrelInputController (Private)

- (void)createSession {
  NSString *app = [_currentClient bundleIdentifier];
  NSLog(@"createSession: %@", app);
  _currentApp = [app copy];
  _session = rime_get_api()->create_session();

  _schemaId = nil;
  _app_ascii_setting = false;

  if (_session) {
    [self updateAppOptions];
  }
}

- (void)updateAppOptions
{
  if (!_currentApp) {
    return;
  }

  // global ascii
  // NSLog(@"Update APP: Set ascii_mode=%d", _global_ascii_mode);
  Bool ascii_mode = _global_ascii_mode;

  SquirrelAppOptions *appOptions = [NSApp.squirrelAppDelegate.config getAppOptions:_currentApp];
  if (appOptions) {
    for (NSString *key in appOptions) {
      Bool value = appOptions[key].intValue;
      NSLog(@"set app option: %@ = %d", key, value);
      if ([key isEqualToString:@"ascii_mode"]) {
        _app_ascii_setting = true;
        _ascii_mode = value;
        ascii_mode = value;
        continue;
      }
      rime_get_api()->set_option(_session, key.UTF8String, value);
    }
  }

  _system_ascii_mode_event = true;
  rime_get_api()->set_option(_session, "ascii_mode", ascii_mode);
}

- (void)UpdateAsciiStatus
{
  if (_session == _last_session) {
    return ;
  }

  // sync ascii mode
  Bool cur_ascii_mode = rime_get_api()->get_option(_session, "ascii_mode");
  if (_app_ascii_setting) {
    if (!cur_ascii_mode && _ascii_mode) {
      // set session to ascii mode if local is not ascii mode
      _system_ascii_mode_event = true;
      rime_get_api()->set_option(_session, "ascii_mode", _ascii_mode);
    }
  }else{
    if (_global_ascii_mode != cur_ascii_mode) {
      _system_ascii_mode_event = true;
      rime_get_api()->set_option(_session, "ascii_mode", _global_ascii_mode);
    }
  }

  _last_session = _session;
}

- (void)destroySession {
  //NSLog(@"destroySession:");
  if (_session) {
    rime_get_api()->destroy_session(_session);
    _session = 0;
  }
  [self clearChord];
}

- (void)rimeConsumeCommittedText {
  RIME_STRUCT(RimeCommit, commit);
  if (rime_get_api()->get_commit(_session, &commit)) {
    NSString *commitText = @(commit.text);
    [self commitString:commitText];
    rime_get_api()->free_commit(&commit);
  }
}

- (void)updateStyleOptions {
  // update the list of switchers that change styles and color-themes
  SquirrelOptionSwitcher *optionSwitcher;
  SquirrelConfig *schema = [[SquirrelConfig alloc] init];
  if ([schema openWithSchemaId:_schemaId 
                    baseConfig:NSApp.squirrelAppDelegate.config] &&
      [schema hasSection:@"style"]) {
    optionSwitcher = [schema getOptionSwitcher];
  } else {
    optionSwitcher = [[SquirrelOptionSwitcher alloc] initWithSchemaId:_schemaId 
                                                             switcher:@{}
                                                         optionGroups:@{}];
  }
  [schema close];
  NSMutableDictionary *switcher = optionSwitcher.mutableSwitcher;
  NSSet<NSString *> *prevStates = [NSSet setWithArray:optionSwitcher.optionStates];
  for (NSString *state in prevStates) {
    NSString *updatedState;
    NSArray<NSString *> *optionGroup = [optionSwitcher.switcher allKeysForObject:state];
    for (NSString *option in optionGroup) {
      if (rime_get_api()->get_option(_session, option.UTF8String)) {
        updatedState = option;
        break;
      }
    }
    updatedState = updatedState ? : [@"!" stringByAppendingString:optionGroup[0]];
    if (![updatedState isEqualToString:state]) {
      for (NSString *option in optionGroup) {
        switcher[option] = updatedState;
      }
    }
  }
  [optionSwitcher updateSwitcher:switcher];
  NSApp.squirrelAppDelegate.panel.optionSwitcher = optionSwitcher;
}

- (void)rimeUpdate {
  //NSLog(@"rimeUpdate");
  [self rimeConsumeCommittedText];

  RIME_STRUCT(RimeStatus, status);
  if (rime_get_api()->get_status(_session, &status)) {
    // enable schema specific ui style
    if (!_schemaId || strcmp(_schemaId.UTF8String, status.schema_id)) {
      _schemaId = @(status.schema_id);
      _showingSwitcherMenu = rime_get_api()->get_option(_session, "dumb");
      if (!_showingSwitcherMenu) {
        [self updateStyleOptions];
        [NSApp.squirrelAppDelegate loadSchemaSpecificLabels:_schemaId];
        [NSApp.squirrelAppDelegate loadSchemaSpecificSettings:_schemaId];
        // inline preedit
        _inlinePreedit = (NSApp.squirrelAppDelegate.panel.inlinePreedit &&
                          !rime_get_api()->get_option(_session, "no_inline")) ||
                          rime_get_api()->get_option(_session, "inline");
        _inlineCandidate = (NSApp.squirrelAppDelegate.panel.inlineCandidate &&
                            !rime_get_api()->get_option(_session, "no_inline"));
        // if not inline, embed soft cursor in preedit string
        rime_get_api()->set_option(_session, "soft_cursor", !_inlinePreedit);
      } else {
        [NSApp.squirrelAppDelegate loadSchemaSpecificLabels:@""];
      }
    }
    rime_get_api()->free_status(&status);
  }

  RIME_STRUCT(RimeContext, ctx);
  if (rime_get_api()->get_context(_session, &ctx)) {
    // update preedit text
    const char *preedit = ctx.composition.preedit;
    NSString *preeditText = preedit ? @(preedit) : @"";

    NSUInteger start = [[NSString alloc] initWithBytes:preedit
                                                length:(NSUInteger)ctx.composition.sel_start
                                              encoding:NSUTF8StringEncoding].length;
    NSUInteger end = [[NSString alloc] initWithBytes:preedit
                                              length:(NSUInteger)ctx.composition.sel_end 
                                            encoding:NSUTF8StringEncoding].length;
    NSUInteger caretPos = [[NSString alloc] initWithBytes:preedit
                                                   length:(NSUInteger)ctx.composition.cursor_pos
                                                 encoding:NSUTF8StringEncoding].length;
    NSUInteger length = [[NSString alloc] initWithBytes:preedit
                                                 length:(NSUInteger)ctx.composition.length
                                               encoding:NSUTF8StringEncoding].length;
    // update candidates
    NSUInteger numCandidates = rime_get_api()->get_option(_session, "ascii_mode") ? 0 : (NSUInteger)ctx.menu.num_candidates;
    NSMutableArray<NSString *> *candidates = [[NSMutableArray alloc] initWithCapacity:numCandidates];
    NSMutableArray<NSString *> *comments = [[NSMutableArray alloc] initWithCapacity:numCandidates];
    for (NSUInteger i = 0; i < numCandidates; ++i) {
      [candidates addObject:@(ctx.menu.candidates[i].text)];
      [comments addObject:@(ctx.menu.candidates[i].comment ? : "")];
    }
    [self showPanelWithPreedit:_inlinePreedit && !_showingSwitcherMenu ? nil : preeditText
                      selRange:NSMakeRange(start, end - start)
                      caretPos:_showingSwitcherMenu ? NSNotFound : caretPos
                    candidates:candidates
                      comments:comments
                   highlighted:(NSUInteger)ctx.menu.highlighted_candidate_index
                       pageNum:(NSUInteger)ctx.menu.page_no
                      lastPage:(BOOL)ctx.menu.is_last_page];

    if (!_showingSwitcherMenu) {
      if (_inlineCandidate) {
        const char *candidatePreview = ctx.commit_text_preview;
        NSString *candidatePreviewText = candidatePreview ? @(candidatePreview) : @"";
        if (_inlinePreedit) {
          if ((caretPos >= end) && (caretPos < length)) {
            candidatePreviewText = [candidatePreviewText stringByAppendingString:
                                    [preeditText substringWithRange:NSMakeRange(caretPos, length - caretPos)]];
          }
          [self showPreeditString:candidatePreviewText
                         selRange:NSMakeRange(start, candidatePreviewText.length - (length - end) - start)
                         caretPos:caretPos <= start ? caretPos : candidatePreviewText.length - (length - caretPos)];
        } else {
          if ((end < caretPos) && (caretPos > start)) {
            candidatePreviewText = [candidatePreviewText substringWithRange:
                                    NSMakeRange(0, candidatePreviewText.length - (caretPos - end))];
          } else if ((end < length) && (caretPos < end)) {
            candidatePreviewText = [candidatePreviewText substringWithRange:
                                    NSMakeRange(0, candidatePreviewText.length - (length - end))];
          }
          [self showPreeditString:candidatePreviewText
                         selRange:NSMakeRange(start - (caretPos < end), candidatePreviewText.length - start + (caretPos < end))
                         caretPos:(caretPos < end ? caretPos : candidatePreviewText.length)];
        }
      } else {
        if (_inlinePreedit && !_showingSwitcherMenu) {
          [self showPreeditString:preeditText 
                         selRange:NSMakeRange(start, end - start)
                         caretPos:caretPos];
        } else {
          // TRICKY: display a non-empty string to prevent iTerm2 from echoing each character in preedit.
          // note this is a full-width space U+3000; using narrow characters like "..." will result in
          // an unstable baseline when composing Chinese characters.
          [self showPreeditString:preedit ? kFullWidthSpace : @""
                         selRange:NSMakeRange(0, 0)
                         caretPos:0];
        }
      }
    }
    rime_get_api()->free_context(&ctx);
  } else {
    [NSApp.squirrelAppDelegate.panel hide];
  }
}

@end // SquirrelController(Private)
