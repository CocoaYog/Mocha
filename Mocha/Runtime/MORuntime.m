//
//  MORuntime.m
//  Mocha
//
//  Created by Logan Collins on 5/10/12.
//  Copyright (c) 2012 Sunflower Softworks. All rights reserved.
//

#import "MORuntime.h"
#import "MORuntime_Private.h"

#import "MOBox.h"
#import "MOUndefined.h"
#import "MOMethod_Private.h"
#import "MOJavaScriptObject_Private.h"
#import "MOJavaScriptFunction.h"
#import "MOPointer.h"
#import "MOUtilities.h"
#import "MOFunctionArgument.h"
#import "MOFunctionInvocation.h"
#import "MOAllocator.h"

#import "MOBridgeSupportController.h"
#import "MOBridgeSupportSymbol.h"

#import "NSArray+MochaAdditions.h"
#import "NSDictionary+MochaAdditions.h"
#import "NSOrderedSet+MochaAdditions.h"

#import <objc/runtime.h>
#import <dlfcn.h>


// Class types
static JSClassRef MochaClass = NULL;

static JSClassRef MOObjectClass = NULL;
static JSClassRef MOBoxedObjectClass = NULL;
static JSClassRef MOConstructorClass = NULL;
static JSClassRef MOFunctionClass = NULL;


// Global object
static JSValueRef   Mocha_getProperty(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName, JSValueRef *exception);

// Private Cocoa object callbacks
static void         MOObject_initialize(JSContextRef ctx, JSObjectRef object);
static void         MOObject_finalize(JSObjectRef object);

static bool         MOObject_hasProperty(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName);
static JSValueRef   MOObject_getProperty(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName, JSValueRef *exception);
static bool         MOObject_setProperty(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName, JSValueRef value, JSValueRef *exception);
static bool         MOObject_deleteProperty(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName, JSValueRef *exception);
static void         MOObject_getPropertyNames(JSContextRef ctx, JSObjectRef object, JSPropertyNameAccumulatorRef propertyNames);
static JSValueRef   MOObject_convertToType(JSContextRef ctx, JSObjectRef object, JSType type, JSValueRef *exception);
static bool         MOObject_hasInstance(JSContextRef ctx, JSObjectRef constructor, JSValueRef possibleInstance, JSValueRef *exception);

static JSObjectRef  MOConstructor_callAsConstructor(JSContextRef ctx, JSObjectRef object, size_t argumentsCount, const JSValueRef arguments[], JSValueRef *exception);

static JSValueRef   MOFunction_callAsFunction(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef *exception);

static JSValueRef   MOJSPrototypeFunctionForOBJCInstance(JSContextRef ctx, id instance, NSString *functionName);


NSString * const MORuntimeException = @"MORuntimeException";
NSString * const MOJavaScriptException = @"MOJavaScriptException";


#pragma mark -
#pragma mark Runtime

@implementation MORuntime {
    JSGlobalContextRef _ctx;
    NSMapTable *_objectsToBoxes;
}

+ (void)initialize {
    if (self == [MORuntime class]) {
        // Global runtime object
        JSClassDefinition MochaClassDefinition      = kJSClassDefinitionEmpty;
        MochaClassDefinition.className              = "MORuntime";
        MochaClassDefinition.getProperty            = Mocha_getProperty;
        MochaClass                                  = JSClassCreate(&MochaClassDefinition);
        
        // Runtime object
        JSClassDefinition MOObjectDefinition        = kJSClassDefinitionEmpty;
        MOObjectDefinition.className                = "MOAbstractObject";
        MOObjectDefinition.initialize               = MOObject_initialize;
        MOObjectDefinition.finalize                 = MOObject_finalize;
        MOObjectDefinition.convertToType            = MOObject_convertToType;
        MOObjectClass                               = JSClassCreate(&MOObjectDefinition);
        
        // Boxed Cocoa object
        JSClassDefinition MOBoxedObjectDefinition   = kJSClassDefinitionEmpty;
        MOBoxedObjectDefinition.className           = "MOObject";
        MOBoxedObjectDefinition.parentClass         = MOObjectClass;
        MOBoxedObjectDefinition.hasProperty         = MOObject_hasProperty;
        MOBoxedObjectDefinition.getProperty         = MOObject_getProperty;
        MOBoxedObjectDefinition.setProperty         = MOObject_setProperty;
        MOBoxedObjectDefinition.deleteProperty      = MOObject_deleteProperty;
        MOBoxedObjectDefinition.getPropertyNames    = MOObject_getPropertyNames;
        MOBoxedObjectDefinition.hasInstance         = MOObject_hasInstance;
        MOBoxedObjectClass                          = JSClassCreate(&MOBoxedObjectDefinition);
        
        // Constructor object
        JSClassDefinition MOConstructorDefinition   = kJSClassDefinitionEmpty;
        MOConstructorDefinition.className           = "MOConstructor";
        MOConstructorDefinition.parentClass         = MOObjectClass;
        MOConstructorDefinition.callAsConstructor   = MOConstructor_callAsConstructor;
        MOConstructorClass                          = JSClassCreate(&MOConstructorDefinition);
        
        // Function object
        JSClassDefinition MOFunctionDefinition      = kJSClassDefinitionEmpty;
        MOFunctionDefinition.className              = "MOFunction";
        MOFunctionDefinition.parentClass            = MOObjectClass;
        MOFunctionDefinition.callAsFunction         = MOFunction_callAsFunction;
        MOFunctionClass                             = JSClassCreate(&MOFunctionDefinition);
        
        
        // Swizzle indexed subscripting support for NSArray
        SEL indexedSubscriptSelector = @selector(objectForIndexedSubscript:);
        if (![NSArray instancesRespondToSelector:indexedSubscriptSelector]) {
            IMP imp = class_getMethodImplementation([NSArray class], @selector(mo_objectForIndexedSubscript:));
            class_addMethod([NSArray class], @selector(objectForIndexedSubscript:), imp, "@@:l");
            
            imp = class_getMethodImplementation([NSMutableArray class], @selector(mo_setObject:forIndexedSubscript:));
            class_addMethod([NSMutableArray class], @selector(setObject:forIndexedSubscript:), imp, "@@:@l");
        }
        
        // Swizzle indexed subscripting support for NSOrderedSet
        if (![NSOrderedSet instancesRespondToSelector:indexedSubscriptSelector]) {
            IMP imp = class_getMethodImplementation([NSOrderedSet class], @selector(mo_objectForIndexedSubscript:));
            class_addMethod([NSOrderedSet class], @selector(objectForIndexedSubscript:), imp, "@@:l");
            
            imp = class_getMethodImplementation([NSMutableOrderedSet class], @selector(mo_setObject:forIndexedSubscript:));
            class_addMethod([NSMutableOrderedSet class], @selector(setObject:forIndexedSubscript:), imp, "@@:@l");
        }
        
        // Swizzle keyed subscripting support for NSDictionary
        SEL keyedSubscriptSelector = @selector(objectForKeyedSubscript:);
        if (![NSDictionary instancesRespondToSelector:keyedSubscriptSelector]) {
            IMP imp = class_getMethodImplementation([NSDictionary class], @selector(mo_objectForKeyedSubscript:));
            class_addMethod([NSDictionary class], @selector(objectForKeyedSubscript:), imp, "@@:@");
            
            imp = class_getMethodImplementation([NSMutableDictionary class], @selector(mo_setObject:forKeyedSubscript:));
            class_addMethod([NSMutableDictionary class], @selector(setObject:forKeyedSubscript:), imp, "@@:@@");
        }
    }
}

