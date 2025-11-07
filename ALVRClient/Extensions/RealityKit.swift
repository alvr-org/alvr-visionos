//
//  Extensions/RealityKit.swift
//

import RealityKit
import CompositorServices

public extension MeshResource {
    // call this to create a 2-sided mesh that will then be displayed 
    func addingInvertedNormals() throws -> MeshResource {
        return try MeshResource.generate(from: contents.addingInvertedNormals())
    }
    
    // call this on a mesh that is already displayed to make it 2 sided
    func addInvertedNormals() throws {
        try replace(with: contents.addingInvertedNormals())
    }

    static func generateTwoSidedPlane(width: Float, depth: Float, cornerRadius: Float = 0) -> MeshResource {
        let plane = generatePlane(width: width, depth: depth, cornerRadius: cornerRadius)
        let twoSided = try? plane.addingInvertedNormals()
        return twoSided ?? plane
    }
}

public extension MeshResource.Contents {
    func addingInvertedNormals() -> MeshResource.Contents {
        var newContents = self

        newContents.models = .init(models.map { $0.addingInvertedNormals() })

        return newContents
    }
}

public extension MeshResource.Model {
    func partsWithNormalsInverted() -> [MeshResource.Part] {
        return parts.map { $0.normalsInverted() }.compactMap { $0 }
    }
    
    func addingParts(additionalParts: [MeshResource.Part]) -> MeshResource.Model {
        let newParts = parts.map { $0 } + additionalParts
        
        var newModel = self
        newModel.parts = .init(newParts)
        
        return newModel
    }
    
    func addingInvertedNormals() -> MeshResource.Model {
        return addingParts(additionalParts: partsWithNormalsInverted())
    }
}

public extension MeshResource.Part {
    func normalsInverted() -> MeshResource.Part? {
        if let normals, let triangleIndices {
            let newNormals = normals.map { $0 * -1.0 }
            var newPart = self
            newPart.normals = .init(newNormals)
            // ordering of points in the triangles must be reversed,
            // or the inversion of the normal has no effect
            newPart.triangleIndices = .init(triangleIndices.reversed())
            // id must be unique, or others with that id will be discarded
            newPart.id = id + " with inverted normals"
            return newPart
        } else {
            print("No normals to invert, returning nil")
            return nil
        }
    }
}

struct MagicRealityKitClientSystemComponent : Component {}

public extension LayerRenderer.Drawable {
    func _extractFrustumTangents(_ P: simd_float4x4) -> simd_float4 {
        let m00 = P[0,0]
        let m11 = P[1,1]
        let m02 = P[2,0]
        let m12 = P[2,1]
        
        // Near plane distance is not directly recoverable from the projection matrix, so we assume n = 1 for computing normalized tangents
        let n: Float = 1.0

        // Reverse the matrix math to get the tangents
        let right  =  n * (1 + m02) / m00
        let left   =  n * (-1 + m02) / m00
        let top    =  n * (1 + m12) / m11
        let bottom =  n * (-1 + m12) / m11
        
        return simd_float4(abs(left), abs(right), abs(bottom), abs(top))
    }
    
    // Calculates a view transform which is orthogonal (with no rotational component),
    // with the same aspect ratio, and can inscribe the rotated view transform inside itself.
    // Useful for converting canted transforms to ones compatible with SteamVR and legacy runtimes.
    func _cantedViewToProportionalCircumscribedOrthogonal(
        fov: AlvrFov,
        viewTransform: simd_float4x4,
        fovPostScale: Float
    ) -> (AlvrFov, simd_float4, simd_float4x4) {
        /*let viewpose_orth = Pose {
            orientation: Quat::IDENTITY,
            position: view_canted.pose.position,
        };*/

        // Calculate unit vectors for the corner of the view space
        let v0 = simd_float3(fov.left,  fov.down, -1.0);
        let v1 = simd_float3(fov.right, fov.down, -1.0);
        let v2 = simd_float3(fov.right, fov.up, -1.0);
        let v3 = simd_float3(fov.left,  fov.up, -1.0);

        // Our four corners in world space
        let orientationOnly = viewTransform.orientationOnly()
        let w0 = orientationOnly * v0;
        let w1 = orientationOnly * v1;
        let w2 = orientationOnly * v2;
        let w3 = orientationOnly * v3;

        // Project into 2D space
        let pt0 = simd_float2(w0.x * (-1.0 / w0.z), w0.y * (-1.0 / w0.z));
        let pt1 = simd_float2(w1.x * (-1.0 / w1.z), w1.y * (-1.0 / w1.z));
        let pt2 = simd_float2(w2.x * (-1.0 / w2.z), w2.y * (-1.0 / w2.z));
        let pt3 = simd_float2(w3.x * (-1.0 / w3.z), w3.y * (-1.0 / w3.z));

        // Find the minimum/maximum point values for our new frustum
        let ptsX = [pt0.x, pt1.x, pt2.x, pt3.x];
        let ptsY = [pt0.y, pt1.y, pt2.y, pt3.y];
        let inscribed_left = ptsX.reduce(Float.infinity) { min($0, $1) }
        let inscribed_right = ptsX.reduce(-Float.infinity) { max($0, $1) }
        let inscribed_up = ptsY.reduce(-Float.infinity) { max($0, $1) }
        let inscribed_down = ptsY.reduce(Float.infinity) { min($0, $1) }

        let fov_orth = AlvrFov(
            left: inscribed_left,
            right: inscribed_right,
            up: inscribed_up,
            down: inscribed_down,
        );

        // Last step: Preserve the aspect ratio, so that we don't have to deal with non-square pixel issues.
        let fov_orth_width = abs(fov_orth.right) + abs(fov_orth.left);
        let fov_orth_height = abs(fov_orth.up) + abs(fov_orth.down);
        let fov_orig_width = abs(fov.right) + abs(fov.left);
        let fov_orig_height = abs(fov.up) + abs(fov.down);
        let scales = [
            fov_orth_width / fov_orig_width,
            fov_orth_height / fov_orig_height,
        ];

        let fov_inscribe_scale = max((scales.reduce(-Float.infinity) { max($0, $1) }), 1.0)
        let fov_orth_corrected = AlvrFov(
            left: fov.left * fov_inscribe_scale * fovPostScale,
            right: fov.right * fov_inscribe_scale * fovPostScale,
            up: fov.up * fov_inscribe_scale * fovPostScale,
            down: fov.down * fov_inscribe_scale * fovPostScale,
        );

        return (fov_orth_corrected, simd_float4(tan(-fov_orth_corrected.left), tan(fov_orth_corrected.right), tan(fov_orth_corrected.up), tan(-fov_orth_corrected.down)), viewTransform.translationOnly())
    }
    
    func gimmeTangents(viewIndex: Int) -> simd_float4 {
        if #available(visionOS 2.0, *) {
            let mat = self.computeProjection(viewIndex: viewIndex)

            // TODO: make this work
            //let renderTangents: [simd_float4] = [simd_float4(1.73205, 1.0, 1.0, 1.19175), simd_float4(1.0, 1.73205, 1.0, 1.19175)]
            //return renderTangents[viewIndex]
            let res = self._extractFrustumTangents(mat)
            print("tangents", res)
            return res
        }
        else {
            return self.views[viewIndex].tangents
        }
    }
}
