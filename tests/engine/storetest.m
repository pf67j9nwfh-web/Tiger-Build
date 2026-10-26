/* Two TBStore objects on one file, as the window and the terminal program will be: storetest DIR  from tiger-build/ */
#import <Foundation/Foundation.h>
#import "TBSupport.h"
#import "expect.h"

static NSMutableDictionary *chat(NSString *ident, NSString *title, NSString *text)
{
    NSMutableArray *messages = [NSMutableArray array];
    [messages addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"user", @"role", text, @"text", nil]];
    return [NSMutableDictionary dictionaryWithObjectsAndKeys:ident, @"id", title, @"title", messages, @"messages", nil];
}

static NSMutableDictionary *find(TBStore *s, NSString *ident)
{
    unsigned i;
    for (i = 0; i < [[s chats] count]; i++)
        if ([[[[s chats] objectAtIndex:i] objectForKey:@"id"] isEqualToString:ident])
            return [[s chats] objectAtIndex:i];
    return nil;
}

static void touch(TBStore *s)
{
    [s markDirty];
    [s flush];
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *dir = [NSString stringWithUTF8String:argv[1]], *file = [dir stringByAppendingPathComponent:@"chats.plist"];
    TBStore *a, *b;
    NSMutableDictionary *held;
    int n1, n2, n3;
    (void)argc;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir attributes:nil];
    a = [[TBStore alloc] initWithPath:file];
    b = [[TBStore alloc] initWithPath:file];

    n1 = [a takeNextId];
    n2 = [b takeNextId];
    n3 = [a takeNextId];
    expectThat(n1 != n2 && n2 != n3 && n1 != n3, @"chat numbers from two processes never repeat");

    [[a chats] addObject:chat([NSString stringWithFormat:@"%d", n1], @"from A", @"hello")];
    touch(a);
    expectThat([b reloadExternal] && find(b, [NSString stringWithFormat:@"%d", n1]) != nil, @"a chat made by A appears in B");
    expectThat(![b reloadExternal], @"nothing changed: nothing to take in");

    held = find(b, [NSString stringWithFormat:@"%d", n1]);
    [[held objectForKey:@"messages"] addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", @"hi from B", @"text", nil]];
    touch(b);
    expectThat([a reloadExternal] && [[[find(a, [NSString stringWithFormat:@"%d", n1]) objectForKey:@"messages"] lastObject] objectForKey:@"text"] != nil
        && [[[[find(a, [NSString stringWithFormat:@"%d", n1]) objectForKey:@"messages"] lastObject] objectForKey:@"text"] isEqualToString:@"hi from B"], @"B's new message reaches A");

    /* the object A holds stays the same object */
    {
        NSMutableDictionary *before = find(a, [NSString stringWithFormat:@"%d", n1]);
        [[held objectForKey:@"messages"] addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"third", @"text", nil]];
        touch(b);
        [a reloadExternal];
        expectThat(before == find(a, [NSString stringWithFormat:@"%d", n1]) && [[before objectForKey:@"messages"] count] == 3, @"the chat object a window holds is updated in place");
    }

    /* different chats changed at the same time: both kept */
    [[a chats] addObject:chat([NSString stringWithFormat:@"%d", [a takeNextId]], @"A second", @"a2")];
    [[b chats] addObject:chat([NSString stringWithFormat:@"%d", [b takeNextId]], @"B second", @"b2")];
    touch(a);
    touch(b);
    [a reloadExternal];
    {
        TBStore *c = [[[TBStore alloc] initWithPath:file] autorelease];
        expectThat([[c chats] count] == 3 && [[a chats] count] == 3, @"two processes saving different chats lose nothing");
    }

    /* a deletion */
    {
        NSString *gone = [NSString stringWithFormat:@"%d", n1];
        [[a chats] removeObject:find(a, gone)];
        touch(a);
        [b reloadExternal];
        expectThat(find(b, gone) == nil && [[b chats] count] == 2, @"a chat deleted by A is gone from B");
    }

    /* the same chat changed in both */
    {
        NSMutableDictionary *ca = [[a chats] objectAtIndex:0], *cb;
        NSString *ident = [ca objectForKey:@"id"];
        [b reloadExternal];
        cb = find(b, ident);
        [[ca objectForKey:@"messages"] addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"A's edit", @"text", nil]];
        [[cb objectForKey:@"messages"] addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"B's edit", @"text", nil]];
        touch(a);
        touch(b);
        {
            TBStore *c = [[[TBStore alloc] initWithPath:file] autorelease];
            unsigned i;
            BOOL sawA = NO, sawB = NO, copy = NO;
            for (i = 0; i < [[c chats] count]; i++) {
                NSDictionary *x = [[c chats] objectAtIndex:i];
                NSString *last = [[[x objectForKey:@"messages"] lastObject] objectForKey:@"text"];
                sawA = sawA || [last isEqualToString:@"A's edit"];
                sawB = sawB || [last isEqualToString:@"B's edit"];
                copy = copy || [[x objectForKey:@"title"] rangeOfString:@"(other copy)"].length > 0;
            }
            expectThat(sawA && sawB && copy, @"the same chat changed in both: both versions are kept");
        }
    }

    /* workspace settings */
    [[a settings] setObject:@"/x" forKey:@"root"];
    touch(a);
    [b reloadExternal];
    expectThat([[[b settings] objectForKey:@"root"] isEqualToString:@"/x"], @"workspace settings follow too");

    [a release];
    [b release];
    [pool release];
    return failures ? 1 : 0;
}
