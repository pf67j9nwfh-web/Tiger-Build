#import "TBChatExport.h"
#import "TBJSON.h"

static NSString *newUUID(void)
{
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    NSString *text = (NSString *)CFUUIDCreateString(NULL, uuid);
    CFRelease(uuid);
    return [[text autorelease] lowercaseString];
}

static NSString *isoTime(double seconds)
{
    NSCalendarDate *date = [NSCalendarDate dateWithTimeIntervalSince1970:seconds];
    [date setTimeZone:[NSTimeZone timeZoneWithName:@"GMT"]];
    return [date descriptionWithCalendarFormat:@"%Y-%m-%dT%H:%M:%S.000000Z"];
}

static NSString *chatModel(NSDictionary *chat)
{
    NSString *model = [chat objectForKey:@"model"];
    return [model length] ? model : @"unknown";
}

@implementation TBChatExport

+ (NSArray *)turnsOfChat:(NSDictionary *)chat
{
    NSArray *messages = [chat objectForKey:@"messages"];
    NSMutableArray *turns = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [messages count]; i++) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSDictionary *attachment = [message objectForKey:@"attachment"];
        NSString *role = [message objectForKey:@"role"], *text = [message objectForKey:@"text"];
        if ([[message objectForKey:@"status"] boolValue] || [message objectForKey:@"activityKind"])
            continue;
        if ([attachment isKindOfClass:[NSDictionary class]]) {
            text = [NSString stringWithFormat:@"[Attached file: %@]", [attachment objectForKey:@"name"] ? [attachment objectForKey:@"name"] : @"file"];
            role = @"user";
        }
        if (![role isEqualToString:@"user"] && ![role isEqualToString:@"assistant"])
            continue;
        if ([text length] == 0)
            continue;
        [turns addObject:[NSDictionary dictionaryWithObjectsAndKeys:role, @"role", text, @"text", nil]];
    }
    return turns;
}

+ (NSData *)chatGPTExportOfChat:(NSDictionary *)chat
{
    NSArray *turns = [self turnsOfChat:chat];
    NSMutableDictionary *mapping = [NSMutableDictionary dictionary];
    NSString *rootId = newUUID(), *parentId = rootId, *lastId = rootId, *conversationId = newUUID();
    double start = [[NSDate date] timeIntervalSince1970] - [turns count] * 5.0, last = start;
    unsigned i;
    [mapping setObject:[NSDictionary dictionaryWithObjectsAndKeys:rootId, @"id", [NSNull null], @"message", [NSNull null], @"parent", [NSMutableArray array], @"children", nil] forKey:rootId];
    for (i = 0; i < [turns count]; i++) {
        NSDictionary *turn = [turns objectAtIndex:i];
        BOOL user = [[turn objectForKey:@"role"] isEqualToString:@"user"];
        NSString *nodeId = newUUID();
        double when = start + i * 5.0;
        NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
        NSDictionary *message;
        if (!user) {
            [metadata setObject:chatModel(chat) forKey:@"model_slug"];
            [metadata setObject:chatModel(chat) forKey:@"default_model_slug"];
        }
        message = [NSDictionary dictionaryWithObjectsAndKeys:nodeId, @"id",
            [NSDictionary dictionaryWithObjectsAndKeys:user ? @"user" : @"assistant", @"role", [NSNull null], @"name", [NSDictionary dictionary], @"metadata", nil], @"author",
            [NSNumber numberWithDouble:when], @"create_time", [NSNull null], @"update_time",
            [NSDictionary dictionaryWithObjectsAndKeys:@"text", @"content_type", [NSArray arrayWithObject:[turn objectForKey:@"text"]], @"parts", nil], @"content",
            @"finished_successfully", @"status", [NSNumber numberWithBool:YES], @"end_turn", [NSNumber numberWithDouble:1.0], @"weight", metadata, @"metadata", @"all", @"recipient", nil];
        [mapping setObject:[NSDictionary dictionaryWithObjectsAndKeys:nodeId, @"id", message, @"message", parentId, @"parent", [NSMutableArray array], @"children", nil] forKey:nodeId];
        [[[mapping objectForKey:parentId] objectForKey:@"children"] addObject:nodeId];
        parentId = nodeId;
        lastId = nodeId;
        last = when;
    }
    return TBJSONData([NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:
        [chat objectForKey:@"title"] ? [chat objectForKey:@"title"] : @"Chat", @"title",
        [NSNumber numberWithDouble:start], @"create_time", [NSNumber numberWithDouble:last], @"update_time",
        mapping, @"mapping", [NSArray array], @"moderation_results", lastId, @"current_node",
        conversationId, @"conversation_id", conversationId, @"id", [NSNumber numberWithBool:NO], @"is_archived",
        chatModel(chat), @"default_model_slug", nil]]);
}

