//
//  CAIP_Aspects.m
//  CAIP_Aspects - A delightful, simple library for CAIP_Aspect oriented programming.
//
//  Copyright (c) 2014 Peter Steinberger. Licensed under the MIT license.
//

#import "CAIP_Aspects.h"
#import <libkern/OSAtomic.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define CAIP_AspectLog(...)
//#define CAIP_AspectLog(...) do { NSLog(__VA_ARGS__); }while(0)
#define CAIP_AspectLogError(...) do { NSLog(__VA_ARGS__); }while(0)

// Block internals.
typedef NS_OPTIONS(int, CAIP_AspectBlockFlags) {
	CAIP_AspectBlockFlagsHasCopyDisposeHelpers = (1 << 25),
	CAIP_AspectBlockFlagsHasSignature          = (1 << 30)
};
typedef struct _CAIP_AspectBlock {
	__unused Class isa;
	CAIP_AspectBlockFlags flags;
	__unused int reserved;
	void (__unused *invoke)(struct _CAIP_AspectBlock *block, ...);
	struct {
		unsigned long int reserved;
		unsigned long int size;
		// requires CAIP_AspectBlockFlagsHasCopyDisposeHelpers
		void (*copy)(void *dst, const void *src);
		void (*dispose)(const void *);
		// requires CAIP_AspectBlockFlagsHasSignature
		const char *signature;
		const char *layout;
	} *descriptor;
	// imported variables
} *CAIP_AspectBlockRef;

@interface CAIP_AspectInfo : NSObject <CAIP_AspectInfo>
- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation;
@property (nonatomic, unsafe_unretained, readonly) id instance;
@property (nonatomic, strong, readonly) NSArray *arguments;
@property (nonatomic, strong, readonly) NSInvocation *originalInvocation;
@end

// Tracks a single CAIP_Aspect.
@interface CAIP_AspectIdentifier : NSObject
+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(CAIP_AspectOptions)options block:(id)block error:(NSError **)error;
- (BOOL)invokeWithInfo:(id<CAIP_AspectInfo>)info;
@property (nonatomic, assign) SEL selector;
@property (nonatomic, strong) id block;
@property (nonatomic, strong) NSMethodSignature *blockSignature;
@property (nonatomic, weak) id object;
@property (nonatomic, assign) CAIP_AspectOptions options;
@end

// Tracks all CAIP_Aspects for an object/class.
@interface CAIP_AspectsContainer : NSObject
- (void)addCAIP_Aspect:(CAIP_AspectIdentifier *)CAIP_Aspect withOptions:(CAIP_AspectOptions)injectPosition;
- (BOOL)removeCAIP_Aspect:(id)CAIP_Aspect;
- (BOOL)hasCAIP_Aspects;
@property (atomic, copy) NSArray *beforeCAIP_Aspects;
@property (atomic, copy) NSArray *insteadCAIP_Aspects;
@property (atomic, copy) NSArray *afterCAIP_Aspects;
@end

@interface CAIP_AspectTracker : NSObject
- (id)initWithTrackedClass:(Class)trackedClass;
@property (nonatomic, strong) Class trackedClass;
@property (nonatomic, readonly) NSString *trackedClassName;
@property (nonatomic, strong) NSMutableSet *selectorNames;
@property (nonatomic, strong) NSMutableDictionary *selectorNamesToSubclassTrackers;
- (void)addSubclassTracker:(CAIP_AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
- (void)removeSubclassTracker:(CAIP_AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
- (BOOL)subclassHasHookedSelectorName:(NSString *)selectorName;
- (NSSet *)subclassTrackersHookingSelectorName:(NSString *)selectorName;
@end

@interface NSInvocation (CAIP_Aspects)
- (NSArray *)CAIP_Aspects_arguments;
@end

#define CAIP_AspectPositionFilter 0x07

#define CAIP_AspectError(errorCode, errorDescription) do { \
CAIP_AspectLogError(@"CAIP_Aspects: %@", errorDescription); \
if (error) { *error = [NSError errorWithDomain:CAIP_AspectErrorDomain code:errorCode userInfo:@{NSLocalizedDescriptionKey: errorDescription}]; }}while(0)

NSString *const CAIP_AspectErrorDomain = @"CAIP_AspectErrorDomain";
static NSString *const CAIP_AspectsSubclassSuffix = @"_CAIP_Aspects_";
static NSString *const CAIP_AspectsMessagePrefix = @"CAIP_Aspects_";

@implementation NSObject (CAIP_Aspects)

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public CAIP_Aspects API

+ (id<CAIP_AspectToken>)CAIP_Aspect_hookSelector:(SEL)selector
                      withOptions:(CAIP_AspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return CAIP_Aspect_add((id)self, selector, options, block, error);
}

/// @return A token which allows to later deregister the CAIP_Aspect.
- (id<CAIP_AspectToken>)CAIP_Aspect_hookSelector:(SEL)selector
                      withOptions:(CAIP_AspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return CAIP_Aspect_add(self, selector, options, block, error);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Private Helper

static id CAIP_Aspect_add(id self, SEL selector, CAIP_AspectOptions options, id block, NSError **error) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);
    NSCParameterAssert(block);

    __block CAIP_AspectIdentifier *identifier = nil;
    CAIP_Aspect_performLocked(^{
        if (CAIP_Aspect_isSelectorAllowedAndTrack(self, selector, options, error)) {
            CAIP_AspectsContainer *CAIP_AspectContainer = CAIP_Aspect_getContainerForObject(self, selector);
            identifier = [CAIP_AspectIdentifier identifierWithSelector:selector object:self options:options block:block error:error];
            if (identifier) {
                [CAIP_AspectContainer addCAIP_Aspect:identifier withOptions:options];

                // Modify the class to allow message interception.
                CAIP_Aspect_prepareClassAndHookSelector(self, selector, error);
            }
        }
    });
    return identifier;
}

