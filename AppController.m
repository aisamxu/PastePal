//
//  AppController.m
//  Flycut
//
//  Flycut by Gennadiy Potapov and contributors. Based on Jumpcut by Steve Cook.
//  Copyright 2011 General Arcade. All rights reserved.
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// AppController owns and interacts with the FlycutOperator, providing a user
// interface and platform-specific mechanisms.

#import "AppController.h"
#import "SGHotKey.h"
#import "SGHotKeyCenter.h"
#import "SRRecorderCell.h"
#import "UKLoginItemRegistry.h"
#import "NSWindow+TrueCenter.h"
#import "NSWindow+ULIZoomEffect.h"
#import "PastePalImageStore.h"
#import "FlycutClipping.h"
#import <ApplicationServices/ApplicationServices.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ServiceManagement/ServiceManagement.h>
#import <Carbon/Carbon.h>

@interface AppController ()
-(void)buildImageHistoryPreferenceRow;
-(IBAction)setImageHistoryMaxBytes:(id)sender;
-(void)addClippingToPasteboard:(FlycutClipping *)clipping;
-(void)addImageToPasteboard:(FlycutClipping *)clipping;
@end

// 在视图树中递归查找指定类型的子视图，用于在不改 XIB 的情况下注入图片设置
static NSView *PastePalFindSubviewOfClass(NSView *view, Class cls)
{
    for (NSView *subview in [view subviews]) {
        if ([subview isKindOfClass:cls]) {
            return subview;
        }
        NSView *found = PastePalFindSubviewOfClass(subview, cls);
        if (found) {
            return found;
        }
    }
    return nil;
}

@implementation AppController

/// Determines, through a hack of sorts, if the app is running sandboxed. The SANDBOXING define has no direct connection to being sandboxed, but this method identifies the state by looking for a directory which will have at least eight path components if sandboxed and is quite unlikely to have that many if not sandboxed. Of course, if this doesn't work for your unique case, just do a custom build with this method returning NO.
+ (BOOL)isAppSandboxed {
	// Get the Desktop directory:
	NSArray *paths = NSSearchPathForDirectoriesInDomains
	(NSDesktopDirectory, NSUserDomainMask, YES);
	NSString *desktopDirectory = [paths objectAtIndex:0];
	return ((NSArray*)[desktopDirectory componentsSeparatedByString:@"/"]).count >= 8;
}

- (id)init
{
	[[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
		[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:[NSNumber numberWithInt:9],[NSNumber numberWithLong:1179648],nil] forKeys:[NSArray arrayWithObjects:@"keyCode",@"modifierFlags",nil]],
		@"ShortcutRecorder mainHotkey",
		[NSNumber numberWithInt:10],
		@"displayNum",
		[NSNumber numberWithInt:40],
		@"displayLen",
		[NSNumber numberWithInt:0],
		@"menuIcon",
		[NSNumber numberWithFloat:.25],
		@"bezelAlpha",
		[NSNumber numberWithBool:NO],
		@"stickyBezel",
		[NSNumber numberWithBool:NO],
		@"wraparoundBezel",
		[NSNumber numberWithBool:NO],// No by default
		@"loadOnStartup",
		[NSNumber numberWithBool:YES], 
		@"menuSelectionPastes",
        // Flycut new options
        [NSNumber numberWithFloat:500.0],
        @"bezelWidth",
        [NSNumber numberWithFloat:320.0],
        @"bezelHeight",
        [NSNumber numberWithBool:NO],
        @"popUpAnimation",
        [NSNumber numberWithBool:YES],
        @"displayClippingSource",
        [NSNumber numberWithBool:NO],
        @"saveForgottenClippings",
#ifdef SANDBOXING
        [NSNumber numberWithBool:NO],
#else
        [NSNumber numberWithBool:YES],
#endif
        @"saveForgottenFavorites",
        [NSNumber numberWithBool:NO],
        @"suppressAccessibilityAlert",
        nil]];

	// 菜单刷新队列使用唯一的 C 字符串标识，避免误用 Objective-C 字面量
	menuQueue = dispatch_queue_create("io.github.aisamxu.PastePal.menuUpdateQueue", DISPATCH_QUEUE_SERIAL);

	return [super init];
}

- (void)showAccessibilityAlert {
    BOOL suppressAlert = [[NSUserDefaults standardUserDefaults] boolForKey:@"suppressAccessibilityAlert"];
    NSDictionary* options = @{(id) (kAXTrustedCheckOptionPrompt): @NO};
    if (!suppressAlert && AXIsProcessTrustedWithOptions != NULL && !AXIsProcessTrustedWithOptions((CFDictionaryRef) (options))) {
        NSAlert *alert = [NSAlert alertWithMessageText:@"PastePal" defaultButton:@"OK" alternateButton:nil otherButton:nil informativeTextWithFormat:@"For correct functioning of the app please tick PastePal in Accessibility apps list"];
        alert.showsSuppressionButton = YES;
        [alert runModal];
        if (alert.suppressionButton.state == NSOnState) {
            [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:YES]
                                                     forKey:@"suppressAccessibilityAlert"];
        }
        NSString *urlString = @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlString]];
    }
}


