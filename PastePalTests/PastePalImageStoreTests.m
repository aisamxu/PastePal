//
//  PastePalImageStoreTests.m
//  PastePalTests
//
//  图片落盘、去重、缩略图、粘贴格式与孤儿清扫的单元测试。
//

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import "FlycutEngine/PastePalImageStore.h"
#import "FlycutEngine/FlycutClipping.h"

// 用 CoreGraphics 生成纯色 PNG，避免依赖测试资源文件
static NSData *PastePalTestPNGData(int width, int height, CGFloat red, CGFloat green, CGFloat blue)
{
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)width, (size_t)height, 8, 0, colorSpace,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        return nil;
    }
    CGContextSetRGBFillColor(context, red, green, blue, 1.0);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    // 叠加逐像素噪点，避免纯色 PNG 被压得过小，容量/上限测试才有意义
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            CGFloat fx = (CGFloat)((x * 37 + y * 17 + (int)(red * 255)) % 256) / 255.0;
            CGFloat fy = (CGFloat)((x * 11 + y * 29 + (int)(green * 255)) % 256) / 255.0;
            CGFloat fz = (CGFloat)((x * 23 + y * 41 + (int)(blue * 255)) % 256) / 255.0;
            CGContextSetRGBFillColor(context, fx, fy, fz, 1.0);
            CGContextFillRect(context, CGRectMake(x, y, 1, 1));
        }
    }
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);

    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    if (destination == NULL) {
        CGImageRelease(cgImage);
        return nil;
    }
    CGImageDestinationAddImage(destination, cgImage, NULL);
    BOOL succeeded = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(cgImage);
    return succeeded ? data : nil;
}

@interface PastePalImageStoreTests : XCTestCase {
    NSString *tempDirectory;
    PastePalImageStore *imageStore;
}
@end

@implementation PastePalImageStoreTests

- (void)setUp
{
    [super setUp];
    // 每个测试使用独立临时目录，绝不写入真实的 Application Support
    tempDirectory = [[NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"PastePalTests-%@", [[NSUUID UUID] UUIDString]]] retain];
    imageStore = [[PastePalImageStore alloc] initWithRootDirectory:tempDirectory];
}

- (void)tearDown
{
    [[NSFileManager defaultManager] removeItemAtPath:tempDirectory error:NULL];
    [imageStore release];
    imageStore = nil;
    [tempDirectory release];
    tempDirectory = nil;
    [super tearDown];
}

- (FlycutClipping *)clippingForData:(NSData *)data file:(NSString *)file
{
    NSString *hash = [PastePalImageStore sha256HexForData:data];
    return [[[FlycutClipping alloc] initWithImageHash:hash
                                                 file:file
                                                  uti:@"public.png"
                                           pixelWidth:1
                                          pixelHeight:1
                                             byteSize:(NSInteger)[data length]
                                        displayString:@"Image"
                                    appLocalizedName:@"Tests"
                                       appBundleURL:nil
                                           timestamp:0] autorelease];
}

