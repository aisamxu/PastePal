//
//  FlycutClipping.h
//  Flycut
//
//  Flycut by Gennadiy Potapov and contributors. Based on Jumpcut by Steve Cook.
//  Copyright 2011 General Arcade. All rights reserved.
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import <Foundation/Foundation.h>

// 剪贴条目类型：文本与图片共用同一条历史时间线
typedef enum {
    FlycutClipKindText = 0,
    FlycutClipKindImage = 1
} FlycutClipKind;

@interface FlycutClipping : NSObject {
// What must a clipping hold?
// The text
    NSString * clipContents;
// The text type
    NSString * clipType;
// The display length
    int clipDisplayLength;
// The display string
    NSString * clipDisplayString;
// Does it have a name?
    BOOL clipHasName;
// The app name it came from
    NSString * appLocalizedName;
// The the bunle URL of the app it came from
    NSString * appBundleURL;
// The time
    NSInteger clipTimestamp;
// 条目类型：文本或图片
    FlycutClipKind clipKind;
// 图片的 SHA-256（十六进制），用于去重
    NSString * imageHash;
// 图片在 Images 目录下的文件名
    NSString * imageFile;
// 图片原始 UTI，决定存储扩展名和粘贴时的首选格式
    NSString * imageUTI;
// 图片像素尺寸
    int imagePixelWidth;
    int imagePixelHeight;
// 图片文件字节数，计入总容量上限
    NSInteger imageByteSize;
}

-(id) initWithContents:(NSString *)contents withType:(NSString *)type withDisplayLength:(int)displayLength withAppLocalizedName:(NSString *)localizedName withAppBundleURL:(NSString *)bundleURL withTimestamp:(NSInteger)timestamp;
// 图片条目初始化：contents 存菜单/搜索用的显示字符串，二进制只落盘
-(id) initWithImageHash:(NSString *)hash
                   file:(NSString *)file
                    uti:(NSString *)uti
             pixelWidth:(int)pixelWidth
            pixelHeight:(int)pixelHeight
               byteSize:(NSInteger)byteSize
          displayString:(NSString *)displayString
      appLocalizedName:(NSString *)localizedName
         appBundleURL:(NSString *)bundleURL
             timestamp:(NSInteger)timestamp;
// 生成 "Image 1920×1080 · PNG · 1.2 MB" 形式的显示字符串
+(NSString *) imageDisplayStringForUTI:(NSString *)uti
                            pixelWidth:(int)pixelWidth
                           pixelHeight:(int)pixelHeight
                              byteSize:(NSInteger)byteSize;
/* -(id) initWithCoder:(NSCoder *)coder;
-(void) decodeWithCoder:(NSCoder *)coder; */
-(NSString *) description;

// set values
-(void) setContents:(NSString *)newContents setDisplayLength:(int)newDisplayLength;
-(void) setContents:(NSString *)newContents;
-(void) setType:(NSString *)newType;
-(void) setDisplayLength:(int)newDisplayLength;
-(void) setHasName:(BOOL)newHasName;
-(void) setAppLocalizedName:(NSString *)new;
-(void) setAppBundleURL:(NSString *)new;
-(void) setTimestamp:(NSInteger)newTimestamp;

// Retrieve values
-(FlycutClipping *) clipping;
-(NSString *) contents;
-(int) displayLength;
-(NSString *) displayString;
-(NSString *) type;
-(NSString *) appLocalizedName;
-(NSString *) appBundleURL;
-(NSInteger) timestamp;
-(BOOL) hasName;

// 图片元数据；文本条目这些值均为 nil/0
-(BOOL) isImage;
-(FlycutClipKind) kind;
-(NSString *) imageHash;
-(NSString *) imageFile;
-(NSString *) imageUTI;
-(int) imagePixelWidth;
-(int) imagePixelHeight;
-(NSInteger) imageByteSize;

// Additional functions
-(void) resetDisplayString;

@end