- (void)awakeFromNib
{
	[self buildAppearancesPreferencePanel];

	// We no longer get autosave from ShortcutRecorder, so let's set the recorder by hand
	if ( [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ShortcutRecorder mainHotkey"] ) {
		[mainRecorder setKeyCombo:SRMakeKeyCombo([[[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ShortcutRecorder mainHotkey"] objectForKey:@"keyCode"] intValue],
												 [[[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ShortcutRecorder mainHotkey"] objectForKey:@"modifierFlags"] intValue] )
		];
	};

	// Initialize the FlycutOperator
	flycutOperator = [[FlycutOperator alloc] init];
	flycutOperator.delegate = self;
	[flycutOperator setClippingsStoreDelegate:self];
	[flycutOperator setFavoritesStoreDelegate:self];
	[flycutOperator awakeFromNibDisplaying:[[NSUserDefaults standardUserDefaults] integerForKey:@"displayNum"]
						 withDisplayLength:[[NSUserDefaults standardUserDefaults] integerForKey:@"displayLen"]
						  withSaveSelector:@selector(savePreferencesOnDict:)
								 forTarget:self];

	// Operator 已注册图片容量默认值，此时再注入 General 面板的容量输入行
	[self buildImageHistoryPreferenceRow];

    [bezel setColor:NO];
    
	// Set up the bezel window
	[self setupBezel:nil];

	// Set up the bezel date formatter
	dateFormat = [[NSDateFormatter alloc] init];
	[dateFormat setDateFormat:@"EEEE, MMMM dd 'at' h:mm a"];

	// Create our pasteboard interface
    jcPasteboard = [NSPasteboard generalPasteboard];
    [jcPasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    pbCount = [[NSNumber numberWithInt:[jcPasteboard changeCount]] retain];

	// Build the statusbar menu
    statusItem = [[[NSStatusBar systemStatusBar]
            statusItemWithLength:NSVariableStatusItemLength] retain];
    [statusItem setHighlightMode:YES];
    [self switchMenuIconTo: [[NSUserDefaults standardUserDefaults] integerForKey:@"menuIcon"]];
	[statusItem setMenu:jcMenu];
    [jcMenu setDelegate:self];
    jcMenuBaseItemsCount = [[[[jcMenu itemArray] reverseObjectEnumerator] allObjects] count];
    [statusItem setEnabled:YES];

    // If our preferences indicate that we are saving, we may have loaded the dictionary from the
    // saved plist and should update the menu.
	if ( [[NSUserDefaults standardUserDefaults] integerForKey:@"savePreference"] >= 1 ) {
        [self updateMenu];
	}

	// Build our listener timer
	NSDate *oneSecondFromNow = [NSDate dateWithTimeIntervalSinceNow:1.0];
	pollPBTimer = [[NSTimer alloc] initWithFireDate:oneSecondFromNow
										   interval:(1.0)
											 target:self
										   selector:@selector(pollPB:)
										   userInfo:nil
											repeats:YES];
	// Assign it to NSRunLoopCommonModes so that it will still poll while the menu is open.  Using a simple NSTimer scheduledTimerWithTimeInterval: would result in polling that stops while the menu is active.  In the past this was okay but with Universal Clipboard a new clipping an arrive while the user has the menu open.
	[[NSRunLoop currentRunLoop] addTimer:pollPBTimer forMode:NSRunLoopCommonModes];

    // Finish up
	srTransformer = [[[SRKeyCodeTransformer alloc] init] retain];
    pbBlockCount = [[NSNumber numberWithInt:0] retain];
    [pollPBTimer fire];
    
    
    // The load-on-startup check can be really slow, so this will be dispatched out so our thread isn't blocked.
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(queue, ^{
        // FIXME: Should ask Gennadii if the "#ifdef SANDBOXING" should be removed and replaced with "if ([AppController isAppSandboxed])"
#ifdef SANDBOXING
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"bundleIdentifier == %@", kPastePalHelperId];
        NSArray *helperApp = [[[NSWorkspace sharedWorkspace] runningApplications] filteredArrayUsingPredicate:predicate];
        BOOL helperLaunched = ([helperApp count] != 0);
        [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:helperLaunched]
                                                            forKey:@"loadOnStartup"];
#else

        // This can take five seconds, perhaps more, so do it in the background instead of holding up opening of the preference panel.
        int checkLoginRegistry = [UKLoginItemRegistry indexForLoginItemWithPath:[[NSBundle mainBundle] bundlePath]];
        if ( checkLoginRegistry >= 1 ) {
            [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:YES]
                                                     forKey:@"loadOnStartup"];
        } else {
            [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:NO]
                                                     forKey:@"loadOnStartup"];
        }
#endif
    });

    [NSApp activateIgnoringOtherApps: YES];
    
    // Check if the app has Accessibility permission
    [self showAccessibilityAlert];
}

-(void)savePreferencesOnDict:(NSMutableDictionary *)saveDict
{
	[saveDict setObject:[NSNumber numberWithInt:[[NSUserDefaults standardUserDefaults] integerForKey:@"displayLen"]]
				 forKey:@"displayLen"];
	[saveDict setObject:[NSNumber numberWithInt:[[NSUserDefaults standardUserDefaults] integerForKey:@"displayNum"]]
				 forKey:@"displayNum"];
}

-(void)menuWillOpen:(NSMenu *)menu
{
    NSEvent *event = [NSApp currentEvent];
    if([event modifierFlags] & NSAlternateKeyMask) {
        [menu cancelTracking];
        bool disableStore = [self toggleMenuIconDisabled];
        if (!disableStore)
        {
            // Update the pbCount so we don't enable and have it immediately copy the thing the user was trying to avoid.
            // Code copied from pollPB, which is disabled at this point, so the "should be okay" should still be okay.
            
            // Reload pbCount with the current changeCount
            // Probably poor coding technique, but pollPB should be the only thing messing with pbCount, so it should be okay
            [pbCount release];
            pbCount = [[NSNumber numberWithInt:[jcPasteboard changeCount]] retain];
        }
        [flycutOperator setDisableStoreTo:disableStore];
    }
    else
    {
        // We need to do a little trick to get the search box functional.  Figure out what is currently active.
        NSRunningApplication *currApp = nil;
        for (currApp in [[NSWorkspace sharedWorkspace] runningApplications])
            if ([currApp isActive])
            {
                break;
            }

        // 改为比较 bundle id，避免应用改名或本地化后误判当前应用是否为自己
        BOOL isPastePalActive = [[currApp bundleIdentifier] isEqualToString:[[NSBundle mainBundle] bundleIdentifier]];
        if ( !isPastePalActive )
        {
            // We haven't activated PastePal yet.
            currentRunningApplication = [currApp retain]; // Remember what app we came from.
            [menu cancelTracking]; // Prevent the menu from displaying, since activateIgnoringOtherApps would close it anyway.
            [NSApp activateIgnoringOtherApps: YES]; // Required to make the search field firstResponder any good.
            [self performSelector:@selector(showMenuAfterActivation) withObject:nil afterDelay:0.2 inModes:[NSArray arrayWithObject:NSRunLoopCommonModes]]; // Because we really do want the menu open.
        }
        else
        {
            // PastePal is now active, so set the first responder once the menu opens.
            [self performSelector:@selector(activateSearchBox) withObject:nil afterDelay:0.2 inModes:[NSArray arrayWithObject:NSRunLoopCommonModes]];
        }
    }
}

-(void)menuDidClose:(NSMenu *)menu
{
    // The method the menu triggers may clear currentRunningApplication, but that method won't be called until after the menu has closed.  Queue a call to the reactivate method that will come up after the method resulting from the menu.
    [self performSelector:@selector(reactivateCurrentRunningApplication) withObject:nil afterDelay:0.0 inModes:[NSArray arrayWithObject:NSRunLoopCommonModes]];
}

-(void)reactivateCurrentRunningApplication
{
    // Return focus to application that the menu search box stole from.
    if ( nil != currentRunningApplication )
    {
        // But only if the bezel hasn't opened since the menu closed.  This happens if the bezel hotkey is pressed while the menu is open.  The bezel won't display until the menu closes, but will then display.
        if (!isBezelDisplayed)
            [currentRunningApplication activateWithOptions: NSApplicationActivateIgnoringOtherApps];
        // Paste from the bezel in this scenario works fine, so release and forget this resource in both cases.
        [currentRunningApplication release];
        currentRunningApplication = nil;
    }
}

-(bool)toggleMenuIconDisabled
{
    // Toggles the "disabled" look of the menu icon.  Returns if the icon looks disabled or not, allowing the caller to decide if anything is actually being disabled or if they just wanted the icon to be a status display.
    if (nil == statusItemText)
    {
        statusItemText = [statusItem title];
        statusItemImage = [statusItem image];
        [statusItem setTitle: @""];
        // 置灰态同样使用单色模板，避免出现彩色像素
        NSImage *disabledIcon = [NSImage imageNamed:@"PastePalMenuDisabledTemplate.png"];
        [disabledIcon setTemplate:YES];
        [statusItem setImage: disabledIcon];
        return true;
    }
    else
    {
        [statusItem setTitle: statusItemText];
        [statusItem setImage: statusItemImage];
        statusItemText = nil;
        statusItemImage = nil;
    }
    return false;
}

- (void)showMenuAfterActivation
{
    [statusItem popUpStatusItemMenu:jcMenu];
}

- (void)activateSearchBox
{
    menuFirstResponder = [[searchBox window] firstResponder]; // So we can return control to normal menu function if the user presses an arrow key.
    [[searchBox window] makeFirstResponder:searchBox]; // So the search box works.
}

-(IBAction) activateAndOrderFrontStandardAboutPanel:(id)sender
{
    [currentRunningApplication release];
    currentRunningApplication = nil; // So it doesn't get pulled foreground atop the about panel.
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    [[NSApplication sharedApplication] orderFrontStandardAboutPanel:sender];
}

-(IBAction) setBezelAlpha:(id)sender
{
	// In a masterpiece of poorly-considered design--because I want to eventually 
	// allow users to select from a variety of bezels--I've decided to create the
	// bezel programatically, meaning that I have to go through AppController as
	// a cutout to allow the user interface to interact w/the bezel.
	[bezel setAlpha:[sender floatValue]];
}

-(IBAction) setBezelWidth:(id)sender
{
    NSSize bezelSize = NSMakeSize([sender floatValue], bezel.frame.size.height);
	NSRect windowFrame = NSMakeRect( 0, 0, bezelSize.width, bezelSize.height);
	[bezel setFrame:windowFrame display:NO];
    [bezel trueCenter];
}

-(IBAction) setBezelHeight:(id)sender
{
    NSSize bezelSize = NSMakeSize(bezel.frame.size.width, [sender floatValue]);
	NSRect windowFrame = NSMakeRect( 0, 0, bezelSize.width, bezelSize.height);
	[bezel setFrame:windowFrame display:NO];
    [bezel trueCenter];
}

-(IBAction) setupBezel:(id)sender
{
    NSRect windowFrame = NSMakeRect(0, 0,
                                    [[NSUserDefaults standardUserDefaults] floatForKey:@"bezelWidth"],
                                    [[NSUserDefaults standardUserDefaults] floatForKey:@"bezelHeight"]);
    bezel = [[BezelWindow alloc] initWithContentRect:windowFrame
                                           styleMask:NSBorderlessWindowMask
                                             backing:NSBackingStoreBuffered
                                               defer:NO
                                          showSource:[[NSUserDefaults standardUserDefaults] boolForKey:@"displayClippingSource"]];

    [bezel trueCenter];
    [bezel setDelegate:self];
}

-(IBAction) switchMenuIcon:(id)sender
{
    [self switchMenuIconTo: [sender indexOfSelectedItem]];
}

-(void) switchMenuIconTo:(int)number
{
    if (number == 1 ) {
        // 剪刀选项使用系统字符，作为标题文本由菜单栏自动着色
        [statusItem setImage:nil];
        [statusItem setTitle:[NSString stringWithFormat:@"%C",0x2702]];
    } else {
        // 默认使用纯单色 P 模板；isTemplate 让系统按菜单栏深浅色自动反色
        [statusItem setTitle:@""];
        NSImage *icon = [NSImage imageNamed:@"PastePalMenuTemplate.png"];
        [icon setTemplate:YES];
        [statusItem setImage:icon];
    }
}

-(IBAction) setRememberNumPref:(id)sender
{
	[self checkRememberNumPref:[sender intValue] forPrimaryStore:YES];
}

-(int) checkRememberNumPref:(int)newRemember forPrimaryStore:(BOOL) isPrimaryStore
{
	int oldRemember = [flycutOperator rememberNum];
	int setRemember = [flycutOperator setRememberNum:newRemember forPrimaryStore:YES];

	if ( isPrimaryStore )
	{
		if ( setRemember == oldRemember )
		{
			[self updateMenu];
		}
		else if ( setRemember < oldRemember )
		{
			// Trim down the number displayed in the menu if it is greater than the new
			// number to remember.
			if ( isPrimaryStore ) {
				if ( setRemember < [[NSUserDefaults standardUserDefaults] integerForKey:@"displayNum"] ) {
					[[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithInt:setRemember]
															 forKey:@"displayNum"];
					[self updateMenu];
				}
			}
		}
	}
}

-(IBAction) setFavoritesRememberNumPref:(id)sender
{
	[self checkFavoritesRememberNumPref:[sender intValue]];
}

-(void) checkFavoritesRememberNumPref:(int)newRemember
{
	[flycutOperator switchToFavoritesStore];
	[self checkRememberNumPref:newRemember forPrimaryStore:NO];
	[flycutOperator restoreStashedStore];
}

-(IBAction) setDisplayNumPref:(id)sender
{
	[self updateMenu];
}

-(NSTextField*) preferencePanelSliderLabelForText:(NSString*)text aligned:(NSTextAlignment)alignment andFrame:(NSRect)frame
{
	NSTextField *newLabel = [[NSTextField alloc] initWithFrame:frame];
	newLabel.editable = NO;
	[newLabel setAlignment:alignment];
	[newLabel setBordered:NO];
	[newLabel setDrawsBackground:NO];
	[newLabel setFont:[NSFont labelFontOfSize:10]];
	[newLabel setStringValue:text];
	return newLabel;
}

-(NSBox*) preferencePanelSliderRowForText:(NSString*)title withTicks:(int)ticks minText:(NSString*)minText maxText:(NSString*)maxText minValue:(double)min maxValue:(double)max frameMaxY:(int)frameMaxY binding:(NSString*)keyPath action:(SEL)action
{
	NSRect panelFrame = [appearancePanel frame];

	if ( frameMaxY < 0 )
		frameMaxY = panelFrame.size.height-8;

	int height = 63;

	NSBox *newRow = [[NSBox alloc] initWithFrame:NSMakeRect(0, frameMaxY-height, panelFrame.size.width-10, height)];
	[newRow setTitlePosition:NSNoTitle];
	[newRow setBorderType:NSNoBorder];

	[newRow addSubview:[self preferencePanelSliderLabelForText:title aligned:NSNaturalTextAlignment andFrame:NSMakeRect(8, 25, 100, 25)]];

	[newRow addSubview:[self preferencePanelSliderLabelForText:minText aligned:NSLeftTextAlignment andFrame:NSMakeRect(113, 0, 151, 25)]];
	[newRow addSubview:[self preferencePanelSliderLabelForText:maxText aligned:NSRightTextAlignment andFrame:NSMakeRect(109+310-151-4, 0, 151, 25)]];

	NSSlider *newControl = [[NSSlider alloc] initWithFrame:NSMakeRect(109, 29, 310, 25)];

	newControl.numberOfTickMarks=ticks;
	[newControl setMinValue:min];
	[newControl setMaxValue:max];

	[self setBinding:@"value" forKey:keyPath andOrAction:action on:newControl];

	[newRow addSubview:newControl];

	return newRow;
}

-(NSBox*) preferencePanelPopUpRowForText:(NSString*)title items:(NSArray*)items frameMaxY:(int)frameMaxY binding:(NSString*)keyPath action:(SEL)action
{
	NSRect panelFrame = [appearancePanel frame];

	if ( frameMaxY < 0 )
		frameMaxY = panelFrame.size.height-8;

	int height = 40;

	NSBox *newRow = [[NSBox alloc] initWithFrame:NSMakeRect(0, frameMaxY-height+5, panelFrame.size.width-10, height)];
	[newRow setTitlePosition:NSNoTitle];
	[newRow setBorderType:NSNoBorder];

	[newRow addSubview:[self preferencePanelSliderLabelForText:title aligned:NSNaturalTextAlignment andFrame:NSMakeRect(8, -2, 100, 25)]];

	NSPopUpButton *newControl = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(109, 4, 150, 25) pullsDown:NO];

	[newControl addItemsWithTitles:items];

	[self setBinding:@"selectedIndex" forKey:keyPath andOrAction:action on:newControl];

	[newRow addSubview:newControl];

	return newRow;
}

-(NSBox*) preferencePanelCheckboxRowForText:(NSString*)title frameMaxY:(int)frameMaxY binding:(NSString*)keyPath action:(SEL)action
{
	NSRect panelFrame = [appearancePanel frame];

	if ( frameMaxY < 0 )
		frameMaxY = panelFrame.size.height-8;

	int height = 40;

	NSBox *newRow = [[NSBox alloc] initWithFrame:NSMakeRect(0, frameMaxY-height+5, panelFrame.size.width-10, height)];
	[newRow setTitlePosition:NSNoTitle];
	[newRow setBorderType:NSNoBorder];

	NSButton *newControl = [[NSButton alloc] initWithFrame:NSMakeRect(8, 4, panelFrame.size.width-20, 25)];

	[newControl setButtonType:NSSwitchButton];
	[newControl setTitle:title];

	[self setBinding:@"value" forKey:keyPath andOrAction:action on:newControl];

	[newRow addSubview:newControl];

	return newRow;
}

-(void)setBinding:(NSString*)binding forKey:(NSString*)keyPath andOrAction:(SEL)action on:(NSControl*)newControl
{
	[newControl bind:binding
			toObject:[NSUserDefaults standardUserDefaults]
		 withKeyPath:keyPath
			 options:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES]
												 forKey:@"NSContinuouslyUpdatesValue"]];
	if ( nil != action )
	{
		[newControl setTarget:self];
		[newControl setAction:action];
	}
}

-(void) buildAppearancesPreferencePanel
{
	NSRect screenFrame = [[NSScreen mainScreen] frame];

	int nextYMax = -1;
	NSView *row = [self preferencePanelSliderRowForText:@"Bezel transparency"
											 withTicks:16
											   minText:@"Lighter"
											   maxText:@"Darker"
											  minValue:0.1
											  maxValue:0.9
											 frameMaxY:nextYMax
											   binding:@"bezelAlpha"
												action:@selector(setBezelAlpha:)];
	[appearancePanel addSubview:row];
	nextYMax = row.frame.origin.y;

	row = [self preferencePanelSliderRowForText:@"Bezel width"
									  withTicks:50
										minText:@"Smaller"
										maxText:@"Bigger"
									   minValue:200
									   maxValue:screenFrame.size.width
									  frameMaxY:nextYMax
										binding:@"bezelWidth"
										 action:@selector(setBezelWidth:)];
	[appearancePanel addSubview:row];
	nextYMax = row.frame.origin.y;

	row = [self preferencePanelSliderRowForText:@"Bezel height"
									  withTicks:50
										minText:@"Smaller"
										maxText:@"Bigger"
									   minValue:200
									   maxValue:screenFrame.size.height
									  frameMaxY:nextYMax
										binding:@"bezelHeight"
										 action:@selector(setBezelHeight:)];
	[appearancePanel addSubview:row];
	nextYMax = row.frame.origin.y;

	row = [self preferencePanelPopUpRowForText:@"Menu bar icon"
										 items:[NSArray arrayWithObjects:
												@"PastePal",
												@"Scissors",nil]
									 frameMaxY:nextYMax
									   binding:@"menuIcon"
										action:@selector(switchMenuIcon:)];
	[appearancePanel addSubview:row];
	nextYMax = row.frame.origin.y;

//	row = [self preferencePanelCheckboxRowForText:@"Animate bezel appearance"
//										frameMaxY:nextYMax
//										  binding:@"popUpAnimation"
//										   action:nil];
//	[appearancePanel addSubview:row];
//	nextYMax = row.frame.origin.y;

    row = [self preferencePanelCheckboxRowForText:@"Show clipping source app and time"
                                        frameMaxY:nextYMax
                                          binding:@"displayClippingSource"
                                           action:@selector(setupBezel:)];
    [appearancePanel addSubview:row];
    nextYMax = row.frame.origin.y;
#ifdef SANDBOXING
    // Hide the Save Clippings preferences. These work fine when sandboxed. They just save to somwehere under ~/Library/Containers. If SANDBOXING isn't set, automatic saving of forgotten clippings will go somewhere under ~/Library/Containers while manual saving (s or S in the bezel) will open an NSSavePanel to prompt the user to pick.
    forgottenItemLabel.hidden = YES;
    forgottenClippingsCheckbox.hidden = YES;
    forgottenFavoritesCheckbox.hidden = YES;
    savingSectionLabel.hidden = YES;
    saveToLocationButton.hidden = YES;
    autoSaveToLocationButton.hidden = YES;
    saveFromBezelToLabel.hidden = YES;
#endif
    if ([AppController isAppSandboxed]) {
        // Saving to a prior-selected location while sandboxed would be unpleasant, so these really should be disabled always when sandboxed but can still show where the saves happen so the user knows what to expect.
        saveToLocationButton.enabled = NO;
        [saveToLocationButton setTitle:@"Ask User"];
        autoSaveToLocationButton.enabled = NO;
        [autoSaveToLocationButton setTitle:@"App Sandbox"];
    }
}

-(void) buildImageHistoryPreferenceRow
{
    // General 面板底部约有 55pt 空闲区域，程序化注入，避免直接改 XIB 的高风险
    NSTabView *tabView = (NSTabView *)PastePalFindSubviewOfClass([prefsPanel contentView], [NSTabView class]);
    if (!tabView || [tabView numberOfTabViewItems] == 0) {
        return;
    }
    NSView *generalView = [[tabView tabViewItemAtIndex:0] view];
    NSBox *box = (NSBox *)PastePalFindSubviewOfClass(generalView, [NSBox class]);
    NSView *container = box ? [box contentView] : generalView;
    if (!container) {
        return;
    }

    NSInteger maxBytes = [[NSUserDefaults standardUserDefaults] integerForKey:@"imageHistoryMaxBytes"];
    if (maxBytes <= 0) {
        maxBytes = 524288000;
    }

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(14, 10, 140, 16)];
    [label setStringValue:@"Image history limit:"];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBordered:NO];
    [label setDrawsBackground:NO];
    [label setFont:[NSFont systemFontOfSize:12]];
    [container addSubview:label];
    [label release];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(158, 6, 60, 22)];
    [field setStringValue:[NSString stringWithFormat:@"%ld", (long)(maxBytes / (1024 * 1024))]];
    [field setToolTip:@"Total disk space for image history. Favorites are never removed automatically."];
    [field setTarget:self];
    [field setAction:@selector(setImageHistoryMaxBytes:)];
    [container addSubview:field];
    [field release];

    NSTextField *unit = [[NSTextField alloc] initWithFrame:NSMakeRect(222, 10, 30, 16)];
    [unit setStringValue:@"MB"];
    [unit setEditable:NO];
    [unit setSelectable:NO];
    [unit setBordered:NO];
    [unit setDrawsBackground:NO];
    [unit setFont:[NSFont systemFontOfSize:12]];
    [container addSubview:unit];
    [unit release];
}

