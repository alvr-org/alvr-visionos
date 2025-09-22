//
//  Extensions/simd.swift
//

import Spatial

extension Float {
    func isUnsanitary() -> Bool {
        return self.isNaN || self.isInfinite || self.isSubnormal
    }
}

extension Double {
    func isUnsanitary() -> Bool {
        return self.isNaN || self.isInfinite || self.isSubnormal
    }
}

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
    
    func asFloat4_1() -> simd_float4
    {
        return simd_float4(self.x, self.y, self.z, 1.0)
    }
    
    func asFloat4x4() -> matrix_float4x4
    {
        var ret = matrix_identity_float4x4
        ret.columns.3 = self.asFloat4_1()
        return ret
    }
    
    func isUnsanitary() -> Bool {
        return self.x.isUnsanitary() || self.y.isUnsanitary() || self.z.isUnsanitary()
    }
    
    func asSanitized() -> simd_float3 {
        return simd_float3((self.x.isUnsanitary()) ? 0.0 : self.x,
            (self.y.isUnsanitary()) ? 0.0 : self.y,
            (self.z.isUnsanitary()) ? 0.0 : self.z)
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
    
    func isUnsanitary() -> Bool {
        return self.x.isUnsanitary() || self.y.isUnsanitary() || self.z.isUnsanitary() || self.w.isUnsanitary()
    }
    
    func asSanitized() -> simd_float4 {
        return simd_float4((self.x.isUnsanitary()) ? 0.0 : self.x,
            (self.y.isUnsanitary()) ? 0.0 : self.y,
            (self.z.isUnsanitary()) ? 0.0 : self.z,
            (self.w.isUnsanitary()) ? 0.0 : self.w)
    }
}

extension simd_float3x3 {
    func isUnsanitary() -> Bool {
        return self.columns.0.isUnsanitary() || self.columns.1.isUnsanitary() || self.columns.2.isUnsanitary()
    }
    
    func asSanitized() -> simd_float3x3 {
        if self.isUnsanitary() {
            return simd_float3x3()
        }
        return self
    }
    
    func asFloat4x4() -> simd_float4x4 {
        return simd_float4x4(self.columns.0.asFloat4(), self.columns.1.asFloat4(), self.columns.2.asFloat4(), simd_float4(0.0, 0.0, 0.0, 1.0))
    }
}

extension simd_float4x4
{
    func orientationOnly() -> simd_float3x3 {
        return simd_float3x3(self.columns.0.asFloat3(), self.columns.1.asFloat3(), self.columns.2.asFloat3())
    }
    
    func translationOnly() -> simd_float4x4 {
        return simd_float4x4(simd_float4(1.0, 0.0, 0.0, 0.0), simd_float4(0.0, 1.0, 0.0, 0.0), simd_float4(0.0, 0.0, 1.0, 0.0), self.columns.3)
    }
    
    func isUnsanitary() -> Bool {
        return self.columns.0.isUnsanitary() || self.columns.1.isUnsanitary() || self.columns.2.isUnsanitary() || self.columns.3.isUnsanitary()
    }
    
    func asSanitized() -> simd_float4x4 {
        if self.isUnsanitary() {
            return simd_float4x4()
        }
        return self
    }
}

extension simd_quatf
{
    func isUnsanitary() -> Bool {
        return self.vector.x.isUnsanitary()
            || self.vector.y.isUnsanitary()
            || self.vector.z.isUnsanitary()
            || self.vector.w.isUnsanitary()
    }
    
    func asSanitized() -> simd_quatf {
        // TODO: simplify this by taking the length and checking for 1 or something?
        if self.isUnsanitary() {
            return simd_quatf()
        }
        return self
    }
}

extension simd_quatd
{
    func toQuatf() -> simd_quatf
    {
        return simd_quatf(ix: Float(self.vector.x), iy: Float(self.vector.y), iz: Float(self.vector.z), r: Float(self.vector.w))
    }
    
    func isUnsanitary() -> Bool {
        return self.vector.x.isUnsanitary()
            || self.vector.y.isUnsanitary()
            || self.vector.z.isUnsanitary()
            || self.vector.w.isUnsanitary()
    }
    
    func asSanitized() -> simd_quatd {
        // TODO: simplify this by taking the length and checking for 1 or something?
        if self.isUnsanitary() {
            return simd_quatd()
        }
        return self
    }
}

extension Float {
    func clamp(_ min: Float, _ max: Float) -> Float {
        if self < min {
            return min
        }
        if self > max {
            return max
        }
        return self
    }
    
    func clamp(_ min: Double, _ max: Double) -> Float {
        if self < Float(min) {
            return Float(min)
        }
        if self > Float(max) {
            return Float(max)
        }
        return self
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
