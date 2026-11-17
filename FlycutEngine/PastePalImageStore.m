//
//  PastePalImageStore.m
//  PastePal
//

#import "PastePalImageStore.h"
#import "FlycutClipping.h"
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>

@interface PastePalImageStore (Private)
-(BOOL) ensureRootDirectory:(NSError **)error;
-(NSData *) encodedDataForCGImage:(CGImageRef)image uti:(NSString *)uti;
@end

static NSError *PastePalImageStoreError(NSString *message)
{
    NSDictionary *info = [NSDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    return [NSError errorWithDomain:@"io.github.aisamxu.PastePal.ImageStore" code:1 userInfo:info];
}

@implementation PastePalImageStore

-(id) init
{
    // 默认目录位于用户的 Application Support，不硬编码 ~/Library
    NSString *base = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0]
                      stringByAppendingPathComponent:@"PastePal"];
    return [self initWithRootDirectory:[base stringByAppendingPathComponent:@"Images"]];
}

-(id) initWithRootDirectory:(NSString *)directory
{
    self = [super init];
    if (self) {
        rootDirectory = [directory copy];
        imageCache = [[NSCache alloc] init];
        imageCache.countLimit = 100;
        representationCache = [[NSCache alloc] init];
        // 只缓存少量最近图片的编码结果，防止大量大图占用内存
        // 只缓存最近一次粘贴的编码结果，避免多张大图同时占用大量内存
        representationCache.countLimit = 1;
        ioQueue = dispatch_queue_create("io.github.aisamxu.PastePal.ImageStore", DISPATCH_QUEUE_SERIAL);
        [self ensureRootDirectory:NULL];
    }
    return self;
}

-(void) dealloc
{
    [rootDirectory release];
    [imageCache release];
    [representationCache release];
    dispatch_release(ioQueue);
    [super dealloc];
}

-(NSString *) rootDirectory
{
    return rootDirectory;
}

-(BOOL) ensureRootDirectory:(NSError **)error
{
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if ([fm fileExistsAtPath:rootDirectory isDirectory:&isDirectory] && isDirectory) {
        return YES;
    }
    return [fm createDirectoryAtPath:rootDirectory
         withIntermediateDirectories:YES
                          attributes:nil
                               error:error];
}

+(NSString *) sha256HexForData:(NSData *)data
{
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256([data bytes], (CC_LONG)[data length], digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

+(NSString *) fileExtensionForUTI:(NSString *)uti
{
    if ([uti isEqualToString:@"public.png"]) {
        return @"png";
    }
    if ([uti isEqualToString:@"public.tiff"]) {
        return @"tiff";
    }
    if ([uti isEqualToString:@"public.jpeg"]) {
        return @"jpeg";
    }
    if ([uti isEqualToString:@"public.heic"]) {
        return @"heic";
    }
    // 未知类型仍给出稳定扩展名，避免文件名缺失后缀
    return @"img";
}

+(BOOL) pixelSizeForImageData:(NSData *)data width:(int *)width height:(int *)height
{
    if ([data length] == 0) {
        return NO;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) {
        return NO;
    }
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    BOOL valid = NO;
    if (properties) {
        NSNumber *pixelWidth = (NSNumber *)CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
        NSNumber *pixelHeight = (NSNumber *)CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
        if (pixelWidth && pixelHeight && [pixelWidth intValue] > 0 && [pixelHeight intValue] > 0) {
            if (width) {
                *width = [pixelWidth intValue];
            }
            if (height) {
                *height = [pixelHeight intValue];
            }
            valid = YES;
        }
        CFRelease(properties);
    }
    CFRelease(source);
    return valid;
}

-(NSString *) pathForImageFile:(NSString *)file
{
    if ([file length] == 0) {
        return nil;
    }
    return [rootDirectory stringByAppendingPathComponent:file];
}

-(BOOL) fileExistsForImageFile:(NSString *)file
{
    NSString *path = [self pathForImageFile:file];
    return path != nil && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

-(NSString *) saveData:(NSData *)data hash:(NSString *)hash uti:(NSString *)uti error:(NSError **)error
{
    if ([data length] == 0 || [hash length] == 0) {
        if (error) {
            *error = PastePalImageStoreError(@"Image data and hash are required");
        }
        return nil;
    }

    NSString *file = [NSString stringWithFormat:@"%@.%@", hash, [[self class] fileExtensionForUTI:uti]];
    NSString *path = [rootDirectory stringByAppendingPathComponent:file];
    __block NSString *savedFile = nil;
    __block NSError *writeError = nil;

    // 串行队列保证同一文件不会被并发写入或清扫
    dispatch_sync(ioQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:path]) {
            savedFile = [file copy];
            return;
        }
        if (![self ensureRootDirectory:&writeError]) {
            return;
        }
        // 先写临时文件再原子替换，避免中途退出留下半张图片
        if ([data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
            savedFile = [file copy];
        }
    });

    if (!savedFile && error) {
        *error = writeError ? writeError : PastePalImageStoreError(@"Could not save image data");
    }
    return [savedFile autorelease];
}

-(NSData *) dataForClipping:(FlycutClipping *)clipping
{
    if (![clipping isImage]) {
        return nil;
    }
    NSString *path = [self pathForImageFile:[clipping imageFile]];
    if (!path) {
        return nil;
    }
    // 原子写入保证这里读到的要么是完整旧文件，要么是完整新文件
    return [NSData dataWithContentsOfFile:path];
}

-(NSImage *) imageForClipping:(FlycutClipping *)clipping maxPixelSize:(NSInteger)maxPixelSize
{
    if (![clipping isImage] || [[clipping imageHash] length] == 0) {
        return nil;
    }
    if (maxPixelSize <= 0) {
        maxPixelSize = 1024;
    }
    NSString *cacheKey = [NSString stringWithFormat:@"%@:%ld", [clipping imageHash], (long)maxPixelSize];
    NSImage *cached = [imageCache objectForKey:cacheKey];
    if (cached) {
        return cached;
    }

    NSString *path = [self pathForImageFile:[clipping imageFile]];
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return nil;
    }

    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!source) {
        return nil;
    }
    // 用 ImageIO 直接生成缩略图，避免把几十 MB 的原图完整解码进内存
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             [NSNumber numberWithInteger:maxPixelSize], (NSString *)kCGImageSourceThumbnailMaxPixelSize,
                             [NSNumber numberWithBool:YES], (NSString *)kCGImageSourceCreateThumbnailFromImageAlways,
                             [NSNumber numberWithBool:YES], (NSString *)kCGImageSourceCreateThumbnailWithTransform,
                             [NSNumber numberWithBool:YES], (NSString *)kCGImageSourceShouldCacheImmediately,
                             nil];
    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!cgImage) {
        return nil;
    }
    NSImage *image = [[NSImage alloc] initWithCGImage:cgImage
                                                 size:NSMakeSize(CGImageGetWidth(cgImage), CGImageGetHeight(cgImage))];
    CGImageRelease(cgImage);
    [imageCache setObject:image forKey:cacheKey];
    return [image autorelease];
}

