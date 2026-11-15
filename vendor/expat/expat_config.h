/* Configuration for the vendored Expat, written for this project (it
 * replaces the file the upstream configure script generates).
 *
 * BYTEORDER, and the source of entropy for hash salting, are chosen in
 * build.zig from the build target, with -DBYTEORDER=... and one of
 * -DHAVE_GETRANDOM / -DHAVE_ARC4RANDOM_BUF.
 *
 * Features are deliberately minimal:
 *   - XML_GE 0: no general entity expansion (so no "billion laughs"), and
 *     no DTD support (XML_DTD undefined). The predefined entities and
 *     character references still work.
 *   - XML_NS 1: namespace processing.
 */
#ifndef EXPAT_CONFIG_H
#define EXPAT_CONFIG_H 1

#define XML_CONTEXT_BYTES 1024
#define XML_GE 0
#define XML_NS 1

#include <stddef.h>
#include <string.h>
#define HAVE_MEMMOVE 1

#endif
