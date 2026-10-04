#import <Foundation/Foundation.h>

/* Colour emoji for Macs before 10.7, which have no emoji font. Twemoji's pictures are read from Emoji.pack
   (see scripts/pack-emoji.py). Each emoji in a text becomes one private-use character that stands for it;
   the chat view turns those into inline pictures. */

/* Use another pack file (the tests do); nil goes back to the one in the app. */
void TBEmojiUsePack(NSString *path);
BOOL TBEmojiPicturesAvailable(void);

/* The text with every emoji that has a picture replaced by its character, and the rest as TBDisplayText gives it. */
NSString *TBEmojiSubstitute(NSString *text);
BOOL TBEmojiIsStandIn(unichar c);
/* The emoji a stand-in character stands for, and the PNG of it. */
NSString *TBEmojiForStandIn(unichar c);
NSData *TBEmojiPNGForStandIn(unichar c);
/* The text with the stand-in characters swapped back for the emoji. */
NSString *TBEmojiRestore(NSString *text);
