/* The C interfaces the Wikipedia connector uses: bzip2's streaming decoder
 * and Expat's push parser. Translated to the `wiki_c` Zig module by build.zig
 * when the Wikipedia connector is built. */
#include <bzlib.h>
#include <expat.h>
