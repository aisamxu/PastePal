//
//  FlycutClipping.m
//  Flycut
//
//  Flycut by Gennadiy Potapov and contributors. Based on Jumpcut by Steve Cook.
//  Copyright 2011 General Arcade. All rights reserved.
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//


#import "FlycutClipping.h"

@implementation FlycutClipping

-(id) init
{
    [self initWithContents:@""
                  withType:@""
         withDisplayLength:40
      withAppLocalizedName:@""
          withAppBundleURL:nil
             withTimestamp:0];
    return self;
}

-(id) initWithContents:(NSString *)contents withType:(NSString *)type withDisplayLength:(int)displayLength withAppLocalizedName:(NSString *)localizedName withAppBundleURL:(NSString*)bundleURL withTimestamp:(NSInteger)timestamp
{
    [super init];
    clipContents = [[[NSString alloc] init] retain];
    clipDisplayString = [[[NSString alloc] init] retain];
    clipType = [[[NSString alloc] init] retain];
    // 文本条目：图片元数据保持空值
    clipKind = FlycutClipKindText;
    imageHash = nil;
    imageFile = nil;
    imageUTI = nil;
    imagePixelWidth = 0;
    imagePixelHeight = 0;
    imageByteSize = 0;

    [self setContents:contents setDisplayLength:displayLength];
    [self setType:type];
    [self setAppLocalizedName:localizedName];
    [self setAppBundleURL:bundleURL];
    [self setTimestamp:timestamp];
    [self setHasName:false];
    
    return self;
}

-(id) initWithImageHash:(NSString *)hash
                   file:(NSString *)file
                    uti:(NSString *)uti
             pixelWidth:(int)pixelWidth
            pixelHeight:(int)pixelHeight
               byteSize:(NSInteger)byteSize
          displayString:(NSString *)displayString
      appLocalizedName:(NSString *)localizedName
         appBundleURL:(NSString *)bundleURL
             timestamp:(NSInteger)timestamp
{
    self = [super init];
    if (self) {
        clipKind = FlycutClipKindImage;
        // contents 存非空显示字符串，菜单、搜索和旧读取路径无需特殊处理；
        // 粘贴前必须用 isImage 判断，绝不能把该字符串当文本写回剪贴板
        clipContents = [displayString copy];
        clipDisplayString = [clipContents retain];
        clipType = [@"public.image" copy];
        clipDisplayLength = 40;
        imageHash = [hash copy];
        imageFile = [file copy];
        imageUTI = [uti copy];
        imagePixelWidth = pixelWidth;
        imagePixelHeight = pixelHeight;
        imageByteSize = byteSize;
        [self setAppLocalizedName:localizedName];
        [self setAppBundleURL:bundleURL];
        [self setTimestamp:timestamp];
        clipHasName = NO;
    }
    return self;
}

+(NSString *) imageDisplayStringForUTI:(NSString *)uti
                            pixelWidth:(int)pixelWidth
                           pixelHeight:(int)pixelHeight
                              byteSize:(NSInteger)byteSize
{
    NSString *format;
    if ([uti isEqualToString:@"public.png"]) {
        format = @"PNG";
    } else if ([uti isEqualToString:@"public.tiff"]) {
        format = @"TIFF";
    } else if ([uti isEqualToString:@"public.jpeg"]) {
        format = @"JPEG";
    } else if ([uti isEqualToString:@"public.heic"]) {
        format = @"HEIC";
    } else {
        // 未知类型退化为 UTI 最后一段，避免显示空白
        format = [[uti lastPathComponent] uppercaseString];
        if ([format length] == 0) {
            format = @"Image";
        }
    }

    // 字节数按人类可读单位展示
    NSString *sizeString;
    if (byteSize < 1024) {
        sizeString = [NSString stringWithFormat:@"%ld B", (long)byteSize];
    } else if (byteSize < 1024 * 1024) {
        sizeString = [NSString stringWithFormat:@"%.1f KB", (double)byteSize / 1024.0];
    } else {
        sizeString = [NSString stringWithFormat:@"%.1f MB", (double)byteSize / (1024.0 * 1024.0)];
    }

    return [NSString stringWithFormat:@"Image %d×%d · %@ · %@",
            pixelWidth, pixelHeight, format, sizeString];
}

/* - (id)initWithCoder:(NSCoder *)coder
{
    NSString * newContents;
    int newDisplayLength;
    NSString *newType;
    BOOL newHasName;
    if ( self = [super init]) {
        newContents = [NSString stringWithString:[coder decodeObject]];
        [coder decodeValueOfObjCType:@encode(int) at:&newDisplayLength];
        newType = [NSString stringWithString:[coder decodeObject]];
        [coder decodeValueOfObjCType:@encode(BOOL) at:&newHasName];
        [self 	     setContents:newContents
                setDisplayLength:newDisplayLength];
        [self setType:newType];
        [self setHasName:newHasName];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    int codeDisplayLength = [self displayLength];
    BOOL codeHasName = [self hasName];
    [coder encodeObject:[self contents]];
    [coder encodeValueOfObjCType:@encode(int) at:&codeDisplayLength];
    [coder encodeObject:[self type]];
    [coder encodeValueOfObjCType:@encode(BOOL) at:&codeHasName];
} */

-(void) setContents:(NSString *)newContents setDisplayLength:(int)newDisplayLength
{
    id old = clipContents;
    [newContents retain];
    clipContents = newContents;
    [old release];
    if ( newDisplayLength  > 0 ) {
        clipDisplayLength = newDisplayLength;
    }
   [self resetDisplayString];
}

