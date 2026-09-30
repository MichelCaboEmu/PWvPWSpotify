#import <Foundation/Foundation.h>
// Categories/codes are fixed. Detailed download fields are sanitized by PWDownloadLog.
void PWEvent(NSString *category, NSString *code, NSInteger status);
void PWEventDetails(NSString *category, NSString *code, NSInteger status, NSDictionary *details);
NSString *PWDiagnosticSnapshot(void);
void PWClearDiagnostics(void);
NSString *PWSecret(NSString *name);
BOOL PWSetSecret(NSString *name, NSString *value);