-(IBAction)setImageHistoryMaxBytes:(id)sender
{
    NSInteger megabytes = [[sender stringValue] integerValue];
    // 下限 10MB，避免误输入直接清空全部图片历史
    if (megabytes < 10) {
        megabytes = 10;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:megabytes * 1024 * 1024
                                               forKey:@"imageHistoryMaxBytes"];
    [sender setStringValue:[NSString stringWithFormat:@"%ld", (long)megabytes]];
    [flycutOperator enforceImageHistoryLimit];
    [flycutOperator sweepUnreferencedImages];
    [self updateMenu];
}

-(IBAction) showPreferencePanel:(id)sender
{
    [currentRunningApplication release];
    currentRunningApplication = nil; // So it doesn't get pulled foreground atop the preference panel.
	if ([prefsPanel respondsToSelector:@selector(setCollectionBehavior:)])
		[prefsPanel setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces];
	[NSApp activateIgnoringOtherApps: YES];
	[prefsPanel makeKeyAndOrderFront:self];
	NSString *fileRoot = [[NSBundle mainBundle] pathForResource:@"acknowledgements" ofType:@"txt"];
	NSString *contents = [NSString stringWithContentsOfFile:fileRoot
												   encoding:NSUTF8StringEncoding
													  error:NULL];
	[acknowledgementsView setString:contents];
	if (![AppController isAppSandboxed]) {
		NSURL* saveToLocation = [[NSUserDefaults standardUserDefaults] URLForKey:@"saveToLocation"];
		if (saveToLocation) {
			[saveToLocationButton setTitle:[saveToLocation lastPathComponent]];
		}
		NSURL* autoSaveToLocation = [[NSUserDefaults standardUserDefaults] URLForKey:@"autoSaveToLocation"];
		if (autoSaveToLocation) {
			[autoSaveToLocationButton setTitle:[autoSaveToLocation lastPathComponent]];
		}
	}
	[flycutOperator willShowPreferences];
}