static BOOL CAIP_Aspect_remove(CAIP_AspectIdentifier *CAIP_Aspect, NSError **error) {
    NSCAssert([CAIP_Aspect isKindOfClass:CAIP_AspectIdentifier.class], @"Must have correct type.");

    __block BOOL success = NO;
    CAIP_Aspect_performLocked(^{
        id self = CAIP_Aspect.object; // strongify
        if (self) {
            CAIP_AspectsContainer *CAIP_AspectContainer = CAIP_Aspect_getContainerForObject(self, CAIP_Aspect.selector);
            success = [CAIP_AspectContainer removeCAIP_Aspect:CAIP_Aspect];

            CAIP_Aspect_cleanupHookedClassAndSelector(self, CAIP_Aspect.selector);
            // destroy token
            CAIP_Aspect.object = nil;
            CAIP_Aspect.block = nil;
            CAIP_Aspect.selector = NULL;
        }else {
            NSString *errrorDesc = [NSString stringWithFormat:@"Unable to deregister hook. Object already deallocated: %@", CAIP_Aspect];
            CAIP_AspectError(CAIP_AspectErrorRemoveObjectAlreadyDeallocated, errrorDesc);
        }
    });
    return success;
}

static void CAIP_Aspect_performLocked(dispatch_block_t block) {
    static OSSpinLock CAIP_Aspect_lock = OS_SPINLOCK_INIT;
    OSSpinLockLock(&CAIP_Aspect_lock);
    block();
    OSSpinLockUnlock(&CAIP_Aspect_lock);
}

static SEL CAIP_Aspect_aliasForSelector(SEL selector) {
    NSCParameterAssert(selector);
	return NSSelectorFromString([CAIP_AspectsMessagePrefix stringByAppendingFormat:@"_%@", NSStringFromSelector(selector)]);
}

static NSMethodSignature *CAIP_Aspect_blockMethodSignature(id block, NSError **error) {
    CAIP_AspectBlockRef layout = (__bridge void *)block;
	if (!(layout->flags & CAIP_AspectBlockFlagsHasSignature)) {
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't contain a type signature.", block];
        CAIP_AspectError(CAIP_AspectErrorMissingBlockSignature, description);
        return nil;
    }
	void *desc = layout->descriptor;
	desc += 2 * sizeof(unsigned long int);
	if (layout->flags & CAIP_AspectBlockFlagsHasCopyDisposeHelpers) {
		desc += 2 * sizeof(void *);
    }
	if (!desc) {
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't has a type signature.", block];
        CAIP_AspectError(CAIP_AspectErrorMissingBlockSignature, description);
        return nil;
    }
	const char *signature = (*(const char **)desc);
	return [NSMethodSignature signatureWithObjCTypes:signature];
}

