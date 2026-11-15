/* The few functions of Wuffs' stb_image-compatible interface that dksearch uses.
 * The implementation is vendor/wuffs/impl.c (Wuffs compiled with only the image modules). */
#ifndef DKSEARCH_WUFFS_C_H
#define DKSEARCH_WUFFS_C_H
typedef unsigned char stbi_uc;
int stbi_info_from_memory(stbi_uc const *buffer, int len, int *x, int *y, int *comp);
stbi_uc *stbi_load_from_memory(stbi_uc const *buffer, int len, int *x, int *y, int *comp, int req_comp);
void stbi_image_free(void *retval_from_stbi_load);
const char *stbi_failure_reason(void);
#endif
