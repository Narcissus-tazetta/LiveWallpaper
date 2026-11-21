#ifndef LIVEWALLPAPER_DRACO_BRIDGE_H
#define LIVEWALLPAPER_DRACO_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LWPDracoMesh LWPDracoMesh;
LWPDracoMesh *lwp_draco_decode(const void *bytes, size_t size);
void lwp_draco_destroy(LWPDracoMesh *mesh);
uint32_t lwp_draco_point_count(const LWPDracoMesh *mesh);
uint32_t lwp_draco_face_count(const LWPDracoMesh *mesh);
int lwp_draco_attribute(const LWPDracoMesh *mesh, uint32_t id, int component_type, int components, void *output);
void lwp_draco_indices(const LWPDracoMesh *mesh, uint32_t *output);

#ifdef __cplusplus
}
#endif

#endif