- (void)testSHA256MatchesKnownVector
{
    NSData *data = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects([PastePalImageStore sha256HexForData:data],
                          @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

- (void)testUTIExtensionMapping
{
    XCTAssertEqualObjects([PastePalImageStore fileExtensionForUTI:@"public.png"], @"png");
    XCTAssertEqualObjects([PastePalImageStore fileExtensionForUTI:@"public.tiff"], @"tiff");
    XCTAssertEqualObjects([PastePalImageStore fileExtensionForUTI:@"public.jpeg"], @"jpeg");
    XCTAssertEqualObjects([PastePalImageStore fileExtensionForUTI:@"public.heic"], @"heic");
    // 未知类型也要有稳定扩展名
    XCTAssertEqualObjects([PastePalImageStore fileExtensionForUTI:@"com.example.unknown"], @"img");
}

- (void)testPixelSizeForPNGData
{
    NSData *data = PastePalTestPNGData(7, 3, 1.0, 0.0, 0.0);
    XCTAssertNotNil(data);

    int width = 0;
    int height = 0;
    XCTAssertTrue([PastePalImageStore pixelSizeForImageData:data width:&width height:&height]);
    XCTAssertEqual(width, 7);
    XCTAssertEqual(height, 3);

    // 非图片数据必须安全返回 NO
    XCTAssertFalse([PastePalImageStore pixelSizeForImageData:[@"not an image" dataUsingEncoding:NSUTF8StringEncoding]
                                                       width:&width
                                                      height:&height]);
}

- (void)testSaveDataIsIdempotentAndReadable
{
    NSData *data = PastePalTestPNGData(4, 4, 0.0, 1.0, 0.0);
    XCTAssertNotNil(data);
    NSString *hash = [PastePalImageStore sha256HexForData:data];

    NSError *error = nil;
    NSString *file = [imageStore saveData:data hash:hash uti:@"public.png" error:&error];
    XCTAssertEqualObjects(file, [hash stringByAppendingString:@".png"]);
    XCTAssertNil(error);
    XCTAssertTrue([imageStore fileExistsForImageFile:file]);

    // 相同 hash 再写一次应复用同一文件
    NSString *again = [imageStore saveData:data hash:hash uti:@"public.png" error:&error];
    XCTAssertEqualObjects(again, file);

    FlycutClipping *clipping = [self clippingForData:data file:file];
    XCTAssertEqualObjects([imageStore dataForClipping:clipping], data);
    XCTAssertEqualObjects([imageStore pathForImageFile:file],
                          [tempDirectory stringByAppendingPathComponent:file]);
}

- (void)testThumbnailRespectsMaxPixelSize
{
    NSData *data = PastePalTestPNGData(40, 20, 0.0, 0.0, 1.0);
    NSError *error = nil;
    NSString *file = [imageStore saveData:data
                                     hash:[PastePalImageStore sha256HexForData:data]
                                      uti:@"public.png"
                                    error:&error];
    XCTAssertNotNil(file);

    FlycutClipping *clipping = [self clippingForData:data file:file];
    NSImage *thumbnail = [imageStore thumbnailForClipping:clipping maxPixelSize:8];
    XCTAssertNotNil(thumbnail);
    // 40x20 等比缩放到最大边 8，宽应为 8、高为 4
    XCTAssertLessThanOrEqual(thumbnail.size.width, 8.0);
    XCTAssertLessThanOrEqual(thumbnail.size.height, 8.0);
}

- (void)testPasteboardRepresentationsAreDecodable
{
    NSData *data = PastePalTestPNGData(6, 6, 0.5, 0.5, 0.5);
    NSError *error = nil;
    NSString *file = [imageStore saveData:data
                                     hash:[PastePalImageStore sha256HexForData:data]
                                      uti:@"public.png"
                                    error:&error];
    FlycutClipping *clipping = [self clippingForData:data file:file];

    NSDictionary *representations = [imageStore pasteboardRepresentationsForClipping:clipping];
    XCTAssertNotNil(representations);
    // 原 PNG 数据应直接复用，TIFF 必须能从原图生成
    XCTAssertEqualObjects([representations objectForKey:@"public.png"], data);
    XCTAssertNotNil([representations objectForKey:@"public.tiff"]);

    for (NSString *uti in representations) {
        NSData *encoded = [representations objectForKey:uti];
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)encoded, NULL);
        XCTAssertTrue(source != NULL, @"Format %@ should decode", uti);
        if (source != NULL) {
            CFRelease(source);
        }
    }
}

- (void)testSweepDeletesOnlyUnreferencedImageFiles
{
    NSData *keptData = PastePalTestPNGData(5, 5, 1.0, 0.0, 0.0);
    NSData *orphanData = PastePalTestPNGData(5, 5, 0.0, 0.0, 1.0);
    NSString *keptFile = [imageStore saveData:keptData
                                         hash:[PastePalImageStore sha256HexForData:keptData]
                                          uti:@"public.png"
                                        error:NULL];
    NSString *orphanFile = [imageStore saveData:orphanData
                                           hash:[PastePalImageStore sha256HexForData:orphanData]
                                            uti:@"public.png"
                                          error:NULL];
    XCTAssertNotNil(keptFile);
    XCTAssertNotNil(orphanFile);

    // 目录中的非 hash 文件与隐藏文件不属于清扫范围
    NSString *notesPath = [tempDirectory stringByAppendingPathComponent:@"notes.txt"];
    NSString *hiddenPath = [tempDirectory stringByAppendingPathComponent:@".DS_Store"];
    [[@"keep me" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:notesPath atomically:YES];
    [[NSData data] writeToFile:hiddenPath atomically:YES];

    NSString *keptHash = [PastePalImageStore sha256HexForData:keptData];
    [imageStore deleteUnreferencedFilesKeepingHashes:[NSSet setWithObject:keptHash] olderThan:0];

    XCTAssertTrue([imageStore fileExistsForImageFile:keptFile]);
    XCTAssertFalse([imageStore fileExistsForImageFile:orphanFile]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:notesPath]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:hiddenPath]);
}

@end