static BOOL CAIP_Aspect_isCompatibleBlockSignature(NSMethodSignature *blockSignature, id object, SEL selector, NSError **error) {
    NSCParameterAssert(blockSignature);
    NSCParameterAssert(object);
    NSCParameterAssert(selector);

    BOOL signaturesMatch = YES;
    NSMethodSignature *methodSignature = [[object class] instanceMethodSignatureForSelector:selector];
    if (blockSignature.numberOfArguments > methodSignature.numberOfArguments) {
        signaturesMatch = NO;
    }else {
        if (blockSignature.numberOfArguments > 1) {
            const char *blockType = [blockSignature getArgumentTypeAtIndex:1];
            if (blockType[0] != '@') {
                signaturesMatch = NO;
            }
        }
        // Argument 0 is self/block, argument 1 is SEL or id<CAIP_AspectInfo>. We start comparing at argument 2.
        // The block can have less arguments than the method, that's ok.
        if (signaturesMatch) {
            for (NSUInteger idx = 2; idx < blockSignature.numberOfArguments; idx++) {
                const char *methodType = [methodSignature getArgumentTypeAtIndex:idx];
                const char *blockType = [blockSignature getArgumentTypeAtIndex:idx];
                // Only compare parameter, not the optional type data.
                if (!methodType || !blockType || methodType[0] != blockType[0]) {
                    signaturesMatch = NO; break;
                }
            }
        }
    }

    if (!signaturesMatch) {
        NSString *description = [NSString stringWithFormat:@"Block signature %@ doesn't match %@.", blockSignature, methodSignature];
        CAIP_AspectError(CAIP_AspectErrorIncompatibleBlockSignature, description);
        return NO;
    }
    return YES;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Class + Selector Preparation

static BOOL CAIP_Aspect_isMsgForwardIMP(IMP impl) {
    return impl == _objc_msgForward
#if !defined(__arm64__)
    || impl == (IMP)_objc_msgForward_stret
#endif
    ;
}

static IMP CAIP_Aspect_getMsgForwardIMP(NSObject *self, SEL selector) {
    IMP msgForwardIMP = _objc_msgForward;
#if !defined(__arm64__)
    // As an ugly internal runtime implementation detail in the 32bit runtime, we need to determine of the method we hook returns a struct or anything larger than id.
    // https://developer.apple.com/library/mac/documentation/DeveloperTools/Conceptual/LowLevelABI/000-Introduction/introduction.html
    // https://github.com/ReactiveCocoa/ReactiveCocoa/issues/783
    // http://infocenter.arm.com/help/topic/com.arm.doc.ihi0042e/IHI0042E_aapcs.pdf (Section 5.4)
    Method method = class_getInstanceMethod(self.class, selector);
    const char *encoding = method_getTypeEncoding(method);
    BOOL methodReturnsStructValue = encoding[0] == _C_STRUCT_B;
    if (methodReturnsStructValue) {
        @try {
            NSUInteger valueSize = 0;
            NSGetSizeAndAlignment(encoding, &valueSize, NULL);

            if (valueSize == 1 || valueSize == 2 || valueSize == 4 || valueSize == 8) {
                methodReturnsStructValue = NO;
            }
        } @catch (__unused NSException *e) {}
    }
    if (methodReturnsStructValue) {
        msgForwardIMP = (IMP)_objc_msgForward_stret;
    }
#endif
    return msgForwardIMP;
}

static void CAIP_Aspect_prepareClassAndHookSelector(NSObject *self, SEL selector, NSError **error) {
    NSCParameterAssert(selector);
    Class klass = CAIP_Aspect_hookClass(self, error);
    Method targetMethod = class_getInstanceMethod(klass, selector);
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    if (!CAIP_Aspect_isMsgForwardIMP(targetMethodIMP)) {
        // Make a method alias for the existing method implementation, it not already copied.
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        SEL aliasSelector = CAIP_Aspect_aliasForSelector(selector);
        if (![klass instancesRespondToSelector:aliasSelector]) {
            __unused BOOL addedAlias = class_addMethod(klass, aliasSelector, method_getImplementation(targetMethod), typeEncoding);
            NSCAssert(addedAlias, @"Original implementation for %@ is already copied to %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);
        }

        // We use forwardInvocation to hook in.
        class_replaceMethod(klass, selector, CAIP_Aspect_getMsgForwardIMP(self, selector), typeEncoding);
        CAIP_AspectLog(@"CAIP_Aspects: Installed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }
}

// Will undo the runtime changes made.
static void CAIP_Aspect_cleanupHookedClassAndSelector(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);

	Class klass = object_getClass(self);
    BOOL isMetaClass = class_isMetaClass(klass);
    if (isMetaClass) {
        klass = (Class)self;
    }

    // Check if the method is marked as forwarded and undo that.
    Method targetMethod = class_getInstanceMethod(klass, selector);
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    if (CAIP_Aspect_isMsgForwardIMP(targetMethodIMP)) {
        // Restore the original method implementation.
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        SEL aliasSelector = CAIP_Aspect_aliasForSelector(selector);
        Method originalMethod = class_getInstanceMethod(klass, aliasSelector);
        IMP originalIMP = method_getImplementation(originalMethod);
        NSCAssert(originalMethod, @"Original implementation for %@ not found %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);

        class_replaceMethod(klass, selector, originalIMP, typeEncoding);
        CAIP_AspectLog(@"CAIP_Aspects: Removed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }

    // Deregister global tracked selector
    CAIP_Aspect_deregisterTrackedSelector(self, selector);

    // Get the CAIP_Aspect container and check if there are any hooks remaining. Clean up if there are not.
    CAIP_AspectsContainer *container = CAIP_Aspect_getContainerForObject(self, selector);
    if (!container.hasCAIP_Aspects) {
        // Destroy the container
        CAIP_Aspect_destroyContainerForObject(self, selector);

        // Figure out how the class was modified to undo the changes.
        NSString *className = NSStringFromClass(klass);
        if ([className hasSuffix:CAIP_AspectsSubclassSuffix]) {
            Class originalClass = NSClassFromString([className stringByReplacingOccurrencesOfString:CAIP_AspectsSubclassSuffix withString:@""]);
            NSCAssert(originalClass != nil, @"Original class must exist");
            object_setClass(self, originalClass);
            CAIP_AspectLog(@"CAIP_Aspects: %@ has been restored.", NSStringFromClass(originalClass));

            // We can only dispose the class pair if we can ensure that no instances exist using our subclass.
            // Since we don't globally track this, we can't ensure this - but there's also not much overhead in keeping it around.
            //objc_disposeClassPair(object.class);
        }else {
            // Class is most likely swizzled in place. Undo that.
            if (isMetaClass) {
                CAIP_Aspect_undoSwizzleClassInPlace((Class)self);
            }else if (self.class != klass) {
            	CAIP_Aspect_undoSwizzleClassInPlace(klass);
            }
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Hook Class

static Class CAIP_Aspect_hookClass(NSObject *self, NSError **error) {
    NSCParameterAssert(self);
	Class statedClass = self.class;
	Class baseClass = object_getClass(self);
	NSString *className = NSStringFromClass(baseClass);

    // Already subclassed
	if ([className hasSuffix:CAIP_AspectsSubclassSuffix]) {
		return baseClass;

        // We swizzle a class object, not a single object.
	}else if (class_isMetaClass(baseClass)) {
        return CAIP_Aspect_swizzleClassInPlace((Class)self);
        // Probably a KVO'ed class. Swizzle in place. Also swizzle meta classes in place.
    }else if (statedClass != baseClass) {
        return CAIP_Aspect_swizzleClassInPlace(baseClass);
    }

    // Default case. Create dynamic subclass.
	const char *subclassName = [className stringByAppendingString:CAIP_AspectsSubclassSuffix].UTF8String;
	Class subclass = objc_getClass(subclassName);

	if (subclass == nil) {
		subclass = objc_allocateClassPair(baseClass, subclassName, 0);
		if (subclass == nil) {
            NSString *errrorDesc = [NSString stringWithFormat:@"objc_allocateClassPair failed to allocate class %s.", subclassName];
            CAIP_AspectError(CAIP_AspectErrorFailedToAllocateClassPair, errrorDesc);
            return nil;
        }

		CAIP_Aspect_swizzleForwardInvocation(subclass);
		CAIP_Aspect_hookedGetClass(subclass, statedClass);
		CAIP_Aspect_hookedGetClass(object_getClass(subclass), statedClass);
		objc_registerClassPair(subclass);
	}

	object_setClass(self, subclass);
	return subclass;
}

static NSString *const CAIP_AspectsForwardInvocationSelectorName = @"__CAIP_Aspects_forwardInvocation:";
static void CAIP_Aspect_swizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    // If there is no method, replace will act like class_addMethod.
    IMP originalImplementation = class_replaceMethod(klass, @selector(forwardInvocation:), (IMP)__CAIP_AspectS_ARE_BEING_CALLED__, "v@:@");
    if (originalImplementation) {
        class_addMethod(klass, NSSelectorFromString(CAIP_AspectsForwardInvocationSelectorName), originalImplementation, "v@:@");
    }
    CAIP_AspectLog(@"CAIP_Aspects: %@ is now CAIP_Aspect aware.", NSStringFromClass(klass));
}

static void CAIP_Aspect_undoSwizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    Method originalMethod = class_getInstanceMethod(klass, NSSelectorFromString(CAIP_AspectsForwardInvocationSelectorName));
    Method objectMethod = class_getInstanceMethod(NSObject.class, @selector(forwardInvocation:));
    // There is no class_removeMethod, so the best we can do is to retore the original implementation, or use a dummy.
    IMP originalImplementation = method_getImplementation(originalMethod ?: objectMethod);
    class_replaceMethod(klass, @selector(forwardInvocation:), originalImplementation, "v@:@");

    CAIP_AspectLog(@"CAIP_Aspects: %@ has been restored.", NSStringFromClass(klass));
}

static void CAIP_Aspect_hookedGetClass(Class class, Class statedClass) {
    NSCParameterAssert(class);
    NSCParameterAssert(statedClass);
	Method method = class_getInstanceMethod(class, @selector(class));
	IMP newIMP = imp_implementationWithBlock(^(id self) {
		return statedClass;
	});
	class_replaceMethod(class, @selector(class), newIMP, method_getTypeEncoding(method));
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Swizzle Class In Place

static void _CAIP_Aspect_modifySwizzledClasses(void (^block)(NSMutableSet *swizzledClasses)) {
    static NSMutableSet *swizzledClasses;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClasses = [NSMutableSet new];
    });
    @synchronized(swizzledClasses) {
        block(swizzledClasses);
    }
}

static Class CAIP_Aspect_swizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);

    _CAIP_Aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        if (![swizzledClasses containsObject:className]) {
            CAIP_Aspect_swizzleForwardInvocation(klass);
            [swizzledClasses addObject:className];
        }
    });
    return klass;
}

static void CAIP_Aspect_undoSwizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);

    _CAIP_Aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        if ([swizzledClasses containsObject:className]) {
            CAIP_Aspect_undoSwizzleForwardInvocation(klass);
            [swizzledClasses removeObject:className];
        }
    });
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - CAIP_Aspect Invoke Point