-(IBAction)toggleLoadOnStartup:(id)sender {
	// Since the control in Interface Builder is bound to User Defaults and sends this action, this method is called after User Defaults already reflects the newly-selected state and merely conveys that value to the relevant mechanisms rather than acting to negate the User Defaults state.
	if ( [[NSUserDefaults standardUserDefaults] boolForKey:@"loadOnStartup"] ) {
        // FIXME: Should ask Gennadii if the "#ifdef SANDBOXING" should be removed and replaced with "if ([AppController isAppSandboxed])"
#ifdef SANDBOXING
        SMLoginItemSetEnabled((__bridge CFStringRef)kPastePalHelperId, YES);
#else
    [UKLoginItemRegistry addLoginItemWithPath:[[NSBundle mainBundle] bundlePath] hideIt:NO];
#endif
	} else {
        // FIXME: Should ask Gennadii if the "#ifdef SANDBOXING" should be removed and replaced with "if ([AppController isAppSandboxed])"
#ifdef SANDBOXING
        SMLoginItemSetEnabled((__bridge CFStringRef)kPastePalHelperId, NO);
#else
		[UKLoginItemRegistry removeLoginItemWithPath:[[NSBundle mainBundle] bundlePath]];
#endif
	}
}

- (void)restoreStashedStoreAndUpdate
{
    if ([flycutOperator restoreStashedStore])
    {
        [bezel setColor:NO];
        [self updateBezel];
    }
}

