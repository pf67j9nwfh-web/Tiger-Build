#import <Foundation/Foundation.h>

/* Skills: folders in ~/Library/Application Support/Tiger Build/skills, each with a SKILL.md (a name and description at the top, then instructions) and any
   files it refers to. The model is told which skills exist and loads one when the task fits. The same folder layout works for Claude skills. */
@interface TBSkills : NSObject
+ (NSString *)root;
+ (NSArray *)all;                                   /* dictionaries: name, description, folder, enabled */
+ (NSArray *)enabled;
+ (void)setName:(NSString *)name enabled:(BOOL)on;
+ (NSString *)systemNote;                           /* the paragraph that lists the enabled skills, or nil */
+ (NSString *)load:(NSString *)name;                /* SKILL.md and the names of its other files; raises through TBFail */
+ (NSString *)readFile:(NSString *)path ofSkill:(NSString *)name;
+ (NSDictionary *)parse:(NSString *)text;           /* name, description, body from one SKILL.md text */
+ (BOOL)createNamed:(NSString *)name description:(NSString *)description body:(NSString *)body;
@end