+ (MORuntime *)runtimeWithContext:(JSContextRef)ctx {
    JSStringRef jsName = JSStringCreateWithUTF8CString("__mocha__");
    JSValueRef jsValue = JSObjectGetProperty(ctx, JSContextGetGlobalObject(ctx), jsName, NULL);
    JSStringRelease(jsName);
    return [self objectForJSValue:jsValue inContext:ctx];
}

- (id)init {
    return [self initWithOptions:MORuntimeOptionsNone];
}

- (id)initWithOptions:(MORuntimeOptions)options {
    self = [super init];
    if (self) {
        self.options = options;
        
        _ctx = JSGlobalContextCreate(MochaClass);
        _objectsToBoxes = [NSMapTable strongToStrongObjectsMapTable];
        
#if !TARGET_OS_IPHONE
        NSArray *libraryPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSAllDomainsMask, YES);
        NSMutableArray *frameworkSearchPaths = [NSMutableArray arrayWithCapacity:[libraryPaths count]];
        for (NSString *libraryPath in libraryPaths) {
            NSString *frameworkSearchPath = [libraryPath stringByAppendingPathComponent:@"Frameworks"];
            [frameworkSearchPaths addObject:frameworkSearchPath];
        }
        self.frameworkSearchPaths = frameworkSearchPaths;
#endif
        
        // Add the runtime as a property of the context
        [self setGlobalObject:self withName:@"__mocha__" attributes:(kJSPropertyAttributeReadOnly|kJSPropertyAttributeDontEnum|kJSPropertyAttributeDontDelete)];
        
        // Load builtins
        [self installBuiltins];
    }
    return self;
}

- (void)dealloc {
    JSGlobalContextRelease(_ctx);
}

- (JSGlobalContextRef)context {
    return _ctx;
}


#pragma mark -
#pragma mark Object Conversion

+ (JSValueRef)JSValueForObject:(id)object inContext:(JSContextRef)ctx {
    return [[MORuntime runtimeWithContext:ctx] JSValueForObject:object];
}

+ (id)objectForJSValue:(JSValueRef)value inContext:(JSContextRef)ctx {
    return [self objectForJSValue:value inContext:ctx unboxObjects:YES];
}

+ (id)objectForJSValue:(JSValueRef)value inContext:(JSContextRef)ctx unboxObjects:(BOOL)unboxObjects {
    if (value == NULL || JSValueIsUndefined(ctx, value)) {
        return [MOUndefined undefined];
    }
    
    if (JSValueIsNull(ctx, value)) {
        return nil;
    }
    
    if (JSValueIsString(ctx, value)) {
        JSStringRef resultStringJS = JSValueToStringCopy(ctx, value, NULL);
        NSString *resultString = (NSString *)CFBridgingRelease(JSStringCopyCFString(kCFAllocatorDefault, resultStringJS));
        JSStringRelease(resultStringJS);
        return resultString;
    }
    
    if (JSValueIsNumber(ctx, value)) {
        double v = JSValueToNumber(ctx, value, NULL);
        return [NSNumber numberWithDouble:v];
    }
    
    if (JSValueIsBoolean(ctx, value)) {
        bool v = JSValueToBoolean(ctx, value);
        return [NSNumber numberWithBool:v];
    }
    
    if (!JSValueIsObject(ctx, value)) {
        return nil;
    }
    
    JSObjectRef jsObject = JSValueToObject(ctx, value, NULL);
    id private = (__bridge id)JSObjectGetPrivate(jsObject);
    
    if (private != nil) {
        if ([private isKindOfClass:[MOBox class]]) {
            if (unboxObjects == YES) {
                // Boxed object
                return [private representedObject];
            }
            else {
                return private;
            }
        }
        else {
            return private;
        }
    }
    else {
        BOOL isFunction = JSObjectIsFunction(ctx, jsObject);
        if (isFunction) {
            // Function
            return [MOJavaScriptFunction objectWithJSObject:jsObject context:ctx];
        }
        
        BOOL isConstructor = JSObjectIsConstructor(ctx, jsObject);
        if (isConstructor) {
            // Constructor
            return [MOJavaScriptObject objectWithJSObject:jsObject context:ctx];
        }
        
        JSStringRef scriptJS = JSStringCreateWithUTF8CString("return arguments[0].constructor == Array.prototype.constructor");
        JSObjectRef fn = JSObjectMakeFunction(ctx, NULL, 0, NULL, scriptJS, NULL, 1, NULL);
        JSValueRef result = JSObjectCallAsFunction(ctx, fn, NULL, 1, (JSValueRef *)&jsObject, NULL);
        JSStringRelease(scriptJS);
        
        BOOL isArray = JSValueToBoolean(ctx, result);
        if (isArray) {
            // Arrays should be automatically converted to NSArray
            return [self arrayForJSArray:jsObject inContext:ctx];
        }
        
        // Object
        return [MOJavaScriptObject objectWithJSObject:jsObject context:ctx];
    }
    
    return nil;
}

