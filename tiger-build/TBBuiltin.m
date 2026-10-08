#import "TBBuiltin.h"
#import "TBEngine.h"
#import "TBJSON.h"
#import "TBHTTP.h"
#import <sys/param.h>
#import <sys/mount.h>
#import <sys/utsname.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <dlfcn.h>
#import <ApplicationServices/ApplicationServices.h>
#import <math.h>
#import <time.h>
#import "mbedtls/sha256.h"

static NSDictionary *prop(NSString *type)
{
    return [NSDictionary dictionaryWithObject:type forKey:@"type"];
}

static NSDictionary *tool(NSString *name, NSString *description, NSArray *names, NSArray *types, NSArray *required)
{
    NSMutableDictionary *props = [NSMutableDictionary dictionary];
    unsigned i;
    for (i = 0; i < [names count]; i++)
        [props setObject:prop([types objectAtIndex:i]) forKey:[names objectAtIndex:i]];
    return [NSDictionary dictionaryWithObjectsAndKeys:name, @"name", description, @"description",
        [NSDictionary dictionaryWithObjectsAndKeys:@"object", @"type", props, @"properties", required, @"required", nil], @"inputSchema", nil];
}

/* ---- calculator ---- */

typedef struct {
    const char *p;
    BOOL integer;      /* every number so far is whole, and no division made a fraction */
    int depth;
} Parser;

static void badExpression(void)
{
    TBFail(@"only numbers, + - * / ** %% //, pi, e and sqrt/sin/cos/tan/log/log10/abs/round/floor/ceil are allowed");
}

static void skip(Parser *s)
{
    while (*s->p == ' ' || *s->p == '\t')
        s->p++;
}

static double sum(Parser *s);

static double atom(Parser *s)
{
    double v;
    skip(s);
    if (++s->depth > 60)
        TBFail(@"expression is nested too deeply");
    if (*s->p == '(') {
        s->p++;
        v = sum(s);
        skip(s);
        if (*s->p != ')')
            badExpression();
        s->p++;
    } else if ((*s->p >= '0' && *s->p <= '9') || *s->p == '.') {
        char *end;
        const char *start = s->p;
        v = strtod(s->p, &end);
        if (end == s->p)
            badExpression();
        {
            const char *q;
            for (q = start; q < end; q++)
                if (*q == '.' || *q == 'e' || *q == 'E')
                    s->integer = NO;
        }
        s->p = end;
    } else if ((*s->p >= 'a' && *s->p <= 'z') || (*s->p >= 'A' && *s->p <= 'Z')) {
        char name[16];
        int n = 0;
        while (((*s->p >= 'a' && *s->p <= 'z') || (*s->p >= 'A' && *s->p <= 'Z') || (*s->p >= '0' && *s->p <= '9')) && n < 15)
            name[n++] = *s->p++;
        name[n] = 0;
        skip(s);
        if (!strcmp(name, "pi")) { v = M_PI; s->integer = NO; }
        else if (!strcmp(name, "e")) { v = M_E; s->integer = NO; }
        else if (*s->p == '(') {
            double x;
            s->p++;
            x = sum(s);
            skip(s);
            if (*s->p != ')')
                badExpression();
            s->p++;
            if (!strcmp(name, "sqrt")) { if (x < 0) TBFail(@"math domain error"); v = sqrt(x); s->integer = NO; }
            else if (!strcmp(name, "sin")) { v = sin(x); s->integer = NO; }
            else if (!strcmp(name, "cos")) { v = cos(x); s->integer = NO; }
            else if (!strcmp(name, "tan")) { v = tan(x); s->integer = NO; }
            else if (!strcmp(name, "log")) { if (x <= 0) TBFail(@"math domain error"); v = log(x); s->integer = NO; }
            else if (!strcmp(name, "log10")) { if (x <= 0) TBFail(@"math domain error"); v = log10(x); s->integer = NO; }
            else if (!strcmp(name, "abs")) v = fabs(x);
            else if (!strcmp(name, "round")) v = rint(x);
            else if (!strcmp(name, "floor")) v = floor(x);
            else if (!strcmp(name, "ceil")) v = ceil(x);
            else { badExpression(); v = 0; }
        } else {
            badExpression();
            v = 0;
        }
    } else {
        badExpression();
        v = 0;
    }
    s->depth--;
    return v;
}

static double unary(Parser *s);

/* ** binds tighter than a minus sign on its left and is right associative: -2**2 is -4, 2**-1 is 0.5 */
static double power(Parser *s)
{
    double base = atom(s), exponent;
    skip(s);
    if (s->p[0] == '*' && s->p[1] == '*') {
        s->p += 2;
        exponent = unary(s);
        if (fabs(exponent) > 1000)
            TBFail(@"exponent too large");
        if (exponent < 0)
            s->integer = NO;
        if (base == 0 && exponent < 0)
            TBFail(@"0.0 cannot be raised to a negative power");
        return pow(base, exponent);
    }
    return base;
}

static double unary(Parser *s)
{
    skip(s);
    if (*s->p == '-') {
        s->p++;
        return -unary(s);
    }
    if (*s->p == '+') {
        s->p++;
        return unary(s);
    }
    return power(s);
}