-(NSImage *) thumbnailForClipping:(FlycutClipping *)clipping maxPixelSize:(NSInteger)maxPixelSize
{
    return [self imageForClipping:clipping maxPixelSize:maxPixelSize];
}

-(NSData *) encodedDataForCGImage:(CGImageRef)image uti:(NSString *)uti
{
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,
                                                                         (__bridge CFStringRef)uti, 1, NULL);
    if (!destination) {
        return nil;
    }
    NSDictionary *options = nil;
    if ([uti isEqualToString:@"public.jpeg"] || [uti isEqualToString:@"public.heic"]) {
        options = [NSDictionary dictionaryWithObject:[NSNumber numberWithDouble:0.9]
                                              forKey:(NSString *)kCGImageDestinationLossyCompressionQuality];
    }
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)options);
    BOOL succeeded = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    if (!succeeded || [data length] == 0) {
        return nil;
    }
    return data;
}

-(NSDictionary *) pasteboardRepresentationsForClipping:(FlycutClipping *)clipping
{
    if (![clipping isImage] || [[clipping imageHash] length] == 0) {
        return nil;
    }
    NSString *hash = [clipping imageHash];
    NSDictionary *cached = [representationCache objectForKey:hash];
    if (cached) {
        return cached;
    }

    NSData *original = [self dataForClipping:clipping];
    if (!original) {
        return nil;
    }

    NSArray *targetUTIs = [NSArray arrayWithObjects:
                           @"public.png", @"public.tiff", @"public.jpeg", @"public.heic", nil];
    NSMutableDictionary *representations = [NSMutableDictionary dictionaryWithCapacity:4];
    NSString *originalUTI = [clipping imageUTI];

    // 原格式直接复用磁盘数据，避免无谓的重新编码
    if ([targetUTIs containsObject:originalUTI]) {
        [representations setObject:original forKey:originalUTI];
    }

    NSMutableArray *missingUTIs = [NSMutableArray array];
    for (NSString *uti in targetUTIs) {
        if (![representations objectForKey:uti]) {
            [missingUTIs addObject:uti];
        }
    }

    if ([missingUTIs count] > 0) {
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)original, NULL);
        CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
        if (image) {
            for (NSString *uti in missingUTIs) {
                // 单个格式编码失败（例如系统不支持 HEIC 编码）只跳过该格式
                NSData *encoded = [self encodedDataForCGImage:image uti:uti];
                if (encoded) {
                    [representations setObject:encoded forKey:uti];
                }
            }
            CGImageRelease(image);
        }
        if (source) {
            CFRelease(source);
        }
    }

    if ([representations count] == 0) {
        return nil;
    }
    [representationCache setObject:representations forKey:hash];
    return representations;
}

-(void) deleteUnreferencedFilesKeepingHashes:(NSSet *)hashes olderThan:(NSTimeInterval)minimumAge
{
    NSSet *keptHashes = hashes ? hashes : [NSSet set];
    dispatch_sync(ioQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *files = [fm contentsOfDirectoryAtPath:rootDirectory error:NULL];
        NSDate *now = [NSDate date];
        for (NSString *file in files) {
            // 跳过隐藏文件（例如 .DS_Store）
            if ([file hasPrefix:@"."]) {
                continue;
            }
            NSString *hash = [file stringByDeletingPathExtension];
            // 只清理 SHA-256 命名的图片文件，避免误删目录中的其他内容
            if ([hash length] != 64 || [keptHashes containsObject:hash]) {
                continue;
            }
            NSString *path = [rootDirectory stringByAppendingPathComponent:file];
            NSDictionary *attributes = [fm attributesOfItemAtPath:path error:NULL];
            NSDate *modified = [attributes objectForKey:NSFileModificationDate];
            // 新文件可能刚被写入但尚未登记到 store，留出最小保留时间
            if (modified && [now timeIntervalSinceDate:modified] < minimumAge) {
                continue;
            }
            [fm removeItemAtPath:path error:NULL];
        }
    });
}

@end
