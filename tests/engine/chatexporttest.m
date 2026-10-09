/* Chats written for ChatGPT-style tools, Claude-style tools and LibreChat: chatexporttest (from tiger-build/) */
#import <Foundation/Foundation.h>
#import "TBChatExport.h"
#import "TBJSON.h"

static int failures = 0;
static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSArray *messages = [NSArray arrayWithObjects:
        [NSDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", @"Hello. Ask me anything.", @"text", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"What is 2+2?", @"text", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", @"Working...", @"text", [NSNumber numberWithBool:YES], @"status", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", @"", @"text", @"tool", @"activityKind", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", @"It is 4.\n\n```c\nint x;\n```", @"text", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"", @"text", [NSDictionary dictionaryWithObjectsAndKeys:@"notes.txt", @"name", nil], @"attachment", nil], nil];
    NSDictionary *chat = [NSDictionary dictionaryWithObjectsAndKeys:@"Arithmetic", @"title", @"claude", @"provider", @"claude-sonnet-5", @"model", messages, @"messages", nil];
    NSArray *turns = [TBChatExport turnsOfChat:chat];
    id parsed;
    NSDictionary *c, *mapping, *node;
    NSString *cursor;
    int walked = 0;
    expectThat([turns count] == 4 && [[[turns objectAtIndex:3] objectForKey:@"text"] hasPrefix:@"[Attached file: notes.txt"], @"export: words only; status and tool lines left out, attachments named");

    parsed = TBJSONParse([TBChatExport chatGPTExportOfChat:chat], NULL);
    c = [parsed isKindOfClass:[NSArray class]] ? [parsed objectAtIndex:0] : nil;
    mapping = [c objectForKey:@"mapping"];
    cursor = [c objectForKey:@"current_node"];
    while ([cursor isKindOfClass:[NSString class]]) {
        node = [mapping objectForKey:cursor];
        if ([node objectForKey:@"message"] && [[node objectForKey:@"message"] isKindOfClass:[NSDictionary class]])
            walked++;
        cursor = [[node objectForKey:@"parent"] isKindOfClass:[NSString class]] ? [node objectForKey:@"parent"] : nil;
    }
    expectThat(walked == 4 && [[c objectForKey:@"title"] isEqualToString:@"Arithmetic"], @"ChatGPT: the thread can be walked from current_node, root has no message");
    node = [mapping objectForKey:[c objectForKey:@"current_node"]];
    expectThat([[[[node objectForKey:@"message"] objectForKey:@"author"] objectForKey:@"role"] isEqualToString:@"user"]
        && [[[[[node objectForKey:@"message"] objectForKey:@"content"] objectForKey:@"parts"] objectAtIndex:0] hasPrefix:@"[Attached"], @"ChatGPT: author role and content parts");

    parsed = TBJSONParse([TBChatExport claudeExportOfChat:chat], NULL);
    c = [parsed isKindOfClass:[NSArray class]] ? [parsed objectAtIndex:0] : nil;
    expectThat([[c objectForKey:@"chat_messages"] count] == 4 && [[[[c objectForKey:@"chat_messages"] objectAtIndex:1] objectForKey:@"sender"] isEqualToString:@"human"]
        && [[[[c objectForKey:@"chat_messages"] objectAtIndex:2] objectForKey:@"text"] hasPrefix:@"It is 4."]
        && [[c objectForKey:@"name"] isEqualToString:@"Arithmetic"], @"Claude: chat_messages with human and assistant senders");
    expectThat([[[[c objectForKey:@"chat_messages"] objectAtIndex:0] objectForKey:@"created_at"] hasSuffix:@"Z"], @"Claude: ISO times");

    parsed = TBJSONParse([TBChatExport libreChatExportOfChat:chat], NULL);
    c = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
    expectThat([[c objectForKey:@"messages"] count] == 4 && [[c objectForKey:@"conversationId"] length] > 10, @"LibreChat: conversation id and messages");
    node = [[c objectForKey:@"messagesTree"] objectAtIndex:0];
    expectThat([[[node objectForKey:@"children"] objectAtIndex:0] objectForKey:@"parentMessageId"] != nil
        && ![[node objectForKey:@"isCreatedByUser"] boolValue] && [[[[node objectForKey:@"children"] objectAtIndex:0] objectForKey:@"isCreatedByUser"] boolValue], @"LibreChat: nested tree, parents link down the chain");
    expectThat([[[[c objectForKey:@"messages"] objectAtIndex:1] objectForKey:@"parentMessageId"] isEqualToString:[[[c objectForKey:@"messages"] objectAtIndex:0] objectForKey:@"messageId"]], @"LibreChat: each message points to the one before");
    [pool release];
    return failures ? 1 : 0;
}
