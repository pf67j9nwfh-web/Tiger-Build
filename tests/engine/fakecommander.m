/* A stand-in for ppc-commander: the MCP calls the engine makes, with canned answers. Records what it was asked in $FAKE_COMMANDER_LOG. */
#import <Foundation/Foundation.h>
#import "TBJSON.h"

static void note(NSString *line)
{
    const char *path = getenv("FAKE_COMMANDER_LOG");
    FILE *f;
    if (!path || !(f = fopen(path, "a")))
        return;
    fprintf(f, "%s\n", [line UTF8String]);
    fclose(f);
}

static NSDictionary *tool(NSString *name, NSString *description, NSDictionary *properties)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:name, @"name", description, @"description",
        [NSDictionary dictionaryWithObjectsAndKeys:@"object", @"type", properties, @"properties", nil], @"inputSchema", nil];
}

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    char *buffer = NULL;
    size_t size = 0;
    NSArray *tools = [NSArray arrayWithObjects:
        tool(@"start_process", @"Run a shell command", [NSDictionary dictionaryWithObjectsAndKeys:[NSDictionary dictionaryWithObject:@"string" forKey:@"type"], @"command", [NSDictionary dictionaryWithObject:@"number" forKey:@"type"], @"timeout_ms", nil]),
        tool(@"read_file", @"Read a file", [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:@"string" forKey:@"type"] forKey:@"path"]),
        tool(@"take_screenshot", @"Screenshot", [NSDictionary dictionary]), tool(@"git_read", @"git", [NSDictionary dictionary]), nil];
    while (getline(&buffer, &size, stdin) > 0) {
        NSAutoreleasePool *inner = [[NSAutoreleasePool alloc] init];
        id message = TBJSONParseString([NSString stringWithUTF8String:buffer], NULL);
        NSString *method = [message objectForKey:@"method"];
        id mid = [message objectForKey:@"id"], result = [NSDictionary dictionary];
        const char *root = getenv("TB_WORKSPACE_ROOT");
        if (![message isKindOfClass:[NSDictionary class]]) {
            [inner release];
            continue;
        }
        note([NSString stringWithFormat:@"%@ %@ env=%s", method, TBJSONString([message objectForKey:@"params"]), root ? root : ""]);
        if (mid) {
            if ([method isEqualToString:@"initialize"])
                result = [NSDictionary dictionaryWithObjectsAndKeys:@"2025-06-18", @"protocolVersion", [NSDictionary dictionaryWithObject:[NSDictionary dictionary] forKey:@"tools"], @"capabilities",
                    [NSDictionary dictionaryWithObjectsAndKeys:@"fake", @"name", @"1", @"version", nil], @"serverInfo", nil];
            else if ([method isEqualToString:@"tools/list"])
                result = [NSDictionary dictionaryWithObject:tools forKey:@"tools"];
            else if ([method isEqualToString:@"tools/call"]) {
                NSString *name = [[message objectForKey:@"params"] objectForKey:@"name"];
                NSString *command = [[[message objectForKey:@"params"] objectForKey:@"arguments"] objectForKey:@"command"];
                NSDictionary *text = [NSDictionary dictionaryWithObjectsAndKeys:@"text", @"type", @"file1\nfile2\033[31mred\033[0m", @"text", nil];
                if ([name isEqualToString:@"start_process"] && [command rangeOfString:@"fail"].location != NSNotFound)
                    result = [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"text", @"type", @"boom", @"text", nil]], @"content", [NSNumber numberWithBool:YES], @"isError", nil];
                else if ([name isEqualToString:@"take_screenshot"])
                    result = [NSDictionary dictionaryWithObject:[NSArray arrayWithObjects:[NSDictionary dictionaryWithObjectsAndKeys:@"text", @"type", @"screen", @"text", nil],
                        [NSDictionary dictionaryWithObjectsAndKeys:@"image", @"type", @"image/png", @"mimeType", @"iVBORw0KGgo=", @"data", nil], nil] forKey:@"content"];
                else
                    result = [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:text] forKey:@"content"];
            }
            printf("%s\n", [TBJSONString([NSDictionary dictionaryWithObjectsAndKeys:@"2.0", @"jsonrpc", mid, @"id", result, @"result", nil]) UTF8String]);
            fflush(stdout);
        }
        [inner release];
    }
    [pool release];
    return 0;
}
