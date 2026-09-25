/*
 * sys/fileport.h - stub header for building with older SDKs
 */

#ifndef _SYS_FILEPORT_H_
#define _SYS_FILEPORT_H_

#include <sys/types.h>
#include <mach/port.h>

typedef int fileport_t;

#ifdef __cplusplus
extern "C" {
#endif

int fileport_makeport(int fd, fileport_t *port);
int fileport_makefd(fileport_t port);

#ifdef __cplusplus
}
#endif

#endif /* _SYS_FILEPORT_H_ */
