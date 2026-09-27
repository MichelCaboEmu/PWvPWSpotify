#import <Foundation/Foundation.h>
// Call sites pass fixed category/code strings and a numeric status, never user data.
void PWEvent(NSString *category, NSString *code, NSInteger status);
NSString *PWDiagnosticSnapshot(void);
void PWClearDiagnostics(void);
NSString *PWSecret(NSString *name);
BOOL PWSetSecret(NSString *name, NSString *value);
