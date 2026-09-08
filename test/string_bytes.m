#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@interface NSString (LC32PrivateByteConstruction)
+ (instancetype)stringWithBytes:(const void *)bytes
                         length:(NSUInteger)length
                       encoding:(NSStringEncoding)encoding;
@end

#define LC32_STRING_CHUNK "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
#define LC32_STRING_REPEAT_2(text) text text
#define LC32_STRING_REPEAT_8(text) \
    LC32_STRING_REPEAT_2(LC32_STRING_REPEAT_2(LC32_STRING_REPEAT_2(text)))
#define LC32_STRING_REPEAT_128(text) \
    LC32_STRING_REPEAT_2(LC32_STRING_REPEAT_8(LC32_STRING_REPEAT_8(text)))

/* Force a compiler-emitted UTF-16 CFString spanning multiple guest pages.
 * Its stored length counts UTF-16 units, not bytes. Include an embedded NUL
 * so bridging cannot accidentally rely on C-string termination either. */
static NSString *const longUnicodeLiteral =
    @"\u03b1" LC32_STRING_REPEAT_128(LC32_STRING_CHUNK) "\0\u03c9";

static BOOL testLongUnicodeLiteral(void) {
    const NSUInteger payloadLength = 128 * 36;
    const NSUInteger expectedLength = payloadLength + 3;
    unichar *characters = calloc(expectedLength, sizeof(*characters));
    if(!characters) return NO;
    [longUnicodeLiteral getCharacters:characters
        range:NSMakeRange(0, expectedLength)];
    BOOL passed = [longUnicodeLiteral length] == expectedLength &&
        characters[0] == 0x03b1 &&
        characters[payloadLength + 1] == 0 &&
        characters[payloadLength + 2] == 0x03c9;
    for(NSUInteger index = 0; index < payloadLength; ++index) {
        if(characters[index + 1] != LC32_STRING_CHUNK[index % 36])
            passed = NO;
    }
    free(characters);
    if(!passed) return NO;

    NSData *data = [longUnicodeLiteral dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *bytes = [data bytes];
    passed = passed && [data length] == payloadLength + 5 && bytes &&
        bytes[0] == 0xce && bytes[1] == 0xb1 &&
        bytes[payloadLength + 2] == 0 &&
        bytes[payloadLength + 3] == 0xcf &&
        bytes[payloadLength + 4] == 0x89;
    return passed;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    const unsigned char embeddedNUL[] = {'A', 0, 'B'};
    NSString *utf8 = [[NSString alloc]
        initWithBytes:embeddedNUL
               length:sizeof(embeddedNUL)
             encoding:NSUTF8StringEncoding];
    BOOL utf8Passed = utf8 && utf8.length == 3 &&
        [utf8 characterAtIndex:0] == 'A' &&
        [utf8 characterAtIndex:1] == 0 &&
        [utf8 characterAtIndex:2] == 'B';
    printf("string-bytes-embedded-nul: %s\n",
           utf8Passed ? "PASS" : "FAIL");
    [utf8 release];

    const unsigned char latin1Bytes[] = {0x41, 0xe9};
    NSString *latin1 = [NSString stringWithBytes:latin1Bytes
                                          length:sizeof(latin1Bytes)
                                        encoding:NSISOLatin1StringEncoding];
    BOOL latin1Passed = latin1 && latin1.length == 2 &&
        [latin1 characterAtIndex:0] == 'A' &&
        [latin1 characterAtIndex:1] == 0x00e9;
    printf("string-bytes-latin1: %s\n",
           latin1Passed ? "PASS" : "FAIL");

    unichar characters[2] = {};
    [latin1 getCharacters:characters range:NSMakeRange(0, 2)];
    BOOL charactersPassed = characters[0] == 'A' &&
        characters[1] == 0x00e9;
    printf("string-get-characters-range: %s\n",
           charactersPassed ? "PASS" : "FAIL");

    unichar allCharacters[2] = {};
    [latin1 getCharacters:allCharacters];
    BOOL allCharactersPassed = allCharacters[0] == 'A' &&
        allCharacters[1] == 0x00e9;
    printf("string-get-characters-all: %s\n",
           allCharactersPassed ? "PASS" : "FAIL");

    const char *utf32 = [@"1.9.11"
        cStringUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const unsigned char expectedUTF32[] = {
        '1', 0, 0, 0, '.', 0, 0, 0, '9', 0, 0, 0, '.', 0, 0, 0,
        '1', 0, 0, 0, '1', 0, 0, 0, 0, 0, 0, 0,
    };
    BOOL utf32Passed = utf32 &&
        memcmp(utf32, expectedUTF32, sizeof(expectedUTF32)) == 0;
    printf("string-cstring-utf32-terminator: %s\n",
           utf32Passed ? "PASS" : "FAIL");

    const char *emptyUTF32 = [@""
        cStringUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const uint32_t emptyUTF32Value = emptyUTF32
        ? *(const uint32_t *)emptyUTF32 : UINT32_MAX;
    BOOL emptyUTF32Passed = emptyUTF32 && emptyUTF32Value == 0;
    printf("string-cstring-empty-utf32-terminator: %s\n",
           emptyUTF32Passed ? "PASS" : "FAIL");

    char *ownedBytes = malloc(6);
    memcpy(ownedBytes, "owned", 6);
    NSString *owned = [[NSString alloc]
        initWithBytesNoCopy:ownedBytes
                     length:5
                   encoding:NSUTF8StringEncoding
               freeWhenDone:YES];
    BOOL noCopyPassed = [owned isEqualToString:@"owned"];
    printf("string-bytes-no-copy-owned: %s\n",
           noCopyPassed ? "PASS" : "FAIL");
    [owned release];

    const BOOL longUnicodePassed = testLongUnicodeLiteral();
    printf("string-literal-multipage-utf16: %s\n",
        longUnicodePassed ? "PASS" : "FAIL");

    [pool drain];
    return !(utf8Passed && latin1Passed && charactersPassed &&
             allCharactersPassed && utf32Passed && emptyUTF32Passed &&
             noCopyPassed && longUnicodePassed);
}
