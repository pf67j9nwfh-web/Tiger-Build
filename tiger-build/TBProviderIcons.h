#import <Cocoa/Cocoa.h>

/* A 16-point picture for each model provider, shown beside its name in the provider popup and the Model menu.
   Simple marks in each service's colours, drawn here rather than shipped as files. nil for a name it does not know. */
NSImage *TBProviderIcon(NSString *provider);

/* Draws the mark into rect (the current graphics context). */
void TBDrawProviderIcon(NSString *provider, NSRect rect);
