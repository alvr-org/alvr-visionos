//
//  ShaderTypes.h
//

//
//  Header containing types and enum constants shared between Metal shaders and Swift/ObjC source
//
#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexMeshPositions = 0,
    BufferIndexMeshGenerics  = 1,
    BufferIndexUniforms      = 2
};

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition  = 0,
    VertexAttributeTexcoord  = 1,
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexColor    = 0,
};

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 modelViewMatrix;
    simd_float4 tangents;
} Uniforms;

typedef struct
{
    Uniforms uniforms[2];
} UniformsArray;

#endif /* ShaderTypes_h */

typedef NS_ENUM(EnumBackingType, ALVRFunctionConstant)
{
    ALVRFunctionConstantFfrEnabled = 100,
    ALVRFunctionConstantFfrCommonShaderTargetResolution = 101,
    ALVRFunctionConstantFfrCommonShaderOptimizedResolution = 102,
    ALVRFunctionConstantFfrCommonShaderEyeSizeRatio = 103,
    ALVRFunctionConstantFfrCommonShaderCenterSize = 104,
    ALVRFunctionConstantFfrCommonShaderCenterShift = 105,
    ALVRFunctionConstantFfrCommonShaderEdgeRatio = 106,
};