+ (NSArray *)arrayForJSArray:(JSObjectRef)arrayValue inContext:(JSContextRef)ctx {
    JSValueRef exception = NULL;
    JSStringRef lengthJS = JSStringCreateWithUTF8CString("length");
    NSUInteger length = JSValueToNumber(ctx, JSObjectGetProperty(ctx, arrayValue, lengthJS, NULL), &exception);
    JSStringRelease(lengthJS);
    
    if (exception != NULL) {
        return nil;
    }
    
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:length];

    for (NSUInteger i=0; i<length; i++) {
        id obj = nil;
        JSValueRef jsValue = JSObjectGetPropertyAtIndex(ctx, arrayValue, (unsigned int)i, &exception);
        if (exception != NULL) {
            return nil;
        }
        
        obj = [self objectForJSValue:jsValue inContext:ctx unboxObjects:YES];
        if (obj == nil) {
            obj = [NSNull null];
        }
        
        [array addObject:obj];
    }
    
    return [array copy];
}

+ (NSDictionary *)dictionaryForJSHash:(JSObjectRef)hashValue inContext:(JSContextRef)ctx {
    JSPropertyNameArrayRef names = JSObjectCopyPropertyNames(ctx, hashValue);
    NSUInteger length = JSPropertyNameArrayGetCount(names);
    
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:length];
    JSValueRef exception = NULL;
    
    for (NSUInteger i=0; i<length; i++) {
        id obj = nil;
        JSStringRef name = JSPropertyNameArrayGetNameAtIndex(names, i);
        JSValueRef jsValue = JSObjectGetProperty(ctx, hashValue, name, &exception);
        
        if (exception != NULL) {
            return NO;
        }
        
        obj = [self objectForJSValue:jsValue inContext:ctx unboxObjects:YES];
        if (obj == nil) {
            obj = [NSNull null];
        }
        
        NSString *key = (NSString *)CFBridgingRelease(JSStringCopyCFString(kCFAllocatorDefault, name));
        [dictionary setObject:obj forKey:key];
    }
    
    JSPropertyNameArrayRelease(names);
    
    return [dictionary copy];
}

- (JSValueRef)JSValueForObject:(id)object {
    JSValueRef value = NULL;
    
    if ([object isKindOfClass:[MOBox class]]) {
        value = [object JSObject];
    }
    else if ([object isKindOfClass:[MOJavaScriptObject class]]) {
        return [object JSObject];
    }
    /*else if ([object isKindOfClass:[NSString class]]) {
        JSStringRef string = JSStringCreateWithCFString((CFStringRef)object);
        value = JSValueMakeString(_ctx, string);
        JSStringRelease(string);
    }
    else if ([object isKindOfClass:[NSNumber class]]) {
        double doubleValue = [object doubleValue];
        value = JSValueMakeNumber(_ctx, doubleValue);
    }*/
    else if (object == nil/* || [object isKindOfClass:[NSNull class]]*/) {
        value = JSValueMakeNull(_ctx);
    }
    else if (object == [MOUndefined undefined]) {
        value = JSValueMakeUndefined(_ctx);
    }
    
    if (value == NULL) {
        value = [self boxedJSObjectForObject:object];
    }
    
    return value;
}

- (id)objectForJSValue:(JSValueRef)value {
    return [self objectForJSValue:value unboxObjects:YES];
}

- (id)objectForJSValue:(JSValueRef)value unboxObjects:(BOOL)unboxObjects {
    return [MORuntime objectForJSValue:value inContext:_ctx unboxObjects:unboxObjects];
}

- (JSObjectRef)boxedJSObjectForObject:(id)object {
    if (object == nil) {
        return NULL;
    }
    
    MOBox *box = [_objectsToBoxes objectForKey:object];
    if (box != nil) {
        return [box JSObject];
    }
    
    box = [[MOBox alloc] init];
    box.runtime = self;
    box.representedObject = object;
    
    JSObjectRef jsObject = NULL;
    
    if ([object conformsToProtocol:@protocol(MOCallable)]) {
        // Callables should be functions
        jsObject = JSObjectMake(_ctx, MOFunctionClass, (__bridge void *)(box));
    }
    else {
        // All other objects should be simple boxes
        jsObject = JSObjectMake(_ctx, MOBoxedObjectClass, (__bridge void *)(box));
    }
    
    box.JSObject = jsObject;
    
    [_objectsToBoxes setObject:box forKey:object];
    
    return jsObject;
}

- (void)removeBoxAssociationForObject:(id)object {
    if (object != nil) {
        [_objectsToBoxes removeObjectForKey:object];
    }
}


#pragma mark -
#pragma mark Evaluation

- (id)evaluateString:(NSString *)string {
    JSValueRef jsValue = [self evaluateJSString:string scriptPath:nil];
    return [self objectForJSValue:jsValue];
}

- (JSValueRef)evaluateJSString:(NSString *)string scriptPath:(NSString *)scriptPath {
    if (string == nil) {
        return NULL;
    }
    
    JSStringRef jsString = JSStringCreateWithCFString((__bridge CFStringRef)string);
    JSStringRef jsScriptPath = (scriptPath != nil ? JSStringCreateWithUTF8CString([scriptPath UTF8String]) : NULL);
    JSValueRef exception = NULL;
    
    JSValueRef result = JSEvaluateScript(_ctx, jsString, NULL, jsScriptPath, 1, &exception);
    
    if (jsString != NULL) {
        JSStringRelease(jsString);
    }
    if (jsScriptPath != NULL) {
        JSStringRelease(jsScriptPath);
    }
    
    if (exception != NULL) {
        [self throwJSException:exception];
        return NULL;
    }
    
    return result;
}


#pragma mark -
#pragma mark Objects

