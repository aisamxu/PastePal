//
//  PastePalTests.m
//  PastePalTests
//
//  基础回归测试：先锁定文本剪贴条目的显示与相等行为，
//  后续图片剪贴功能会在同一 target 中继续补充测试。
//

#import <XCTest/XCTest.h>
#import "FlycutEngine/FlycutClipping.h"

@interface PastePalTests : XCTestCase
@end

@implementation PastePalTests

- (FlycutClipping *)clippingWithContents:(NSString *)contents
{
    // 引擎代码使用 MRC，测试 target 同样关闭 ARC，返回前交给自动释放池
    return [[[FlycutClipping alloc] initWithContents:contents
                                            withType:@"NSStringPboardType"
                                   withDisplayLength:40
                                withAppLocalizedName:@"Finder"
                                    withAppBundleURL:@"/System/Library/CoreServices/Finder.app"
                                       withTimestamp:0] autorelease];
}

- (void)testDisplayStringUsesFirstLine
{
    FlycutClipping *clipping = [self clippingWithContents:@"first line\nsecond line"];
    XCTAssertEqualObjects([clipping displayString], @"first line");
}

- (void)testDisplayStringTruncatesLongLine
{
    FlycutClipping *clipping = [self clippingWithContents:@"0123456789012345678901234567890123456789ABC"];
    XCTAssertEqualObjects([clipping displayString], @"0123456789012345678901234567890123456789…");
}

- (void)testClippingsWithSameContentsAreEqual
{
    FlycutClipping *first = [self clippingWithContents:@"same content"];
    FlycutClipping *second = [self clippingWithContents:@"same content"];
    FlycutClipping *different = [self clippingWithContents:@"other content"];

    XCTAssertEqualObjects(first, second);
    XCTAssertNotEqualObjects(first, different);
}

- (void)testMetadataIsRetained
{
    FlycutClipping *clipping = [self clippingWithContents:@"metadata"];
    XCTAssertEqualObjects([clipping type], @"NSStringPboardType");
    XCTAssertEqualObjects([clipping appLocalizedName], @"Finder");
    XCTAssertEqualObjects([clipping appBundleURL], @"/System/Library/CoreServices/Finder.app");
}

@end
