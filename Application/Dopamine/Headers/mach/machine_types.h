/*
 * mach/machine_types.h - additional CPU family constants for newer processors
 */

#ifndef _MACH_MACHINE_TYPES_H_
#define _MACH_MACHINE_TYPES_H_

/* Import the system header first */
#include_next <mach/machine.h>

/* Additional CPU families not in iOS 16.2 SDK */
#ifndef CPUFAMILY_ARM_COLL
#define CPUFAMILY_ARM_COLL 0x36e1812f  /* A17/A18 */
#endif

#ifndef CPUFAMILY_ARM_TAHITI
#define CPUFAMILY_ARM_TAHITI 0x72015832  /* A18 Pro */
#endif

#endif /* _MACH_MACHINE_TYPES_H_ */
