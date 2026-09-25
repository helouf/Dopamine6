/*
 * cpufamily_additions.h - Additional CPU family constants
 * These constants are not available in iOS 16.2 SDK
 */

#ifndef _CPUFAMILY_ADDITIONS_H_
#define _CPUFAMILY_ADDITIONS_H_

/* Additional CPU families for newer processors */
#ifndef CPUFAMILY_ARM_COLL
#define CPUFAMILY_ARM_COLL 0x36e1812f  /* A17/A18 */
#endif

#ifndef CPUFAMILY_ARM_TAHITI
#define CPUFAMILY_ARM_TAHITI 0x72015832  /* A18 Pro */
#endif

#endif /* _CPUFAMILY_ADDITIONS_H_ */