+ (NSData *)claudeExportOfChat:(NSDictionary *)chat
{
    NSArray *turns = [self turnsOfChat:chat];
    NSMutableArray *list = [NSMutableArray array];
    double start = [[NSDate date] timeIntervalSince1970] - [turns count] * 5.0;
    unsigned i;
    for (i = 0; i < [turns count]; i++) {
        NSDictionary *turn = [turns objectAtIndex:i];
        NSString *stamp = isoTime(start + i * 5.0), *text = [turn objectForKey:@"text"];
        [list addObject:[NSDictionary dictionaryWithObjectsAndKeys:newUUID(), @"uuid", text, @"text",
            [NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"text", @"type", text, @"text", nil]], @"content",
            [[turn objectForKey:@"role"] isEqualToString:@"user"] ? @"human" : @"assistant", @"sender",
            stamp, @"created_at", stamp, @"updated_at", [NSArray array], @"attachments", [NSArray array], @"files", nil]];
    }
    return TBJSONData([NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:newUUID(), @"uuid",
        [chat objectForKey:@"title"] ? [chat objectForKey:@"title"] : @"Chat", @"name",
        isoTime(start), @"created_at", isoTime(start + [turns count] * 5.0), @"updated_at",
        [NSDictionary dictionaryWithObject:newUUID() forKey:@"uuid"], @"account", list, @"chat_messages", nil]]);
}

+ (NSData *)libreChatExportOfChat:(NSDictionary *)chat
{
    NSArray *turns = [self turnsOfChat:chat];
    NSMutableArray *list = [NSMutableArray array];
    NSString *parent = @"00000000-0000-0000-0000-000000000000";
    double start = [[NSDate date] timeIntervalSince1970] - [turns count] * 5.0;
    NSString *provider = [chat objectForKey:@"provider"], *endpoint = @"custom";
    unsigned i;
    if ([provider isEqualToString:@"chatgpt"]) endpoint = @"openAI";
    else if ([provider isEqualToString:@"claude"]) endpoint = @"anthropic";
    else if ([provider isEqualToString:@"gemini"]) endpoint = @"google";
    for (i = 0; i < [turns count]; i++) {
        NSDictionary *turn = [turns objectAtIndex:i];
        BOOL user = [[turn objectForKey:@"role"] isEqualToString:@"user"];
        NSString *mid = newUUID();
        [list addObject:[NSDictionary dictionaryWithObjectsAndKeys:mid, @"messageId", parent, @"parentMessageId", [turn objectForKey:@"text"], @"text",
            user ? @"User" : chatModel(chat), @"sender", [NSNumber numberWithBool:user], @"isCreatedByUser", isoTime(start + i * 5.0), @"createdAt",
            chatModel(chat), @"model", endpoint, @"endpoint", nil]];
        parent = mid;
    }
    /* LibreChat's own export nests the messages ("messagesTree", each with its children); the flat list is there too */
    {
        NSMutableArray *tree = [NSMutableArray array];
        int k;
        for (k = (int)[list count] - 1; k >= 0; k--) {
            NSMutableDictionary *node = [NSMutableDictionary dictionaryWithDictionary:[list objectAtIndex:k]];
            [node setObject:[NSArray arrayWithArray:tree] forKey:@"children"];
            [tree removeAllObjects];
            [tree addObject:node];
        }
        return TBJSONData([NSDictionary dictionaryWithObjectsAndKeys:newUUID(), @"conversationId",
            [chat objectForKey:@"title"] ? [chat objectForKey:@"title"] : @"Chat", @"title", isoTime([[NSDate date] timeIntervalSince1970]), @"exportAt",
            [NSNumber numberWithBool:NO], @"branches", [NSNumber numberWithBool:YES], @"recursive",
            [NSDictionary dictionaryWithObjectsAndKeys:endpoint, @"endpoint", chatModel(chat), @"model", nil], @"options", list, @"messages", tree, @"messagesTree", nil]);
    }
}

@end