// This is a macro so we get a cleaner stack trace.
#define CAIP_Aspect_invoke(CAIP_Aspects, info) \
for (CAIP_AspectIdentifier *CAIP_Aspect in CAIP_Aspects) {\
    [CAIP_Aspect invokeWithInfo:info];\
    if (CAIP_Aspect.options & CAIP_AspectOptionAutomaticRemoval) { \
        CAIP_AspectsToRemove = [CAIP_AspectsToRemove?:@[] arrayByAddingObject:CAIP_Aspect]; \
    } \
}

// This is the swizzled forwardInvocation: method.
static void __CAIP_AspectS_ARE_BEING_CALLED__(__unsafe_unretained NSObject *self, SEL selector, NSInvocation *invocation) {
    NSCParameterAssert(self);
    NSCParameterAssert(invocation);
    SEL originalSelector = invocation.selector;
	SEL aliasSelector = CAIP_Aspect_aliasForSelector(invocation.selector);
    invocation.selector = aliasSelector;
    CAIP_AspectsContainer *objectContainer = objc_getAssociatedObject(self, aliasSelector);
    CAIP_AspectsContainer *classContainer = CAIP_Aspect_getContainerForClass(object_getClass(self), aliasSelector);
    CAIP_AspectInfo *info = [[CAIP_AspectInfo alloc] initWithInstance:self invocation:invocation];
    NSArray *CAIP_AspectsToRemove = nil;

    // Before hooks.
    CAIP_Aspect_invoke(classContainer.beforeCAIP_Aspects, info);
    CAIP_Aspect_invoke(objectContainer.beforeCAIP_Aspects, info);

    // Instead hooks.
    BOOL respondsToAlias = YES;
    if (objectContainer.insteadCAIP_Aspects.count || classContainer.insteadCAIP_Aspects.count) {
        CAIP_Aspect_invoke(classContainer.insteadCAIP_Aspects, info);
        CAIP_Aspect_invoke(objectContainer.insteadCAIP_Aspects, info);
    }else {
        Class klass = object_getClass(invocation.target);
        do {
            if ((respondsToAlias = [klass instancesRespondToSelector:aliasSelector])) {
                [invocation invoke];
                break;
            }
        }while (!respondsToAlias && (klass = class_getSuperclass(klass)));
    }

    // After hooks.
    CAIP_Aspect_invoke(classContainer.afterCAIP_Aspects, info);
    CAIP_Aspect_invoke(objectContainer.afterCAIP_Aspects, info);

    // If no hooks are installed, call original implementation (usually to throw an exception)
    if (!respondsToAlias) {
        invocation.selector = originalSelector;
        SEL originalForwardInvocationSEL = NSSelectorFromString(CAIP_AspectsForwardInvocationSelectorName);
        if ([self respondsToSelector:originalForwardInvocationSEL]) {
            ((void( *)(id, SEL, NSInvocation *))objc_msgSend)(self, originalForwardInvocationSEL, invocation);
        }else {
            [self doesNotRecognizeSelector:invocation.selector];
        }
    }

    // Remove any hooks that are queued for deregistration.
    [CAIP_AspectsToRemove makeObjectsPerformSelector:@selector(remove)];
}
#undef CAIP_Aspect_invoke

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - CAIP_Aspect Container Management