- (NSArray *)globalObjectNames {
    JSPropertyNameArrayRef propertyNamesRef = JSObjectCopyPropertyNames(_ctx, JSContextGetGlobalObject(_ctx));
    size_t count = JSPropertyNameArrayGetCount(propertyNamesRef);
    
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:count];
    for (size_t i=0; i<count; i++) {
        JSStringRef nameRef = JSPropertyNameArrayGetNameAtIndex(propertyNamesRef, i);
        NSString *name = CFBridgingRelease(JSStringCopyCFString(NULL, nameRef));
        [array addObject:name];
    }
    
    JSPropertyNameArrayRelease(propertyNamesRef);
    
    return array;
}

- (id)globalObjectWithName:(NSString *)objectName {
    JSValueRef exception = NULL;
    
    // Get function as property of global object
    JSStringRef jsObjectName = JSStringCreateWithUTF8CString([objectName UTF8String]);
    JSValueRef jsObjectValue = JSObjectGetProperty(_ctx, JSContextGetGlobalObject(_ctx), jsObjectName, &exception);
    JSStringRelease(jsObjectName);
    
    if (exception != NULL) {
        [self throwJSException:exception];
        return NULL;
    }
    
    return [self objectForJSValue:jsObjectValue];
}

- (void)setGlobalObject:(id)object withName:(NSString *)name {
    [self setGlobalObject:object withName:name attributes:(kJSPropertyAttributeNone)];
}

- (void)setGlobalObject:(id)object withName:(NSString *)name attributes:(JSPropertyAttributes)attributes {
    JSValueRef jsValue = [self JSValueForObject:object];
    
    // Set
    JSValueRef exception = NULL;
    JSStringRef jsName = JSStringCreateWithUTF8CString([name UTF8String]);
    JSObjectSetProperty(_ctx, JSContextGetGlobalObject(_ctx), jsName, jsValue, attributes, &exception);
    JSStringRelease(jsName);
    
    if (exception != NULL) {
        [self throwJSException:exception];
    }
}

- (void)removeGlobalObjectWithName:(NSString *)name {
    JSValueRef exception = NULL;
    
    // Delete
    JSStringRef jsName = JSStringCreateWithUTF8CString([name UTF8String]);
    JSObjectDeleteProperty(_ctx, JSContextGetGlobalObject(_ctx), jsName, &exception);
    JSStringRelease(jsName);
    
    if (exception != NULL) {
        [self throwJSException:exception];
    }
}


#pragma mark -
#pragma mark Syntax Validation

- (BOOL)isSyntaxValidForString:(NSString *)string {
    JSStringRef jsScript = JSStringCreateWithUTF8CString([string UTF8String]);
    JSValueRef exception = NULL;
    bool success = JSCheckScriptSyntax(_ctx, jsScript, NULL, 1, &exception);
    
    if (jsScript != NULL) {
        JSStringRelease(jsScript);
    }
    
    if (exception != NULL) {
        [self throwJSException:exception];
    }
    
    return success;
}


#pragma mark -
#pragma mark Exceptions

+ (NSException *)exceptionWithJSException:(JSValueRef)exception context:(JSContextRef)ctx {
    NSString *error = nil;
    JSStringRef resultStringJS = JSValueToStringCopy(ctx, exception, NULL);
    if (resultStringJS != NULL) {
        error = (NSString *)CFBridgingRelease(JSStringCopyCFString(kCFAllocatorDefault, resultStringJS));
        JSStringRelease(resultStringJS);
    }
    
    if (JSValueGetType(ctx, exception) != kJSTypeObject) {
        NSException *mochaException = [NSException exceptionWithName:MOJavaScriptException reason:error userInfo:nil];
        return mochaException;
    }
    else {
        // Iterate over all properties of the exception
        JSObjectRef jsObject = JSValueToObject(ctx, exception, NULL);
        JSPropertyNameArrayRef jsNames = JSObjectCopyPropertyNames(ctx, jsObject);
        size_t count = JSPropertyNameArrayGetCount(jsNames);
        
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithCapacity:count];
        
        for (size_t i = 0; i < count; i++) {
            JSStringRef jsName = JSPropertyNameArrayGetNameAtIndex(jsNames, i);
            NSString *name = (NSString *)CFBridgingRelease(JSStringCopyCFString(kCFAllocatorDefault, jsName));
            
            JSValueRef jsValueRef = JSObjectGetProperty(ctx, jsObject, jsName, NULL);
            JSStringRef valueJS = JSValueToStringCopy(ctx, jsValueRef, NULL);
            NSString *value = (NSString *)CFBridgingRelease(JSStringCopyCFString(kCFAllocatorDefault, valueJS));
            JSStringRelease(valueJS);
            
            [userInfo setObject:value forKey:name];
        }
        
        JSPropertyNameArrayRelease(jsNames);
        
        NSException *mochaException = [NSException exceptionWithName:MOJavaScriptException reason:error userInfo:userInfo];
        return mochaException;
    }
}

- (NSException *)exceptionWithJSException:(JSValueRef)exception {
    return [MORuntime exceptionWithJSException:exception context:_ctx];
}

- (void)throwJSException:(JSValueRef)exceptionJS {
    id object = [self objectForJSValue:exceptionJS];
    if ([object isKindOfClass:[NSException class]]) {
        // Rethrow ObjC exceptions that were boxed within the runtime
        @throw object;
    }
    else {
        // Throw all other types of exceptions as an NSException
        NSException *exception = [self exceptionWithJSException:exceptionJS];
        if (exception != nil) {
            @throw exception;
        }
    }
}


#pragma mark -
#pragma mark BridgeSupport Metadata