static double product(Parser *s)
{
    double v = unary(s);
    for (;;) {
        skip(s);
        if (s->p[0] == '*' && s->p[1] != '*') {
            s->p++;
            v *= unary(s);
        } else if (s->p[0] == '/' && s->p[1] == '/') {
            double r;
            s->p += 2;
            r = unary(s);
            if (r == 0)
                TBFail(@"division by zero");
            v = floor(v / r);
        } else if (s->p[0] == '/') {
            double r;
            s->p++;
            r = unary(s);
            if (r == 0)
                TBFail(@"division by zero");
            if (fmod(v, r) != 0)
                s->integer = NO;
            v /= r;
            s->integer = NO; /* Python's / always gives a float */
        } else if (s->p[0] == '%') {
            double r;
            s->p++;
            r = unary(s);
            if (r == 0)
                TBFail(@"modulo by zero");
            v = v - floor(v / r) * r;
        } else
            return v;
    }
}

static double sum(Parser *s)
{
    double v = product(s);
    for (;;) {
        skip(s);
        if (*s->p == '+') {
            s->p++;
            v += product(s);
        } else if (*s->p == '-') {
            s->p++;
            v -= product(s);
        } else
            return v;
    }
}

/* the shortest text that reads back as the same number, as Python prints it */
static NSString *shortest(double v)
{
    char buffer[40];
    int digits;
    for (digits = 1; digits <= 17; digits++) {
        snprintf(buffer, sizeof buffer, "%.*g", digits, v);
        if (strtod(buffer, NULL) == v)
            break;
    }
    if (!strchr(buffer, '.') && !strchr(buffer, 'e') && !strchr(buffer, 'n') && !strchr(buffer, 'i'))
        strcat(buffer, ".0");
    return [NSString stringWithUTF8String:buffer];
}

/* ---- unit conversion ---- */

static double unitFactor(NSString *u, NSDictionary *table)
{
    NSNumber *n = [table objectForKey:u];
    return n ? [n doubleValue] : 0;
}

static NSString *convert(NSDictionary *args)
{
    double value = [TBValue(args, @"value") doubleValue];
    NSString *from = TBString(args, @"from"), *to = TBString(args, @"to");
    NSDictionary *length = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithDouble:1.0], @"m", [NSNumber numberWithDouble:1000.0], @"km", [NSNumber numberWithDouble:0.01], @"cm",
        [NSNumber numberWithDouble:0.001], @"mm", [NSNumber numberWithDouble:0.0254], @"in", [NSNumber numberWithDouble:0.3048], @"ft", [NSNumber numberWithDouble:0.9144], @"yd",
        [NSNumber numberWithDouble:1609.344], @"mi", nil];
    NSDictionary *mass = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithDouble:1.0], @"kg", [NSNumber numberWithDouble:0.001], @"g", [NSNumber numberWithDouble:0.45359237], @"lb",
        [NSNumber numberWithDouble:0.028349523125], @"oz", nil];
    NSArray *tables = [NSArray arrayWithObjects:length, mass, nil];
    unsigned i;
    NSString *f = [from lowercaseString], *t = [to lowercaseString];
    for (i = 0; i < [tables count]; i++) {
        NSDictionary *table = [tables objectAtIndex:i];
        if (unitFactor(from, table) && unitFactor(to, table))
            return [NSString stringWithFormat:@"%g %@ = %g %@", value, from, value * unitFactor(from, table) / unitFactor(to, table), to];
    }
    if (([f isEqualToString:@"c"] || [f isEqualToString:@"f"] || [f isEqualToString:@"k"]) && ([t isEqualToString:@"c"] || [t isEqualToString:@"f"] || [t isEqualToString:@"k"])) {
        double c = [f isEqualToString:@"c"] ? value : ([f isEqualToString:@"f"] ? (value - 32) * 5 / 9 : value - 273.15);
        double out = [t isEqualToString:@"c"] ? c : ([t isEqualToString:@"f"] ? c * 9 / 5 + 32 : c + 273.15);
        return [NSString stringWithFormat:@"%g %@ = %g %@", value, from, out, to];
    }
    TBFail(@"cannot convert %@ to %@", from, to);
    return nil;
}

/* ---- notes ---- */

static NSString *notesPath(void)
{
    NSString *over = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBNotesFile"];
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build"];
    if ([over length])
        return over;
    [[NSFileManager defaultManager] createDirectoryAtPath:[folder stringByDeletingLastPathComponent] attributes:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder attributes:nil];
    return [folder stringByAppendingPathComponent:@"notes-data.json"];
}

static NSMutableDictionary *loadNotes(void)
{
    NSData *data = [NSData dataWithContentsOfFile:notesPath()];
    id json = data ? TBJSONParse(data, NULL) : nil;
    return [json isKindOfClass:[NSDictionary class]] ? [NSMutableDictionary dictionaryWithDictionary:json] : [NSMutableDictionary dictionary];
}

static void saveNotes(NSDictionary *notes)
{
    if (![TBJSONData(notes) writeToFile:notesPath() atomically:YES])
        TBFail(@"The notes could not be saved.");
}

/* ---- weather ---- */

