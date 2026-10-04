/* One source for Mac OS X 10.4 through 10.6, 32-bit and 64-bit.
   The 10.4 SDK has no NSInteger, NSUInteger or CGFloat. Newer SDKs do, and
   on 64-bit they are wider than int and float, so any method that overrides
   or implements a Cocoa delegate method must use these types. */
#ifndef TBCOMPAT_H
#define TBCOMPAT_H

#import <Foundation/Foundation.h>
#import <limits.h>

#ifndef NSINTEGER_DEFINED
typedef int NSInteger;
typedef unsigned int NSUInteger;
#define NSIntegerMax INT_MAX
#define NSIntegerMin INT_MIN
#define NSUIntegerMax UINT_MAX
#define NSINTEGER_DEFINED 1
#endif

/* The 10.6 SDK declares delegates as formal protocols and warns when a class
   uses one without saying so. Older SDKs have none, so the list is empty there. */
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1060
#define TB_PROTOCOLS(...) <__VA_ARGS__>
#else
#define TB_PROTOCOLS(...)
#endif

#ifndef CGFLOAT_DEFINED
typedef float CGFloat;
#define CGFLOAT_DEFINED 1
#endif

/* The video player is QuickTime's QTKit. It has no 64-bit PowerPC version, and
   64-bit Intel only has one from Snow Leopard (10.6) on. The 32-bit slices
   always play inline. The x86_64 slice is built with the 10.6 SDK (and
   TB_QTKIT64) where that is installed, links QTKit weakly, and plays inline
   only when the running system is 10.6 or later. Other 64-bit builds open
   videos in the default player. */
#if defined(__LP64__) && !defined(TB_QTKIT64)
#define TB_INLINE_VIDEO 0
#else
#define TB_INLINE_VIDEO 1
#endif

/* The running system's minor version: 4 for Tiger, 5 for Leopard, 6 for Snow
   Leopard. Read from the system, not assumed. */
int TBSystemMinor(void);

/* Whether this process can show videos in the chat: always in a 32-bit
   slice, on 10.6 or later in a 64-bit one. */
int TBInlineVideoAvailable(void);

#endif