- (BOOL)loadBridgeSupportFilesAtPath:(NSString *)path {
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    
    BOOL isDirectory = NO;
    if ([fileManager fileExistsAtPath:path isDirectory:&isDirectory]) {
        NSMutableArray *filesToLoad = [NSMutableArray array];
        if (isDirectory) {
            NSArray *contents = [fileManager contentsOfDirectoryAtPath:path error:nil];
            for (NSString *filePathComponent in contents) {
                NSString *filePath = [path stringByAppendingPathComponent:filePathComponent];
                if ([[filePath pathExtension] isEqualToString:@"bridgesupport"]
                    || [[filePathComponent pathExtension] isEqualToString:@"dylib"]) {
                    [filesToLoad addObject:filePath];
                }
            }
        }
        else {
            if ([[path pathExtension] isEqualToString:@"bridgesupport"]
                || [[path pathExtension] isEqualToString:@"dylib"]) {
                [filesToLoad addObject:path];
            }
            else {
                return NO;
            }
        }
        
        // Load files
        for (NSString *filePath in filesToLoad) {
            if ([[filePath pathExtension] isEqualToString:@"bridgesupport"]) {
                // BridgeSupport
                NSError *error = nil;
                if (![[MOBridgeSupportController sharedController] loadBridgeSupportAtURL:[NSURL fileURLWithPath:filePath] error:&error]) {
                    return NO;
                }
            }
#if !TARGET_OS_IPHONE
            else if ([[filePath pathExtension] isEqualToString:@"dylib"]) {
                // dylib
                dlopen([filePath UTF8String], RTLD_LAZY);
            }
#endif
        }
        
        return YES;
    }
    else {
        return NO;
    }
}

#if !TARGET_OS_IPHONE

