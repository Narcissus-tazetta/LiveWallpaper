#include "DracoBridge.h"
#include <draco/compression/decode.h>
#include <memory>
#include <utility>

struct LWPDracoMesh {
    std::unique_ptr<draco::Mesh> value;
};

LWPDracoMesh *lwp_draco_decode(const void *bytes, size_t size) {
    if (size == 0) {
        return nullptr;
    }
    draco::DecoderBuffer buffer;
    buffer.Init(static_cast<const char *>(bytes), size);
    auto decoded = draco::Decoder().DecodeMeshFromBuffer(&buffer);
    if (!decoded.ok()) {
        return nullptr;
    }
    return new LWPDracoMesh{std::move(decoded).value()};
}

void lwp_draco_destroy(LWPDracoMesh *mesh) {
    delete mesh;
}

uint32_t lwp_draco_point_count(const LWPDracoMesh *mesh) {
    return mesh->value->num_points();
}

uint32_t lwp_draco_face_count(const LWPDracoMesh *mesh) {
    return mesh->value->num_faces();
}

template <typename T>
static bool copy_attribute(const draco::Mesh &mesh, const draco::PointAttribute &attribute,
                           int components, void *output) {
    auto *values = static_cast<T *>(output);
    for (draco::PointIndex i(0); i < mesh.num_points(); ++i) {
        if (!attribute.ConvertValue(attribute.mapped_index(i), components, values)) {
            return false;
        }
        values += components;
    }
    return true;
}

int lwp_draco_attribute(const LWPDracoMesh *mesh, uint32_t id, int component_type,
                        int components, void *output) {
    const auto *attribute = mesh->value->GetAttributeByUniqueId(id);
    if (!attribute || attribute->num_components() != components) {
        return false;
    }
    switch (component_type) {
        case 5120: return copy_attribute<int8_t>(*mesh->value, *attribute, components, output);
        case 5121: return copy_attribute<uint8_t>(*mesh->value, *attribute, components, output);
        case 5122: return copy_attribute<int16_t>(*mesh->value, *attribute, components, output);
        case 5123: return copy_attribute<uint16_t>(*mesh->value, *attribute, components, output);
        case 5125: return copy_attribute<uint32_t>(*mesh->value, *attribute, components, output);
        case 5126: return copy_attribute<float>(*mesh->value, *attribute, components, output);
        default: return false;
    }
}

void lwp_draco_indices(const LWPDracoMesh *mesh, uint32_t *output) {
    for (draco::FaceIndex i(0); i < mesh->value->num_faces(); ++i) {
        const auto &face = mesh->value->face(i);
        for (const auto point : face) {
            *output++ = point.value();
        }
    }
}