static NSString *firstValue(id item, NSString *key)
{
    NSArray *list = TBArray(item, key);
    return [list count] ? TBString([list objectAtIndex:0], @"value") : @"";
}

static NSString *whereText(id data)
{
    NSArray *areas = TBArray(data, @"nearest_area");
    NSMutableArray *parts = [NSMutableArray array];
    NSArray *keys = [NSArray arrayWithObjects:@"areaName", @"region", @"country", nil];
    unsigned i;
    if (![areas count])
        return @"";
    for (i = 0; i < [keys count]; i++) {
        NSString *v = firstValue([areas objectAtIndex:0], [keys objectAtIndex:i]);
        if ([v length])
            [parts addObject:v];
    }
    return [parts componentsJoinedByString:@", "];
}

static NSString *words(id item)
{
    return TBTrim(firstValue(item, @"weatherDesc"));
}

static NSString *encodePlace(NSString *place)
{
    NSMutableString *out = [NSMutableString string];
    NSData *bytes = [place dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *b = [bytes bytes];
    unsigned i;
    for (i = 0; i < [bytes length]; i++) {
        unsigned char c = b[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~')
            [out appendFormat:@"%c", c];
        else
            [out appendFormat:@"%%%02X", c];
    }
    return out;
}

static id weatherData(NSDictionary *args, TBRun *run)
{
    NSString *place = TBTrim(TBString(args, @"place"));
    NSString *base = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBBaseURL.wttr"];
    TBHTTP *http;
    int result;
    id data;
    if (![place length])
        TBFail(@"Give a place, such as Chicago, 60601 or Paris,France.");
    http = [TBHTTP request:@"GET" url:[NSString stringWithFormat:@"%@/%@?format=j1", [base length] ? base : @"https://wttr.in", encodePlace(place)]];
    [http setHeader:@"User-Agent" value:@"curl/8.0"];
    [http setIdleTimeout:25];
    [run attach:http];
    result = [http perform];
    [run detach:http];
    [run check];
    if (result != TBNET_OK || [http status] < 200 || [http status] >= 300)
        TBFail(@"could not get the weather for '%@': %@", place, result != TBNET_OK ? [http error] : [NSString stringWithFormat:@"HTTP %d", [http status]]);
    data = TBJSONParse([http data], NULL);
    if (![TBArray(data, @"current_condition") count])
        TBFail(@"wttr.in did not return a forecast for '%@'.", place);
    return data;
}

static NSString *degrees(void)
{
    return [NSString stringWithFormat:@"%C", (unichar)0xb0];
}

static long cpuCount(void)
{
    int n = 0;
    size_t size = sizeof n;
    return sysctlbyname("hw.ncpu", &n, &size, NULL, 0) == 0 ? n : 1;
}

/* ---- the servers ---- */

/* The displays, read through CoreGraphics. Newer calls are looked up when the program runs so the same code works from Tiger on. */
static NSString *displayReport(void)
{
    CGDirectDisplayID ids[16];
    CGDisplayCount count = 0, i;
    NSMutableString *out = [NSMutableString string];
    void *cg = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
    CFDictionaryRef (*currentMode)(CGDirectDisplayID) = cg ? (CFDictionaryRef (*)(CGDirectDisplayID))dlsym(cg, "CGDisplayCurrentMode") : NULL;
    double (*rotation)(CGDirectDisplayID) = cg ? (double (*)(CGDirectDisplayID))dlsym(cg, "CGDisplayRotation") : NULL;
    CGSize (*screenSize)(CGDirectDisplayID) = cg ? (CGSize (*)(CGDirectDisplayID))dlsym(cg, "CGDisplayScreenSize") : NULL;
    if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess || !count)
        return @"No display is reported (no one may be logged in at the console).";
    [out appendFormat:@"displays: %u\n", (unsigned)count];
    for (i = 0; i < count; i++) {
        CGDirectDisplayID d = ids[i];
        CGRect b = CGDisplayBounds(d);
        size_t w = CGDisplayPixelsWide(d), h = CGDisplayPixelsHigh(d);
        NSMutableString *line = [NSMutableString stringWithFormat:@"display %u%@%@: %lu x %lu pixels", (unsigned)(i + 1), CGDisplayIsMain(d) ? @" (main)" : @"",
            CGDisplayIsBuiltin(d) ? @" (built in)" : @"", (unsigned long)w, (unsigned long)h];
        if (currentMode) {
            CFDictionaryRef mode = currentMode(d);
            CFNumberRef depth = mode ? CFDictionaryGetValue(mode, CFSTR("BitsPerPixel")) : NULL, rate = mode ? CFDictionaryGetValue(mode, CFSTR("RefreshRate")) : NULL;
            int bits = 0;
            double hz = 0;
            if (depth) CFNumberGetValue(depth, kCFNumberIntType, &bits);
            if (rate) CFNumberGetValue(rate, kCFNumberDoubleType, &hz);
            if (bits) [line appendFormat:@", %d-bit colour", bits];
            if (hz > 0) [line appendFormat:@", %.0f Hz", hz];
            else [line appendString:@", refresh rate not reported (usual for flat panels)"];
        }
        [line appendFormat:@", at (%.0f, %.0f)", b.origin.x, b.origin.y];
        if (screenSize) {
            CGSize mm = screenSize(d);
            if (mm.width > 1 && mm.height > 1) {
                double diag = sqrt(mm.width * mm.width + mm.height * mm.height) / 25.4;
                [line appendFormat:@", %.0f x %.0f mm (about %.1f inch diagonal, %.0f pixels per inch)", mm.width, mm.height, diag, w / (mm.width / 25.4)];
            } else
                [line appendString:@", physical size not reported"];
        }
        if (rotation && rotation(d) != 0)
            [line appendFormat:@", rotated %.0f degrees", rotation(d)];
        if (CGDisplayIsInMirrorSet(d))
            [line appendString:@", mirrored"];
        [out appendFormat:@"%@\n", line];
    }
    return out;
}

/* ---- currency (Frankfurter, with open.er-api.com as the second source) and US inflation (BLS CPI-U) ---- */

static NSData *fetchURL(NSString *url, TBRun *run, int *status)
{
    TBHTTP *http = [TBHTTP request:@"GET" url:url];
    int result;
    NSData *data;
    [http setHeader:@"User-Agent" value:@"TigerBuild/2.2"];
    [http setIdleTimeout:25];
    [run attach:http];
    result = [http perform];
    [run detach:http];
    [run check];
    *status = result == TBNET_OK ? [http status] : 0;
    data = result == TBNET_OK ? [http data] : nil;
    return data;
}

static NSString *rateText(double v)
{
    char text[40];
    snprintf(text, sizeof text, v >= 100 ? "%.2f" : (v >= 1 ? "%.4f" : "%.6g"), v);
    return [NSString stringWithUTF8String:text];
}

static NSString *currencyCode(NSDictionary *args, NSString *key)
{
    NSString *code = [TBTrim(TBString(args, key)) uppercaseString];
    unsigned i;
    if ([code length] != 3)
        TBFail(@"Give %@ as a three-letter currency code such as USD, EUR or JPY.", key);
    for (i = 0; i < 3; i++) {
        unichar c = [code characterAtIndex:i];
        if (c < 'A' || c > 'Z')
            TBFail(@"Give %@ as a three-letter currency code such as USD, EUR or JPY.", key);
    }
    return code;
}

static NSString *convertCurrency(NSDictionary *args, TBRun *run)
{
    NSString *from = currencyCode(args, @"from"), *to = currencyCode(args, @"to"), *date = TBTrim(TBString(args, @"date")), *root, *path;
    double amount = [TBValue(args, @"amount") isKindOfClass:[NSNumber class]] ? [TBValue(args, @"amount") doubleValue] : 1, rate = 0;
    int status = 0;
    NSData *data;
    id json;
    NSString *when = @"latest";
    NSString *baseURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBBaseURL.frankfurter"];
    root = [baseURL length] ? baseURL : @"https://api.frankfurter.dev";
    if ([date length] && ([date length] != 10 || [date characterAtIndex:4] != '-' || [date characterAtIndex:7] != '-'))
        TBFail(@"Give the date as YYYY-MM-DD, or leave it out for today's rate.");
    if (amount < 0 || amount > 1e15)
        TBFail(@"That amount is not usable.");
    if ([from isEqualToString:to])
        return [NSString stringWithFormat:@"%@ %@ = %@ %@ (same currency)", rateText(amount), from, rateText(amount), to];
    path = [NSString stringWithFormat:@"%@/v1/%@?base=%@&symbols=%@", root, [date length] ? date : @"latest", from, to];
    data = fetchURL(path, run, &status);
    json = status == 200 ? TBJSONParse(data, NULL) : nil;
    if ([TBDictionary(json, @"rates") objectForKey:to]) {
        rate = [[TBDictionary(json, @"rates") objectForKey:to] doubleValue];
        when = TBString(json, @"date");
    } else if (status == 404 || status == 422)
        TBFail(@"%@ or %@ is not a currency this source knows, or there is no rate for %@. list_currencies shows the ones it has.", from, to, [date length] ? date : @"today");
    else if (![date length]) {
        /* the second source: today's rates from another service */
        NSString *second = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBBaseURL.er-api"];
        data = fetchURL([NSString stringWithFormat:@"%@/v6/latest/%@", [second length] ? second : @"https://open.er-api.com", from], run, &status);
        json = status == 200 ? TBJSONParse(data, NULL) : nil;
        if ([TBDictionary(json, @"rates") objectForKey:to]) {
            rate = [[TBDictionary(json, @"rates") objectForKey:to] doubleValue];
            when = [TBString(json, @"time_last_update_utc") length] ? TBString(json, @"time_last_update_utc") : @"latest (open.er-api.com)";
        }
    }
    if (rate <= 0)
        TBFail(@"No exchange rate service answered. Try again in a moment.");
    return [NSString stringWithFormat:@"%@ %@ = %@ %@  (1 %@ = %@ %@, rate of %@)", rateText(amount), from, rateText(amount * rate), to, from, rateText(rate), to, when];
}

static NSString *listCurrencies(TBRun *run)
{
    NSString *baseURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBBaseURL.frankfurter"];
    int status = 0;
    NSData *data = fetchURL([NSString stringWithFormat:@"%@/v1/currencies", [baseURL length] ? baseURL : @"https://api.frankfurter.dev"], run, &status);
    id json = status == 200 ? TBJSONParse(data, NULL) : nil;
    NSArray *codes;
    NSMutableArray *lines = [NSMutableArray array];
    unsigned i;
    if (![json isKindOfClass:[NSDictionary class]])
        TBFail(@"The exchange rate service did not answer.");
    codes = [[json allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (i = 0; i < [codes count]; i++)
        [lines addObject:[NSString stringWithFormat:@"%@ %@", [codes objectAtIndex:i], [json objectForKey:[codes objectAtIndex:i]]]];
    return [lines componentsJoinedByString:@"\n"];
}

/* US consumer prices (CPI-U, all items, not adjusted, 1982-84 = 100): yearly averages 1913 to 2024 are built in. Later years come from the
   Bureau of Labor Statistics when the Mac can reach it, as the average of the months published so far. */
static const double cpiAnnual[112] = {9.883, 10.017, 10.108, 10.883, 12.825, 15.042, 17.333, 20.042, 17.850, 16.750, 17.050, 17.125, 17.542, 17.700, 17.358, 17.158, 17.158, 16.700, 15.208, 13.642, 12.933, 13.383, 13.725, 13.867, 14.383, 14.092, 13.908, 14.008, 14.725, 16.333, 17.308, 17.592, 17.992, 19.517, 22.325, 24.042, 23.808, 24.067, 25.958, 26.550, 26.767, 26.850, 26.775, 27.183, 28.092, 28.858, 29.150, 29.575, 29.892, 30.250, 30.625, 31.017, 31.508, 32.458, 33.358, 34.783, 36.683, 38.825, 40.492, 41.817, 44.400, 49.308, 53.817, 56.908, 60.608, 65.233, 72.575, 82.408, 90.925, 96.500, 99.600, 103.883, 107.567, 109.608, 113.625, 118.258, 123.967, 130.658, 136.192, 140.317, 144.458, 148.225, 152.383, 156.850, 160.517, 163.008, 166.575, 172.200, 177.067, 179.875, 183.958, 188.883, 195.292, 201.592, 207.342, 215.303, 214.537, 218.056, 224.939, 229.594, 232.957, 236.736, 237.017, 240.007, 245.120, 251.107, 255.657, 258.811, 270.970, 292.655, 304.702, 313.689};

static NSMutableDictionary *cpiLater = nil;   /* year -> [average, months] */

static void loadLaterCPI(TBRun *run)
{
    int status = 0;
    NSData *data;
    NSArray *rows, *years;
    NSMutableDictionary *sums = [NSMutableDictionary dictionary], *counts = [NSMutableDictionary dictionary];
    unsigned i;
    NSString *baseURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBBaseURL.bls"];
    id json;
    if (cpiLater)
        return;
    /* the Bureau of Labor Statistics' public API, no key needed: the latest three years of the series */
    data = fetchURL([NSString stringWithFormat:@"%@/publicAPI/v1/timeseries/data/CUUR0000SA0", [baseURL length] ? baseURL : @"https://api.bls.gov"], run, &status);
    cpiLater = [[NSMutableDictionary alloc] init];
    if (status != 200)
        return;
    json = TBJSONParse(data, NULL);
    {
        NSArray *series = TBArray(TBDictionary(json, @"Results"), @"series");
        rows = [series count] ? TBArray([series objectAtIndex:0], @"data") : nil;
    }
    for (i = 0; i < [rows count]; i++) {
        id row = [rows objectAtIndex:i];
        NSNumber *year = [NSNumber numberWithInt:[TBString(row, @"year") intValue]];
        double v = [TBString(row, @"value") doubleValue];
        if (v <= 0 || ![TBString(row, @"period") hasPrefix:@"M"] || [TBString(row, @"period") isEqualToString:@"M13"] || [year intValue] < 2025)
            continue;
        [sums setObject:[NSNumber numberWithDouble:[[sums objectForKey:year] doubleValue] + v] forKey:year];
        [counts setObject:[NSNumber numberWithInt:[[counts objectForKey:year] intValue] + 1] forKey:year];
    }
    years = [sums allKeys];
    for (i = 0; i < [years count]; i++) {
        NSNumber *year = [years objectAtIndex:i];
        [cpiLater setObject:[NSArray arrayWithObjects:[NSNumber numberWithDouble:[[sums objectForKey:year] doubleValue] / [[counts objectForKey:year] intValue]], [counts objectForKey:year], nil] forKey:year];
    }
}

/* the index for a year, with a note when it is not a whole year; 0 when unknown */
static double cpiFor(int year, NSString **note, TBRun *run)
{
    if (year >= 1913 && year <= 2024)
        return cpiAnnual[year - 1913];
    if (year > 2024) {
        NSArray *entry;
        loadLaterCPI(run);
        entry = [cpiLater objectForKey:[NSNumber numberWithInt:year]];
        if (entry) {
            if ([[entry objectAtIndex:1] intValue] < 12)
                *note = [NSString stringWithFormat:@"%d is the average of its %d published months.", year, [[entry objectAtIndex:1] intValue]];
            return [[entry objectAtIndex:0] doubleValue];
        }
    }
    return 0;
}

static NSString *inflationAdjust(NSDictionary *args, TBRun *run)
{
    int from = [TBValue(args, @"from_year") isKindOfClass:[NSNumber class]] ? [TBValue(args, @"from_year") intValue] : 0;
    int to = [TBValue(args, @"to_year") isKindOfClass:[NSNumber class]] ? [TBValue(args, @"to_year") intValue] : 0;
    double amount = [TBValue(args, @"amount") isKindOfClass:[NSNumber class]] ? [TBValue(args, @"amount") doubleValue] : 1, a, b;
    NSString *note = nil;
    if (!to) {
        int y;
        loadLaterCPI(run);
        to = 2024;
        for (y = 2025; y < 2100; y++)
            if ([cpiLater objectForKey:[NSNumber numberWithInt:y]])
                to = y;
    }
    if (from < 1913)
        TBFail(@"Give from_year between 1913 and the present.");
    a = cpiFor(from, &note, run);
    b = cpiFor(to, &note, run);
    if (a <= 0 || b <= 0)
        TBFail(@"No price index for %d. Years from 1913 to 2024 are built in; later years need an internet connection to the Bureau of Labor Statistics.", a <= 0 ? from : to);
    return [NSString stringWithFormat:@"$%@ in %d has the buying power of $%.2f in %d (prices changed by %+.1f%%; CPI-U %.1f to %.1f).%@",
        rateText(amount), from, amount * b / a, to, (b / a - 1) * 100, a, b, note ? [@" " stringByAppendingString:note] : @""];
}

@implementation TBBuiltin

+ (BOOL)knows:(NSString *)name
{
    return [[NSArray arrayWithObjects:@"calc", @"notes", @"sysinfo", @"weather", @"currency", @"inflation", nil] containsObject:name];
}

+ (NSDictionary *)listTools:(NSString *)name
{
    NSArray *tools = nil;
    NSArray *text = [NSArray arrayWithObject:@"string"], *none = [NSArray array];
    if ([name isEqualToString:@"calc"])
        tools = [NSArray arrayWithObjects:
            tool(@"calculate", @"Evaluate an arithmetic expression exactly, for example 17*23+sqrt(2).", [NSArray arrayWithObject:@"expression"], text, [NSArray arrayWithObject:@"expression"]),
            tool(@"convert_units", @"Convert a number between length units (m km cm mm in ft yd mi), mass units (kg g lb oz) or temperatures (C F K).",
                [NSArray arrayWithObjects:@"value", @"from", @"to", nil], [NSArray arrayWithObjects:@"number", @"string", @"string", nil], [NSArray arrayWithObjects:@"value", @"from", @"to", nil]), nil];
    else if ([name isEqualToString:@"notes"])
        tools = [NSArray arrayWithObjects:
            tool(@"note_set", @"Save a note under a title, replacing any note with that title.", [NSArray arrayWithObjects:@"title", @"text", nil], [NSArray arrayWithObjects:@"string", @"string", nil], [NSArray arrayWithObjects:@"title", @"text", nil]),
            tool(@"note_get", @"Read a note by its title.", [NSArray arrayWithObject:@"title"], text, [NSArray arrayWithObject:@"title"]),
            tool(@"note_list", @"List every note title with the start of its text.", none, none, none),
            tool(@"note_delete", @"Delete a note by its title. This cannot be undone.", [NSArray arrayWithObject:@"title"], text, [NSArray arrayWithObject:@"title"]), nil];
    else if ([name isEqualToString:@"sysinfo"])
        tools = [NSArray arrayWithObjects:
            tool(@"host_info", @"Name, operating system and CPU count of this Mac. Use display_info for its screens.", none, none, none),
            tool(@"display_info", @"The displays attached to this Mac: how many, and for each its resolution in pixels, colour depth, refresh rate, physical size, rotation and position.", none, none, none),
            tool(@"disk_free", @"Free and total disk space for a path on this Mac.", [NSArray arrayWithObject:@"path"], text, none),
            tool(@"current_time", @"This Mac's local date and time with its UTC offset.", none, none, none),
            tool(@"sha256", @"SHA-256 of a piece of text, as hex.", [NSArray arrayWithObject:@"text"], text, [NSArray arrayWithObject:@"text"]),
            tool(@"slow_task", @"Wait for a number of seconds (up to 120), then report. For testing Stop and long runs.", [NSArray arrayWithObject:@"seconds"], [NSArray arrayWithObject:@"number"], none),
            tool(@"always_fails", @"A tool that always returns an error. For testing error handling.", none, none, none), nil];
    else if ([name isEqualToString:@"currency"])
        tools = [NSArray arrayWithObjects:
            tool(@"convert_currency", @"Convert an amount between two currencies at the latest published rate, or the rate on a past date (back to 1999 for most currencies; central bank data, updated on working days).",
                [NSArray arrayWithObjects:@"amount", @"from", @"to", @"date", nil], [NSArray arrayWithObjects:@"number", @"string", @"string", @"string", nil], [NSArray arrayWithObjects:@"from", @"to", nil]),
            tool(@"list_currencies", @"The currency codes and names this service knows.", none, none, none), nil];
    else if ([name isEqualToString:@"inflation"])
        tools = [NSArray arrayWithObjects:
            tool(@"inflation_adjust", @"What an amount of US dollars from one year is worth in another year, by the US consumer price index (CPI-U): yearly averages from 1913. to_year defaults to the latest year with data.",
                [NSArray arrayWithObjects:@"amount", @"from_year", @"to_year", nil], [NSArray arrayWithObjects:@"number", @"number", @"number", nil], [NSArray arrayWithObjects:@"amount", @"from_year", nil]), nil];
    else if ([name isEqualToString:@"weather"])
        tools = [NSArray arrayWithObjects:
            tool(@"current_weather", @"Current conditions from wttr.in for a place (a city, postcode or 'City,Country').", [NSArray arrayWithObject:@"place"], text, [NSArray arrayWithObject:@"place"]),
            tool(@"forecast", @"Up to three days of forecast from wttr.in for a place: conditions, highs and lows, rain chance, sunrise and sunset.",
                [NSArray arrayWithObjects:@"place", @"days", nil], [NSArray arrayWithObjects:@"string", @"number", nil], [NSArray arrayWithObject:@"place"]), nil];
    return [NSDictionary dictionaryWithObject:tools ? tools : [NSArray array] forKey:@"tools"];
}

+ (NSString *)calculate:(NSString *)expression
{
    Parser s;
    NSString *shown;
    double v;
    const char *text;
    if (![expression isKindOfClass:[NSString class]] || [expression length] > 300)
        TBFail(@"give an expression of at most 300 characters");
    text = [expression UTF8String];
    s.p = text;
    s.integer = YES;
    s.depth = 0;
    v = sum(&s);
    skip(&s);
    if (*s.p)
        badExpression();
    if (s.integer && fabs(v) < 9e15)
        shown = [NSString stringWithFormat:@"%.0f", v];
    else if (isnan(v) || isinf(v))
        shown = isnan(v) ? @"nan" : (v < 0 ? @"-inf" : @"inf");
    else
        shown = shortest(v);
    return [NSString stringWithFormat:@"%@ = %@", expression, shown];
}

+ (NSString *)call:(NSString *)name arguments:(NSDictionary *)args server:(NSString *)server run:(TBRun *)run
{
    if ([server isEqualToString:@"calc"]) {
        if ([name isEqualToString:@"calculate"])
            return [self calculate:TBString(args, @"expression")];
        if ([name isEqualToString:@"convert_units"])
            return convert(args);
    } else if ([server isEqualToString:@"notes"]) {
        NSMutableDictionary *notes = loadNotes();
        NSString *title = TBString(args, @"title");
        if ([name isEqualToString:@"note_set"]) {
            [notes setObject:TBString(args, @"text") forKey:title];
            saveNotes(notes);
            return [NSString stringWithFormat:@"Saved '%@' (%u notes).", title, (unsigned)[notes count]];
        }
        if ([name isEqualToString:@"note_get"]) {
            if (![notes objectForKey:title])
                TBFail(@"no note called '%@'", title);
            return [notes objectForKey:title];
        }
        if ([name isEqualToString:@"note_list"]) {
            NSArray *titles = [[notes allKeys] sortedArrayUsingSelector:@selector(compare:)];
            NSMutableArray *rows = [NSMutableArray array];
            unsigned i;
            for (i = 0; i < [titles count]; i++) {
                NSString *t = [notes objectForKey:[titles objectAtIndex:i]];
                [rows addObject:[NSString stringWithFormat:@"%@: %@", [titles objectAtIndex:i], [t length] > 60 ? [t substringToIndex:60] : t]];
            }
            return [rows count] ? [rows componentsJoinedByString:@"\n"] : @"No notes yet.";
        }
        if ([name isEqualToString:@"note_delete"]) {
            if (![notes objectForKey:title])
                TBFail(@"no note called '%@'", title);
            [notes removeObjectForKey:title];
            saveNotes(notes);
            return [NSString stringWithFormat:@"Deleted '%@'.", title];
        }
    } else if ([server isEqualToString:@"sysinfo"]) {
        if ([name isEqualToString:@"host_info"]) {
            char host[256];
            struct utsname u;
            gethostname(host, sizeof host);
            uname(&u);
            return [NSString stringWithFormat:@"host: %s\nsystem: %s %s (%s)\ncpus: %ld", host, u.sysname, u.release, u.machine, cpuCount()];
        }
        if ([name isEqualToString:@"display_info"])
            return TBTrim(displayReport());
        if ([name isEqualToString:@"disk_free"]) {
            struct statfs fs;
            NSString *path = [TBString(args, @"path") length] ? TBString(args, @"path") : @"/";
            if (statfs([path fileSystemRepresentation], &fs) != 0)
                TBFail(@"cannot read %@", path);
            return [NSString stringWithFormat:@"%.1f GB free of %.1f GB", (double)fs.f_bavail * fs.f_bsize / 1e9, (double)fs.f_blocks * fs.f_bsize / 1e9];
        }
        if ([name isEqualToString:@"current_time"]) {
            time_t now = time(NULL);
            struct tm local;
            char buffer[40], zone[8];
            localtime_r(&now, &local);
            strftime(buffer, sizeof buffer, "%Y-%m-%dT%H:%M:%S", &local);
            strftime(zone, sizeof zone, "%z", &local);
            return [NSString stringWithFormat:@"%s%c%c%c:%c%c", buffer, zone[0], zone[1], zone[2], zone[3], zone[4]];
        }
        if ([name isEqualToString:@"sha256"]) {
            NSData *bytes = [[args objectForKey:@"text"] isKindOfClass:[NSString class]] ? [TBString(args, @"text") dataUsingEncoding:NSUTF8StringEncoding] : [[[args objectForKey:@"text"] description] dataUsingEncoding:NSUTF8StringEncoding];
            unsigned char digest[32];
            NSMutableString *hex = [NSMutableString string];
            int i;
            mbedtls_sha256([bytes bytes], [bytes length], digest, 0);
            for (i = 0; i < 32; i++)
                [hex appendFormat:@"%02x", digest[i]];
            return hex;
        }
        if ([name isEqualToString:@"slow_task"]) {
            double seconds = [TBValue(args, @"seconds") isKindOfClass:[NSNumber class]] ? [TBValue(args, @"seconds") doubleValue] : 5;
            NSDate *end;
            if (seconds < 0) seconds = 0;
            if (seconds > 120) seconds = 120;
            end = [NSDate dateWithTimeIntervalSinceNow:seconds];
            while ([end timeIntervalSinceNow] > 0) {
                [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
                [run check];
            }
            return [NSString stringWithFormat:@"slept %.1f seconds", seconds];
        }
        if ([name isEqualToString:@"always_fails"])
            TBFail(@"this tool always fails, to show how errors look");
    } else if ([server isEqualToString:@"currency"]) {
        if ([name isEqualToString:@"convert_currency"])
            return convertCurrency(args, run);
        if ([name isEqualToString:@"list_currencies"])
            return listCurrencies(run);
    } else if ([server isEqualToString:@"inflation"]) {
        if ([name isEqualToString:@"inflation_adjust"])
            return inflationAdjust(args, run);
    } else if ([server isEqualToString:@"weather"]) {
        id data = weatherData(args, run);
        if ([name isEqualToString:@"current_weather"]) {
            id now = [TBArray(data, @"current_condition") objectAtIndex:0];
            NSString *d = degrees();
            return [NSString stringWithFormat:@"%@: %@, %@%@F (%@%@C), feels like %@%@F (%@%@C). Humidity %@%%, wind %@ mph (%@ km/h) %@, UV %@, rain %@ in.",
                whereText(data), words(now), TBString(now, @"temp_F"), d, TBString(now, @"temp_C"), d, TBString(now, @"FeelsLikeF"), d, TBString(now, @"FeelsLikeC"), d,
                TBString(now, @"humidity"), TBString(now, @"windspeedMiles"), TBString(now, @"windspeedKmph"), TBString(now, @"winddir16Point"), TBString(now, @"uvIndex"), TBString(now, @"precipInches")];
        }
        if ([name isEqualToString:@"forecast"]) {
            int days = [TBValue(args, @"days") isKindOfClass:[NSNumber class]] ? [TBValue(args, @"days") intValue] : 3;
            NSArray *weather = TBArray(data, @"weather");
            NSMutableArray *lines = [NSMutableArray arrayWithObject:whereText(data)];
            NSString *d = degrees();
            int i;
            if (days < 1) days = 1;
            if (days > 3) days = 3;
            for (i = 0; i < days && i < (int)[weather count]; i++) {
                id day = [weather objectAtIndex:i];
                NSArray *hours = TBArray(day, @"hourly");
                id midday = [hours count] ? [hours objectAtIndex:([hours count] > 4 ? 4 : [hours count] - 1)] : [NSDictionary dictionary];
                int rain = 0;
                unsigned h;
                id sun = [TBArray(day, @"astronomy") count] ? [TBArray(day, @"astronomy") objectAtIndex:0] : [NSDictionary dictionary];
                for (h = 0; h < [hours count]; h++)
                    if (TBInteger([hours objectAtIndex:h], @"chanceofrain") > rain)
                        rain = (int)TBInteger([hours objectAtIndex:h], @"chanceofrain");
                [lines addObject:[NSString stringWithFormat:@"%@: %@, high %@%@F (%@%@C), low %@%@F (%@%@C), rain chance up to %d%%, sunrise %@, sunset %@",
                    TBString(day, @"date"), words(midday), TBString(day, @"maxtempF"), d, TBString(day, @"maxtempC"), d, TBString(day, @"mintempF"), d, TBString(day, @"mintempC"), d, rain,
                    [TBString(sun, @"sunrise") length] ? TBString(sun, @"sunrise") : @"?", [TBString(sun, @"sunset") length] ? TBString(sun, @"sunset") : @"?"]];
            }
            return [lines componentsJoinedByString:@"\n"];
        }
    }
    TBFail(@"Unknown tool %@.", name);
    return nil;
}

@end