- (void)pasteFromStack
{
	FlycutClipping *clipping = [flycutOperator getClippingFromStackPosition];
	if ( nil != clipping ) {
		[self addClippingToPasteboard:clipping];
		[self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
		[self performSelector:@selector(fakeCommandV) withObject:nil afterDelay:0.2];
	} else {
		[self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
	}
    [self restoreStashedStoreAndUpdate];
}

- (void)moveItemAtStackPositionToTopOfStack
{
	if ( [flycutOperator stackPositionIsInBounds] ) {
		[self pasteIndexAndUpdate: [flycutOperator stackPosition]];
		[self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
	} else {
		[self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
	}
}

- (void)pasteIndexAndUpdate:(int) position {
    // If there is an active search, we need to map the menu index to the stack position.
    NSString* search = [searchBox stringValue];
    if ( nil != search && 0 != search.length )
    {
        NSArray *mapping = [flycutOperator previousIndexes:[[NSUserDefaults standardUserDefaults] integerForKey:@"displayNum"] containing:search];
        position = [mapping[position] intValue];
    }

    FlycutClipping *clipping = [flycutOperator getClippingFromIndex: position];
    if ( nil != clipping )
    {
        [self addClippingToPasteboard:clipping];
        [self updateMenu];
	}
}

- (void)metaKeysReleased
{
	if ( ! isBezelPinned ) {
		[self pasteFromStack];
	}
}

- (void)windowDidResignKey:(NSNotification *)notification {
	if ( isBezelPinned ) {
		[self hideApp];
	}
}

-(void)fakeKey:(NSNumber*) keyCode withCommandFlag:(BOOL) setFlag
	/*" +fakeKey synthesizes keyboard events. "*/
{     
    CGEventSourceRef sourceRef = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    if (!sourceRef)
    {
        DLog(@"No event source");
        return;
    }
    CGKeyCode veeCode = (CGKeyCode)[keyCode intValue];
    CGEventRef eventDown = CGEventCreateKeyboardEvent(sourceRef, veeCode, true);
    if ( setFlag )
        CGEventSetFlags(eventDown, kCGEventFlagMaskCommand|0x000008); // some apps want bit set for one of the command keys
    CGEventRef eventUp = CGEventCreateKeyboardEvent(sourceRef, veeCode, false);
    CGEventPost(kCGHIDEventTap, eventDown);
    CGEventPost(kCGHIDEventTap, eventUp);
    CFRelease(eventDown);
    CFRelease(eventUp);
    CFRelease(sourceRef);
}

/*" +fakeCommandV synthesizes keyboard events for Cmd-v Paste shortcut. "*/
-(void)fakeCommandV { [self fakeKey:@(kVK_ANSI_V) withCommandFlag:TRUE]; }

/*" +fakeDownArrow synthesizes keyboard events for the down-arrow key. "*/
-(void)fakeDownArrow { [self fakeKey:@125 withCommandFlag:FALSE]; }

/*" +fakeUpArrow synthesizes keyboard events for the up-arrow key. "*/
-(void)fakeUpArrow { [self fakeKey:@126 withCommandFlag:FALSE]; }

// Perform the search and display updated results when the user types.
-(void)controlTextDidChange:(NSNotification *)aNotification
{
    NSString* search = [searchBox stringValue];
    [self updateMenuContaining:search];
}

// Perform the search and display updated results when the search field performs its action.
-(IBAction)searchItems:(id)sender
{
    NSString* search = [searchBox stringValue];
    [self updateMenuContaining:search];
}

// Catch keystrokes in the search field and look for arrows.
-(BOOL)control:(NSControl *)control textView:(NSTextView *)fieldEditor doCommandBySelector:(SEL)commandSelector
{
    if( commandSelector == @selector(moveUp:) )
    {
        [[searchBox window] makeFirstResponder:menuFirstResponder];
        [self fakeUpArrow];
        return YES;    // We handled this command; don't pass it on
    }
    if( commandSelector == @selector(moveDown:) )
    {
        [[searchBox window] makeFirstResponder:menuFirstResponder];
        [self fakeDownArrow];
        return YES;    // We handled this command; don't pass it on
    }

    return NO;    // Default handling of the command
}

-(void)pollPB:(NSTimer *)timer
{
    // 只有剪贴板变化且未被禁用时才处理
    if ( [pbCount intValue] == [jcPasteboard changeCount] || [flycutOperator storeDisabled] ) {
        return;
    }

    // 先记录新的 changeCount；后台读取期间若又有新复制，提交前会被 pbCount 校验拦下
    [pbCount release];
    pbCount = [[NSNumber numberWithInt:[jcPasteboard changeCount]] retain];

    // 文本优先：同时带文本和 TIFF 的复制不应被误记为图片
    NSString *type = [jcPasteboard availableTypeFromArray:[NSArray arrayWithObject:NSStringPboardType]];
    if ( type != nil ) {
        NSRunningApplication *currRunningApp = nil;
        for (NSRunningApplication *currApp in [[NSWorkspace sharedWorkspace] runningApplications])
            if ([currApp isActive])
                currRunningApp = currApp;
        bool largeCopyRisk = nil != currRunningApp && [[currRunningApp localizedName] rangeOfString:@"Remote Desktop Connection"].location != NSNotFound;

        // Microsoft's Remote Desktop Connection has an issue with large copy actions, which appears to be in the time it takes to transer them over the network.  The copy starts being registered with OS X prior to completion of the transfer, and if the active application changes during the transfer the copy will be lost.  Indicate this time period by toggling the menu icon at the beginning of all RDC trasfers and back at the end.  Apple's Screen Sharing does not demonstrate this problem.
        if (largeCopyRisk)
            [self toggleMenuIconDisabled];

        // In case we need to do a status visual, this will be dispatched out so our thread isn't blocked.
        dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        dispatch_async(queue, ^{

            // This operation blocks until the transfer is complete, though it was was here before the RDC issue was discovered.  Convenient.
            NSString *contents = [jcPasteboard stringForType:type];

            // Toggle back if dealing with the RDC issue.
            if (largeCopyRisk) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self toggleMenuIconDisabled];
                });
            }

            if ( contents == nil || [flycutOperator shouldSkip:contents ofType:[jcPasteboard availableTypeFromArray:[NSArray arrayWithObject:NSStringPboardType]] fromAvailableTypes:[jcPasteboard types]] ) {
                DLog(@"Contents: Empty or skipped");
            } else {
                // Dispatch back to main queue to safely modify the clipping store and update UI.
                // jcList (NSMutableArray) is not thread-safe, and concurrent access from this
                // background queue and the main thread (e.g. showing the bezel) causes crashes.
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ( ! [pbCount isEqualTo:pbBlockCount] ) {
                        [flycutOperator addClipping:contents ofType:type fromApp:[currRunningApp localizedName] withAppBundleURL:currRunningApp.bundleURL.path target:self clippingAddedSelector:@selector(updateMenu)];
                    }
                });
            }
        });
        return;
    }

    // 没有文本时按 PNG > TIFF > JPEG > HEIC 的优先级读取一种图片格式
    NSArray *imageTypes = [NSArray arrayWithObjects:
                           NSPasteboardTypePNG,
                           NSPasteboardTypeTIFF,
                           @"public.jpeg",
                           @"public.heic",
                           nil];
    NSString *imageType = [jcPasteboard availableTypeFromArray:imageTypes];
    if ( imageType == nil ) {
        return;
    }

    NSRunningApplication *currRunningApp = nil;
    for (NSRunningApplication *currApp in [[NSWorkspace sharedWorkspace] runningApplications])
        if ([currApp isActive])
            currRunningApp = currApp;
    NSArray *availableTypes = [jcPasteboard types];

    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(queue, ^{
        // 图片可能很大，读取、哈希和尺寸解析全部放在后台
        NSData *data = [jcPasteboard dataForType:imageType];
        if ( data == nil || [data length] == 0 ) {
            return;
        }

        NSInteger maxItemBytes = [[NSUserDefaults standardUserDefaults] integerForKey:@"imageMaxItemBytes"];
        if ( maxItemBytes <= 0 ) {
            maxItemBytes = 52428800;
        }
        if ( (NSInteger)[data length] > maxItemBytes ) {
            DLog(@"Skipping oversized image: %lu bytes", (unsigned long)[data length]);
            return;
        }
        if ( [flycutOperator shouldSkipImageOfType:imageType fromAvailableTypes:availableTypes] ) {
            DLog(@"Image pasteboard type skipped");
            return;
        }

        int pixelWidth = 0;
        int pixelHeight = 0;
        if ( ![PastePalImageStore pixelSizeForImageData:data width:&pixelWidth height:&pixelHeight] ) {
            DLog(@"Unreadable image data");
            return;
        }
        NSString *hash = [PastePalImageStore sha256HexForData:data];
        NSString *displayString = [FlycutClipping imageDisplayStringForUTI:imageType
                                                               pixelWidth:pixelWidth
                                                              pixelHeight:pixelHeight
                                                                 byteSize:(NSInteger)[data length]];

        dispatch_async(dispatch_get_main_queue(), ^{
            // 后台读取期间用户又复制了其他内容，则放弃这次图片
            if ( [pbCount isEqualTo:pbBlockCount] ) {
                return;
            }
            [flycutOperator addImageClippingWithData:data
                                                hash:hash
                                                 uti:imageType
                                          pixelWidth:pixelWidth
                                         pixelHeight:pixelHeight
                                            byteSize:(NSInteger)[data length]
                                       displayString:displayString
                                             fromApp:[currRunningApp localizedName]
                                   withAppBundleURL:currRunningApp.bundleURL.path
                                              target:self
                               clippingAddedSelector:@selector(updateMenu)];
        });
    });
}

