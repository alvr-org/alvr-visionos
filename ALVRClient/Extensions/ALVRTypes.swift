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
}
