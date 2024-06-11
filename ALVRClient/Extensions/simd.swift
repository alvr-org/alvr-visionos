//
//  Extensions/simd.swift
//

import Spatial

extension simd_float3
{
    func asArray3() -> (Float, Float, Float)
    {
        return (self.x, self.y, self.z)
    }
    
    func asFloat4() -> simd_float4
    {
        return simd_float4(self.x, self.y, self.z, 0.0)
    }
}

extension simd_float4
{
    func asArray3() -> (Float, Float, Float)
    {
        return (self.x, self.y, self.z)
    }
    
    func asFloat3() -> simd_float3
    {
        return simd_float3(self.x, self.y, self.z)
    }
}

extension simd_quatd
{
    func toQuatf() -> simd_quatf
    {
        return simd_quatf(ix: Float(self.vector.x), iy: Float(self.vector.y), iz: Float(self.vector.z), r: Float(self.vector.w))
    }
}

func simd_look(at: SIMD3<Float>, up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) -> simd_float4x4 {
    let zAxis = normalize(at)
    let xAxis = normalize(cross(up, zAxis))
    let yAxis = normalize(cross(zAxis, xAxis))
    
    return simd_float4x4(
        simd_float4(xAxis, 0),
        simd_float4(yAxis, 0),
        simd_float4(zAxis, 0),
        simd_float4(0, 0, 0, 1)
    )
}
