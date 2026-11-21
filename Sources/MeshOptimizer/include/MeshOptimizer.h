#ifndef LIVEWALLPAPER_MESHOPTIMIZER_H
#define LIVEWALLPAPER_MESHOPTIMIZER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int meshopt_decodeVertexBuffer(void* destination, size_t count, size_t stride, const unsigned char* buffer, size_t size);
int meshopt_decodeIndexBuffer(void* destination, size_t count, size_t stride, const unsigned char* buffer, size_t size);
int meshopt_decodeIndexSequence(void* destination, size_t count, size_t stride, const unsigned char* buffer, size_t size);
void meshopt_decodeFilterOct(void* buffer, size_t count, size_t stride);
void meshopt_decodeFilterQuat(void* buffer, size_t count, size_t stride);
void meshopt_decodeFilterExp(void* buffer, size_t count, size_t stride);
void meshopt_decodeFilterColor(void* buffer, size_t count, size_t stride);

#ifdef __cplusplus
}
#endif

#endif