// Loads or creates the CAIP_Aspect container.
static CAIP_AspectsContainer *CAIP_Aspect_getContainerForObject(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    SEL aliasSelector = CAIP_Aspect_aliasForSelector(selector);
    CAIP_AspectsContainer *CAIP_AspectContainer = objc_getAssociatedObject(self, aliasSelector);
    if (!CAIP_AspectContainer) {
        CAIP_AspectContainer = [CAIP_AspectsContainer new];
        objc_setAssociatedObject(self, aliasSelector, CAIP_AspectContainer, OBJC_ASSOCIATION_RETAIN);
    }
    return CAIP_AspectContainer;
}

static CAIP_AspectsContainer *CAIP_Aspect_getContainerForClass(Class klass, SEL selector) {
    NSCParameterAssert(klass);
    CAIP_AspectsContainer *classContainer = nil;
    do {
        classContainer = objc_getAssociatedObject(klass, selector);
        if (classContainer.hasCAIP_Aspects) break;
    }while ((klass = class_getSuperclass(klass)));

    return classContainer;
}

static void CAIP_Aspect_destroyContainerForObject(id<NSObject> self, SEL selector) {
    NSCParameterAssert(self);
    SEL aliasSelector = CAIP_Aspect_aliasForSelector(selector);
    objc_setAssociatedObject(self, aliasSelector, nil, OBJC_ASSOCIATION_RETAIN);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Selector Blacklist Checking

static NSMutableDictionary *CAIP_Aspect_getSwizzledClassesDict() {
    static NSMutableDictionary *swizzledClassesDict;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClassesDict = [NSMutableDictionary new];
    });
    return swizzledClassesDict;
}

