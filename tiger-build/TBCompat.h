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

#ifndef CGFLOAT_DEFINED
typedef float CGFloat;
#define CGFLOAT_DEFINED 1
#endif

/* The video player is QuickTime's QTKit, which has no 64-bit PowerPC version
   and is missing from 64-bit Intel on 10.5. 64-bit builds open videos in the
   default player instead. */
#if defined(__LP64__)
#define TB_INLINE_VIDEO 0
#else
#define TB_INLINE_VIDEO 1
#endif

/* The running system's minor version: 4 for Tiger, 5 for Leopard, 6 for Snow
   Leopard. Read from the system, not assumed. */
int TBSystemMinor(void);

#endif