- (BOOL)loadFrameworkWithName:(NSString *)frameworkName {
    BOOL success = NO;
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    
    for (NSString *path in _frameworkSearchPaths) {
        NSString *frameworkPath = [path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.framework", frameworkName]];
        if ([fileManager fileExistsAtPath:frameworkPath]) {
            success = [self loadFrameworkWithName:frameworkName inDirectory:path];
            if (success) {
                break;
            }
        }
    }
    
    return success;
}

- (BOOL)loadFrameworkWithName:(NSString *)frameworkName inDirectory:(NSString *)directory {
    NSString *frameworkPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.framework", frameworkName]];
    
    // Load the framework
    NSString *libPath = [frameworkPath stringByAppendingPathComponent:frameworkName];
    void *address = dlopen([libPath UTF8String], RTLD_LAZY);
    if (!address) {
        //NSLog(@"ERROR: Could not load framework dylib: %@, %@", frameworkName, libPath);
        return NO;
    }
    
    // Load the BridgeSupport data
    NSString *bridgeSupportPath = [frameworkPath stringByAppendingPathComponent:[NSString stringWithFormat:@"Resources/BridgeSupport"]];
    [self loadBridgeSupportFilesAtPath:bridgeSupportPath];
    
    return YES;
}

#endif


#pragma mark -
#pragma mark Garbage Collection

- (void)garbageCollect {
    JSGarbageCollect(_ctx);
}


#pragma mark -
#pragma mark Support

- (void)installBuiltins {
    [self setGlobalObject:[MOMethod methodWithTarget:self selector:@selector(loadFrameworkWithName:)] withName:@"framework"];
    [self setGlobalObject:[MOMethod methodWithTarget:self selector:@selector(print:)] withName:@"print"];
}

- (void)print:(id)o {
    if (!o) {
        printf("null\n");
        return;
    }
    printf("%s\n", [[o description] UTF8String]);
}

@end


#pragma mark -
#pragma mark Global Object

JSValueRef Mocha_getProperty(JSContextRef ctx, JSObjectRef object, JSStringRef propertyNameJS, JSValueRef *exception) {
    NSString *propertyName = (NSString *)CFBridgingRelease(JSStringCopyCFString(kCFAllocatorDefault, propertyNameJS));
    
    if ([propertyName isEqualToString:@"__mocha__"]) {
        return NULL;
    }
    
    MORuntime *runtime = [MORuntime runtimeWithContext:ctx];
    
    // Class
    Class classObject = NSClassFromString(propertyName);
    if (classObject != nil) {
        return [runtime JSValueForObject:classObject];
    }
    
    // Query BridgeSupport for property
    NSArray *types = [NSArray arrayWithObjects:
                      [MOBridgeSupportClass class],
                      [MOBridgeSupportFunction class],
                      [MOBridgeSupportConstant class],
                      [MOBridgeSupportStringConstant class],
                      [MOBridgeSupportEnum class],
                      nil];
    NSDictionary *symbols = [[MOBridgeSupportController sharedController] symbolsWithName:propertyName types:types];
    
    
    // Classes
    MOBridgeSupportClass *aClass = [symbols objectForKey:NSStringFromClass([MOBridgeSupportClass class])];
    if ([aClass isKindOfClass:[MOBridgeSupportClass class]]) {
        Class realClass = NSClassFromString(aClass.name);
        return [runtime JSValueForObject:realClass];
    }
    
    // Functions
    MOBridgeSupportFunction *function = [symbols objectForKey:NSStringFromClass([MOBridgeSupportFunction class])];
    if (function != nil) {
        return [runtime JSValueForObject:function];
    }
    
    // Constants
    MOBridgeSupportConstant *constant = [symbols objectForKey:NSStringFromClass([MOBridgeSupportConstant class])];
    if (constant != nil) {
        NSString *type = nil;
#if __LP64__
        type = [constant type64];
        if (type == nil) {
            type = [constant type];
        }
#else
        type = [constant type];
#endif
        
        // Raise if there is no type
        if (type == nil) {
            NSException *e = [NSException exceptionWithName:MORuntimeException reason:[NSString stringWithFormat:@"No type defined for symbol: %@", constant] userInfo:nil];
            if (exception != NULL) {
                *exception = [runtime JSValueForObject:e];
            }
            return NULL;
        }
        
        // Grab symbol
        void *symbol = dlsym(RTLD_DEFAULT, [propertyName UTF8String]);
        if (!symbol) {
            NSException *e = [NSException exceptionWithName:MORuntimeException reason:[NSString stringWithFormat:@"Symbol not found: %@", constant] userInfo:nil];
            if (exception != NULL) {
                *exception = [runtime JSValueForObject:e];
            }
            return NULL;
        }
        
        char typeEncodingChar = [type UTF8String][0];
        MOFunctionArgument *argument = [[MOFunctionArgument alloc] init];
        
        if (typeEncodingChar == _C_STRUCT_B) {
            [argument setStructureTypeEncoding:type withCustomStorage:symbol];
        }
        else if (typeEncodingChar == _C_PTR) {
            if ([type isEqualToString:@"^{__CFString=}"]) {
                [argument setTypeEncoding:_C_ID withCustomStorage:symbol];
            }
            else {
                [argument setPointerTypeEncoding:type withCustomStorage:symbol];
            }
        }
        else {
            [argument setTypeEncoding:typeEncodingChar withCustomStorage:symbol];
        }
        
        JSValueRef valueJS = [argument getValueAsJSValueInContext:ctx];
        
        return valueJS;
    }
    
    // String constants
    MOBridgeSupportStringConstant *stringConstant = [symbols objectForKey:NSStringFromClass([MOBridgeSupportStringConstant class])];
    if (stringConstant != nil) {
        NSString *value = [stringConstant value];
        return [runtime JSValueForObject:value];
    }
    
    // Enums
    MOBridgeSupportEnum *anEnum = [symbols objectForKey:NSStringFromClass([MOBridgeSupportEnum class])];
    if (anEnum != nil) {
        double doubleValue = 0;
        NSNumber *value = [anEnum value];
#if __LP64__
        NSNumber *value64 = [anEnum value64];
        if (value64 != nil) {
            doubleValue = [value doubleValue];
        }
        else {
#endif
            if (value != nil) {
                doubleValue = [value doubleValue];
            }
            else {
                NSException *e = [NSException exceptionWithName:MORuntimeException reason:[NSString stringWithFormat:@"No value for enum: %@", anEnum] userInfo:nil];
                if (exception != NULL) {
                    *exception = [runtime JSValueForObject:e];
                }
                return NULL;
            }
#if __LP64__
        }
#endif
        return JSValueMakeNumber(ctx, doubleValue);
    }
    
    return NULL;
}


#pragma mark -
#pragma mark Objects

static void MOObject_initialize(JSContextRef ctx, JSObjectRef object) {
    
}

static void MOObject_finalize(JSObjectRef object) {
    MOBox *private = (__bridge MOBox *)(JSObjectGetPrivate(object));
    id o = [private representedObject];
    
    // Remove the object association
    MORuntime *runtime = [private runtime];
    [runtime removeBoxAssociationForObject:o];
    
    JSObjectSetPrivate(object, NULL);
}


#pragma mark -
#pragma mark Boxed Objects

static bool MOObject_hasProperty(JSContextRef ctx, JSObjectRef objectJS, JSStringRef propertyNameJS) {
    NSString *propertyName = (NSString *)CFBridgingRelease(JSStringCopyCFString(NULL, propertyNameJS));
    
//    Mocha *runtime = [Mocha runtimeWithContext:ctx];
    
    id private = (__bridge id)(JSObjectGetPrivate(objectJS));
    id object = [private representedObject];
    Class objectClass = [object class];
    
    // String conversion
    if ([propertyName isEqualToString:@"toString"]) {
        return YES;
    }
    
    // Allocators
    if ([object isKindOfClass:[MOAllocator class]]) {
        objectClass = [object objectClass];
        
        // Method
        SEL selector = MOSelectorFromPropertyName(propertyName);
        NSMethodSignature *methodSignature = [objectClass instanceMethodSignatureForSelector:selector];
        if (!methodSignature) {
            // Allow the trailing underscore to be left off (issue #7)
            selector = MOSelectorFromPropertyName([propertyName stringByAppendingString:@"_"]);
            methodSignature = [objectClass instanceMethodSignatureForSelector:selector];
        }
        if (methodSignature != nil) {
            return YES;
        }
    }
    
    // Property
    objc_property_t property = class_getProperty(objectClass, [propertyName UTF8String]);
    if (property != NULL) {
        SEL selector = NULL;
        char * getterValue = property_copyAttributeValue(property, "G");
        if (getterValue != NULL) {
            selector = NSSelectorFromString([NSString stringWithUTF8String:getterValue]);
            free(getterValue);
        }
        else {
            selector = NSSelectorFromString(propertyName);
        }
        
        if ([object respondsToSelector:selector]) {
            return YES;
        }
    }
    
    // Method
    SEL selector = MOSelectorFromPropertyName(propertyName);
    NSMethodSignature *methodSignature = [object methodSignatureForSelector:selector];
    if (!methodSignature) {
        // Allow the trailing underscore to be left off (issue #7)
        selector = MOSelectorFromPropertyName([propertyName stringByAppendingString:@"_"]);
        methodSignature = [object methodSignatureForSelector:selector];
    }
    if (methodSignature != nil) {
        return YES;
    }
    
    // Indexed subscript
    if ([object respondsToSelector:@selector(objectForIndexedSubscript:)]) {
        NSScanner *scanner = [NSScanner scannerWithString:propertyName];
        NSInteger integerValue;
        if ([scanner scanInteger:&integerValue]) {
            return YES;
        }
    }
    
    // Keyed subscript
    if ([object respondsToSelector:@selector(objectForKeyedSubscript:)]) {
        return YES;
    }
    
    if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSArray class]]) {
        // Special case bridging of NSString & NSArray w/ JS functions
        
        if (MOJSPrototypeFunctionForOBJCInstance(ctx, object, propertyName)) {
            return YES;
        }
        
        if ([object isKindOfClass:[NSArray class]]) {
            // if we're calling length on an NSArray (which will happen from inside JS'a Array.forEach), we need to make sure
            // to catch and do that right.  We could also add a category to NSArray I suppose, but that feels a little dirty.
            if ([propertyName isEqualToString:@"length"]) {
                return YES;
            }
        }
    }
    
    return NO;
}