-(void) setContents:(NSString *)newContents
{
    id old = clipContents;
    [newContents retain];
    clipContents = newContents;
    [old release];
    [self resetDisplayString];
}

-(void) setType:(NSString *)newType
{
    id old = clipType;
    [newType retain];
    clipType = newType;
    [old release];
}

-(void) setDisplayLength:(int)newDisplayLength
{
    if ( newDisplayLength > 0 && clipDisplayLength != newDisplayLength ) {
        clipDisplayLength = newDisplayLength;
        [self resetDisplayString];
    }
}

-(void) setAppLocalizedName:(NSString *)new
{
    id old = appLocalizedName;
    [new retain];
    appLocalizedName = new;
    [old release];
}

-(void) setAppBundleURL:(NSString *)new
{
    id old = appBundleURL;
    [new retain];
    appBundleURL = new;
    [old release];
}

-(void) setTimestamp:(NSInteger)newTimestamp
{
    clipTimestamp = newTimestamp;
}

-(void) setHasName:(BOOL)newHasName
{
        clipHasName = newHasName;
}

-(void) resetDisplayString
{
    NSString *newDisplayString, *firstLineOfClipping, *trimmedString;
	NSUInteger start, lineEnd, contentsEnd;
	// 图片描述是固定格式的短字符串，不受文本显示长度偏好影响
    if (clipKind == FlycutClipKindImage) {
        [clipDisplayString release];
        clipDisplayString = [clipContents copy];
        return;
    }
	NSRange startRange = NSMakeRange(0,0);
	NSRange contentsRange;
	// We're resetting the display string, so release the old one.
    [clipDisplayString release];
	// We want to restrict the display string to the clipping contents through the first line break.
    trimmedString = [clipContents stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [trimmedString getLineStart:&start end:&lineEnd contentsEnd:&contentsEnd forRange:startRange];
	contentsRange = NSMakeRange(0, contentsEnd);
	firstLineOfClipping = [trimmedString substringWithRange:contentsRange];
    if ( [firstLineOfClipping length] > clipDisplayLength ) {
        newDisplayString = [[NSString stringWithString:[firstLineOfClipping substringToIndex:clipDisplayLength]] stringByAppendingString:@"…"];   
    } else {
        newDisplayString = [NSString stringWithString:firstLineOfClipping];
    }
    [newDisplayString retain];
    clipDisplayString = newDisplayString;
}

-(NSString *) description
{
    NSString *description = [[super description] stringByAppendingString:@": "];
    description = [description stringByAppendingString:[self displayString]];   
    return description;
}

-(FlycutClipping *) clipping
{
    return self;
}

-(NSString *) contents
{
//    NSString *returnClipContents;
//    returnClipContents = [NSString stringWithString:clipContents];
//    return returnClipContents;
    return clipContents;
}

-(NSString *) appLocalizedName
{
    return appLocalizedName;
}

-(NSString *) appBundleURL
{
    return appBundleURL;
}

-(NSInteger) timestamp
{
    return clipTimestamp;
}

-(int) displayLength
{
    return clipDisplayLength;
}

-(NSString *) type
{
    return clipType;
}

-(NSString *) displayString
{
    // QUESTION
    // Why doesn't the below work?
    // NSString *returnClipDisplayString;
    // returnClipDisplayString = [NSString stringWithString:clipDisplayString];
    // return returnClipDisplayString;
    return clipDisplayString;
}

-(BOOL) hasName
{
    return clipHasName;
}

-(BOOL) isImage
{
    return clipKind == FlycutClipKindImage;
}

-(FlycutClipKind) kind
{
    return clipKind;
}

-(NSString *) imageHash
{
    return imageHash;
}

-(NSString *) imageFile
{
    return imageFile;
}

-(NSString *) imageUTI
{
    return imageUTI;
}

-(int) imagePixelWidth
{
    return imagePixelWidth;
}

-(int) imagePixelHeight
{
    return imagePixelHeight;
}

-(NSInteger) imageByteSize
{
    return imageByteSize;
}

- (BOOL)isEqual:(id)other {
    if (other == self)
        return YES;
    if (!other || ![other isKindOfClass:[self class]])
        return NO;
    FlycutClipping * otherClip = (FlycutClipping *)other;
    // 图片按内容哈希比较，避免相同尺寸/格式的不同图片因占位文本相同被误去重
    if ([self isImage] || [otherClip isImage]) {
        if (![self isImage] || ![otherClip isImage]) {
            return NO;
        }
        return imageHash != nil && [imageHash isEqualToString:[otherClip imageHash]];
    }
    return (/*[self.type isEqualToString:otherClip.type] &&*/ // Type is under-utilized a this time and will mismatch on cross-device (macOS <-> iOS) usage.  This should be revisited once we have support for more than just raw text clippings.
            [self.contents isEqualToString:otherClip.contents]);
}

-(NSUInteger) hash
{
    if (clipKind == FlycutClipKindImage) {
        return [imageHash hash];
    }
    return [clipContents hash];
}

-(void) dealloc
{
    [clipContents release];
    [clipType release];
    [appLocalizedName release];
    [appBundleURL release];
    [imageHash release];
    [imageFile release];
    [imageUTI release];
    clipDisplayLength = 0;
    [clipDisplayString release];
    clipHasName = 0;
    [super dealloc];
}
@end
