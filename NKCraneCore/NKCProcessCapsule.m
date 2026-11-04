#include "NKCProcessCapsule.h"
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

NKCLaunchCapsule NKCProcessLaunchCapsule(void) {
    static dispatch_once_t once;
    static NKCLaunchCapsule context;
    dispatch_once(&once, ^{
        size_t count = 0;
        if (environ) {
            while (environ[count] != NULL && count < 4097) count++;
        }
        // Parser explicitly rejects >4096 variables instead of truncating.
        context = NKCParseEnvStrings((const char * const *)environ, count);
    });
    return context;
}
