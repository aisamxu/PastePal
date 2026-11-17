//
//  FlycutOperator.h
//  Flycut
//
//  Flycut by Gennadiy Potapov and contributors. Based on Jumpcut by Steve Cook.
//  Copyright 2011 General Arcade. All rights reserved.
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// FlycutOperator owns and interacts with the FlycutStores, providing
// manipulation of the stores.

#ifndef FlycutOperator_h
#define FlycutOperator_h

#import "FlycutStore.h"

@class PastePalImageStore;

@protocol FlycutOperatorDelegate <NSObject>
@optional
- (NSString*)alertWithMessageText:(NSString*)message informationText:(NSString*)information buttonsTexts:(NSArray*)buttons;
@end

@interface FlycutOperator : NSObject <FlycutStoreDeleteDelegate> {
    int							stackPosition;
    int							favoritesStackPosition;
    int							stashedStackPosition;

    FlycutStore				*clippingStore;
    FlycutStore				*favoritesStore;
    FlycutStore				*stashedStore;

    // 图片文件存储；图片条目只保存元数据，二进制落盘
    PastePalImageStore      *imageStore;

	SEL saveSelector;
	NSObject* saveTarget;
	int displayNum;
	int displayLength;

    BOOL disableStore;
	BOOL inhibitSaveEngineAfterListModification;
	BOOL inhibitAutosaveClippings;

	//Preferences
	BOOL issuedRememberResizeWarning;
}

// Basic functionality
-(int)indexOfClipping:(NSString*)contents ofType:(NSString*)type fromApp:(NSString *)appName withAppBundleURL:(NSString *)bundleURL;
-(bool)addClipping:(NSString*)contents ofType:(NSString*)type fromApp:(NSString *)appName withAppBundleURL:(NSString *)bundleURL target:(id)selectorTarget clippingAddedSelector:(SEL)clippingAddedSelectorclippingAddedSelector;
-(int)stackPosition;
-(NSString*)getPasteFromStackPosition;
-(NSString*)getPasteFromIndex:(int) position;
// 返回完整剪贴条目，供调用方区分文本/图片；pasteMovesToTop 行为与 getPasteFromIndex 一致
-(FlycutClipping *)getClippingFromStackPosition;
-(FlycutClipping *)getClippingFromIndex:(int) position;
-(bool) saveFromStack;
-(bool)clearItemAtStackPosition;
-(void)clearList;
-(void)mergeList;

// Stack position manipulation functionality
-(bool)setStackPositionToOneMoreRecent;
-(bool)setStackPositionToOneLessRecent;
-(bool)setStackPositionToFirstItem;
-(bool)setStackPositionToLastItem;
-(bool)setStackPositionToTenMoreRecent;
-(bool)setStackPositionToTenLessRecent;
-(bool)setStackPositionTo:(int) newStackPosition;
-(void)adjustStackPositionIfOutOfBounds;
-(bool)stackPositionIsInBounds;

// Stack related
-(BOOL) isValidClippingNumber:(NSNumber *)number;
-(NSString *) clippingStringWithCount:(int)count;

// Save and load
-(void) saveEngine;
-(bool) loadEngineFromPList;

// Preference related
-(void) willShowPreferences;
-(int) setRememberNum:(int)newRemember forPrimaryStore:(BOOL) isPrimaryStore;

// Initialization / cleanup related
-(void)applicationWillTerminate;;
-(void)awakeFromNibDisplaying:(int) displayNum withDisplayLength:(int) displayLength withSaveSelector:(SEL) selector forTarget:(NSObject*) target;

// Favorites Store related
-(bool)favoritesStoreIsSelected;
-(void)switchToFavoritesStore;
-(bool)restoreStashedStore;
-(void)toggleToFromFavoritesStore;
-(bool)saveFromStackToFavorites;

// Clippings Store related
-(int)jcListCount;
-(int)rememberNum;
-(FlycutClipping*)clippingAtStackPosition;
-(NSArray *) previousDisplayStrings:(int)howMany containing:(NSString*)search;
// 与 previousDisplayStrings 顺序一致，供菜单设置图片缩略图
-(NSArray *) previousClippings:(int)howMany containing:(NSString*)search;
-(NSArray *) previousIndexes:(int)howMany containing:(NSString*)search; // This method is in newest-first order.
// 图片插入：强制按 hash 去重，成功后调用 clippingAddedSelector
-(bool)addImageClippingWithData:(NSData *)data
                           hash:(NSString *)hash
                            uti:(NSString *)uti
                     pixelWidth:(int)pixelWidth
                    pixelHeight:(int)pixelHeight
                       byteSize:(NSInteger)byteSize
                  displayString:(NSString *)displayString
                        fromApp:(NSString *)appName
              withAppBundleURL:(NSString *)bundleURL
                         target:(id)selectorTarget
          clippingAddedSelector:(SEL)clippingAddedSelector;
// 文本内容/类型是否应跳过（密码与敏感 Pasteboard 类型）
-(BOOL)shouldSkip:(NSString *)contents ofType:(NSString *)type fromAvailableTypes:(NSArray<NSString *> *)availableTypes;
// 图片类型是否命中敏感的 Pasteboard 类型跳过列表
-(BOOL)shouldSkipImageOfType:(NSString *)type fromAvailableTypes:(NSArray<NSString *> *)availableTypes;
// 按总容量上限淘汰最旧的非收藏图片，并清扫无引用文件
-(void)enforceImageHistoryLimit;
-(void)sweepUnreferencedImages;
// 测试可注入临时目录的图片存储
-(PastePalImageStore *)imageStore;
-(void)setImageStore:(PastePalImageStore *)store;
-(void)setDisableStoreTo:(bool) value;
-(bool)storeDisabled;
-(void)setClippingsStoreDelegate:(id<FlycutStoreDelegate>) delegate;
-(void)setFavoritesStoreDelegate:(id<FlycutStoreDelegate>) delegate;

/** optional delegate (not retained) */
@property (nonatomic, nullable, assign) id<FlycutOperatorDelegate> delegate;

@end

#endif /* FlycutOperator_h */
