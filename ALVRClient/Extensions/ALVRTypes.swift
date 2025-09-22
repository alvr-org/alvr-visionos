//
//  Extensions/ALVRTypes.swift
//

import Spatial

extension AlvrQuat
{
	init(_ q: simd_quatf)
	{
		self.init(x: q.vector.x, y: q.vector.y, z: q.vector.z, w: q.vector.w)
	}
 
    func asQuatf() -> simd_quatf {
        return simd_quatf(ix: self.x, iy: self.y, iz: self.z, r: self.w)
    }
}

extension AlvrPose
{
    init() {
        self.init(simd_quatf(), simd_float3())
    }

    init(_ q: simd_quatf, _ p: simd_float3) {
        self.init(orientation: AlvrQuat(q), position: p.asArray3())
    }
    
    init(_ q: simd_quatf, _ p: simd_float4) {
        self.init(orientation: AlvrQuat(q), position: p.asArray3())
    }
    
    func asFloat4x4() -> simd_float4x4 {
        return simd_float3(self.position.0, self.position.1, self.position.2).asFloat4x4() * simd_float4x4(self.orientation.asQuatf())
    }
}
