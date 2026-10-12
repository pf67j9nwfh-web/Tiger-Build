/* Shared by the host tests (not by commanderfull.m, which is copied alone to the old Macs): a pass/fail line per check and a count of failures. */
#import <Foundation/Foundation.h>

static int failures = 0;
static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}
