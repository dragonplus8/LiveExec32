#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <cmath>
#include <cstring>
#include <mach-o/loader.h>
#include <stdint.h>

struct LC32FontDyldBuildVersion {
    uint32_t platform;
    uint32_t version;
};
extern "C" bool dyld_program_sdk_at_least(LC32FontDyldBuildVersion version);

static thread_local bool LC32RepairingLegacyFont;
using LC32FontRetry = id (^)(UITraitCollection *);

static bool LC32FiniteFont(UIFont *font) {
    return font && std::isfinite(font.pointSize) && std::isfinite(font.ascender) &&
        std::isfinite(font.descender) && std::isfinite(font.lineHeight);
}

/* Only used on an already-invalid preferred font. Keep valid authored traits,
 * features, variations and transforms, not NaN values nested inside them. */
static id LC32FiniteFontAttribute(id value) {
    if([value isKindOfClass:NSNumber.class])
        return std::isfinite([value doubleValue]) ? value : nil;
    if([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for(id key in value) {
            id child = LC32FiniteFontAttribute(value[key]);
            if(child) result[key] = child;
        }
        return result;
    }
    if([value isKindOfClass:NSArray.class]) {
        NSMutableArray *result = [NSMutableArray array];
        for(id child in value) {
            id finite = LC32FiniteFontAttribute(child);
            if(finite) [result addObject:finite];
        }
        return result;
    }
    if([value isKindOfClass:NSValue.class] &&
       !strcmp([value objCType], @encode(CGAffineTransform))) {
        CGAffineTransform matrix = [value CGAffineTransformValue];
        if(!std::isfinite(matrix.a) || !std::isfinite(matrix.b) ||
           !std::isfinite(matrix.c) || !std::isfinite(matrix.d) ||
           !std::isfinite(matrix.tx) || !std::isfinite(matrix.ty)) return nil;
    }
    return value;
}

static UITraitCollection *LC32LargestFiniteFontTraits(UITraitCollection *traits) {
    /* The pre-iOS-11 CoreText override has missing accessibility-size records.
     * Do not invent modern AX sizes or scale from an unrelated Body font: only
     * when the original size is nonfinite, clamp to the last normal category.
     * This deliberately sacrifices further AX enlargement for a usable font.
     * Retain the caller's other traits, including legibility and interface idiom. */
    return [UITraitCollection traitCollectionWithTraitsFromCollections:@[
        traits ?: UITraitCollection.currentTraitCollection,
        [UITraitCollection traitCollectionWithPreferredContentSizeCategory:
            UIContentSizeCategoryExtraExtraExtraLarge]]];
}

static id LC32RepairPreferredFont(id original, bool descriptorResult,
                                 UITraitCollection *traits, LC32FontRetry retry) {
    if(!original || LC32RepairingLegacyFont) return original;
    struct RepairScope {
        RepairScope() { LC32RepairingLegacyFont = true; }
        ~RepairScope() { LC32RepairingLegacyFont = false; }
    } scope;

    UIFontDescriptor *descriptor = descriptorResult ? original : [original fontDescriptor];
    UIFont *font = descriptorResult ? [UIFont fontWithDescriptor:descriptor size:0] : original;
    CGFloat size = descriptorResult ? descriptor.pointSize : font.pointSize;
    if(std::isfinite(size) && LC32FiniteFont(font)) return original;

    UIFont *resolvedFont = font;
    if(!std::isfinite(size)) {
        id fallback = retry(LC32LargestFiniteFontTraits(traits));
        UIFontDescriptor *fallbackDescriptor = descriptorResult ? fallback : [fallback fontDescriptor];
        resolvedFont = descriptorResult ? [UIFont fontWithDescriptor:fallbackDescriptor size:0] : fallback;
        size = descriptorResult ? fallbackDescriptor.pointSize : resolvedFont.pointSize;
    }
    if(!resolvedFont || !std::isfinite(size) || size <= 0 || !resolvedFont.fontName.length)
        return original;

    NSMutableDictionary *attributes = [LC32FiniteFontAttribute(
        resolvedFont.fontDescriptor.fontAttributes) mutableCopy];
    [attributes addEntriesFromDictionary:LC32FiniteFontAttribute(descriptor.fontAttributes)];

    /* Merely fixing a CTFont's language-aware ratio is insufficient: UIFont's
     * fontDescriptor can drop that override while retaining text-style usage,
     * causing a subsequent fontWithDescriptor: to recompute the same NaNs.
     * Resolve to the actual native face and size instead. These private key
     * spellings are descriptor metadata, not OS-specific offsets or symbols.
     * UIFontDescriptorTextStyleAttribute also names NSCTFontUIUsageAttribute
     * on current UIKit; removing both is harmless on other SDKs. */
    [attributes removeObjectsForKeys:@[
        UIFontDescriptorTextStyleAttribute, @"NSCTFontUIUsageAttribute",
        @"NSCTFontSizeCategoryAttribute", @"CTFontLanguageAwareLineHeightRatioAttribute",
        @"CTFontLineSpacingOverrideAttribute"]];
    attributes[UIFontDescriptorNameAttribute] = resolvedFont.fontName;
    attributes[UIFontDescriptorSizeAttribute] = @(size);
    UIFontDescriptor *concrete = [UIFontDescriptor fontDescriptorWithFontAttributes:attributes];
    UIFont *repaired = [UIFont fontWithDescriptor:concrete size:size];
    if(!LC32FiniteFont(repaired)) return original;
    return descriptorResult ? concrete : repaired;
}

/* Private methods are optional and can change ABI. Inspect each argument's
 * actual encoding, ignoring stack offsets and quoted Objective-C class names.
 * The captured original IMP always receives its real selector, never an alias. */
static Method LC32FontClassMethod(Class cls, const char *name, const char *arguments) {
    Method method = class_getClassMethod(cls, sel_registerName(name));
    if(!method || method_getNumberOfArguments(method) != strlen(arguments) + 2) return nullptr;
    char type[32];
    method_getReturnType(method, type, sizeof(type));
    if(type[0] != '@') return nullptr;
    for(unsigned index = 0; arguments[index]; ++index) {
        method_getArgumentType(method, index + 2, type, sizeof(type));
        if(type[0] != arguments[index]) return nullptr;
    }
    return method;
}

static void LC32ReplaceFontClassMethod(Class cls, Method method, id block) {
    class_replaceMethod(object_getClass(cls), method_getName(method),
        imp_implementationWithBlock(block), method_getTypeEncoding(method));
}

static void LC32HookPreferredFontPair(Class cls, bool descriptor) {
    const char *oneName = descriptor ? "preferredFontDescriptorWithTextStyle:" : "preferredFontForTextStyle:";
    const char *twoName = descriptor ? "preferredFontDescriptorWithTextStyle:compatibleWithTraitCollection:" :
        "preferredFontForTextStyle:compatibleWithTraitCollection:";
    Method one = LC32FontClassMethod(cls, oneName, "@");
    Method two = LC32FontClassMethod(cls, twoName, "@@");
    if(!two) return;
    SEL twoSelector = method_getName(two);
    auto twoOriginal = (id (*)(id, SEL, NSString *, UITraitCollection *))method_getImplementation(two);
    LC32ReplaceFontClassMethod(cls, two, ^id(id self, NSString *style, UITraitCollection *traits) {
        id result = twoOriginal(self, twoSelector, style, traits);
        return LC32RepairPreferredFont(result, descriptor, traits, ^id(UITraitCollection *fallback) {
            return twoOriginal(self, twoSelector, style, fallback);
        });
    });
    if(one) {
        SEL selector = method_getName(one);
        auto original = (id (*)(id, SEL, NSString *))method_getImplementation(one);
        LC32ReplaceFontClassMethod(cls, one, ^id(id self, NSString *style) {
            id result = original(self, selector, style);
            return LC32RepairPreferredFont(result, descriptor, nil, ^id(UITraitCollection *fallback) {
                // The one-argument spelling has no place to pass the category.
                return twoOriginal(self, twoSelector, style, fallback);
            });
        });
    }
}

static void LC32HookPreferredDescriptorTraits(void) {
    Class cls = UIFontDescriptor.class;
    Method method = LC32FontClassMethod(cls,
        "_preferredFontDescriptorWithTextStyle:addingSymbolicTraits:compatibleWithTraitCollection:", "@I@");
    if(!method) return;
    SEL selector = method_getName(method);
    auto original = (id (*)(id, SEL, NSString *, uint32_t, UITraitCollection *))method_getImplementation(method);
    LC32ReplaceFontClassMethod(cls, method, ^id(id self, NSString *style, uint32_t symbolic, UITraitCollection *traits) {
        id result = original(self, selector, style, symbolic, traits);
        return LC32RepairPreferredFont(result, true, traits, ^id(UITraitCollection *fallback) {
            return original(self, selector, style, symbolic, fallback);
        });
    });
}

static void LC32HookPreferredDescriptorOptions(void) {
    Class cls = UIFontDescriptor.class;
    Method method = LC32FontClassMethod(cls,
        "preferredFontDescriptorWithTextStyle:addingSymbolicTraits:options:", "@IQ");
    if(!method) return;
    SEL selector = method_getName(method);
    auto original = (id (*)(id, SEL, NSString *, uint32_t, NSUInteger))method_getImplementation(method);
    LC32ReplaceFontClassMethod(cls, method,
        ^id(id self, NSString *style, uint32_t symbolic, NSUInteger options) {
        /* Native alert text fields and action-sheet titles use this factory,
         * which calls CoreText directly rather than the trait-taking methods.
         * Keep its category policy and symbolic traits, repairing only an
         * invalid result. For a missing AX point size, option bit 0 caps the
         * legacy category at XXXL; preserve all other option bits. */
        id result = original(self, selector, style, symbolic, options);
        return LC32RepairPreferredFont(result, true, nil, ^id(UITraitCollection *) {
            return original(self, selector, style, symbolic, options | 1u);
        });
    });
}

static void LC32HookPreferredDescriptorDesign(void) {
    Class cls = UIFontDescriptor.class;
    Method method = LC32FontClassMethod(cls,
        "_preferredFontDescriptorWithTextStyle:design:weight:compatibleWithTraitCollection:", "@@d@");
    if(method) {
        SEL selector = method_getName(method);
        auto original = (id (*)(id, SEL, NSString *, NSString *, CGFloat, UITraitCollection *))method_getImplementation(method);
        LC32ReplaceFontClassMethod(cls, method, ^id(id self, NSString *style, NSString *design, CGFloat weight, UITraitCollection *traits) {
            id result = original(self, selector, style, design, weight, traits);
            return LC32RepairPreferredFont(result, true, traits, ^id(UITraitCollection *fallback) {
                return original(self, selector, style, design, weight, fallback);
            });
        });
    }
    method = LC32FontClassMethod(cls,
        "_preferredFontDescriptorWithTextStyle:addingSymbolicTraits:design:weight:compatibleWithTraitCollection:", "@I@d@");
    if(method) {
        SEL selector = method_getName(method);
        auto original = (id (*)(id, SEL, NSString *, uint32_t, NSString *, CGFloat, UITraitCollection *))method_getImplementation(method);
        LC32ReplaceFontClassMethod(cls, method, ^id(id self, NSString *style, uint32_t symbolic, NSString *design, CGFloat weight, UITraitCollection *traits) {
            id result = original(self, selector, style, symbolic, design, weight, traits);
            return LC32RepairPreferredFont(result, true, traits, ^id(UITraitCollection *fallback) {
                return original(self, selector, style, symbolic, design, weight, fallback);
            });
        });
    }
}

static void LC32HookPreferredFontVariants(void) {
    Class cls = UIFont.class;
    Method method = LC32FontClassMethod(cls,
        "_preferredFontForTextStyle:design:weight:symbolicTraits:maximumContentSizeCategory:compatibleWithTraitCollection:pointSize:pointSizeForScaling:",
        "@@@I@@dd");
    if(method) {
        SEL selector = method_getName(method);
        auto original = (id (*)(id, SEL, NSString *, NSString *, NSNumber *, uint32_t,
            NSString *, UITraitCollection *, CGFloat, CGFloat))method_getImplementation(method);
        LC32ReplaceFontClassMethod(cls, method, ^id(id self, NSString *style, NSString *design,
            NSNumber *weight, uint32_t symbolic, NSString *maximum, UITraitCollection *traits,
            CGFloat size, CGFloat scalingSize) {
            id result = original(self, selector, style, design, weight, symbolic, maximum, traits, size, scalingSize);
            return LC32RepairPreferredFont(result, false, traits, ^id(UITraitCollection *fallback) {
                return original(self, selector, style, design, weight, symbolic, maximum, fallback, size, scalingSize);
            });
        });
    }
    method = LC32FontClassMethod(cls,
        "_preferredFontForTextStyle:maximumContentSizeCategory:compatibleWithTraitCollection:", "@@@");
    if(method) {
        SEL selector = method_getName(method);
        auto original = (id (*)(id, SEL, NSString *, NSString *, UITraitCollection *))method_getImplementation(method);
        LC32ReplaceFontClassMethod(cls, method, ^id(id self, NSString *style, NSString *maximum, UITraitCollection *traits) {
            id result = original(self, selector, style, maximum, traits);
            return LC32RepairPreferredFont(result, false, traits, ^id(UITraitCollection *fallback) {
                return original(self, selector, style, maximum, fallback);
            });
        });
    }
}

@interface LC32LegacyFonts : NSObject
@end

@implementation LC32LegacyFonts
+ (void)load {
    if(dyld_program_sdk_at_least({PLATFORM_IOS, 0x000b0000})) return;

    /* Modern CoreText's pre-iOS-11 text-style table can produce nonfinite line
     * metrics (language dependent) and nonfinite accessibility point sizes.
     * Native UIKit uses these fonts too, so repairing only guest UIFont calls
     * misses alerts and other system controls. Hook creation, not metric getters:
     * the returned UIFont and its descriptor must both be usable by CoreText.
     * Valid fonts remain untouched, and no process SDK or font table is changed.
     * This safety fix is independent of the optional LC32 geometry adapters. */
    LC32HookPreferredFontPair(UIFont.class, false);
    LC32HookPreferredFontPair(UIFontDescriptor.class, true);
    LC32HookPreferredDescriptorTraits();
    LC32HookPreferredDescriptorOptions();
    LC32HookPreferredDescriptorDesign();
    LC32HookPreferredFontVariants();
}
@end