static JSValueRef MOObject_getProperty(JSContextRef ctx, JSObjectRef objectJS, JSStringRef propertyNameJS, JSValueRef *exception) {
    NSString *propertyName = (NSString *)CFBridgingRelease(JSStringCopyCFString(NULL, propertyNameJS));
    
    MORuntime *runtime = [MORuntime runtimeWithContext:ctx];
    
    id private = (__bridge id)(JSObjectGetPrivate(objectJS));
    id object = [private representedObject];
    Class objectClass = [object class];
    
    // Perform the lookup
    @try {
        // String conversion
        if ([propertyName isEqualToString:@"toString"]) {
            MOMethod *function = [MOMethod methodWithTarget:object selector:@selector(description)];
            return [runtime JSValueForObject:function];
        }
        
        // Allocators
        if ([object isKindOfClass:[MOAllocator class]]) {
            objectClass = [object objectClass];
            
            // Method
            SEL selector = MOSelectorFromPropertyName(propertyName);
            NSMethodSignature *methodSignature = [objectClass instanceMethodSignatureForSelector:selector];
            if (!methodSignature) {
                // Allow the trailing underscore to be left off (issue #7)
                selector = MOSelectorFromPropertyName([propertyName stringByAppendingString:@"_"]);
                methodSignature = [objectClass instanceMethodSignatureForSelector:selector];
            }
            if (methodSignature != nil) {
                MOMethod *function = [MOMethod methodWithTarget:object selector:selector];
                return [runtime JSValueForObject:function];
            }
        }
        
        // Property
        objc_property_t property = class_getProperty(objectClass, [propertyName UTF8String]);
        if (property != NULL) {
            SEL selector = NULL;
            char * getterValue = property_copyAttributeValue(property, "G");
            if (getterValue != NULL) {
                selector = NSSelectorFromString([NSString stringWithUTF8String:getterValue]);
                free(getterValue);
            }
            else {
                selector = NSSelectorFromString(propertyName);
            }
            
            if ([object respondsToSelector:selector]) {
                MOMethod *method = [MOMethod methodWithTarget:object selector:selector];
                JSValueRef value = MOFunctionInvoke(method, ctx, 0, NULL, exception);
                return value;
            }
        }
        
        // Method
        SEL selector = MOSelectorFromPropertyName(propertyName);
        NSMethodSignature *methodSignature = [object methodSignatureForSelector:selector];
        if (!methodSignature) {
            // Allow the trailing underscore to be left off (issue #7)
            selector = MOSelectorFromPropertyName([propertyName stringByAppendingString:@"_"]);
            methodSignature = [object methodSignatureForSelector:selector];
        }
        if (methodSignature != nil) {
            MOMethod *function = [MOMethod methodWithTarget:object selector:selector];
            return [runtime JSValueForObject:function];
        }
        
        // Indexed subscript
        if ([object respondsToSelector:@selector(objectForIndexedSubscript:)]) {
            NSScanner *scanner = [NSScanner scannerWithString:propertyName];
            NSInteger integerValue;
            if ([scanner scanInteger:&integerValue]) {
                id value = [object objectForIndexedSubscript:integerValue];
                if (value != nil) {
                    return [runtime JSValueForObject:value];
                }
            }
        }
        
        // Keyed subscript
        if ([object respondsToSelector:@selector(objectForKeyedSubscript:)]) {
            id value = [object objectForKeyedSubscript:propertyName];
            if (value != nil) {
                return [runtime JSValueForObject:value];
            }
            else {
                return JSValueMakeNull(ctx);
            }
        }
        
        if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSArray class]]) {
            // Special case bridging of NSString & NSArray w/ JS functions
            
            JSValueRef jsPropertyValue = MOJSPrototypeFunctionForOBJCInstance(ctx, object, propertyName);
            if (jsPropertyValue) {
                return jsPropertyValue;
            }
            
            if ([object isKindOfClass:[NSArray class]]) {
                // See the notes in MOObject_hasProperty
                if ([propertyName isEqualToString:@"length"]) {
                    MOMethod *method = [MOMethod methodWithTarget:object selector:@selector(count)];
                    return MOFunctionInvoke(method, ctx, 0, NULL, exception);
                }
            }
        }
        
//        if (exception != NULL) {
//            NSString *reason = nil;
//            if (object == objectClass) {
//                // Class method
//                reason = [NSString stringWithFormat:@"Unrecognized selector sent to class: +[%@ %@]", objectClass, NSStringFromSelector(selector)];
//            }
//            else {
//                // Instance method
//                reason = [NSString stringWithFormat:@"Unrecognized selector sent to instance -[%@ %@]", objectClass, NSStringFromSelector(selector)];
//            }
//            NSException *e = [NSException exceptionWithName:NSInvalidArgumentException reason:reason userInfo:nil];
//            *exception = [runtime JSValueForObject:e];
//        }
//        
//        return NULL;
    }
    @catch (NSException *e) {
        // Catch ObjC exceptions and propogate them up as JS exceptions
        if (exception != NULL) {
            *exception = [runtime JSValueForObject:e];
        }
    }
    
    return NULL;
}

static bool MOObject_setProperty(JSContextRef ctx, JSObjectRef objectJS, JSStringRef propertyNameJS, JSValueRef valueJS, JSValueRef *exception) {
    NSString *propertyName = (NSString *)CFBridgingRelease(JSStringCopyCFString(NULL, propertyNameJS));
    
    MORuntime *runtime = [MORuntime runtimeWithContext:ctx];
    
    id private = (__bridge id)(JSObjectGetPrivate(objectJS));
    id object = [private representedObject];
    Class objectClass = [object class];
    id value = [runtime objectForJSValue:valueJS];
    
    // Perform the lookup
    @try {
        // Property
        objc_property_t property = class_getProperty(objectClass, [propertyName UTF8String]);
        if (property != NULL) {
            SEL selector = NULL;
            char * setterValue = property_copyAttributeValue(property, "S");
            if (setterValue != NULL) {
                selector = NSSelectorFromString([NSString stringWithUTF8String:setterValue]);
                free(setterValue);
            }
            else {
                NSString *setterName = MOPropertyNameToSetterName(propertyName);
                selector = MOSelectorFromPropertyName(setterName);
            }
            
            if ([object respondsToSelector:selector]) {
                MOMethod *method = [MOMethod methodWithTarget:object selector:selector];
                MOFunctionInvoke(method, ctx, 1, &valueJS, exception);
                return YES;
            }
        }
        
        // Indexed subscript
        if ([object respondsToSelector:@selector(setObject:forIndexedSubscript:)]) {
            NSScanner *scanner = [NSScanner scannerWithString:propertyName];
            NSInteger integerValue;
            if ([scanner scanInteger:&integerValue]) {
                [object setObject:value forIndexedSubscript:integerValue];
                return YES;
            }
        }
        
        // Keyed subscript
        if ([object respondsToSelector:@selector(objectForKeyedSubscript:)]) {
            [object setObject:value forKeyedSubscript:propertyName];
            return YES;
        }
    }
    @catch (NSException *e) {
        // Catch ObjC exceptions and propogate them up as JS exceptions
        if (exception != NULL) {
            *exception = [runtime JSValueForObject:e];
        }
    }
    
    return NO;
}

