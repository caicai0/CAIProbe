//
//  CAIP_Aspects.h
//  CAIP_Aspects - A delightful, simple library for CAIP_Aspect oriented programming.
//
//  Copyright (c) 2014 Peter Steinberger. Licensed under the MIT license.
//

#import <Foundation/Foundation.h>

typedef NS_OPTIONS(NSUInteger, CAIP_AspectOptions) {
    CAIP_AspectPositionAfter   = 0,            /// Called after the original implementation (default)
    CAIP_AspectPositionInstead = 1,            /// Will replace the original implementation.
    CAIP_AspectPositionBefore  = 2,            /// Called before the original implementation.
    
    CAIP_AspectOptionAutomaticRemoval = 1 << 3 /// Will remove the hook after the first execution.
};

/// Opaque CAIP_Aspect Token that allows to deregister the hook.
@protocol CAIP_AspectToken <NSObject>

/// Deregisters an CAIP_Aspect.
/// @return YES if deregistration is successful, otherwise NO.
- (BOOL)remove;

@end

/// The CAIP_AspectInfo protocol is the first parameter of our block syntax.
@protocol CAIP_AspectInfo <NSObject>

/// The instance that is currently hooked.
- (id)instance;

/// The original invocation of the hooked method.
- (NSInvocation *)originalInvocation;

/// All method arguments, boxed. This is lazily evaluated.
- (NSArray *)arguments;

@end

/**
 CAIP_Aspects uses Objective-C message forwarding to hook into messages. This will create some overhead. Don't add CAIP_Aspects to methods that are called a lot. CAIP_Aspects is meant for view/controller code that is not called a 1000 times per second.

 Adding CAIP_Aspects returns an opaque token which can be used to deregister again. All calls are thread safe.
 */
@interface NSObject (CAIP_Aspects)

/// Adds a block of code before/instead/after the current `selector` for a specific class.
///
/// @param block CAIP_Aspects replicates the type signature of the method being hooked.
/// The first parameter will be `id<CAIP_AspectInfo>`, followed by all parameters of the method.
/// These parameters are optional and will be filled to match the block signature.
/// You can even use an empty block, or one that simple gets `id<CAIP_AspectInfo>`.
///
/// @note Hooking static methods is not supported.
/// @return A token which allows to later deregister the CAIP_Aspect.
+ (id<CAIP_AspectToken>)CAIP_Aspect_hookSelector:(SEL)selector
                           withOptions:(CAIP_AspectOptions)options
                            usingBlock:(id)block
                                 error:(NSError **)error;

/// Adds a block of code before/instead/after the current `selector` for a specific instance.
- (id<CAIP_AspectToken>)CAIP_Aspect_hookSelector:(SEL)selector
                           withOptions:(CAIP_AspectOptions)options
                            usingBlock:(id)block
                                 error:(NSError **)error;

@end


typedef NS_ENUM(NSUInteger, CAIP_AspectErrorCode) {
    CAIP_AspectErrorSelectorBlacklisted,                   /// Selectors like release, retain, autorelease are blacklisted.
    CAIP_AspectErrorDoesNotRespondToSelector,              /// Selector could not be found.
    CAIP_AspectErrorSelectorDeallocPosition,               /// When hooking dealloc, only CAIP_AspectPositionBefore is allowed.
    CAIP_AspectErrorSelectorAlreadyHookedInClassHierarchy, /// Statically hooking the same method in subclasses is not allowed.
    CAIP_AspectErrorFailedToAllocateClassPair,             /// The runtime failed creating a class pair.
    CAIP_AspectErrorMissingBlockSignature,                 /// The block misses compile time signature info and can't be called.
    CAIP_AspectErrorIncompatibleBlockSignature,            /// The block signature does not match the method or is too large.

    CAIP_AspectErrorRemoveObjectAlreadyDeallocated = 100   /// (for removing) The object hooked is already deallocated.
};

extern NSString *const CAIP_AspectErrorDomain;