static BOOL CAIP_Aspect_isSelectorAllowedAndTrack(NSObject *self, SEL selector, CAIP_AspectOptions options, NSError **error) {
    static NSSet *disallowedSelectorList;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        disallowedSelectorList = [NSSet setWithObjects:@"retain", @"release", @"autorelease", @"forwardInvocation:", nil];
    });

    // Check against the blacklist.
    NSString *selectorName = NSStringFromSelector(selector);
    if ([disallowedSelectorList containsObject:selectorName]) {
        NSString *errorDescription = [NSString stringWithFormat:@"Selector %@ is blacklisted.", selectorName];
        CAIP_AspectError(CAIP_AspectErrorSelectorBlacklisted, errorDescription);
        return NO;
    }

    // Additional checks.
    CAIP_AspectOptions position = options&CAIP_AspectPositionFilter;
    if ([selectorName isEqualToString:@"dealloc"] && position != CAIP_AspectPositionBefore) {
        NSString *errorDesc = @"CAIP_AspectPositionBefore is the only valid position when hooking dealloc.";
        CAIP_AspectError(CAIP_AspectErrorSelectorDeallocPosition, errorDesc);
        return NO;
    }

    if (![self respondsToSelector:selector] && ![self.class instancesRespondToSelector:selector]) {
        NSString *errorDesc = [NSString stringWithFormat:@"Unable to find selector -[%@ %@].", NSStringFromClass(self.class), selectorName];
        CAIP_AspectError(CAIP_AspectErrorDoesNotRespondToSelector, errorDesc);
        return NO;
    }

    // Search for the current class and the class hierarchy IF we are modifying a class object
    if (class_isMetaClass(object_getClass(self))) {
        Class klass = [self class];
        NSMutableDictionary *swizzledClassesDict = CAIP_Aspect_getSwizzledClassesDict();
        Class currentClass = [self class];

        CAIP_AspectTracker *tracker = swizzledClassesDict[currentClass];
        if ([tracker subclassHasHookedSelectorName:selectorName]) {
            NSSet *subclassTracker = [tracker subclassTrackersHookingSelectorName:selectorName];
            NSSet *subclassNames = [subclassTracker valueForKey:@"trackedClassName"];
            NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked subclasses: %@. A method can only be hooked once per class hierarchy.", selectorName, subclassNames];
            CAIP_AspectError(CAIP_AspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
            return NO;
        }

        do {
            tracker = swizzledClassesDict[currentClass];
            if ([tracker.selectorNames containsObject:selectorName]) {
                if (klass == currentClass) {
                    // Already modified and topmost!
                    return YES;
                }
                NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked in %@. A method can only be hooked once per class hierarchy.", selectorName, NSStringFromClass(currentClass)];
                CAIP_AspectError(CAIP_AspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
                return NO;
            }
        } while ((currentClass = class_getSuperclass(currentClass)));

        // Add the selector as being modified.
        currentClass = klass;
        CAIP_AspectTracker *subclassTracker = nil;
        do {
            tracker = swizzledClassesDict[currentClass];
            if (!tracker) {
                tracker = [[CAIP_AspectTracker alloc] initWithTrackedClass:currentClass];
                swizzledClassesDict[(id<NSCopying>)currentClass] = tracker;
            }
            if (subclassTracker) {
                [tracker addSubclassTracker:subclassTracker hookingSelectorName:selectorName];
            } else {
                [tracker.selectorNames addObject:selectorName];
            }

            // All superclasses get marked as having a subclass that is modified.
            subclassTracker = tracker;
        }while ((currentClass = class_getSuperclass(currentClass)));
	} else {
		return YES;
	}

    return YES;
}

static void CAIP_Aspect_deregisterTrackedSelector(id self, SEL selector) {
    if (!class_isMetaClass(object_getClass(self))) return;

    NSMutableDictionary *swizzledClassesDict = CAIP_Aspect_getSwizzledClassesDict();
    NSString *selectorName = NSStringFromSelector(selector);
    Class currentClass = [self class];
    CAIP_AspectTracker *subclassTracker = nil;
    do {
        CAIP_AspectTracker *tracker = swizzledClassesDict[currentClass];
        if (subclassTracker) {
            [tracker removeSubclassTracker:subclassTracker hookingSelectorName:selectorName];
        } else {
            [tracker.selectorNames removeObject:selectorName];
        }
        if (tracker.selectorNames.count == 0 && tracker.selectorNamesToSubclassTrackers) {
            [swizzledClassesDict removeObjectForKey:currentClass];
        }
        subclassTracker = tracker;
    }while ((currentClass = class_getSuperclass(currentClass)));
}

@end

@implementation CAIP_AspectTracker

- (id)initWithTrackedClass:(Class)trackedClass {
    if (self = [super init]) {
        _trackedClass = trackedClass;
        _selectorNames = [NSMutableSet new];
        _selectorNamesToSubclassTrackers = [NSMutableDictionary new];
    }
    return self;
}

- (BOOL)subclassHasHookedSelectorName:(NSString *)selectorName {
    return self.selectorNamesToSubclassTrackers[selectorName] != nil;
}

- (void)addSubclassTracker:(CAIP_AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName {
    NSMutableSet *trackerSet = self.selectorNamesToSubclassTrackers[selectorName];
    if (!trackerSet) {
        trackerSet = [NSMutableSet new];
        self.selectorNamesToSubclassTrackers[selectorName] = trackerSet;
    }
    [trackerSet addObject:subclassTracker];
}
- (void)removeSubclassTracker:(CAIP_AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName {
    NSMutableSet *trackerSet = self.selectorNamesToSubclassTrackers[selectorName];
    [trackerSet removeObject:subclassTracker];
    if (trackerSet.count == 0) {
        [self.selectorNamesToSubclassTrackers removeObjectForKey:selectorName];
    }
}
- (NSSet *)subclassTrackersHookingSelectorName:(NSString *)selectorName {
    NSMutableSet *hookingSubclassTrackers = [NSMutableSet new];
    for (CAIP_AspectTracker *tracker in self.selectorNamesToSubclassTrackers[selectorName]) {
        if ([tracker.selectorNames containsObject:selectorName]) {
            [hookingSubclassTrackers addObject:tracker];
        }
        [hookingSubclassTrackers unionSet:[tracker subclassTrackersHookingSelectorName:selectorName]];
    }
    return hookingSubclassTrackers;
}
- (NSString *)trackedClassName {
    return NSStringFromClass(self.trackedClass);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %@, trackedClass: %@, selectorNames:%@, subclass selector names: %@>", self.class, self, NSStringFromClass(self.trackedClass), self.selectorNames, self.selectorNamesToSubclassTrackers.allKeys];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSInvocation (CAIP_Aspects)

@implementation NSInvocation (CAIP_Aspects)

// Thanks to the ReactiveCocoa team for providing a generic solution for this.
- (id)CAIP_Aspect_argumentAtIndex:(NSUInteger)index {
	const char *argType = [self.methodSignature getArgumentTypeAtIndex:index];
	// Skip const type qualifier.
	if (argType[0] == _C_CONST) argType++;

#define WRAP_AND_RETURN(type) do { type val = 0; [self getArgument:&val atIndex:(NSInteger)index]; return @(val); } while (0)
	if (strcmp(argType, @encode(id)) == 0 || strcmp(argType, @encode(Class)) == 0) {
		__autoreleasing id returnObj;
		[self getArgument:&returnObj atIndex:(NSInteger)index];
		return returnObj;
	} else if (strcmp(argType, @encode(SEL)) == 0) {
        SEL selector = 0;
        [self getArgument:&selector atIndex:(NSInteger)index];
        return NSStringFromSelector(selector);
    } else if (strcmp(argType, @encode(Class)) == 0) {
        __autoreleasing Class theClass = Nil;
        [self getArgument:&theClass atIndex:(NSInteger)index];
        return theClass;
        // Using this list will box the number with the appropriate constructor, instead of the generic NSValue.
	} else if (strcmp(argType, @encode(char)) == 0) {
		WRAP_AND_RETURN(char);
	} else if (strcmp(argType, @encode(int)) == 0) {
		WRAP_AND_RETURN(int);
	} else if (strcmp(argType, @encode(short)) == 0) {
		WRAP_AND_RETURN(short);
	} else if (strcmp(argType, @encode(long)) == 0) {
		WRAP_AND_RETURN(long);
	} else if (strcmp(argType, @encode(long long)) == 0) {
		WRAP_AND_RETURN(long long);
	} else if (strcmp(argType, @encode(unsigned char)) == 0) {
		WRAP_AND_RETURN(unsigned char);
	} else if (strcmp(argType, @encode(unsigned int)) == 0) {
		WRAP_AND_RETURN(unsigned int);
	} else if (strcmp(argType, @encode(unsigned short)) == 0) {
		WRAP_AND_RETURN(unsigned short);
	} else if (strcmp(argType, @encode(unsigned long)) == 0) {
		WRAP_AND_RETURN(unsigned long);
	} else if (strcmp(argType, @encode(unsigned long long)) == 0) {
		WRAP_AND_RETURN(unsigned long long);
	} else if (strcmp(argType, @encode(float)) == 0) {
		WRAP_AND_RETURN(float);
	} else if (strcmp(argType, @encode(double)) == 0) {
		WRAP_AND_RETURN(double);
	} else if (strcmp(argType, @encode(BOOL)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(bool)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(char *)) == 0) {
		WRAP_AND_RETURN(const char *);
	} else if (strcmp(argType, @encode(void (^)(void))) == 0) {
		__unsafe_unretained id block = nil;
		[self getArgument:&block atIndex:(NSInteger)index];
		return [block copy];
	} else {
		NSUInteger valueSize = 0;
		NSGetSizeAndAlignment(argType, &valueSize, NULL);

		unsigned char valueBytes[valueSize];
		[self getArgument:valueBytes atIndex:(NSInteger)index];

		return [NSValue valueWithBytes:valueBytes objCType:argType];
	}
	return nil;
#undef WRAP_AND_RETURN
}

- (NSArray *)CAIP_Aspects_arguments {
	NSMutableArray *argumentsArray = [NSMutableArray array];
	for (NSUInteger idx = 2; idx < self.methodSignature.numberOfArguments; idx++) {
		[argumentsArray addObject:[self CAIP_Aspect_argumentAtIndex:idx] ?: NSNull.null];
	}
	return [argumentsArray copy];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - CAIP_AspectIdentifier

@implementation CAIP_AspectIdentifier

+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(CAIP_AspectOptions)options block:(id)block error:(NSError **)error {
    NSCParameterAssert(block);
    NSCParameterAssert(selector);
    NSMethodSignature *blockSignature = CAIP_Aspect_blockMethodSignature(block, error); // TODO: check signature compatibility, etc.
    if (!CAIP_Aspect_isCompatibleBlockSignature(blockSignature, object, selector, error)) {
        return nil;
    }

    CAIP_AspectIdentifier *identifier = nil;
    if (blockSignature) {
        identifier = [CAIP_AspectIdentifier new];
        identifier.selector = selector;
        identifier.block = block;
        identifier.blockSignature = blockSignature;
        identifier.options = options;
        identifier.object = object; // weak
    }
    return identifier;
}

- (BOOL)invokeWithInfo:(id<CAIP_AspectInfo>)info {
    NSInvocation *blockInvocation = [NSInvocation invocationWithMethodSignature:self.blockSignature];
    NSInvocation *originalInvocation = info.originalInvocation;
    NSUInteger numberOfArguments = self.blockSignature.numberOfArguments;

    // Be extra paranoid. We already check that on hook registration.
    if (numberOfArguments > originalInvocation.methodSignature.numberOfArguments) {
        CAIP_AspectLogError(@"Block has too many arguments. Not calling %@", info);
        return NO;
    }

    // The `self` of the block will be the CAIP_AspectInfo. Optional.
    if (numberOfArguments > 1) {
        [blockInvocation setArgument:&info atIndex:1];
    }
    
	void *argBuf = NULL;
    for (NSUInteger idx = 2; idx < numberOfArguments; idx++) {
        const char *type = [originalInvocation.methodSignature getArgumentTypeAtIndex:idx];
		NSUInteger argSize;
		NSGetSizeAndAlignment(type, &argSize, NULL);
        
		if (!(argBuf = reallocf(argBuf, argSize))) {
            CAIP_AspectLogError(@"Failed to allocate memory for block invocation.");
			return NO;
		}
        
		[originalInvocation getArgument:argBuf atIndex:idx];
		[blockInvocation setArgument:argBuf atIndex:idx];
    }
    
    [blockInvocation invokeWithTarget:self.block];
    
    if (argBuf != NULL) {
        free(argBuf);
    }
    return YES;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, SEL:%@ object:%@ options:%tu block:%@ (#%tu args)>", self.class, self, NSStringFromSelector(self.selector), self.object, self.options, self.block, self.blockSignature.numberOfArguments];
}

- (BOOL)remove {
    return CAIP_Aspect_remove(self, NULL);
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - CAIP_AspectsContainer

@implementation CAIP_AspectsContainer

- (BOOL)hasCAIP_Aspects {
    return self.beforeCAIP_Aspects.count > 0 || self.insteadCAIP_Aspects.count > 0 || self.afterCAIP_Aspects.count > 0;
}

- (void)addCAIP_Aspect:(CAIP_AspectIdentifier *)CAIP_Aspect withOptions:(CAIP_AspectOptions)options {
    NSParameterAssert(CAIP_Aspect);
    NSUInteger position = options&CAIP_AspectPositionFilter;
    switch (position) {
        case CAIP_AspectPositionBefore:  self.beforeCAIP_Aspects  = [(self.beforeCAIP_Aspects ?:@[]) arrayByAddingObject:CAIP_Aspect]; break;
        case CAIP_AspectPositionInstead: self.insteadCAIP_Aspects = [(self.insteadCAIP_Aspects?:@[]) arrayByAddingObject:CAIP_Aspect]; break;
        case CAIP_AspectPositionAfter:   self.afterCAIP_Aspects   = [(self.afterCAIP_Aspects  ?:@[]) arrayByAddingObject:CAIP_Aspect]; break;
    }
}

- (BOOL)removeCAIP_Aspect:(id)CAIP_Aspect {
    for (NSString *CAIP_AspectArrayName in @[NSStringFromSelector(@selector(beforeCAIP_Aspects)),
                                        NSStringFromSelector(@selector(insteadCAIP_Aspects)),
                                        NSStringFromSelector(@selector(afterCAIP_Aspects))]) {
        NSArray *array = [self valueForKey:CAIP_AspectArrayName];
        NSUInteger index = [array indexOfObjectIdenticalTo:CAIP_Aspect];
        if (array && index != NSNotFound) {
            NSMutableArray *newArray = [NSMutableArray arrayWithArray:array];
            [newArray removeObjectAtIndex:index];
            [self setValue:newArray forKey:CAIP_AspectArrayName];
            return YES;
        }
    }
    return NO;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, before:%@, instead:%@, after:%@>", self.class, self, self.beforeCAIP_Aspects, self.insteadCAIP_Aspects, self.afterCAIP_Aspects];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - CAIP_AspectInfo

@implementation CAIP_AspectInfo

@synthesize arguments = _arguments;

- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation {
    NSCParameterAssert(instance);
    NSCParameterAssert(invocation);
    if (self = [super init]) {
        _instance = instance;
        _originalInvocation = invocation;
    }
    return self;
}

- (NSArray *)arguments {
    // Lazily evaluate arguments, boxing is expensive.
    if (!_arguments) {
        _arguments = self.originalInvocation.CAIP_Aspects_arguments;
    }
    return _arguments;
}

@end
