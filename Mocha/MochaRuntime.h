//
//  MochaRuntime.h
//  Mocha
//
//  Created by Logan Collins on 5/10/12.
//  Copyright (c) 2012 Sunflower Softworks. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <Mocha/MochaDefines.h>


@protocol MochaDelegate;


/*!
 * @class Mocha
 * @abstract The Mocha runtime interface
 */
@interface Mocha : NSObject

/*!
 * @method sharedRuntime
 * @abstract The shared runtime instance
 * 
 * @discussion
 * Additional runtimes can be created by calling -init or -initWithGlobalContext:
 * 
 * @result A Mocha object
 */
+ (Mocha *)sharedRuntime;

/*!
 * @method initWithGlobalContext:
 * @abstract Creates a new runtime
 * 
 * @param ctx
 * The JSGlobalContext on which to base the runtime
 * 
 * @result A Mocha object
 */
- (id)initWithGlobalContext:(JSGlobalContextRef)ctx;


/*!
 * @property context
 * @abstract Gets the JSGlobalContext backing the runtime
 * 
 * @result A JSGlobalContextRef value
 */
@property (readonly) JSGlobalContextRef context;

/*!
 * @property delegate
 * @abstract Gets the runtime delegate
 * 
 * @result An object conforming to the MochaDelegate protocol
 */
@property (assign) id <MochaDelegate> delegate;


/*!
 * @method evalString:
 * @abstract Evalutates the specified JavaScript expression, returning the result
 * 
 * @param string
 * The JavaScript expression to evaluate
 * 
 * @result An object, or nil
 */
- (id)evalString:(NSString *)string;


/*!
 * @method callFunctionWithName:
 * @abstract Calls a JavaScript function in the global context
 * 
 * @param functionName
 * The name of the function
 * 
 * @result An object, or nil
 */
- (id)callFunctionWithName:(NSString *)functionName;

/*!
 * @method callFunctionWithName:withArguments:
 * @abstract Calls a JavaScript function in the global context
 * 
 * @param functionName
 * The name of the function
 * 
 * @param firstArg
 * A variable-length list of arguments to pass to the function
 * 
 * @result An object, or nil
 */
- (id)callFunctionWithName:(NSString *)functionName withArguments:(id)firstArg, ... NS_REQUIRES_NIL_TERMINATION;

/*!
 * @method callFunctionWithName:withArgumentsInArray:
 * @abstract Calls a JavaScript function in the global context
 * 
 * @param functionName
 * The name of the function
 * 
 * @param arguments
 * An array of arguments to pass to the function
 * 
 * @result An object, or nil
 */
- (id)callFunctionWithName:(NSString *)functionName withArgumentsInArray:(NSArray *)arguments;


/*!
 * @method isSyntaxValidForString:
 * @abstract Validates the syntax of a JavaScript expression
 * 
 * @param string
 * The JavaScript expression to validate
 * 
 * @result A BOOL value
 */
- (BOOL)isSyntaxValidForString:(NSString *)string;


/*!
 * @method loadFrameworkWithName:
 * @abstract Loads BridgeSupport info and symbols a specified framework
 * 
 * @param frameworkName
 * The name of the framework to load
 * 
 * @discussion
 * This method will attempt to load BridgeSupport info and symbols for the
 * framework via dyld. If the framework cannot be found, or fails to load,
 * this method returns NO.
 * 
 * @result A BOOL value
 */
- (BOOL)loadFrameworkWithName:(NSString *)frameworkName;

/*!
 * @method loadFrameworkWithName:inDirectory:
 * @abstract Loads BridgeSupport info and symbols a specified framework
 * 
 * @param frameworkName
 * The name of the framework to load
 * 
 * @param directory
 * The directory in which to look for the framework
 * 
 * @discussion
 * This method will attempt to load BridgeSupport info and symbols for the
 * framework via dyld. If the framework cannot be found, or fails to load,
 * this method returns NO.
 * 
 * @result A BOOL value
 */
- (BOOL)loadFrameworkWithName:(NSString *)frameworkName inDirectory:(NSString *)directory;


/*!
 * @method garbageCollect
 * @abstract Instructs the JavaScript garbage collector to perform a collection
 */
- (void)garbageCollect;

@end


/*!
 * @protocol MochaDelegate
 * @abstract Implemented by objects acting as a runtime delegate
 */
@protocol MochaDelegate <NSObject>

@optional

@end


/*!
 * @category NSObject(MochaScripting)
 * @abstract Methods for customizing object behavior within the runtime
 */
@interface NSObject (MochaScripting)

/*!
 * @method isSelectorExcludedFromMochaScript:
 * @abstract Whether the specified selector is excluded from runtime access
 * 
 * @param selector
 * The selector to optionally exclude
 * 
 * @discussion
 * By default, this method returns NO, enabling access to all selectors for
 * an object. Returning YES from this method will prevent the given selector
 * from being called by the runtime.
 * 
 * @result A BOOL value
 */
+ (BOOL)isSelectorExcludedFromMochaScript:(SEL)selector;

/*!
 * @method finalizeForMochaScript
 * @abstract Invoked before the object is dereferenced in the runtime
 * 
 * @discussion
 * This method allows objects to clear internal caches and data tied to
 * other runtime information in preparation for being remove from the runtime.
 */
- (void)finalizeForMochaScript;

@end


/*!
 * @category NSObject(MochaObjectSubscripting)
 * @abstract Methods for enabling object subscripting within the runtime
 */
@interface NSObject (MochaObjectSubscripting)

/*!
 * @method objectForIndexedSubscript:
 * @abstract Gets the object for a given index
 * 
 * @param idx
 * The index for which to get an object
 * 
 * @result An object
 */
- (id)objectForIndexedSubscript:(NSUInteger)idx;

/*!
 * @method setObject:forIndexedSubscript:
 * @abstract Sets the object for a given index
 * 
 * @param obj
 * The object value to set
 * 
 * @param idx
 * The index for which to get an object
 */
- (void)setObject:(id)obj forIndexedSubscript:(NSUInteger)idx;


/*!
 * @method objectForKeyedSubscript:
 * @abstract Gets the object for a given key
 * 
 * @param key
 * The key for which to get an object
 * 
 * @result An object
 */
- (id)objectForKeyedSubscript:(NSString *)key;

/*!
 * @method setObject:forKeyedSubscript:
 * @abstract Sets the object for a given key
 * 
 * @param obj
 * The object value to set
 * 
 * @param key
 * The key for which to get an object
 */
- (void)setObject:(id)obj forKeyedSubscript:(NSString *)key;

@end


/*!
 * @constant MORuntimeException
 * @abstract The name of exceptions raised within the runtime's internal implementation
 */
MOCHA_EXTERN NSString * const MORuntimeException;

/*!
 * @constant MOJavaScriptException
 * @abstract The name of exceptions raised within JavaScript code
 */
MOCHA_EXTERN NSString * const MOJavaScriptException;