static bool MOObject_deleteProperty(JSContextRef ctx, JSObjectRef objectJS, JSStringRef propertyNameJS, JSValueRef *exception) {
    NSString *propertyName = (NSString *)CFBridgingRelease(JSStringCopyCFString(NULL, propertyNameJS));
    
    MORuntime *runtime = [MORuntime runtimeWithContext:ctx];
    
    id private = (__bridge id)(JSObjectGetPrivate(objectJS));
    id object = [private representedObject];
    
    // Perform the lookup
    @try {
        // Indexed subscript
        if ([object respondsToSelector:@selector(setObject:forIndexedSubscript:)]) {
            NSScanner *scanner = [NSScanner scannerWithString:propertyName];
            NSInteger integerValue;
            if ([scanner scanInteger:&integerValue]) {
                [object setObject:nil forIndexedSubscript:integerValue];
                return YES;
            }
        }
        
        // Keyed subscript
        if ([object respondsToSelector:@selector(objectForKeyedSubscript:)]) {
            [object setObject:nil forKeyedSubscript:propertyName];
            return YES;
        }
    }
    @catch (NSException *e) {
        // Catch ObjC exceptions and propogate them up as JS exceptions
        if (exception != NULL) {
            *exception = [runtime JSValueForObject:e];
        }
    }
    
    return NO;
}

static void MOObject_getPropertyNames(JSContextRef ctx, JSObjectRef object, JSPropertyNameAccumulatorRef propertyNames) {
    MOBox *privateObject = (__bridge MOBox *)(JSObjectGetPrivate(object));
    
    // If we have a dictionary, add keys from allKeys
    id o = [privateObject representedObject];
    
    if ([o isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = o;
        NSArray *keys = [dictionary allKeys];
        
        for (NSString *key in keys) {
            JSStringRef jsString = JSStringCreateWithUTF8CString([key UTF8String]);
            JSPropertyNameAccumulatorAddName(propertyNames, jsString);
            JSStringRelease(jsString);
        }
    }
}

static JSValueRef MOObject_convertToType(JSContextRef ctx, JSObjectRef object, JSType type, JSValueRef *exception) {
    return MOJSValueToType(ctx, object, type, exception);
}

static bool MOObject_hasInstance(JSContextRef ctx, JSObjectRef constructor, JSValueRef possibleInstance, JSValueRef *exception) {
    MORuntime *runtime = [MORuntime runtimeWithContext:ctx];
    MOBox *privateObject = (__bridge MOBox *)(JSObjectGetPrivate(constructor));
    id representedObject = [privateObject representedObject];
    
    if (!JSValueIsObject(ctx, possibleInstance)) {
        return false;
    }
    
    JSObjectRef instanceObj = JSValueToObject(ctx, possibleInstance, exception);
    if (instanceObj == nil) {
        return NO;
    }
    MOBox *instancePrivateObj = (__bridge MOBox *)(JSObjectGetPrivate(instanceObj));
    id instanceRepresentedObj = [instancePrivateObj representedObject];
    
    // Check to see if the object's class matches the passed-in class
    @try {
        if (representedObject == [instanceRepresentedObj class]) {
            return true;
        }
    }
    @catch (NSException *e) {
        // Catch ObjC exceptions and propogate them up as JS exceptions
        if (exception != nil) {
            *exception = [runtime JSValueForObject:e];
        }
    }
    
    return false;
}


#pragma mark -
#pragma mark Constructors

static JSObjectRef MOConstructor_callAsConstructor(JSContextRef ctx, JSObjectRef object, size_t argumentsCount, const JSValueRef arguments[], JSValueRef *exception) {
    return NULL;
}


#pragma mark -
#pragma mark Functions

static JSValueRef MOFunction_callAsFunction(JSContextRef ctx, JSObjectRef functionJS, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef *exception) {
    MORuntime *runtime = [MORuntime runtimeWithContext:ctx];
    MOBox *private = (__bridge MOBox *)(JSObjectGetPrivate(functionJS));
    id function = [private representedObject];
    JSValueRef value = NULL;
    
    // Perform the invocation
    @try {
        value = MOFunctionInvoke(function, ctx, argumentCount, arguments, exception);
    }
    @catch (NSException *e) {
        // Catch ObjC exceptions and propogate them up as JS exceptions
        if (exception != nil) {
            *exception = [runtime JSValueForObject:e];
        }
    }
    
    return value;
}

static JSValueRef MOJSPrototypeFunctionForOBJCInstance(JSContextRef ctx, id instance, NSString *name) {
    char *propName = nil;
    if ([instance isKindOfClass:[NSString class]]) {
        propName = "String";
    }
    else if ([instance isKindOfClass:[NSArray class]]) {
        propName = "Array";
    }
    
    if (!propName) {
        return NO;
    }
    
    JSValueRef exception = nil;
    JSStringRef jsPropertyName = JSStringCreateWithUTF8CString(propName);
    JSValueRef jsPropertyValue = JSObjectGetProperty(ctx, JSContextGetGlobalObject(ctx), jsPropertyName, &exception);
    JSStringRelease(jsPropertyName);
    
    jsPropertyName = JSStringCreateWithUTF8CString("prototype");
    jsPropertyValue = JSObjectGetProperty(ctx, JSValueToObject(ctx, jsPropertyValue, nil), jsPropertyName, &exception);
    JSStringRelease(jsPropertyName);
    
    jsPropertyName = JSStringCreateWithUTF8CString([name UTF8String]);
    jsPropertyValue = JSObjectGetProperty(ctx, JSValueToObject(ctx, jsPropertyValue, nil), jsPropertyName, &exception);
    JSStringRelease(jsPropertyName);
    
    if (jsPropertyValue && JSValueGetType(ctx, jsPropertyValue) == kJSTypeObject) {
        // OK, there's a JS String method with the same name as propertyName.  Let's use that.
        return jsPropertyValue;
    }
    
    return nil;
}