- (void)processBezelKeyDown:(NSEvent *)theEvent {
	int newStackPosition;
	// AppControl should only be getting these directly from bezel via delegation
	if ([theEvent type] == NSKeyDown) {
		if ([theEvent keyCode] == [mainRecorder keyCombo].code ) {
			if ([theEvent modifierFlags] & NSShiftKeyMask) [self stackUp];
			 else [self stackDown];
			return;
		}
		unichar pressed = [[theEvent charactersIgnoringModifiers] characterAtIndex:0];
        NSUInteger modifiers = [theEvent modifierFlags];
		switch (pressed) {
			case 0x1B:
				[self hideApp];
				break;
            case 0xD: // Enter or Return
				[self pasteFromStack];
				break;
			case 0x3:
                [self moveItemAtStackPositionToTopOfStack];
                break;
            case 0x2C: // Comma
                if ( modifiers & NSCommandKeyMask ) {
                    [self showPreferencePanel:nil];
                }
                break;
			case NSUpArrowFunctionKey: 
			case NSLeftArrowFunctionKey: 
            case 0x6B: // k
				[self stackUp];
				break;
			case NSDownArrowFunctionKey: 
			case NSRightArrowFunctionKey:
            case 0x6A: // j
				[self stackDown];
				break;
            case NSHomeFunctionKey:
				if ( [flycutOperator setStackPositionToFirstItem] ) {
					[self updateBezel];
				}
				break;
            case NSEndFunctionKey:
				if ( [flycutOperator setStackPositionToLastItem] ) {
					[self updateBezel];
				}
				break;
            case NSPageUpFunctionKey:
				if ( [flycutOperator setStackPositionToTenMoreRecent] ) {
					[self updateBezel];
				}
				break;
			case NSPageDownFunctionKey:
				if ( [flycutOperator setStackPositionToTenLessRecent] ) {
                    [self updateBezel];
                }
				break;
			case NSBackspaceCharacter:
            case NSDeleteCharacter:
                if ( [flycutOperator clearItemAtStackPosition] ) {
                    [self updateBezel];
                    [self updateMenu];
                }
                break;
            case NSDeleteFunctionKey: break;
			case 0x30: case 0x31: case 0x32: case 0x33: case 0x34: 				// Numeral 
			case 0x35: case 0x36: case 0x37: case 0x38: case 0x39:
				// We'll currently ignore the possibility that the user wants to do something with shift.
				// First, let's set the new stack count to "10" if the user pressed "0"
				newStackPosition = pressed == 0x30 ? 9 : [[NSString stringWithCharacters:&pressed length:1] intValue] - 1;
				if ( [flycutOperator setStackPositionTo: newStackPosition] ) {
					[self fillBezel];
				}
				break;
            case 's': case 'S': // Save / Save-and-delete
                {
                    bool success = [flycutOperator saveFromStack];
                    [self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
                    [self restoreStashedStoreAndUpdate];

                    if ( success ) {
                        if ( modifiers & NSShiftKeyMask ) {
                            [flycutOperator clearItemAtStackPosition];
                            [self updateBezel];
                            [self updateMenu];
                        }
                    }
                }
                break;
            case 'f':
                [flycutOperator toggleToFromFavoritesStore];
                [bezel setColor:[flycutOperator favoritesStoreIsSelected]];
                [self updateBezel];
                [self hideBezel];
                [self showBezel];
                break;
            case 'F':
                if ( [flycutOperator saveFromStackToFavorites] )
                {
                    [self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
                    [self restoreStashedStoreAndUpdate];
                    [self updateBezel];
                    [self updateMenu];
                }

                [self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
                break;
            default: // It's not a navigation/application-defined thing, so let's figure out what to do with it.
				DLog(@"PRESSED %d", pressed);
				DLog(@"CODE %ld", (long)[mainRecorder keyCombo].code);
				break;
		}		
    }
}

-(void) processBezelMouseEvents:(NSEvent *)theEvent {
    if (theEvent.type == NSScrollWheel) {
        if (theEvent.deltaY > 0.0f) {
            [self stackUp];
        } else if (theEvent.deltaY < 0.0f) {
            [self stackDown];
        }
    } else if (theEvent.type == NSLeftMouseUp && theEvent.clickCount == 2) {
        [self pasteFromStack];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	//Create our hot key
	[self toggleMainHotKey:[NSNull null]];
}

- (void) updateBezel
{
	[flycutOperator adjustStackPositionIfOutOfBounds];
	if ([flycutOperator jcListCount] == 0) { // empty
		[bezel setText:@""];
		[bezel setCharString:@"Empty"];
        [bezel setSource:@""];
        [bezel setDate:@""];
        [bezel setSourceIcon:nil];
	}
	else { // normal
		[self fillBezel];
	}
}

- (void) showBezel
{
	if ( [flycutOperator stackPositionIsInBounds] ) {
		[self fillBezel];
	}
	NSRect mainScreenRect = [NSScreen mainScreen].visibleFrame;
	[bezel setFrame:NSMakeRect(mainScreenRect.origin.x + mainScreenRect.size.width/2 - bezel.frame.size.width/2,
							   mainScreenRect.origin.y + mainScreenRect.size.height/2 - bezel.frame.size.height/2,
							   bezel.frame.size.width,
							   bezel.frame.size.height) display:YES];
	if ([bezel respondsToSelector:@selector(setCollectionBehavior:)])
		[bezel setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces];
//	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"popUpAnimation"])
//		[bezel makeKeyAndOrderFrontWithPopEffect];
//	else
    [bezel makeKeyAndOrderFront:self];
	isBezelDisplayed = YES;
}

- (void) hideBezel
{
	[bezel orderOut:nil];
	[bezel setCharString:@"Empty"];
	isBezelDisplayed = NO;
}

-(void)hideApp
{
	isBezelPinned = NO;
	[self hideBezel];
	[NSApp hide:self];
}

- (void) applicationWillResignActive:(NSApplication *)app; {
	// This should be hidden anyway, but just in case it's not.
	[self hideBezel];
}


- (void)hitMainHotKey:(SGHotKey *)hotKey
{
	if ( ! isBezelDisplayed ) {
		//Do NOT activate the app so focus stays on app the user is interacting with
		//https://github.com/TermiT/Flycut/issues/45
		//[NSApp activateIgnoringOtherApps:YES];
		if ( [[NSUserDefaults standardUserDefaults] boolForKey:@"stickyBezel"] ) {
			isBezelPinned = YES;
		}
		[self showBezel];
	} else {
		[self stackDown];
	}
}

- (IBAction)toggleMainHotKey:(id)sender
{
	if (mainHotKey != nil)
	{
		[[SGHotKeyCenter sharedCenter] unregisterHotKey:mainHotKey];
		[mainHotKey release];
		mainHotKey = nil;
	}
	mainHotKey = [[SGHotKey alloc] initWithIdentifier:@"mainHotKey"
											   keyCombo:[SGKeyCombo keyComboWithKeyCode:[mainRecorder keyCombo].code
																			  modifiers:[mainRecorder cocoaToCarbonFlags: [mainRecorder keyCombo].flags]]];
	[mainHotKey setName: @"Activate PastePal HotKey"]; //This is typically used by PTKeyComboPanel
	[mainHotKey setTarget: self];
	[mainHotKey setAction: @selector(hitMainHotKey:)];
	[[SGHotKeyCenter sharedCenter] registerHotKey:mainHotKey];
}

- (IBAction)setSavePreference:(id)sender
{
	// 保存策略仅影响本地自动保存，云同步移除后无需额外处理。
}

- (IBAction)selectSaveLocation:(id)sender {
	// Create and configure the panel.
	NSOpenPanel* panel = [NSOpenPanel openPanel];
	[panel retain];
	[panel setCanChooseFiles:NO];
	[panel setCanChooseDirectories:YES];
	[panel setCanCreateDirectories:YES];
	[panel setAllowsMultipleSelection:NO];
	[panel setMessage:@"Select a directory."];

	// Display the panel attached to the document's window.
	[panel beginSheetModalForWindow:prefsPanel completionHandler:^(NSInteger result){
		if (result == NSFileHandlingPanelOKButton) {
			NSURL* url = [[panel URLs] firstObject];

			[panel release];

			if (!url) { return; }

			if (sender == saveToLocationButton) {
				[[NSUserDefaults standardUserDefaults] setURL:url forKey:@"saveToLocation"];
			}
			else if (sender == autoSaveToLocationButton) {
				[[NSUserDefaults standardUserDefaults] setURL:url forKey:@"autoSaveToLocation"];
			}
			[sender setTitle:[url lastPathComponent]];
		}

	}];
}

-(IBAction)clearClippingList:(id)sender {
    int choice;
	
	[NSApp activateIgnoringOtherApps:YES];
    choice = NSRunAlertPanel(@"Clear Clipping List", 
							 @"Do you want to clear all recent clippings?",
							 @"Clear", @"Cancel", nil);
	
    // on clear, zap the list and redraw the menu
    if ( choice == NSAlertDefaultReturn ) {
        [self restoreStashedStoreAndUpdate]; // Only clear the clipping store.  Never the favorites.
        [flycutOperator clearList];
        [self updateMenu];
		if ( [[NSUserDefaults standardUserDefaults] integerForKey:@"savePreference"] >= 1 ) {
			[flycutOperator saveEngine];
		}
		[bezel setText:@""];
    }
}

-(IBAction)mergeClippingList:(id)sender {
    [flycutOperator mergeList];
    [self updateMenu];
}

- (void)updateMenu {
    dispatch_async(dispatch_get_main_queue(), ^{
    if ( !statusItem || !statusItem.isEnabled )
        return;

        [self updateMenuContaining:nil];
        // Clear the search box whenever the is reason for updateMenu to be called, since the nil call will produce non-searched results.
        [searchBox setStringValue:@""];
        [[[searchBox cell] cancelButtonCell] performClick:self];
    });
}

- (void)updateMenuContaining:(NSString*)search {
	// Use GDC to prevent concurrent modification of the menu, since that would be messy.
	dispatch_async(dispatch_get_main_queue(), ^{
		[jcMenu setMenuChangedMessagesEnabled:NO];

		NSArray *returnedClippings = [flycutOperator previousClippings:[[NSUserDefaults standardUserDefaults] integerForKey:@"displayNum"] containing:search];

		NSArray *menuItems = [[[jcMenu itemArray] reverseObjectEnumerator] allObjects];

		NSArray *clipItems = [[returnedClippings reverseObjectEnumerator] allObjects];

		// Figure out if the number of menu items is changing and add or remove entries as necessary.
		// If we remove all of them and add all new ones, the menu won't redraw if the count is unchanged, so just reuse them by changing their title.
		int oldItems = [menuItems count]-jcMenuBaseItemsCount;
		int newItems = [clipItems count];
        DLog(@"list=%@, oldItems=%d, newItems=%d", returnedClippings, oldItems, newItems);

        for ( int i = 0; i < oldItems; i++ )
            [jcMenu removeItemAtIndex:0];

        for ( int i = 0; i < newItems; i++ )
        {
            FlycutClipping *clipping = [clipItems objectAtIndex:i];
            NSMenuItem *item;
            item = [[NSMenuItem alloc] initWithTitle:[clipping displayString]
                                              action:@selector(processMenuClippingSelection:)
                                       keyEquivalent:@""];
            [item setTarget:self];
            [item setEnabled:YES];
            // 图片条目显示 32px 缩略图；设为 16pt 以适配菜单并在 Retina 上清晰
            if ( [clipping isImage] ) {
                NSImage *thumbnail = [[flycutOperator imageStore] thumbnailForClipping:clipping maxPixelSize:32];
                if ( thumbnail ) {
                    [thumbnail setSize:NSMakeSize(16, 16)];
                    [item setImage:thumbnail];
                }
            }
            [jcMenu insertItem:item atIndex:0];
            // Way back in 0.2, failure to release the new item here was causing a quite atrocious memory leak.
            [item release];
        }
    });
}

-(IBAction)processMenuClippingSelection:(id)sender
{
	int index=[[sender menu] indexOfItem:sender];
	[self pasteIndexAndUpdate:index];

	if ( [[NSUserDefaults standardUserDefaults] boolForKey:@"menuSelectionPastes"] ) {
		[self performSelector:@selector(hideApp) withObject:nil];
		[self performSelector:@selector(fakeCommandV) withObject:nil afterDelay:0.2];
	}
}

-(void) setPBBlockCount:(NSNumber *)newPBBlockCount
{
    [newPBBlockCount retain];
    [pbBlockCount release];
    pbBlockCount = newPBBlockCount;
}

-(void)addClipToPasteboard:(NSString*)pbFullText
{
    NSArray *pbTypes;
    pbTypes = [NSArray arrayWithObjects:@"NSStringPboardType",NULL];

    [jcPasteboard declareTypes:pbTypes owner:NULL];

    [jcPasteboard setString:pbFullText forType:@"NSStringPboardType"];
    [self setPBBlockCount:[NSNumber numberWithInt:[jcPasteboard changeCount]]];
}

-(void)addClippingToPasteboard:(FlycutClipping *)clipping
{
    if ( [clipping isImage] ) {
        [self addImageToPasteboard:clipping];
    } else {
        [self addClipToPasteboard:[clipping contents]];
    }
}

-(void)addImageToPasteboard:(FlycutClipping *)clipping
{
    NSDictionary *representations = [[flycutOperator imageStore] pasteboardRepresentationsForClipping:clipping];
    if ( [representations count] == 0 ) {
        DLog(@"No pasteboard representation could be generated for image");
        return;
    }

    // 固定声明顺序，让接收方优先选择无损 PNG；JPG 与 JPEG 是同一 UTI，只声明一次
    NSArray *preferredTypes = [NSArray arrayWithObjects:
                               @"public.png", @"public.tiff", @"public.jpeg", @"public.heic", nil];
    NSMutableArray *declaredTypes = [NSMutableArray arrayWithCapacity:4];
    for ( NSString *type in preferredTypes ) {
        if ( [representations objectForKey:type] ) {
            [declaredTypes addObject:type];
        }
    }

    [jcPasteboard declareTypes:declaredTypes owner:NULL];
    BOOL wroteAny = NO;
    for ( NSString *type in declaredTypes ) {
        if ( [jcPasteboard setData:[representations objectForKey:type] forType:type] ) {
            wroteAny = YES;
        }
    }

    // 至少成功写入一种格式才屏蔽轮询，避免吞掉用户接下来的真实复制
    if ( wroteAny ) {
        [self setPBBlockCount:[NSNumber numberWithInt:[jcPasteboard changeCount]]];
    }
}

-(void) stackDown
{
	if ( [flycutOperator setStackPositionToOneLessRecent] ) {
		[self fillBezel];
	}
}

-(void) fillBezel
{
    FlycutClipping* clipping = [flycutOperator clippingAtStackPosition];
    if ( [clipping isImage] ) {
        // 预览按最大 640px 解码，避免几十 MB 的原图撑爆 Bezel 和内存
        NSImage *preview = [[flycutOperator imageStore] imageForClipping:clipping maxPixelSize:640];
        if ( nil != preview ) {
            [bezel setImage:preview displayText:[clipping contents]];
        } else {
            [bezel setText:[clipping contents]];
        }
    } else {
        [bezel setText:[NSString stringWithFormat:@"%@", [clipping contents]]];
    }
    [bezel setCharString:[NSString stringWithFormat:@"%d of %d", [flycutOperator stackPosition] + 1, [flycutOperator jcListCount]]];
    NSString *localizedName = [clipping appLocalizedName];
    if ( nil == localizedName )
        localizedName = @"";
    NSString* dateString = @"";
    if ( [clipping timestamp] > 0)
        dateString = [dateFormat stringFromDate:[NSDate dateWithTimeIntervalSince1970: [clipping timestamp]]];
    NSImage* icon = nil;
    if (nil != [clipping appBundleURL])
        icon = [[NSWorkspace sharedWorkspace] iconForFile:[clipping appBundleURL]];
    [bezel setSource:localizedName];
    [bezel setDate:dateString];
    [bezel setSourceIcon:icon];
}

-(void) stackUp
{
	if ( [flycutOperator setStackPositionToOneMoreRecent] ) {
		[self fillBezel];
	}
}

- (void)setHotKeyPreferenceForRecorder:(SRRecorderControl *)aRecorder {
	if (aRecorder == mainRecorder) {
		[[NSUserDefaults standardUserDefaults] setObject:
			[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:[NSNumber numberWithInt:[mainRecorder keyCombo].code],[NSNumber numberWithInt:[mainRecorder keyCombo].flags],nil] forKeys:[NSArray arrayWithObjects:@"keyCode",@"modifierFlags",nil]]
		forKey:@"ShortcutRecorder mainHotkey"];
	}
}

- (BOOL)shortcutRecorder:(SRRecorderControl *)aRecorder isKeyCode:(NSInteger)keyCode andFlagsTaken:(NSUInteger)flags reason:(NSString **)aReason {
	return NO;
}

- (void)shortcutRecorder:(SRRecorderControl *)aRecorder keyComboDidChange:(KeyCombo)newKeyCombo {
	if (aRecorder == mainRecorder) {
		[self toggleMainHotKey: aRecorder];
		[self setHotKeyPreferenceForRecorder: aRecorder];
	}
	DLog(@"code: %ld, flags: %lu", (long)newKeyCombo.code, (unsigned long)newKeyCombo.flags);
}

- (NSString*)alertWithMessageText:(NSString*)message informationText:(NSString*)information buttonsTexts:(NSArray*)buttons {
	NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:message];
	[buttons enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
		[alert addButtonWithTitle:obj];
	}];
	[alert setInformativeText:information];
	NSInteger result = [alert runModal];
	[alert release];
	if ( result < NSAlertFirstButtonReturn || result >= NSAlertFirstButtonReturn + [buttons count] )
		return nil;
	return buttons[result - NSAlertFirstButtonReturn];
}

- (void)beginUpdates {
	needBezelUpdate = NO;
	needMenuUpdate = NO;
}

- (void)endUpdates {
	DLog(@"ending updates");
	if ( needBezelUpdate && isBezelDisplayed )
		[self updateBezel];
	if ( needMenuUpdate )
	{
		DLog(@"launching updateMenu");
		// Timers attach to the run loop of the process, which isn't present on all processes, so we must dispatch to the main queue to ensure we have a run loop for the timer.
		dispatch_async(dispatch_get_main_queue(), ^{
			// Menu updates need to be in NSRunLoopCommonModes to reliably happen.
			[[NSRunLoop currentRunLoop] performSelector:@selector(updateMenu) target:self argument:nil order:0 modes:[NSArray arrayWithObject:NSRunLoopCommonModes]];
		});
	}
	needBezelUpdate = needMenuUpdate = NO;
}

- (void)insertClippingAtIndex:(int)index {
	[self noteChangeAtIndex:index];
}

- (void)deleteClippingAtIndex:(int)index {
	[self noteChangeAtIndex:index];
}

- (void)reloadClippingAtIndex:(int)index {
	[self noteChangeAtIndex:index];
}

- (void)moveClippingAtIndex:(int)index toIndex:(int)newIndex {
	[self noteChangeAtIndex:index];
	[self noteChangeAtIndex:newIndex];
}

- (void)noteChangeAtIndex:(int)index {
	// Always give bezel update, since the count may need updating and the possibility of concurrent user bezel navigation and store changes make need detection risky.
	needBezelUpdate = YES;
	if ( index < [[NSUserDefaults standardUserDefaults] integerForKey:@"displayNum"] )
		needMenuUpdate = YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
	[flycutOperator applicationWillTerminate];
	//Unregister our hot key (not required)
	[[SGHotKeyCenter sharedCenter] unregisterHotKey: mainHotKey];
	[mainHotKey release];
	mainHotKey = nil;
	[self hideBezel];
	[[NSDistributedNotificationCenter defaultCenter]
		removeObserver:self
        		  name:@"AppleKeyboardPreferencesChangedNotification"
				object:nil];
	[[NSDistributedNotificationCenter defaultCenter]
		removeObserver:self
				  name:@"AppleSelectedInputSourcesChangedNotification"
				object:nil];
}

- (void) dealloc {
	[bezel release];
	[srTransformer release];
	[super dealloc];
}

@end
